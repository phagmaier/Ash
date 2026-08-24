(** What one collapse measurement records (spec §9.1, §9.2, §9.4).

    Three runs of one program, plus a walk of what specialization left behind:

    - the {b source} run, on the ground evaluator, which is what the program
      means;
    - the {b tower} run at a stated depth, where every step of level 0 is a term
      some level above has to evaluate — the cost the collapser exists to remove;
    - the {b specialization}, which is the specializer's own work, and the
      {b residual} run, which is what the collapsed program costs.

    Every number here is either a counter the evaluator already keeps or a walk
    of an AST. Gathering them is observationally inert: no Ash value, output,
    identifier, or error depends on a counter (AGENTS, invariant on
    instrumentation).

    What this module does {e not} claim: the residual is produced by specializing
    the program, not by specializing the tower configuration. Erasing a level's
    interposed evaluator is static reflective collapse, which is Phase 9. The
    tower figures are here as the measured cost that collapse is set against,
    and the report says so in as many words. *)

open Ash_core
open Ash_runtime

type outcome = Answered of Value.value | Failed of Error.t

val outcome_to_string : outcome -> string

type agreement =
  | Agrees
  | Differs
  | Incomparable
      (** One of the answers carries identity — a closure, continuation,
          reifier, environment, or cell. Two runs allocate two of those, and
          closure equality is identity (§D1), so they cannot be compared across
          runs at all. Proving a residual {e function} right means applying it,
          which is a test's job and not a report's; saying "agrees" here on the
          strength of matching lambda syntax would be claiming more than was
          checked. *)

val agreement : outcome -> outcome -> agreement
(** Whether two runs of one program produced the same answer. *)

type run = {
  outcome : outcome;
  steps : int;  (** Evaluator group calls: every [eval], [apply], [eval_list]. *)
  output : Io.event list;  (** What the run observably did, in order. *)
}

type level_cost = {
  index : int;
  steps : int;
  cell_dereferences : int;
      (** Reads of this level's own evaluator-group cells. At depth [n] the read
          at level 0 returns an interposed Ash term rather than the default
          evaluator, which is what makes the level above do the work. *)
}

type tower = {
  depth : int;
  run : run;  (** Measured at level 0, which is where the program runs. *)
  levels : level_cost list;
      (** Each materialized level, level 0 first. Level 0's step count is
          invariant in depth (the transparency law); the levels above it are the
          machinery the collapser exists to remove. *)
  open_dereferences : int;
      (** [open_deref] calls performed: dereferences of an {e Ash}-level open
          group, which is what an interpreter written in Ash costs. Zero for the
          interposed identity interpreter, which is a host closure in a host
          cell. *)
  dispatches : int;  (** Core-constructor dispatches performed, all levels. *)
  named_var_lookups : int;
}

type specialization = {
  steps : int;
  dispatches : (string * int) list;  (** Per Core form, in declaration order. *)
  total_dispatches : int;
  named_var_lookups : int;
  open_dereferences : int;
  specialization_points : int;
      (** Residual functions the specializer introduced because unrolling the
          call again would not have ended (task 6.1). Zero is the stronger
          result: it says every recursion in the program was decided at
          specialization time. *)
  memoized_calls : int;
      (** Calls emitted to those residual functions. *)
  generalizations : int;
      (** Arguments marked dynamic under budget pressure (task 6.2). Zero is the
          stronger result: §7.5's argument is that a program which collapses
          without generalizing says more than one that does not. *)
  generalization_reasons : Ash_stage.Specialize.generalization list;
      (** Each of those decisions: the function, the parameter given up, and the
          pressure that forced it. *)
  output : Io.event list;
      (** Must be empty. Specialization that prints is the trap §D7 exists to
          prevent, so the report shows this rather than assuming it. *)
}

type residual = { term : Core.t; residue : Residue.t; run : run }

type t = {
  name : string;
  file : string;
  program : Core.t;  (** The program, lowered and resolved against {!globals}. *)
  globals : Value.env;
      (** The tower's own ground globals, which every run above shared. A caller
          that wants to run the residual itself — applying a residual function to
          arguments is the only way to check a {!Incomparable} answer — needs
          exactly this environment: a term resolved against some other globals
          list is not resolved against this one. *)
  sizes : Ash_tower.Tower.size_metrics;
  source : run;
  tower : tower;
  specialization : specialization;
  residual : (residual, Error.t) result;
      (** [Error] when the program is outside the fragment the specializer
          handles; the report names the failure instead of pretending to a
          residual. *)
}

type program =
  | Surface of string  (** Ash source, parsed and lowered by the front end. *)
  | Core_notation of string  (** Core in the canonical notation. *)

val measure :
  ?depth:int ->
  ?budget:Ash_stage.Specialize.budget ->
  file:string ->
  name:string ->
  program ->
  t
(** Read [program], and measure it at [depth] (default 1). The program is
    resolved against a fresh tower's own ground globals, so every run shares one
    set of hygienic identities and one buffered output stream — which is why the
    text is read here rather than taken already lowered.

    [budget] applies to the specialization step only and is restored afterwards.
    It is the knob that makes a generalization observable in a report: the
    default budget is deliberately far above anything a working program reaches.
    @raise Ash_core.Error.Ash_error if the source does not read or lower. *)
