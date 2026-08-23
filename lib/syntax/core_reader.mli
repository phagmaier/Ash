(** The canonical Core s-expression reader.

    This is the debug and test notation for Core, not the Ash surface parser.
    Every Core form has exactly one spelling, so a term written here is
    unambiguous and a printed term reads back as itself:

    {v
    (lit 42)  (lit #t)  (lit "s")  (lit 'sym)  (lit unit)  (lit nil)
    (var x)
    (named-var "x")
    (lam (x y) body)
    (app f arg ...)
    (let x value body)
    (letrec ((f (lam (n) body)) ...) body)
    (if condition consequent alternative)
    (set x value)
    (quote core)
    (reifier (exp env cont) body)
    v}

    {1 Names and identity}

    The notation is written in printed names, but Core is hygienic, so the reader
    resolves names to identities as it goes. Each binder allocates a fresh
    {!Ash_core.Ident.t}, and a [(var x)] under it reads as that identity — so
    reading the same text twice yields alpha-equivalent but not equal terms, which
    is exactly right. A name with no binder in scope is an error unless a scope
    supplies it, because there is no identity to give it.

    Quoted code is read in the enclosing scope, so a quoted variable carries the
    binder ID of the binding it was written under (spec §D1). [(named-var "x")]
    is the deliberate exception: it names a string and is resolved against a
    first-class environment at evaluation time.

    One binder list may not bind a printed name twice. The reader has only names
    to work with, so allowing it would make resolution depend on the order
    bindings were entered, and would build a frame no name lookup could
    resolve. *)

open Ash_core

type scope
(** Printed names visible to a read, mapping to the identities they denote. *)

val empty_scope : scope
val scope_of_list : (string * Ident.t) list -> scope
val scope_find : scope -> string -> Ident.t option

val read_sexp : ?scope:scope -> Sexp.t -> Core.t
(** @raise Error.Ash_error with phase {!Error.Read} and a located cause. *)

val read : ?scope:scope -> ?file:string -> string -> Core.t
(** Read exactly one Core term from [string]. *)

val read_all : ?scope:scope -> ?file:string -> string -> Core.t list
(** Read every Core term in [string], each in the same starting scope. *)
