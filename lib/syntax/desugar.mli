(** Lowering the surface language of spec §4 to the eleven Core forms.

    This is where names become identities. The parser works in printed strings
    because that is all source text has; the desugarer walks the binding
    structure once, allocates one {!Ash_core.Ident.t} per binder, and resolves
    every occurrence through it. Hygiene is therefore not a pass that runs
    afterwards — a term that leaves this module cannot capture, because a
    generated binder and a user binder that print alike are already different
    identities (spec §D1).

    {1 What lowers to what}

    {v
    e1 <newline|;> e2      Let _ = e1 in e2
    let x = v; rest        Let x = v in rest
    var x = v; rest        Let x = v in rest, with x assignable
    x := v                 Set x v
    fn f(a) = b; rest      LetRec ((f (Lam (a) b))) rest
    fn(a) -> b             Lam (a) b
    a && b                 If a b false
    a || b                 If a true b
    !a / -a                not(a) / 0 - a
    a <op> b               <primitive>(a, b)
    [a, b]                 list(a, b), and [] is the Nil literal
    x |> f(a)              f(x, a), and x |> f is f(x)
    match s { ... }        nested If over shape/empty?/head/tail/== tests
    `{ e }                  Quote template, plus pure code_splice calls for holes
    Lit(p), App(p,p), ...   guarded code_view plus ordinary nested patterns
    `{ ${p} ... }           alpha-aware code_match plus nested hole patterns
    v}

    Adjacent [fn] declarations in one statement list form a single [LetRec]
    group, so mutual recursion is written by writing it. A statement list whose
    last statement is a definition evaluates to unit: a file of definitions is a
    legal program.

    {1 Primitives}

    Operators, list literals, and match tests lower to calls of named
    primitives, so the caller must supply the global bindings those names denote
    — see {!scope_of_globals} and {!required_primitives}. Generated calls resolve
    against the globals directly rather than through the lexical scope, so a
    program that binds its own [length] or [head] still gets the primitive in the
    code the desugarer writes, and its own binding everywhere it wrote one.

    {1 Provenance}

    A Core node that corresponds to a surface node of the same shape keeps that
    node's span unchanged. A node the desugarer invents — the [Let] behind a
    statement separator, the [If] behind [&&], everything behind [match] — keeps
    the same positions and adds a {!Ash_core.Span.Generated} marker naming the
    rewrite, so a diagnostic still points at user text while
    {!Ash_core.Span.generators} says which rewrite produced the node.

    {1 Code and hygiene}

    A quotation template uses fresh free [Var] identities as splice markers.
    [code_splice] replaces an exact marker identity, so inserting code beneath a
    same-printed binder cannot capture it. Quoted binders are visible to nested
    quotations inside splice expressions, which is what staged builders such as
    [power] need. Unbound names are permitted inside a quotation and receive a
    fresh hygienic identity; outside quotation, a free surface name remains a
    desugar error rather than an implicit [NamedVar]. Runtime string lookup is
    requested explicitly with the pure [NamedVar] Code constructor.

    List, constructor, and quasiquote patterns are refutable on a wrong value
    shape. Constructor patterns destructure immutable [Code] through [code_view];
    quasiquotes use alpha-aware [code_match]. *)

open Ash_core

type scope
(** The names a term is lowered under: the lexical bindings in scope, each with
    the identity it denotes and whether it may be assigned, plus the global
    bindings generated code resolves against. *)

val empty_scope : scope
(** No globals. Only terms that use no operator, list literal, or [match] can be
    lowered under it. *)

val scope_of_globals : (string * Ident.t) list -> scope
(** The initial scope of a program: every global is visible lexically and is
    also what generated code refers to. Globals are immutable, so [:=] on one is
    an error rather than a way to redefine a primitive.
    @raise Invalid_argument if two globals share a printed name, which would make
    the choice between them arbitrary. *)

val required_primitives : string list
(** Every primitive name the desugarer can emit, in one list so that a registry
    and this module cannot drift apart silently. *)

(** {1 Lowering}

    Both raise {!Ash_core.Error.Ash_error} with phase
    {!Ash_core.Error.Desugar} and a located cause: an unbound name, an
    assignment to an immutable binding, a repeated binder in one binder list,
    or inconsistent alternative arms. *)

val expression : ?scope:scope -> Surface.t -> Core.t
(** Lower one statement-shaped expression, as {!Parser.expression} produces. A
    lone definition lowers like a one-statement program and evaluates to unit. *)

val program : ?scope:scope -> Surface.program -> Core.t
(** Lower a statement list to a single Core term. The empty program is the unit
    literal at {!Ash_core.Span.unknown}, there being no source to point at. *)
