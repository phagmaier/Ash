(** The runtime value domain, plus the environment, frame, and cell types the
    evaluator threads through it.

    [Code] lives in the same domain as everything else. That is what makes the
    §7 collapser {e online} rather than a separate abstract interpreter: a static
    value is a real value, a dynamic value is [Code], and one evaluator handles
    both.

    Environments and cells are defined here rather than in their own module
    because they are mutually recursive with [value]: a closure captures an
    environment, an environment maps identifiers to cells, and a cell holds a
    value. The operations over them — lookup, bind, extend, preallocate, assign —
    belong to [Env] (task 0.4); this module owns only the representation and the
    few mutations that must stay centralized.

    As with {!Core}, no match over {!value} in this project uses a catch-all
    case. *)

type value =
  | Num of int
  | Bool of bool
  | Str of string
  | Sym of string
  | Unit
  | List of value list  (** Immutable. Mutation goes through {!Cell}. *)
  | Closure of closure
  | Reifier of reifier
  | Continuation of continuation
  | Environment of env  (** Environments are first class: reifiers receive one. *)
  | Cell of cell
  | Code of Core.t  (** The staging domain. *)
  | Primitive of primitive

and answer = value
(** The result of running a CPS computation to completion (the spec's [Ans]).
    Evaluator continuations are invoked in tail position, so OCaml's guaranteed
    tail-call optimization keeps CPS evaluation in constant host stack. Widening
    this to carry, say, an error channel would change the evaluator's type and
    needs a decision record. *)

and closure = {
  clo_lambda : Core.lambda;
  clo_env : env;
  clo_name : Ident.t option;  (** For diagnostics only; never for identity. *)
}

and reifier = {
  reif_def : Core.reifier;
  reif_env : env;
  reif_name : Ident.t option;
}

and continuation = private {
  cont_invoke : value -> answer;
  mutable cont_used : bool;
      (** One-shot enforcement (spec §D4) is dynamic: the flag is set {e before}
          transfer, so a continuation that re-invokes itself is caught too. *)
  cont_capture : Span.t;  (** Where the continuation was captured. *)
  cont_level : int;
      (** The meta-context: the tower level whose evaluation this continuation
          resumes, counted relative to the base program (spec §D9). A reifier
          runs at level [n + 1] holding the continuation of level [n], so a
          continuation that did not know its own level could be resumed on the
          wrong machine. Only level 0 exists before Phase 4; the field is here
          from the start because retrofitting it means revisiting every capture
          site. *)
  mutable cont_first_use : Span.t option;
      (** Where it was first invoked, so a second invocation can name both
          sites. *)
}

and env = frame list
(** A chain of lexical frames, innermost first. *)

and frame = { bindings : cell Ident.Map.t }

and cell = private { mutable contents : value option }
(** [None] means preallocated but not yet filled, which [LetRec] needs and which
    must be reported explicitly rather than read as some default value. Cells
    have identity: two cells with equal contents are still different cells, so
    compare them with {!same_cell}. *)

and primitive = {
  prim_name : string;
  prim_arity : arity;
  prim_class : Effect_class.t;
      (** Exactly one class per primitive; see {!Effect_class} and spec §D7. *)
  prim_impl :
    call_site:Span.t -> apply:applier -> value list -> (value -> answer) -> answer;
      (** In CPS so that control primitives are ordinary members of the registry
          rather than evaluator special cases. [call_site] is where the
          application was written: a primitive that rejects an argument has no
          other location to report, and a diagnostic without one is not much of a
          diagnostic. Arity is checked by the applying evaluator, so every
          primitive reports arity the same way; a primitive still checks its own
          argument types.

          [apply] is how a primitive calls an Ash function — what [callcc] needs
          to hand a captured continuation to its argument. The caller supplies
          it, so the call goes through whatever evaluator is running: the ground
          evaluator routes it through the machine's open-recursion cell (spec
          §D3), and a replaced [apply] therefore intercepts a primitive's call
          too. A primitive that never calls back ignores it. *)
}

and applier = call_site:Span.t -> value -> value list -> (value -> answer) -> answer
(** Applying an Ash callee to arguments, in CPS. *)

and arity = Exactly of int | At_least of int

(** {1 Constants} *)

val of_constant : Constant.t -> value
(** [Nil] becomes the empty {!List}: the empty list is a value shape, not a
    separate runtime constant. *)

val to_constant : value -> Constant.t option
(** The inverse where one exists. A non-empty list, closure, cell, and so on have
    no constant form and yield [None]. *)

(** {1 Cells} *)

val cell : value -> cell
(** A filled cell. *)

val preallocated_cell : unit -> cell
(** An unfilled cell, for [LetRec]. Reading it before it is filled is an error the
    evaluator must report, never a silent default. *)

val cell_contents : cell -> value option
val is_filled : cell -> bool

val fill_cell : cell -> value -> unit
(** The one supported mutation of a cell. Centralized here because Ash cells are
    the only mutable part of the value domain, and every store-discipline
    argument in Phase 7 depends on knowing where mutation can happen. *)

val same_cell : cell -> cell -> bool
(** Cell identity, which is what aliasing means. *)

(** {1 Continuations} *)

val continuation : capture:Span.t -> level:int -> (value -> answer) -> continuation
val continuation_used : continuation -> bool
val continuation_capture_site : continuation -> Span.t
val continuation_level : continuation -> int
val continuation_first_use : continuation -> Span.t option

val mark_continuation_used : continuation -> at:Span.t -> unit
(** Record a use. Callers must do this {e before} transferring control. Marking an
    already-used continuation is allowed here and leaves the recorded first-use
    site alone: detecting and reporting the reuse is the caller's job (task 1.5),
    and this function must not lose the evidence that report needs. *)

(** {1 Environments} *)

val empty_env : env

val frame_of_list : (Ident.t * cell) list -> frame
(** @raise Invalid_argument if two entries share a binder identity, which would
    otherwise silently drop one of them. Entries that merely share a printed name
    are fine. *)

val push_frame : frame -> env -> env

(** {1 Arities} *)

val arity_matches : arity -> int -> bool
val arity_to_string : arity -> string

(** {1 Description} *)

val type_name : value -> string
(** The bare name of a value's shape, e.g. ["closure"]. Exhaustive over
    {!value}. *)

val type_phrase : value -> string
(** The noun phrase diagnostics use, e.g. ["a closure"], ["the empty list"]. *)

val equal : value -> value -> bool
(** Ash-level equality, as the [==] primitive computes it: scalars and lists
    compare structurally, and everything carrying identity compares by identity,
    because two closures with the same body are still two closures. Primitives
    compare by name, so the same primitive drawn from two cloned global
    environments is the same value.

    [Code] compares by alpha-equivalence: binder allocation order and printed
    parameter choices are not observations of generated code. *)

val to_string : value -> string
(** A diagnostic rendering. Scalars and lists print structurally; everything with
    identity prints opaquely as [#<closure fact>] and similar. Cell and closure
    contents are deliberately not followed: the value graph is cyclic as soon as a
    recursive function exists. *)

val pp : Format.formatter -> value -> unit
