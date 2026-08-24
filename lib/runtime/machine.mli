(** The evaluator machine: open-recursion cells plus instrumentation.

    {1 Open recursion}

    [eval], [apply], and [eval_list] are held in mutable cells, and every call
    between them goes through this module. No member of the group ever calls
    another directly, and no closure retains a direct reference to one. This is
    the invariant the whole tower rests on (spec §D3): a meta level that replaces
    the [eval] cell must intercept {e every} nested evaluation step, not just the
    one at the top. An evaluator with a direct self-reference produces a
    meta-patch that fires once and looks almost right, which is the most
    expensive mistake on the spec's list of traps.

    Doing it now rather than when the tower arrives is deliberate: retrofitting
    open recursion means revisiting every recursive call site in the evaluator,
    and the failure it causes is silent.

    {1 Instrumentation}

    Every dereference, call, and constructor dispatch is counted. The counters
    are the raw material for the §9.2 step metrics and the collapse report, which
    has to say how many eval-cell dereferences and dispatch sites survived
    specialization.

    Instrumentation is observationally inert: counters are integers that no Ash
    value, error, identifier, or output can depend on. Nothing in the evaluator
    may read them. *)

open Ash_core

type cont = Value.value -> Value.answer
type args_cont = Value.value list -> Value.answer

type t
(** One evaluator level: its group cells and its counters. Task 4.1 gives each
    materialized tower level its own, with cloned globals. *)

and eval_fn = t -> Core.t -> Value.env -> cont -> Value.answer
and apply_fn = t -> call_site:Span.t -> Value.value -> Value.value list -> cont -> Value.answer
and eval_list_fn = t -> Core.t list -> Value.env -> args_cont -> Value.answer

val create : eval:eval_fn -> apply:apply_fn -> eval_list:eval_list_fn -> t

(** {1 Calling the group}

    These are the dereference points. Every recursive call inside the evaluator
    goes through one of them, so replacing a cell takes effect from the very next
    step. *)

val eval : t -> Core.t -> Value.env -> cont -> Value.answer
val apply : t -> call_site:Span.t -> Value.value -> Value.value list -> cont -> Value.answer
val eval_list : t -> Core.t list -> Value.env -> args_cont -> Value.answer

(** {1 Replacing the group}

    Replacing a cell is what a meta level does. The replacement receives the
    machine, so it can call back into the group and see any further
    replacement. *)

val set_eval : t -> eval_fn -> unit
val set_apply : t -> apply_fn -> unit
val set_eval_list : t -> eval_list_fn -> unit
val current_eval : t -> eval_fn
val current_apply : t -> apply_fn
val current_eval_list : t -> eval_list_fn

(** {1 Global environment} *)

val set_global_env : t -> Value.env -> unit
(** Set the explicit environment of the top-level evaluation. [run] executes
    accepted Code here, never in the lexical environment of its call site. *)

val global_env : t -> Value.env

(** {1 Counters} *)

val count_dispatch : t -> Core.shape -> unit
(** Record that the default evaluator dispatched on this form. Called by the
    evaluator; a replacement that handles a form itself does not count here,
    which is exactly what the collapse report wants to know. *)

val count_named_var_lookup : t -> unit
val steps : t -> int
(** Total group calls: every [eval], [apply], and [eval_list]. *)

val eval_calls : t -> int
val apply_calls : t -> int
val eval_list_calls : t -> int

val cell_dereferences : t -> int
(** How many times a group cell was read. Equal to {!steps} while the group is
    the default one; the collapse report counts the ones that survive. *)

val named_var_lookups : t -> int
val dispatches : t -> (string * int) list
(** Per-form dispatch counts, in {!Ash_core.Core.kind_names} order. *)

val total_dispatches : t -> int
val reset_counters : t -> unit
