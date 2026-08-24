(** The staged CPS evaluator supporting identity and lifting modes (spec §7.3).

    In {!Mode.Identity} mode, this evaluator behaves as the standard production
    CPS evaluator.

    In {!Mode.Lift} mode, a primitive folds when its {!Effect_class} permits it
    and everything it inspects is static (see {!Stage_value.may_fold}), dynamic
    conditionals and dynamic applications residualize {!Value.Code}, and static
    values crossing into residual code are reified: a closure into its lambda
    syntax with a specialized body, a list into a residual [list] call over
    reified elements, everything else through [lift].

    Calls are inlined by default, which is what collapses recursion the
    specializer can decide. A call whose key is already being inlined is a cycle
    with no end, so it becomes a memoized specialization point instead: a
    residual function bound by a [LetRec], parameterised on exactly the argument
    positions nothing is known about. See {!Specialize}. *)

open Ash_core
open Ash_runtime

val eval_default :
  Mode.t ->
  Machine.t ->
  Core.t ->
  Value.env ->
  (Value.value -> Value.answer) ->
  Value.answer

val apply_default :
  Mode.t ->
  Machine.t ->
  call_site:Span.t ->
  Value.value ->
  Value.value list ->
  (Value.value -> Value.answer) ->
  Value.answer

val eval_list_default :
  Mode.t ->
  Machine.t ->
  Core.t list ->
  Value.env ->
  (Value.value list -> Value.answer) ->
  Value.answer

val machine : ?mode:Mode.t -> unit -> Machine.t
(** Create a machine wired with the open-recursion evaluator group for [mode]. *)

val run : ?mode:Mode.t -> Machine.t -> env:Value.env -> Core.t -> Value.value
(** Evaluate [node] on [machine] in [env], deriving the mode from the machine's
    evaluator wiring.  An explicitly supplied mismatching mode is rejected
    before evaluation.  In {!Mode.Lift} mode, the final answer is residual code. *)

val eval : ?mode:Mode.t -> env:Value.env -> Core.t -> Value.value
(** Convenience helper that allocates a fresh machine and evaluates [node]. *)

val fold : env:Value.env -> Core.t -> Core.t
(** Evaluate [node] in {!Mode.Lift} mode and return the resulting residual or
    constant-folded {!Core.t}. *)
