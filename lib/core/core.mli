(** The Core language: the eleven forms the self-interpreter handles.

    Core is deliberately closed. Every later layer — the oracle, the CPS
    evaluator, the self-interpreter written in Ash, the staged collapser — must
    handle exactly these shapes, so a match over {!shape} is always written out in
    full. There is no catch-all case anywhere in this library: adding a form must
    be a compile error at every site that interprets one, not a silent fallthrough
    into default behaviour.

    Every node carries a {!Span.t}. A node a later phase invents keeps the span of
    the source it came from plus a generated marker, so provenance survives all
    the way into the residual program. Spans are metadata: they take no part in
    the meaning of a term, and semantic comparison must ignore them. *)

type t = { shape : shape; span : Span.t }

and shape =
  | Lit of Constant.t  (** A literal constant. *)
  | Var of Ident.t
      (** A hygienic variable: resolved through the binder's identity, never its
          printed name. *)
  | NamedVar of string
      (** A reflective variable: resolved by printed name against a first-class
          environment at evaluation time. A distinct node rather than a [Var]
          with a null ID, because the specializer must see the difference — a
          [NamedVar] whose environment is not statically known is a
          specialization barrier, and the collapse report counts the ones that
          survive. *)
  | Lam of lambda
  | App of application
  | Let of let_binding
  | LetRec of letrec
      (** A Core form, not sugar: the interpreter is recursively defined and the
          specializer has to reason about recursive functions directly. *)
  | If of conditional
  | Set of assignment  (** Assignment to an existing binding's cell. *)
  | Quote of t  (** Code as data. The quoted term is not evaluated. *)
  | Reifier of reifier
      (** A procedure whose arguments are not evaluated: it runs one level up
          with the caller's expression, environment, and continuation. [up] is
          sugar over this. *)

and lambda = { params : Ident.t list; lam_body : t }
and application = { func : t; args : t list }
and let_binding = { let_binder : Ident.t; let_value : t; let_body : t }
and letrec = { rec_bindings : rec_binding list; rec_body : t }

and rec_binding = {
  rec_name : Ident.t;
  rec_lambda : lambda;
      (** Recursive bindings bind lambdas only. Enforcing that in the type keeps
          the preallocate-then-fill implementation total: evaluating a lambda
          cannot observe a sibling cell before it is filled. *)
  rec_span : Span.t;
}

and conditional = { condition : t; consequent : t; alternative : t }
and assignment = { set_target : Ident.t; set_value : t }

and reifier = {
  exp_param : Ident.t;  (** Bound to the whole unevaluated call expression. *)
  env_param : Ident.t;  (** Bound to the caller's environment. *)
  cont_param : Ident.t;  (** Bound to the caller's one-shot continuation. *)
  reifier_body : t;
}

(** {1 Constructors}

    These are the supported way to build Core. They check the shape contracts a
    well-formed term must satisfy and raise [Invalid_argument] when a host caller
    violates one — a host bug, not an Ash runtime error. *)

val lit : span:Span.t -> Constant.t -> t
val var : span:Span.t -> Ident.t -> t
val named_var : span:Span.t -> string -> t

val lambda : params:Ident.t list -> body:t -> lambda
(** @raise Invalid_argument if two parameters are the same binder. Repeating a
    printed name is fine — that is the whole point of hygienic identity — but
    repeating an identity would make the binding ambiguous. *)

val lam : span:Span.t -> params:Ident.t list -> body:t -> t

val of_lambda : span:Span.t -> lambda -> t
(** Wrap an already-built lambda as a node, for callers that construct the
    lambda first because [LetRec] needs one too. *)

val app : span:Span.t -> func:t -> args:t list -> t
val let_ : span:Span.t -> binder:Ident.t -> value:t -> body:t -> t

val rec_binding : span:Span.t -> name:Ident.t -> lambda -> rec_binding

val letrec : span:Span.t -> bindings:rec_binding list -> body:t -> t
(** @raise Invalid_argument if two bindings share a binder identity. *)

val if_ : span:Span.t -> condition:t -> consequent:t -> alternative:t -> t
val set : span:Span.t -> target:Ident.t -> value:t -> t
val quote : span:Span.t -> t -> t

val reifier_def :
  exp:Ident.t -> env:Ident.t -> cont:Ident.t -> body:t -> reifier
(** @raise Invalid_argument if the three parameters are not distinct binders. *)

val reifier :
  span:Span.t -> exp:Ident.t -> env:Ident.t -> cont:Ident.t -> body:t -> t

(** {1 Accessors and provenance} *)

val span : t -> Span.t
val shape : t -> shape

val with_span : Span.t -> t -> t
(** Replace a node's span without touching its shape. *)

val mark_generated : by:string -> t -> t
(** Record that this node was produced by phase [by], keeping the positions it
    already had. Only the node itself is marked; subterms keep their own
    provenance. *)

(** {1 Structure} *)

val kind_name : t -> string
(** The form's name for diagnostics and reports, e.g. ["named-var"]. *)

val kind_name_of_shape : shape -> string

val children : t -> t list
(** Immediate syntactic subterms, in source order. The body of a [Quote] is
    included: it is a subterm of the program text even though it is data rather
    than something evaluated in place. Callers that mean "positions this node
    evaluates" must not use this. *)

val binders : t -> Ident.t list
(** The identifiers this node itself binds over its subterms, in source order.
    Empty for nodes that bind nothing. *)

val node_count : t -> int
(** Raw AST node count, including quoted subterms. This is a syntactic size, not
    one of the §9 report metrics. *)

val equal_structure : t -> t -> bool
(** Structural equality ignoring spans, comparing identifiers by identity.

    This is {e not} alpha-equivalence: two terms that differ only by renaming are
    structurally different. Use {!Alpha.equal} to compare meaning, or compare
    {!Alpha.canonicalize}d terms with this. Spans are ignored because they are
    metadata: where a term was written has nothing to do with what it is. *)
