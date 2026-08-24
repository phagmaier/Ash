(* The tower laws of spec §5.7, at depth (to-do task 4.4).

   Tasks 4.2 and 4.3 proved each mechanism once: one step up, one step back
   down, one evaluator replaced. A law is the claim that this keeps being true
   however deep the tower is, so this suite is parameterized by depth rather
   than by mechanism.

   {1 What "depth" means here}

   Materialization is lazy, and a level that exists but still holds the
   evaluator it started with is observationally indistinguishable from the
   default by construction (ADR 0022, and the inertness fast path of ADR 0024).
   A depth built out of such levels would make transparency true by definition.
   So {!Ash_tower.Depth} interposes a real Ash interpreter —
   [fn(e, r, k) -> base(e, r, k)] — at every level below the stated depth. Every
   step of level [n] is then a term level [n + 1] has to evaluate. The
   interpreter is semantically the identity; the law is that stacking it five
   deep changes nothing an Ash program can observe.

   {1 What is deliberately not compared}

   Spec §D9 excludes four channels from the equivalence, and this suite excludes
   exactly those: wall time, host stack depth, resource exhaustion, and gensym
   counters. Evaluator step counts at the levels {e above} the base program are
   the sharpest of these — they grow by roughly a factor of five per level, which
   is the measurement that makes the collapser necessary rather than a defect in
   the tower — and {!test_excluded_observations} states that exclusion as a test
   rather than as a comment, by asserting that they do differ.

   What is compared is everything else: the value, the failure's cause, span,
   phase and level, and the exact sequence of observable effects. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_tower

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let file = "laws.ash"

(* Depth 0 to 5, which is the range AGENTS.md fixes for depth tests. *)
let max_depth = 5

(* Nontermination and depth cost are both bounded by counted Ash steps, never by
   wall time. [depth_budget] caps the work one comparison may do at the top of
   the tower; a program whose base cost times the per-level multiplier exceeds it
   is compared at the depths it fits and reported at the ones it does not, so a
   skipped depth is visible rather than silent. *)
let depth_budget = 20_000_000

(* The measured cost of one interposed interpreter, used only to decide which
   comparisons to run. Under-estimating it costs time; over-estimating it costs
   coverage. Five is what `docs/progress/0002-depth-cost.md` records. *)
let per_level_multiplier = 5

let projected_steps ~base ~depth =
  let rec go value remaining =
    if remaining = 0 then value
    else if value > depth_budget then value
    else go (value * per_level_multiplier) (remaining - 1)
  in
  go base depth

(* {1 Running a program at a depth} *)

type outcome = Answered of Value.value | Failed of Error.t | Unlowerable of Error.t

let outcome_equal a b =
  match (a, b) with
  | Answered x, Answered y -> Value.equal x y
  | Failed x, Failed y | Unlowerable x, Unlowerable y ->
      Error.cause_equal x.Error.cause y.Error.cause
      && Span.equal x.Error.span y.Error.span
      && x.Error.phase = y.Error.phase
      && x.Error.level = y.Error.level
  | (Answered _ | Failed _ | Unlowerable _), _ -> false

(* Two programs that are not the same source text have their nodes at different
   positions by construction, so a law comparing one program {e against another}
   compares everything about a failure except where it was written. Depth
   comparisons, which run one program twice, use the exact {!outcome_equal}. *)
let outcome_equal_apart_from_position a b =
  match (a, b) with
  | Answered x, Answered y -> Value.equal x y
  | Failed x, Failed y | Unlowerable x, Unlowerable y ->
      Error.cause_equal x.Error.cause y.Error.cause
      && x.Error.phase = y.Error.phase
      && x.Error.level = y.Error.level
  | (Answered _ | Failed _ | Unlowerable _), _ -> false

let outcome_to_string = function
  | Answered value -> Value.to_string value
  | Failed error -> "failure: " ^ Error.to_string error
  | Unlowerable error -> "did not lower: " ^ Error.to_string error

let events_to_string events =
  String.concat ", "
    (List.map (function Io.Wrote text -> Printf.sprintf "%S" text | other -> Io.event_to_string other) events)

(* A tower, its output stream, and the names its base program is lowered under.
   Every run gets its own, because a tower is stateful and a level's globals are
   its own identities: reusing a scope across towers would resolve to nothing. *)
let fresh () =
  let io = Io.create () in
  let tower = Tower.create ~registry:(Primitives.create ~io ()) () in
  let named =
    Ident.Set.fold
      (fun ident collected -> (Ident.name ident, ident) :: collected)
      (Env.idents (Level.global (Tower.ground tower)))
      []
  in
  (tower, io, named)

let core_term text named =
  Core_reader.read ~scope:(Core_reader.scope_of_list named) ~file text

let surface_term source named =
  Desugar.program ~scope:(Desugar.scope_of_globals named) (Parser.program ~file source)

(* Everything a run of the same program at a different depth must agree about,
   plus the two numbers used for budgeting and for the exclusion test. *)
type observation = {
  outcome : outcome;
  effects : Io.event list;
  base_steps : int;  (** Level 0's own evaluator calls. *)
  top_steps : int;  (** The top level's, which is what depth costs. *)
}

let observe ~depth build =
  let tower, io, named = fresh () in
  match build named with
  | exception Error.Ash_error error ->
      { outcome = Unlowerable error; effects = []; base_steps = 0; top_steps = 0 }
  | term ->
      let outcome =
        match Depth.run tower ~depth term with
        | value -> Answered value
        | exception Error.Ash_error error -> Failed error
      in
      let steps_of level =
        match Tower.find_level tower level with
        | Some found -> Machine.steps (Level.machine found)
        | None -> 0
      in
      {
        outcome;
        effects = Io.events io;
        base_steps = steps_of 0;
        top_steps = steps_of depth;
      }

(* {1 Transparency}

   A program using no reflective operator produces identical values and
   identical observable effects at depth 0 and at depth k, for all k. *)

let compared_at = Array.make (max_depth + 1) 0
let over_budget = ref []

let transparency name build =
  let reference = observe ~depth:0 build in
  compared_at.(0) <- compared_at.(0) + 1;
  let deepest = ref 0 in
  for depth = 1 to max_depth do
    if projected_steps ~base:reference.base_steps ~depth <= depth_budget then (
      deepest := depth;
      compared_at.(depth) <- compared_at.(depth) + 1;
      let actual = observe ~depth build in
      if not (outcome_equal reference.outcome actual.outcome) then (
        incr failures;
        Printf.printf "FAIL %s at depth %d\n  depth 0: %s\n  depth %d: %s\n" name depth
          (outcome_to_string reference.outcome)
          depth
          (outcome_to_string actual.outcome));
      if not (List.equal Io.event_equal reference.effects actual.effects) then (
        incr failures;
        Printf.printf "FAIL %s: observable effects differ at depth %d\n  depth 0: [%s]\n  depth %d: [%s]\n"
          name depth
          (events_to_string reference.effects)
          depth
          (events_to_string actual.effects));
      (* Not required by the law, and stronger than it: interposing an
         interpreter does not change how much work the base program itself does,
         because the same host evaluator is still called once per step of it.
         A drift here would mean the interposition had changed the program's own
         evaluation rather than only who performs it. *)
      if not (Int.equal reference.base_steps actual.base_steps) then (
        incr failures;
        Printf.printf "FAIL %s: level 0 did different work at depth %d (%d then %d)\n" name
          depth reference.base_steps actual.base_steps))
  done;
  if !deepest < max_depth then
    over_budget := (name, reference.base_steps, !deepest) :: !over_budget

(* Observable output is the half of transparency the shared corpus does not
   exercise: it has mutation and evaluation order, but no writes. An effect has
   to reach the one stream through k interpreters, in the same order. *)
let output_programs =
  [
    ("a single write", "(app (var println) (lit 1))");
    ("writes in order",
     "(let _ (app (var println) (lit 1)) (let _ (app (var print) (lit \"a\")) (app (var println) (lit 'b))))");
    ("a write inside a recursive call",
     "(letrec ((down (lam (n) (if (app (var ==) (var n) (lit 0)) (lit 'done) (let _ (app (var println) (var n)) (app (var down) (app (var -) (var n) (lit 1)))))))) (app (var down) (lit 3)))");
    ("effects before a failure",
     "(let _ (app (var println) (lit \"before\")) (app (var /) (lit 1) (lit 0)))");
    ("a write in an argument position",
     "(app (var list) (app (var println) (lit 1)) (app (var println) (lit 2)))");
  ]

let test_transparency () =
  List.iter (fun (name, text) -> transparency ("value: " ^ name) (core_term text)) Corpus.values;
  List.iter (fun (name, text) -> transparency ("effect: " ^ name) (core_term text)) Corpus.effects;
  List.iter (fun (name, text) -> transparency ("error: " ^ name) (core_term text)) Corpus.errors;
  List.iter
    (fun (name, source) -> transparency ("surface: " ^ name) (surface_term source))
    Corpus.surface;
  List.iter
    (fun (name, source) -> transparency ("surface error: " ^ name) (surface_term source))
    Corpus.surface_errors;
  List.iter (fun (name, text) -> transparency ("output: " ^ name) (core_term text)) output_programs

(* {1 Depth observation}

   §D9: [level] is relative, so the base program is 0 however deep the tower is,
   and [tower_depth()] is the single explicit opt-in that can tell. A program
   that calls neither is in the fragment the invariance claim covers. *)

let test_depth_observation () =
  for depth = 0 to max_depth do
    let relative = observe ~depth (surface_term "tower_level()") in
    check
      (Printf.sprintf "the base program is at level 0 under a tower %d deep" depth)
      (outcome_equal relative.outcome (Answered (Value.Num 0)));
    let observed = observe ~depth (surface_term "tower_depth()") in
    check
      (Printf.sprintf "tower_depth() reports %d at depth %d" depth depth)
      (outcome_equal observed.outcome (Answered (Value.Num depth)))
  done;
  (* And the two disagree exactly where §D9 says they should: one is a fact about
     the program's position, the other about the tower it sits in. *)
  let deep = observe ~depth:3 (surface_term "[tower_level(), tower_depth()]") in
  check "relative level and tower depth are different observations"
    (outcome_equal deep.outcome (Answered (Value.List [ Value.Num 0; Value.Num 3 ])))

(* {1 Open recursion, at depth}

   Patching [eval] intercepts every recursive evaluation step at arbitrary AST
   depth. Phase 2 proved this for an Ash [open fn] group; here the group is the
   tower's own, patched from inside the language with [up].

   The count is the law: it must equal the number of steps level 0 takes, and
   therefore must not change when the tower gets deeper. *)

let counting_program body =
  Printf.sprintf
    "var steps = 0\n\
     up {\n\
    \  let base = eval\n\
    \  eval := fn(e, r, k) -> { steps := steps + 1; base(e, r, k) }\n\
     }\n\
     let answer = %s\n\
     [answer, steps]"
    body

let intercepted name ~depth body =
  match (observe ~depth (surface_term (counting_program body))).outcome with
  | Answered (Value.List [ answer; Value.Num steps ]) -> Some (answer, steps)
  | Answered other ->
      incr failures;
      Printf.printf "FAIL %s at depth %d: expected an answer and a count, got %s\n" name
        depth (Value.to_string other);
      None
  | (Failed error | Unlowerable error) ->
      incr failures;
      Printf.printf "FAIL %s at depth %d: %s\n" name depth (Error.to_string error);
      None

let test_open_recursion_at_depth () =
  (* Nested to four levels, so "every step" has somewhere to hide. *)
  let body = "1 + (2 * (3 + (4 * 5)))" in
  let counts =
    List.filter_map
      (fun depth ->
        match intercepted "a patched evaluator sees the program" ~depth body with
        | Some (answer, steps) ->
            check
              (Printf.sprintf "the program still computes its answer at depth %d" depth)
              (Value.equal (Value.Num 47) answer);
            Some steps
        | None -> None)
      [ 0; 1; 2; 3 ]
  in
  check "a patched evaluator intercepts far more than the outermost node"
    (match counts with first :: _ -> first > 10 | [] -> false);
  (* The sharp form: how many steps of level 0 there are is a property of the
     program, not of the tower under it. *)
  check "the number of intercepted steps does not depend on the tower's depth"
    (match counts with
    | first :: rest -> List.for_all (Int.equal first) rest
    | [] -> false);
  (* And interception tracks the term, not the entry point: one more nested
     application costs a fixed number of additional intercepted steps. *)
  let nested =
    List.filter_map
      (fun body ->
        Option.map snd (intercepted "nesting is counted" ~depth:1 body))
      [ "1"; "1 + 1"; "1 + (1 + 1)"; "1 + (1 + (1 + 1))" ]
  in
  check "each extra level of nesting is intercepted too"
    (match nested with
    | [ a; b; c; d ] -> a < b && b < c && c < d && c - b = d - c
    | _ -> false)

(* {1 Level independence}

   Mutating [eval] at level n+1 affects levels ≤ n and not level n+1's own
   execution. The negative half is the one that matters: a replacement that
   intercepted its own level would be its own interpreter, and its first step
   would not return. *)

let test_level_independence () =
  List.iter
    (fun depth ->
      let source =
        "var steps = 0\n\
         up {\n\
        \  let base = eval\n\
        \  eval := fn(e, r, k) -> { steps := steps + 1; base(e, r, k) }\n\
         }\n\
         let before = steps\n\
         let inner = up { resume(cont, 1 + (2 * (3 + 4))) }\n\
         let after = steps\n\
         [inner, after - before]"
      in
      match (observe ~depth (surface_term source)).outcome with
      | Answered (Value.List [ inner; Value.Num moved ]) ->
          check
            (Printf.sprintf "the level above still computes its own answer at depth %d" depth)
            (Value.equal (Value.Num 15) inner);
          (* Level 0 evaluates the [up] call and the statements around it, so the
             counter does move; what it must not contain is the level-1 body's
             own arithmetic, which is four applications and seven operands. *)
          check
            (Printf.sprintf "level 1's own execution is not intercepted at depth %d" depth)
            (moved < 10)
      | Answered other ->
          incr failures;
          Printf.printf "FAIL level independence at depth %d: got %s\n" depth
            (Value.to_string other)
      | (Failed error | Unlowerable error) ->
          incr failures;
          Printf.printf "FAIL level independence at depth %d: %s\n" depth
            (Error.to_string error))
    [ 0; 1; 2 ]

(* {1 Reifier identity}

   [id = reifier(e, r, k) -> reflect(arg(e, 0), r, k)] is observationally
   [fn(x) -> x]: same value, same effects in the same order, evaluated once. *)

(* Written in Core notation, because the surface language has no [reifier] form
   yet: `arg(e, 0)` is the head of the third field of [code_view]. *)
let identity_reifier_core body =
  Printf.sprintf
    "(let id (reifier (e r k) (app (var reflect) (app (var head) (app (var head) (app (var tail) (app (var tail) (app (var code_view) (var e)))))) (var r) (var k))) %s)"
    body

let test_reifier_identity () =
  let same name ~through ~directly =
    let reifier = observe ~depth:0 (core_term (identity_reifier_core through)) in
    let plain = observe ~depth:0 (core_term directly) in
    check
      (Printf.sprintf "the identity reifier is the identity: %s" name)
      (outcome_equal_apart_from_position reifier.outcome plain.outcome);
    check
      (Printf.sprintf "and preserves observable effects exactly: %s" name)
      (List.equal Io.event_equal reifier.effects plain.effects)
  in
  same "a value"
    ~through:"(app (var +) (app (var id) (app (var +) (lit 1) (lit 2))) (lit 10))"
    ~directly:"(app (var +) (app (var +) (lit 1) (lit 2)) (lit 10))";
  same "an effect, once and in order"
    ~through:"(let _ (app (var println) (lit \"a\")) (let _ (app (var id) (app (var println) (lit \"b\"))) (app (var println) (lit \"c\"))))"
    ~directly:"(let _ (app (var println) (lit \"a\")) (let _ (app (var println) (lit \"b\")) (app (var println) (lit \"c\"))))";
  same "a failure raised by a primitive"
    ~through:"(app (var id) (app (var /) (lit 1) (lit 0)))"
    ~directly:"(app (var /) (lit 1) (lit 0))";
  (* And one the evaluator raises itself, because only those carry a level today
     (ADR 0023 defers threading it through primitive argument diagnostics). This
     is the case where "same failure" includes "owned by the same level". *)
  same "a failure raised by the evaluator, level included"
    ~through:"(app (var id) (if (lit 1) (lit 2) (lit 3)))"
    ~directly:"(if (lit 1) (lit 2) (lit 3))";
  same "an arity failure, level included"
    ~through:"(app (var id) (app (lam (x) (var x)) (lit 1) (lit 2)))"
    ~directly:"(app (lam (x) (var x)) (lit 1) (lit 2))";
  same "a closure"
    ~through:"(app (app (var id) (lam (x) (app (var * ) (var x) (lit 3)))) (lit 5))"
    ~directly:"(app (lam (x) (app (var *) (var x) (lit 3))) (lit 5))"

(* Nontermination, bounded by counted steps rather than by wall time: an argument
   that never finishes must not finish through the reifier either, and must stop
   at exactly the same step. A step cap installed on the ground machine is host
   instrumentation, so it costs the measured program nothing. *)

exception Budget_exhausted

let with_step_cap ~cap build =
  let tower, io, named = fresh () in
  match build named with
  | exception Error.Ash_error error -> (Unlowerable error, [], 0)
  | term ->
      let machine = Level.machine (Tower.ground tower) in
      let base = Machine.current_eval machine in
      let steps = ref 0 in
      Machine.set_eval machine (fun m node env k ->
          incr steps;
          if !steps > cap then raise Budget_exhausted;
          base m node env k);
      let outcome =
        match Tower.run tower term with
        | value -> Answered value
        | exception Error.Ash_error error -> Failed error
        | exception Budget_exhausted -> Answered (Value.Sym "still-running")
      in
      (outcome, Io.events io, !steps)

let test_reifier_identity_on_a_nonterminating_argument () =
  let cap = 5000 in
  let loop = "(letrec ((spin (lam (n) (app (var spin) (app (var +) (var n) (lit 1)))))) (app (var spin) (lit 0)))" in
  let direct, direct_effects, direct_steps = with_step_cap ~cap (core_term loop) in
  let through, through_effects, through_steps =
    with_step_cap ~cap (core_term (identity_reifier_core (Printf.sprintf "(app (var id) %s)" loop)))
  in
  check "a non-terminating argument does not terminate on its own"
    (outcome_equal direct (Answered (Value.Sym "still-running")));
  check "and does not terminate through the identity reifier either"
    (outcome_equal through (Answered (Value.Sym "still-running")));
  check "both are stopped by the same budget, at the same step"
    (Int.equal direct_steps through_steps && Int.equal direct_steps (cap + 1));
  check "and neither produced output on the way"
    (List.equal Io.event_equal direct_effects through_effects)

(* {1 Error propagation}

   An error at level n is reported at level n and reaches level n + 1, which is
   where it stops: the level below never resumes, so nothing after the reflective
   call runs. There is no handler form in Core (ADR 0023), so "catchable at n+1"
   is observed as ownership plus non-resumption rather than as a handler. *)

let test_error_propagation () =
  List.iter
    (fun depth ->
      let source =
        "let ignored = up { meta_error(\"stop\") }\nprintln(\"after\")"
      in
      let observed = observe ~depth (surface_term source) in
      (match observed.outcome with
      | Failed error ->
          check
            (Printf.sprintf "meta_error keeps its message at depth %d" depth)
            (Error.cause_equal error.Error.cause (Error.Meta_error "stop"));
          check
            (Printf.sprintf "and belongs to the level that ran it at depth %d" depth)
            (error.Error.level = Some 1)
      | (Answered _ | Unlowerable _) ->
          incr failures;
          Printf.printf "FAIL meta_error did not fail the run at depth %d: %s\n" depth
            (outcome_to_string observed.outcome));
      check
        (Printf.sprintf "the level below never resumes at depth %d" depth)
        (List.equal Io.event_equal [] observed.effects))
    [ 0; 1; 2 ];

  (* The other direction: code reflected back down belongs to the level that
     evaluated it, not to the level that handed it over. The failure has to be one
     the evaluator raises, since a primitive's argument diagnostics carry no level
     yet — a gap ADR 0023 recorded deliberately rather than half-closing. *)
  let reflected =
    observe ~depth:0
      (core_term (identity_reifier_core "(app (var id) (if (lit 1) (lit 2) (lit 3)))"))
  in
  (match reflected.outcome with
  | Failed error ->
      check "an error in reflected code belongs to the level it ran on"
        (error.Error.level = Some 0
        && Error.cause_equal error.Error.cause
             (Error.Unexpected { found = "a number"; expected = "a boolean" }))
  | (Answered _ | Unlowerable _) ->
      incr failures;
      Printf.printf "FAIL reflected code that fails did not fail: %s\n"
        (outcome_to_string reflected.outcome));

  (* Stated so that closing the gap is a visible change rather than a silent one:
     a primitive's own diagnostic is still unattributed. When ADR 0023's deferred
     item is taken up, this assertion is what fails first. *)
  let primitive_failure = observe ~depth:0 (core_term "(app (var /) (lit 1) (lit 0))") in
  match primitive_failure.outcome with
  | Failed error ->
      check "a primitive's own diagnostic still carries no level (ADR 0023, deferred)"
        (error.Error.level = None)
  | (Answered _ | Unlowerable _) ->
      incr failures;
      Printf.printf "FAIL division by zero did not fail: %s\n"
        (outcome_to_string primitive_failure.outcome)

(* {1 One-shot enforcement}

   A continuation is invocable exactly once, and a second invocation raises
   rather than silently corrupting the level it came from. The continuation has
   to outlive the transfer to be invoked twice, so it is stored in a cell the
   level below shares — which also checks that it crosses the boundary at all. *)

let test_one_shot_enforcement () =
  let source =
    "(let saved (app (var cell_new) (lit 0))\n\
    \  (let twice (reifier (e r k)\n\
    \     (let _ (app (var cell_set) (var saved) (var k))\n\
    \       (app (var resume) (var k) (lit 1))))\n\
    \    (let _ (app (var twice) (lit 0))\n\
    \      (app (app (var deref) (var saved)) (lit 2)))))"
  in
  List.iter
    (fun depth ->
      let observed = observe ~depth (core_term source) in
      match observed.outcome with
      | Failed error ->
          check
            (Printf.sprintf "a resumed continuation cannot be resumed again at depth %d" depth)
            (match error.Error.cause with
            | Error.Continuation_reuse _ -> true
            | Error.Unbound_ident _ | Error.Unbound_name _ | Error.Ambiguous_name _
            | Error.Unfilled_binding _ | Error.Open_code _ | Error.Unliftable_value _
            | Error.Unexpected_character _ | Error.Unterminated _ | Error.Unexpected _
            | Error.Unknown_form _ | Error.Malformed_form _ | Error.Arity_error _
            | Error.Unsupported _ | Error.Division_by_zero | Error.Meta_error _
            | Error.Immutable_binding _ | Error.No_matching_clause _
            | Error.Duplicate_binder _ | Error.Inconsistent_pattern_binders _
            | Error.End_of_input ->
                false);
          check
            (Printf.sprintf "and the reuse names the level whose control it was at depth %d" depth)
            (error.Error.level = Some 0)
      | (Answered _ | Unlowerable _) ->
          incr failures;
          Printf.printf "FAIL a continuation was reused without failing at depth %d: %s\n"
            depth (outcome_to_string observed.outcome))
    [ 0; 1; 2 ]

(* {1 The excluded observations}

   §D9 excludes timing, host stack depth, resource exhaustion, and gensym
   counters. Stated as a test rather than as a comment: evaluator work at the top
   of the tower is not invariant, and if it ever became invariant that would mean
   the interposed interpreters had stopped doing anything. Wall time and host
   stack are not asserted on anywhere in this file, and gensym counters cannot be
   observed because identifiers are compared through alpha-equivalence. *)

let test_excluded_observations () =
  let build = surface_term "fn fact(n) = if n == 0 then 1 else n * fact(n - 1)\nfact(5)" in
  let measured =
    List.map (fun depth -> (depth, observe ~depth build)) [ 0; 1; 2; 3 ]
  in
  let tops = List.map (fun (_, observation) -> observation.top_steps) measured in
  check "the work the tower does is not invariant under depth, which is why it is excluded"
    (match tops with
    | first :: rest ->
        let rec increasing previous = function
          | [] -> true
          | next :: more -> next > previous && increasing next more
        in
        increasing first rest
    | [] -> false);
  (* The same programs agree about everything §5.7 does claim. *)
  check "while the value is invariant"
    (match measured with
    | (_, reference) :: rest ->
        List.for_all
          (fun (_, observation) -> outcome_equal reference.outcome observation.outcome)
          rest
    | [] -> false)

let () =
  test_transparency ();
  test_depth_observation ();
  test_open_recursion_at_depth ();
  test_level_independence ();
  test_reifier_identity ();
  test_reifier_identity_on_a_nonterminating_argument ();
  test_error_propagation ();
  test_one_shot_enforcement ();
  test_excluded_observations ();
  Printf.printf "tower laws: %d programs compared for transparency at depth 0" compared_at.(0);
  for depth = 1 to max_depth do
    Printf.printf ", %d at depth %d" compared_at.(depth) depth
  done;
  print_newline ();
  List.iter
    (fun (name, steps, deepest) ->
      Printf.printf "  over the %d-step depth budget, so depth %d only: %s (%d level-0 steps)\n"
        depth_budget deepest name steps)
    (List.rev !over_budget);
  if !failures > 0 then (
    Printf.printf "%d tower law assertion(s) failed\n" !failures;
    exit 1)
