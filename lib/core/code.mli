(** Hygienic operations on Core values used by quotation and code patterns.

    A splice marker is an ordinary fresh identifier occurring as a free [Var]
    node in a quotation template. Replacing that exact identity cannot capture
    or be captured: binders compare by identity, never by printed name. *)

val splice : marker:Ident.t -> replacement:Core.t -> Core.t -> Core.t
(** [splice ~marker ~replacement template] replaces free [Var marker] nodes in
    expression positions with [replacement]. The replacement keeps its own
    spans and binder identities. Identifier-only positions such as a [Set]
    target are not splice positions. *)

val match_template :
  holes:Ident.t list -> template:Core.t -> Core.t -> Core.t list option
(** Match [template] against a subject up to alpha-equivalence, treating every
    free [Var] whose identity is in [holes] as a single-node wildcard. On
    success, return the captured subject nodes in [holes] order. Return [None]
    when the requested holes are repeated or absent from the template; surface
    pattern validation prevents both cases in normally lowered programs. *)
