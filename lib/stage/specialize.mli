(** Memoized specialization points (spec §7.5, to-do task 6.1).

    Inlining a function call is how the pure fragment collapses: recursion whose
    control the specializer can decide unrolls away entirely. Recursion whose
    control it cannot decide has no end to unroll to, and inlining it forever is
    the fragment's edge.

    This module is the bookkeeping that stops there instead. A call is keyed by
    {e function identity plus the static projection of its arguments}. While a
    key is being inlined it is {e active}; meeting the same key again is a cycle
    the unroller cannot leave, so that call becomes a {e specialization point}:
    a residual function whose parameters are exactly the argument positions the
    specializer knows nothing about, whose body is specialized once, and which
    the recursive call then simply calls.

    The module holds only the keys and the memo table. Building the residual
    function is the staged evaluator's job, because it needs the emitter and the
    machine. Nothing here reads or writes Ash values, so it is observationally
    inert: it changes which residual a program specializes to, never what that
    residual computes.

    Not every recursion ties a knot. One whose static argument {e grows} — an
    accumulator that conses rather than counts down — presents a fresh key every
    step, and there is no cycle to find. That is what the {e budget} is for
    (spec §7.5): deterministic limits on how deep the unroller may go and how
    much residual it may emit before it stops believing it is making progress.
    On budget pressure the specializer {e generalizes} — marks one more argument
    of the offending function dynamic and specializes under the coarser key —
    and records why. Generalizing is sticky per function and monotone, so after
    at most one generalization per parameter the key is fixed and the next call
    must find the memo table.

    All run state is cleared by {!reset}. The budget is configuration, not run
    state, and {!reset} leaves it alone. *)

open Ash_core

type projection =
  | Known of Value.value
      (** A fully static argument: specialized into the residual function's
          body, and compared with other calls by value. *)
  | Held of Value.value
      (** A value the specializer holds whose contents are partially dynamic —
          a list with a static spine and dynamic elements. Also specialized in,
          but compared by identity: two such values that look alike still stand
          for different residual expressions. *)
  | Unknown
      (** Residual code. This argument position becomes a parameter of the
          residual function. *)

type key
type point

type entry
(** A call the unroller is currently following, together with the context it
    started in: the emission blocks that were open, the specialization points
    that were visible, and the calls already being inlined. *)

val project : Value.value -> projection
(** How much of [value] a specialization may be keyed on. *)

