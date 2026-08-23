(** Printing Core in the canonical notation {!Core_reader} reads.

    {1 Deterministic readable binders}

    Core binders are identities, and several of them can print alike. Printing
    them by name alone silently changes meaning: two different [x] bindings in
    nested scopes would read back as one. The printer therefore renames as it
    goes, and it renames further than strictly necessary — {b a printed binder
    never shadows a name already visible}. Within any scope, one printed name
    denotes exactly one binder, so the output can be read back with nothing but
    the free names in hand, and a reader looking at it never has to work out
    which [x] is meant.

    The name chosen for a binder is its own printed name if that is free, and
    otherwise that name with the smallest number appended that is not. The choice
    depends only on the term's shape and the names in it, so printing is
    deterministic: the same term always prints identically, and printing
    {!Alpha.canonicalize}d terms gives a form in which alpha-equivalent terms
    print identically too.

    {1 Round trip}

    For any term whose free identifiers have distinct, readable names,
    [Core_reader.read (to_string term)] — given a scope binding those free names —
    is alpha-equivalent to [term]. That is the law {!Core_reader} and this module
    exist to satisfy together. *)

open Ash_core

val to_sexp : Core.t -> Sexp.t
(** The term as a datum, carrying each node's span. *)

val to_string : Core.t -> string
(** The canonical notation, on one line.

    @raise Invalid_argument if two free identifiers of [term] print alike, or if
    a free identifier's printed name is not a readable atom. Such a term has no
    faithful written form: no reading scope could tell the two apart. Binder
    names are renamed anyway, so an unreadable one is replaced rather than
    rejected. *)

val free_scope : Core.t -> Core_reader.scope
(** A reading scope binding each free identifier of [term] to itself, which is
    what reading [to_string term] back needs. *)