val key : lambda:Core.lambda -> env:Value.env -> arguments:Value.value list -> key
(** The call's specialization key: the function's identity — its lambda and the
    environment it closed over — together with each argument's projection. *)

val arguments : key -> projection list
(** The key's argument projections, in call order. *)

val parameter_count : key -> int
(** How many argument positions of [key] are {!Unknown}, and so become
    parameters of the residual function. *)

val lookup : key -> point option
(** The specialization point for [key], if one is in scope here. *)

val active_entry : key -> entry option
(** The call of [key] currently being inlined, if there is one. A call whose key
    is already being inlined is the cycle the unroller must not follow: it is
    that call, not this one, that becomes the specialization point. *)

val entry_arguments : entry -> Value.value list
(** The argument values the entered call was made with. The two calls have equal
    keys, so these agree with the inner call's arguments about everything the
    specialization depends on — and unlike the inner call's, they are values the
    residual function's binding site can still refer to. *)

val with_entry_context : entry -> (unit -> 'a) -> 'a
(** Run [f] in the context [entry] was made in. A specialization point is built
    and bound where its call began, not where its cycle was discovered: at the
    discovery site the enclosing blocks may be a dynamic conditional's branch,
    and a residual function bound there could not be called from anywhere else.
    The entered call's own key is deliberately not active inside [f], so the
    recursive call reaches {!lookup} and emits a call to the point being
    defined. *)

val define : key -> Ident.t -> point
(** Record that [key] is specialized by the residual function [ident], and
    return the point. Called {e before} the residual body is specialized, so
    that the recursive call inside it finds the point and emits a call.
    @raise Invalid_argument when no scope is open. *)

val residual_name : point -> Ident.t

val count_call : unit -> unit
(** Record that a call to a specialization point was emitted. *)

val active : unit -> entry list
(** The calls currently being inlined, innermost first. *)

val enter : key -> arguments:Value.value list -> unit
(** Mark this call of [key] as being inlined, remembering the context it started
    in. *)

val restore : entry list -> unit
(** Restore the active calls to a value previously returned by {!active}. The
    staged evaluator is in CPS, so this happens in the continuation that
    receives the inlined body's value rather than after a host call returns. *)

val in_scope : (unit -> 'a) -> 'a
(** Run [f] with its own specialization-point scope: points defined inside it
    are visible to everything nested in it, and are forgotten when it ends.
    Wraps every emission block, because a point is bound by a [LetRec] inside
    that block and calling it from outside would be out of scope. *)

val reset : unit -> unit
(** Clear all run state, including the emitter's binding count. Called once per
    specialization run. The budget is left as configured. *)

(** {1 Budgets and generalization} *)

type budget = {
  max_inline_depth : int;
      (** Nested calls the unroller may follow into {e one} function before
          generalizing. Counted per function, so a program that nests many
          different functions is not mistaken for one going nowhere. *)
  max_residual_bindings : int;
      (** Residual bindings specialization may emit before generalizing. This is
          the signal that separates a deep unrolling that is working — it folds,
          and emits nothing — from one that is not. *)
}

val default_budget : budget
(** Chosen to leave the whole corpus alone: its deepest static unrolling is a
    10,000-step loop that folds to a literal. §7.5's argument is that a program
    which collapses {e without} generalizing is the stronger result, so the
    defaults are the sizes at which the specializer stops believing it is making
    progress, not sizes any correct program is expected to reach. *)

val budget : unit -> budget
val set_budget : budget -> unit
(** Configuration, not run state: {!reset} does not restore it.
    @raise Invalid_argument on a non-positive depth or negative binding limit. *)

type pressure =
  | Inline_depth of int  (** The depth limit that was reached. *)
  | Residual_size of int  (** The residual-binding limit that was reached. *)

val pressure_name : pressure -> string
(** ["inlining-depth"] or ["residual-size"], for diagnostics. *)

val pressure_limit : pressure -> int
val pressure_message : pressure -> string
(** What was true when the specializer gave up, as a clause. *)

type generalization = {
  gen_function : string;
  gen_parameter : string;
  gen_position : int;
  gen_pressure : pressure;
  gen_site : Span.t;
}

val pressure_of : key -> pressure option
(** Whether specializing this call would exceed the budget. [None] is the
    ordinary answer and means inline. *)

val generalize :
  key ->
  callee:string option ->
  parameters:Ident.t list ->
  site:Span.t ->
  pressure ->
  key option
(** Mark one more argument of this function dynamic and return the coarser key,
    or [None] when every argument is already dynamic and there is nothing left
    to give up — which is where the specializer must fail rather than diverge.

    The position chosen is the leftmost that {e differs} from the nearest
    enclosing call to the same function, because that is what the unrolling is
    following; failing that, the leftmost the specializer still knows. The
    decision is recorded against the function's identity and applies to every
    later call, so a generalization cannot be undone by the next one. *)

val reification_depth : unit -> int
(** How many closure reifications are nested here. Reifying a closure
    specializes its body, which may reify further closures; that nesting is not
    a call, so it has no key to memoize and {!max_inline_depth} is the only
    thing bounding it. *)

val with_reification : (unit -> 'a) -> 'a
(** Run [f] one reification deeper. *)

val generalizations : unit -> generalization list
(** Every generalization this run made, in the order it made them. *)

val generalization_count : unit -> int

val points_created : unit -> int
(** How many specialization points this run created: how many times the
    specializer stopped unrolling and emitted a residual function instead. *)

val memoized_calls : unit -> int
(** How many calls to specialization points this run emitted. *)
