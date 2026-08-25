# Handoff log (archive)

Historical handoff entries from to-do.md, archived 2026-08-24. Newest first.
New entries go at the top of this file after each completed task.

Prepend entries, newest first. Include completed task, exact verification, design
decisions, known issues, and exact next task.

### 2026-08-24 — task 7.2

- Completed: static-store splitting and dynamic joins, which is where `Core.Set`
  first reaches a residual. Before this the specializer refused it outright.
  - **A cell is held or residual (ADR 0036).** `Ash_stage.Store` decides, per
    binding, whether the specializer owns the cell — writes update it, reads
    fold, nothing survives — or the residual program does, writes becoming `Set`
    nodes emitted in order and reads becoming a variable. A held cell's contents
    live *in the cell*, so an ordinary `Var` read finds them with no store
    lookup, and every decision is gated on the term's write set: a program that
    assigns nothing takes exactly the path it took before. The whole pure corpus
    specializes to bit-identical residuals, which is why every figure below is
    unchanged.
  - **Keyed by the cell, never the binder.** Two names for one cell are one
    place — that is aliasing — and one binder evaluated twice is two places.
    `Value.same_cell` gets both at once: two closures over one `var` write to
    one residual binding, while `fn twice(n) = { var t = n; t := t * 2; t }`
    called three times folds to a literal, each activation folding separately.
  - **Holding is proved, not assumed.** `Store.holdable` is syntactic, local,
    memoized per binder, and over-approximate: not free in any `Lam`/`LetRec`
    body, not mentioned in a `Quote`, not spelled by a `NamedVar`, no `Reifier`
    in scope. Failing is not refusing — the binding is residualized. The first
    clause does the load-bearing work twice over: it is why no inlined callee can
    assign a held binder, so the branches' *syntactic* write set is enough at a
    fork, and it is why a promotion's binding always lands in a block that
    dominates every later read of it.
  - **Joins promote before they fork.** §7.4's own example
    (`if d then x := 1 else x := 2; use(x)`) gives `x` up to the residual program
    *before* specializing either branch, because the residual needs one place
    both branches write to, bound where both — and everything after the join —
    can see it. `Store.join` then keeps only what outlives the branch and
    requires both forks to describe it the same way. In the same program a
    binding no branch writes stays held: `var y = 5` folds into the addition
    while `x` becomes a residual binding. That is the splitting.
  - **One write set, two consumers.** `Core.assigned_idents` moved into
    `Ash_core.Core`; the store and `Ash_collapse.Normalize` read the same
    definition. This is what promotes ADR 0033's guards from defensive to
    load-bearing: the promoted binding of §7.4's example is `let x = 0`, and a
    normalizer with a narrower write set would substitute the literal into the
    read after the join and answer 0 for both branches.
  - **Considered and rejected:** residualizing every mutable binding (sound,
    a tenth of the code, and makes "static store" vacuous — `var x = 1; x := x +
    1; x * 10` would emit three operations instead of folding to 20); and
    speculating both branches then restarting on disagreement to a fixpoint
    (more precise, but the discarded attempts would have to sandbox the
    emitted-binding count the budget watches, sticky generalizations, and the
    compile-time log — a lot of machinery for a little precision).
- Scope, deliberately: the store's domain is bindings, not heap allocations.
  `cell_new`, `deref`, `cell_set` and the open-group trio are still
  `Allocation_or_mutation` and still residualize, so an `open fn` group remains
  the criterion suite's boundary sample and the report still counts surviving
  evaluator-cell dereferences. Making allocation static needs an escape analysis
  over values rather than scopes, and that is what Phase 9 will need.
- Refusals, all three tested: an assignment to a cell the store does not track (a
  `LetRec` name); a specialization point whose *specialized* parameter is
  assigned and cannot be held, where the only place would be outside the residual
  function and one call's write would be the next call's start; and a reifier
  application or `reflect` while the store holds a binding, since the level the
  environment goes to may write a cell the specializer already folded from.
- Measurement: no counter changed meaning or value. The criterion suite still
  proves its 73 depth-1 samples against the same 906,708-dispatch /
  2,125,589-cell-read tower figures and the same 250 residual nodes; depth
  results are still 417 invariant and 18 depth-sensitive checks. The golden
  report gains two samples (a held store binding; mutation across a dynamic
  branch) and replaces the "outside the fragment" one, which now shows an
  assignment the store cannot place rather than assignment as such.
- Tests: new `test/unit/store_test.ml` (held bindings, escaping bindings and
  aliases, §7.4's branch both ways, one-sided writes, nested branches, split
  versus held in one program, promotion on a dynamic write, specialization points
  over an assigned parameter, the three refusals, `Store.join` directly, and the
  normalizer's guard on a residual the store built);
  `test/differential/residual_test.ml` now also compares the corpus's eight
  mutation and evaluation-order programs; `collapse_test` and `stage_test`
  re-pinned to where the boundary is now; `test/golden/collapse.expected`
  re-pinned.
- Documentation: ADR 0036; spec §7.4 step 3, §8 Phase 7, the §D7 class table, and
  §10's static-store trap; README gains the abstract-store section and updates
  the effect-class table and normalizer note.
- Verified from a removed `_build` with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, `opam exec -- dune exec ash --
  --demos`, and `opam exec -- dune exec ash -- --collapse examples/fact.ash
  --depth 1` all pass.
- Known issues: `open fn` dereferences still residualize (Phase 9's work, and the
  criterion's falsifiability sample). The join's disagreement refusal is a guard
  at a site today's rules cannot reach — pre-promotion makes agreement the only
  outcome — so it is tested against the module rather than through a program,
  for the same reason 7.1's effect gate is kept.
- Next: 7.3 — the effect-order differential corpus: compare values, output,
  errors, and observable store at depths 0-5, on *normalized* residuals, and
  require that compilation has no runtime effects.

### 2026-08-24 — task 7.1

- Completed: primitive effect policy during specialization, which opens Phase 7.
  - **The gate is structural (ADR 0035).** `Effect_class.always_residualizes`
    existed, documented D7's absolute, and had no caller: the guarantee held
    because the one fold path happened to consult `may_fold`. Task 6.4 then
    added a second fold path, `static_reading`, which consults `may_fold` never
    — harmless, since `tower_depth` is `Reflection`, but the shape of the
    near-miss is the point. `Staged_eval.apply_primitive` now checks
    `always_residualizes` first in lift mode, so an observable effect cannot
    reach a fold path whatever rule is added below it.
  - **Pinned as load-bearing, not assumed.** Two experiments, both run: with the
    observable class deliberately mis-marked as foldable, the gate holds the
    criterion and only the class-consistency assertions fail; with the gate
    removed, the same mis-marking produces 20 failures including
    `specialization wrote nothing: expected [] actual [x]` — compilation
    printing, which is exactly the D7 bug.
  - **`static_log` and a sixth class.** `Effect_class.Specialization_only` is
    the inverse of `Observable_effect` rather than a weaker form: that class may
    never run at specialization time, this one may never survive it. A class
    rather than a special-cased name, so the specializer keeps reading policy
    off the class. `static_log` runs when the specializer meets it, observes its
    argument as `Unobserved` so a dynamic one is logged as the code it stands
    for, and leaves no residual call.
  - **A second stream, deliberately.** It writes to `Primitives.log`, never
    `Primitives.io`. Had the log shared `io` with a tag, "the program printed
    nothing" would have become "printed nothing once you filter", and a test one
    refactor from not filtering is not a guarantee. Nothing in the language can
    read the log; no equivalence claim consults it. A plain run is therefore
    silent (the log has no echo), while the collapse report shows the
    specialization phase's entries.
  - **Considered and rejected:** making `static_log` a no-op under ordinary
    evaluation. It would buy symmetry between the source and residual runs in a
    stream nothing compares, at the cost of giving primitives access to the mode
    they run under, which none currently has.
- Measurement: no counter changed meaning or value — `may_fold` already refused
  every observable primitive, so the gate re-decides nothing. The registry grows
  to 50 primitives, so a materialized level has 50 global cells rather than 49,
  and the report gains a `Specialization log:` line beside
  `Specialization output:`.
- Tests: new `test/unit/effect_policy_test.ml`; `data_model_test` and
  `primitives_test` re-pinned (six classes, both policy predicates fixed to
  their exact class sets, `static_log` in the independent classification and
  arity tables); `test/golden/collapse.expected` re-pinned.
- Documentation: ADR 0035; README gains the effect-policy and compile-time
  channel bullets.
- Verified from a removed `_build` with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, `opam exec -- dune exec ash --
  --demos`, and `opam exec -- dune exec ash -- --collapse examples/fact.ash
  --depth 1` all pass. The prior figures are identical: 906,708 dispatches /
  2,125,589 cell reads / 250 residual nodes, 417 invariant and 18
  depth-sensitive checks.
- Known issues: unchanged. `open fn` dereferences and Core `Set` still
  residualize until 7.2's store splitting; reflective collapse is Phase 9.
- Next: 7.2 — static-store splitting and dynamic joins: fork and conservatively
  merge abstract stores while retaining alias/cell identity, residualizing when
  proof is unavailable.

### 2026-08-24 — tasks 6.3 and 6.4

- Completed: the residual normalizer (6.3) and the depth results (6.4), which
  close Phase 6.
  - **The normalizer (`Ash_collapse.Normalize`, ADR 0033)** is three rewrites:
    value-position lets flatten however deep they nest (`let x = (let y = ey in
    ex) in b` → `let y = ey in let x = ex in b`); trivial bindings — a literal,
    or a variable nothing in the term assigns — substitute away, or drop when
    nothing mentions them; alpha-canonical renaming runs last. The guard that
    makes elimination sound is an occurrence classifier, not `free_idents`: a
    `Set` target reads its binding to find its cell, a variable inside a
    `Quote` body is data, and a `Reifier` body is another level's code — any
    such mention keeps the whole binding rather than being rewritten. The
    mirror-image guard is on the value: substituting a variable that something
    writes to would make the body read what the write put there, so the write
    set is collected over the whole term (a closure can outlive its binding)
    and blocks the substitution. Nothing hoists across lambdas,
    branches, or `LetRec` groups; unused effectful bindings stay; idempotence
    holds as exact structural equality. `Metrics.measure` normalizes before the
    residue survey and run.
  - **Depth-aware specialization (ADR 0034).** In lift mode one predicate,
    `Staged_eval.static_reading`, folds a nullary reflection reading whose
    answer the configuration fixes: today exactly `tower_depth()`, folded to
    the attached depth. Everything else stays dynamic — `meta_eval`/
    `meta_apply`/`meta_global` answer with identity-carrying cells and
    environments the lift domain refuses to reify; `tower_level()` reads 0 both
    ways already. Two attachment points: `Metrics.measure` attaches its staging
    machine to the measurement's real materialized tower;
    `Metrics.specialize ~depth ~env` (new) attaches only the faithful depth
    reading against a caller-owned environment, which is what makes residuals
    comparable at all — cloned globals (ADR 0022) give each environment its own
    identities, so cross-environment comparison is impossible by construction.
    Standalone specialization (`Stage.fold`, unattached machines) is unchanged
    bit-for-bit, so every prior result held.
  - **The depth law suite** (`test/laws/depth_invariance_test.ml`) runs two
    halves. Syntactic: one shared environment, `Metrics.specialize` at depths
    0–5 over the corpus plus computing and depth-sensitive samples — ordinary
    programs equal depth 1 structurally, `tower_depth()` programs are required
    to differ, zero surviving interpretation everywhere. Semantic:
    `Metrics.measure` per affordable depth with budget projection (one corpus
    entry stops at depth 2 and says so) — transparency for invariant samples,
    program/residual agreement by application where answers are functions,
    tower/residual agreement for closed answers, residual cost ≤ source cost.
    Plus the falsifiability guard: two raw specializations differ structurally
    while their normal forms coincide.
  - **A rejected shortcut worth remembering:** memoizing global identities per
    registry would have made cross-tower terms comparable mechanically but
    weakened three pinned properties (fresh global identity per cloned level,
    `primitives_test` / `tower_test` / `up_test`) that keep levels
    independently stateful per ADR 0022. Reverted; shared-environment driving
    costs nothing and touches nothing below `ash.collapse`.
  - **Deliberately left out:** merging alpha-equal residual functions across
    dynamic branches (the same key met twice still yields two functions) —
    correct as-is, required by no acceptance criterion, recorded here so it is
    not mistaken for a regression.
- Measurement: none changed. Residuals arrive normalized (two golden samples
  shrank slightly; re-pinned), no counter moved meaning, and no golden sample
  reads its depth.
- Tests: new `test/unit/normalize_test.ml`; new
  `test/laws/depth_invariance_test.ml`; `test/golden/collapse.expected`
  re-pinned; `examples/depth.ash` documents the depth-sensitive shape from the
  CLI (`--collapse examples/depth.ash --depth N` prints source 0 vs tower n vs
  residual n and states the difference honestly).
- Documentation: ADRs 0033 and 0034; spec §8's Phase 6 carries the Done note;
  README gains the normalizer bullet and a Depth results section;
  `examples/README.md` lists `depth.ash`.
- Verified from a removed `_build` with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, `opam exec -- dune exec ash --
  --demos`, and `opam exec -- dune exec ash -- --collapse examples/fact.ash
  --depth 1` all pass.
- Known issues: unchanged from 6.1/6.2 plus none new inside the fragment.
  Outside it, expected: `open fn` dereferences and Core `Set` residualize until
  Phase 7's store splitting; reflective collapse is Phase 9.
- Next: 7.1 — enforce primitive effect policy during specialization: IO always
  residualizes, allocation/mutation until proven by store discipline,
  `static_log` compile-time-only, and specialization emits no program-visible
  output.

### 2026-08-24 — task 6.2

- Completed: specialization budgets and generalization (spec §7.5), so the
  recursion 6.1 cannot key — the kind that never repeats — terminates too.
  - **Two deterministic limits**, never wall time: `max_inline_depth` (nested
    calls the unroller has followed into *one* function, counted per function
    identity) and `max_residual_bindings` (residual bindings emitted so far,
    across every block).
  - **Why the size limit is phrased in emitted bindings.** An unrolling that is
    working folds, and emits nothing: the corpus's deepest static unrolling is a
    10,000-step tail-recursive loop that collapses to one literal and emits no
    bindings at all, while an unrolling going nowhere emits at every step. The
    budget separates the two without a whistle, an embedding test, or any
    analysis of the values involved.
  - **Generalization picks the argument the unrolling is following**: the
    leftmost position whose projection differs from the nearest enclosing call
    to the same function, falling back to the leftmost still-known position.
    One at a time, as §7.5 says — a `rev(xs, acc)` whose list shrinks while its
    accumulator grows is driven by both, and needs both given up.
  - **Sticky and monotone**, recorded against the function's identity. That is
    the termination argument: *k* parameters means at most *k* generalizations,
    after which the key is constant and the next call must meet the memo table.
  - **Nothing left to give up is not an error**: a key that is already all
    dynamic ties its own knot, so the pressure path always produces a point.
    The one place specialization can only refuse is closure reification — a
    closure reaching a dynamic position inside its own reified body is not a
    call and has no argument to generalize — which raises the new
    `Error.Budget_exhausted { what; limit; callee }`.
  - **Defaults leave the corpus alone** (25,000 / 50,000), which
    `collapse_criterion_test.ml` now asserts: zero generalizations across all 73
    samples. §7.5's argument is that collapsing *without* generalizing is the
    stronger result, so a budget that fired on a working program would weaken
    every result for nothing.
- Measurement: `Metrics.specialization.generalizations` stops being a hard-wired
  zero and `generalization_reasons` carries each decision; the report prints
  them under the count (`rev(acc): inlining-depth, 6 nested calls to it were
  already being inlined`), at most six then "and N more".
  `Metrics.measure`/`Collapse.report` take an optional `?budget`, restored
  afterwards — the budget is configuration, not run state, and
  `Specialize.reset` leaves it alone.
- Tests: new `test/unit/stage_budget_test.ml` (growing accumulator, runaway
  counter, size pressure, the self-passing closure that exhausts, and the
  regression that the default budget generalizes nothing).
  `test/laws/collapse_criterion_test.ml` asserts zero generalizations.
  `test/unit/collapse_test.ml` measures a budgeted program and checks both
  reasons, their order, and that they reach the rendered report, plus that the
  configured budget is restored. `test/golden/collapse.expected` gains "an
  accumulator too large for its budget". `test/unit/error_test.ml` enumerates
  the new cause.
- Documentation: ADR 0032; spec §7.5 carries a Done note and §8's Phase 6 an
  updated in-progress note; README describes the budget and what it is watching.
- Verified with OCaml 5.4.1 and Dune 3.24.2: `opam exec -- dune build @all`,
  `opam exec -- dune runtest --force`, `opam exec -- dune exec ash -- --help`,
  `opam exec -- dune exec ash -- --demos`, and
  `opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1`
  all pass. No prior figure moved: every existing sample generalizes nothing.
- Known issues: the budget is not reachable from the CLI, so `--collapse` always
  measures at the default — a `?budget` argument exists on `Metrics.measure` and
  `Collapse.report` and the golden test uses it. The same key met in two
  branches of a dynamic conditional still produces two residual functions (6.3).
  Unchanged and expected: `open fn` dereferences and Core `Set` residualize
  until Phase 7's store splitting, and reflective collapse is Phase 9.
- Next: 6.3 — a semantics-preserving residual normalizer: alpha-canonicalize and
  flatten administrative lets without moving effects, idempotent, and passing
  effect counterexamples. It is what 6.4's cross-depth comparison rests on, and
  §8's Phase 6 warns that a sloppy normalizer makes that claim vacuous.

### 2026-08-24 — task 6.1

- Completed: memoized specialization points and residual `LetRec` (spec §7.5),
  so recursion the specializer cannot see the end of terminates.
  - **The key** is the function's identity — its lambda together with the
    environment it closed over, both compared physically, which is what makes a
    `LetRec`-bound function's recursive call the same function — plus a
    projection of each argument: `Known` (static all the way down, compared by
    `Value.equal`), `Held` (constructor known, contents partly dynamic, compared
    by identity), `Unknown` (residual code). Known and held arguments are
    specialized into the residual function's body; unknown ones become its
    parameters. `lib/stage/specialize.ml{,i}`.
  - **The trigger is the design decision.** §7.5 says what to memoize, not when.
    Inlining stays the default and a call becomes a specialization point only
    when its own key is already being inlined. A key repeats only once unrolling
    has stopped making progress, so `power(3, x)` walks four different keys and
    creates no point, and a traversal of a static spine walks four different
    `Held` lists — every Phase 5 result is unchanged, and the pre-existing
    collapse-report counters are identical.
  - **The point belongs to the call that started the inlining**, not the one
    that discovered the cycle. Discovery normally happens inside a dynamic
    conditional's branch, and a function bound there is unreachable from the
    next call with the same key. `Specialize` records each entered call's
    context — open emission blocks, visible point scopes, active calls — and
    committing a point reinstalls it. The entered key is deliberately not active
    inside, so the recursive call reaches the memo table and calls the point
    being defined. That ties the knot, and it is why mutual recursion closes on
    one function with its partner inlined into it.
  - **Emission blocks now carry ordered items**, let-insertions and `LetRec`
    groups, instead of a list of bindings (`lib/stage/emit.ml`). A point is
    bound where it was created and never hoisted: its body may mention binders
    that let-insertion introduced earlier in that block, and the partially
    static values specialized into it may hold residual variables of that block.
    A point's scope ends when its block does, so the two branches of a dynamic
    conditional each get their own.
  - `Identity` mode is untouched; all of this is inside the `Lift` branch of
    `apply`.
- Measurement: `Metrics.specialization` gains `specialization_points` and
  `memoized_calls`, printed as `Specialization points: N (M calls)`. Zero is the
  stronger result — it says every recursion in the program was decided at
  specialization time — which is §7.5's argument for instrumenting
  generalizations, one step earlier.
- Tests: new `test/unit/stage_recursion_test.ml` (12 programs, all but the two
  static-control regressions overflowed the host stack before this change, so termination is part of
  the assertion; each residual is run against its source on several argument
  lists). `test/laws/collapse_criterion_test.ml` gains two dynamically recursive
  open samples, so the milestone-2 criterion now covers residuals containing a
  `LetRec`: 73 samples, 250 residual nodes, still zero interpretation.
  `test/golden/collapse.expected` gains the new report line and a
  "recursion on an unknown argument" sample, which is where that counter is not
  zero — the golden file's rule is that every counter is non-zero somewhere.
- Documentation: ADR 0031; spec §7.5 carries a Done note and §8's Phase 6 an
  in-progress note; §8's Phase 5 Done figures are updated to the grown suite
  with the original figures kept alongside; README describes the strategy.
- Verified with OCaml 5.4.1 and Dune 3.24.2: `opam exec -- dune build @all`,
  `opam exec -- dune runtest --force`, `opam exec -- dune exec ash -- --help`,
  `opam exec -- dune exec ash -- --demos`, and
  `opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1`
  all pass.
- Known issues: recursion whose static projection *grows* still does not
  terminate at specialization time (6.2); a recursive closure that passes itself
  across a dynamic boundary each step likewise, because `reify_value` of a
  closure is not itself a specialization point (6.2); the same key met in two
  branches of a dynamic conditional produces two residual functions, which is
  correct but larger than necessary (6.3). Unchanged and expected: `open fn`
  dereferences and Core `Set` residualize until Phase 7's store splitting, and
  reflective collapse is Phase 9.
- Next: 6.2 — specialization budgets and generalization: a depth/size cutoff
  that progressively marks arguments dynamic under budget pressure, reports
  every reason, and makes hostile recursive cases terminate with useful
  diagnostics. The `generalizations` field in `Metrics.specialization` and the
  report line already exist and are wired to zero.

### 2026-08-24 — task 5.5 (Phase 5 complete — milestone 2)

- Completed: the pure Phase 5 criterion, as a law suite
  (`test/laws/collapse_criterion_test.ml`) rather than a claim in prose.
  - **What is proved, per sample, at depth 1:** the source run, the depth-1
    tower run, and the residual run agree on value, on failure cause and
    location, and on the observable trace; the residual contains zero surviving
    eval-cell dereferences, evaluator calls, Core-constructor dispatch sites,
    residualized `NamedVar` lookups, and reflection boundaries, and no nodes
    from any other source; specialization left no output; and the residual costs
    no more to run than the source.
  - **Samples:** 71. The pure corpus's 44 values and 21 failures, plus 6 whose
    value is a function of an argument the specializer does not have. A pure
    program that fails is inside the claim: specialization may fold a certain
    failure, but only into the failure the program actually has, at the place it
    has it.
  - **Three defences against tautology.** The premise is asserted — the tower
    run must have performed the interpretation the residual is claimed not to
    contain (906,684 dispatches and 2,125,537 cell reads across the suite,
    against 142 residual nodes). The six function-valued samples are checked to
    still be lambdas with non-trivial bodies and are compared by *applying*
    source and residual to the same arguments, closure equality being identity.
    And the criterion is falsifiable: the boundary section runs an `open fn`
    group and a runtime `code_view`, requires the measurement to report the
    interpretation they leave, and requires those uncollapsed residuals to still
    be correct.
  - Verified against deliberate violations before acceptance: a program with a
    surviving `open_deref` fails the criterion, and a residual that folded to a
    literal fails the "still computes" check.
- Scope, recorded rather than assumed: ADR 0030 fixes what `collapse(1, p)`
  means in Phase 5 — specialize `p`, and compare it against what the depth-1
  tower did. Squashing the interposed evaluator itself needs the meta `eval`
  binding to fold when the evaluator's identity is statically known, which is
  §7.4 step 5 and task 9.1. The ADR also records the `Quote` prerequisite for
  the first Futamura projection so it is not rediscovered.
- Documentation: ADR 0030; spec §8's Phase 5 carries a Done note with the
  figures; README documents the suite and what keeps it honest.
- `Metrics.t` now carries the `globals` the measurement used, which is what a
  caller needs to apply a residual function itself.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`,
  `opam exec -- dune exec ash -- --demos`, and
  `opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1`
  all pass.
- Known issues: none inside the fragment. Outside it, unchanged and expected:
  recursion driven by dynamic control does not terminate at specialization time
  (6.1, 6.2); `open fn` dereferences and Core `Set` residualize until Phase 7's
  store splitting; reflective collapse is Phase 9.
- Next: 6.1 — memoized specialization points and residual `LetRec`, keyed by
  function identity plus a canonical static-argument projection, so recursive
  programs specialize without infinite unrolling.

### 2026-08-24 — task 5.4

- Completed: the initial collapse metrics and report (spec §9.4), as a new
  library `ash.collapse` sitting above `ash.stage` and `ash.tower`.
  - **One measurement, four numbers per program.** `Metrics.measure` runs the
    program on the ground evaluator, at a stated tower depth, through the
    specializer, and then runs the residual — sharing one tower's ground
    globals and one buffered output stream, with counters cleared between
    phases so each figure belongs to the phase it is printed under.
  - **`Residue.survey` decides what interpretation survived, syntactically.**
    `open_deref` applications are evaluator-group dereferences; an application
    *of* an `open_deref` is a surviving evaluator call; `code_view`/`code_match`
    are constructor dispatch; `NamedVar` nodes are lookups by printed name;
    reflection-class applications are boundaries. Callees are resolved by
    hygienic identity in the environment the residual will run in, so a local
    binder printing `open_deref` counts as nothing.
  - **Residue is attributed by provenance.** Residual nodes are grouped by the
    source file their span ultimately points at, so "interpreter residue" is
    nodes that came from some other program's text — the definition that will
    still mean something when the input contains an interpreter.
  - **Agreement is stated honestly or not at all.** A value carrying a closure,
    continuation, reifier, environment, or cell cannot be compared across two
    runs (closure equality is identity), so the report says so rather than
    comparing lambda syntax and calling it agreement.
  - **`Depth.interposed_term`** exposes the term interposed at each level, so
    the per-level interpreter size the §9.1 figure multiplies by depth is
    measured from what is actually installed.
  - **CLI:** `ash --collapse FILE [--depth N]`, with `examples/fact.ash` as the
    sample program.
- Acceptance: `test/golden/collapse.expected` pins the report over nine samples
  chosen so every counter is non-zero in at least one — full folding; the same
  program at depths 0, 1, and 3; a residual that still depends on an unknown
  argument; a traversal of a statically shaped list; an open-recursion group
  (2 surviving dereferences); a `code_view` dispatch (1 surviving site);
  observable output (source and residual print, specialization does not); and a
  program outside the fragment (no residual, and the report says why).
  `test/unit/collapse_test.ml` pins what the numbers mean, including the
  hygiene of callee identification, residue across two source files, and the
  invariants that level 0's cost does not depend on depth and that
  specialization leaves no output.
- Cross-check: the report's depth figures reproduce
  `docs/progress/0001-depth-cost.md` exactly — 162 level-0 steps for `fact(5)`,
  and 960, 4720, 23600 at levels 1, 2, and 3.
- Decisions and documentation: ADR 0029 records what the report measures and
  what it deliberately does not claim, including why heap words stay out of the
  printed report (they vary with the OCaml runtime; `Metrics` still carries them
  for task 10.4) and why classification is not attempted (task 10.2). README and
  AGENTS document the command and its golden file; `examples/README.md` lists
  the sample.
- Known issues: none. The report is scoped, and says so in its own output: the
  residual is the program specialized on its own, so the tower figures are the
  cost collapse is set against rather than a cost this residual removed.
  Erasing a level's interposed evaluator needs the meta `eval` binding to fold
  when the evaluator's identity is statically known — Phase 9.1.
- Next: 5.5 — prove the pure Phase 5 criterion: compare source, tower, and
  residual runs, and show every depth-1 pure sample equivalent with zero Core
  dispatch and zero surviving eval-cell dereferences. Expect one design
  question first: `Quote` currently residualizes in lift mode, so a program the
  specializer holds as syntax is dynamic to it, and a self-interpreter applied
  to a known program would not fold. Deciding how a statically known `Code`
  value differs from an unknown one is the substance of that task.

### 2026-08-24 — task 5.3

- Completed: staging of the pure fragment (spec §7.4 step 1) — higher-order
  Core, recursion, and immutable data.
  - **Partially static data.** A `Value.List` whose spine is known may carry
    dynamic `Code` elements and is still a real static value.
    `Stage_value.is_shape_static` names that condition; `is_purely_static` keeps
    its old, stronger meaning.
  - **Primitives declare what they inspect.** New `Ash_core.Observation`
    (`Whole_value | Shape_only | Unobserved`, per argument position) is a field
    on `Value.primitive`, defaulting to whole-value. `cons` observes only the
    shape of its tail, `head`/`tail`/`empty?`/`length`/`list?` only their
    argument's constructor, `list` nothing. One predicate,
    `Stage_value.may_fold`, reads the effect class and the observation together:
    *fold when the class permits it and nothing the primitive inspects is
    dynamic*. Class still dominates — no argument knowledge folds `print` or
    `cell_new`.
  - **One boundary conversion.** `Staged_eval.reify_value` replaced
    `lift_to_code` wherever a value crosses into residual code. It reifies a
    closure into its lambda syntax with dynamic parameters and an isolated
    `reify_block` body, rebuilds a non-empty list as a residual `list` call over
    reified elements, and defers everything else to `lift`. The `lift`
    primitive's §D6 domain is unchanged; §D6 already prescribed exactly this for
    the specializer.
  - **`apply_primitive` simplified.** The fold and residualize paths are now one
    decision instead of a duplicated class match; residual provenance still
    distinguishes `stage/prim` (foldable, arguments not known) from
    `stage/residualize` (class forbids folding).
- Acceptance:
  - `test/differential/residual_test.ml` (new) stages all 44 pure corpus
    programs and compares source execution with residual execution — value,
    failure cause, and observable trace — and checks that specialization itself
    leaves no output and that every residual is closed.
  - `test/unit/stage_fragment_test.ml` (new) does the same for programs whose
    result still depends on unknown arguments: `twice`, a closure crossing into
    a dynamic call, one closure reified twice, a closure chosen by a dynamic
    branch, a curried closure over a dynamic capture, a higher-order fold, a
    static-exponent `power`, mutual recursion, `mapinc`/`append`/`rev` over
    static spines of dynamic elements, and nested partially static data. Each
    residual is applied to concrete arguments and must give the source's answer.
    It also pins what must *not* fold (`==` over dynamic elements, `list?` and
    `length` of unknown values) and unit-tests `may_fold` directly.
  - Collapse actually happens, and is asserted, not assumed: `power(3, x)`
    leaves three multiplications and no comparison; `mapinc(list(x, 7))` leaves
    one addition and no `empty?`/`head`/`tail`/`cons`; `head(cons(x, nil))`
    leaves the identity.
- Decisions and documentation: ADR 0028 records partially static data, the
  observation policy, and boundary reification. Spec §D7's "fold when all
  arguments are static" is updated in the same change (§D6 needed no change and
  is cited as confirming the closure decision). README documents the second
  primitive field, the boundary conversion, and the new differential.
- Known issues: recursion driven by *dynamic* control still does not terminate
  at specialization time — that is 6.1's memoized specialization points and
  residual `LetRec` plus 6.2's budgets, and is deliberately not preempted here.
  Reifying one closure at several boundaries duplicates its body; 6.1 bounds it.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, and
  `opam exec -- dune exec ash -- --demos` all pass.
- Next: 5.4 — initial collapse metrics and report: count semantic, materialized,
  and residual size, interpreter nodes, eval-cell dereferences, dispatch sites,
  `NamedVar` lookups, evaluator calls, generalizations, and reflection
  boundaries, with provenance and reasons, behind stable golden tests.

### 2026-08-23 — staging correctness review fixes

- Corrected all seven findings against tasks 5.1–5.2 without advancing the
  checklist:
  - Lift-mode Core `Set` is rejected before evaluating its value or mutating the
    specialization environment; Phase 7 remains responsible for store splitting.
  - Lift-mode `Quote` residualizes the enclosing `Core.Quote`, so residual
    execution returns Code rather than the quoted value.
  - evaluator machines record ground/staged-Identity/staged-Lift wiring;
    `Staged_eval.run` derives the mode and rejects explicit mismatches before IO.
  - residual primitive calls recover the outermost hygienic binding containing
    the exact primitive value by identity, never by printed-name lookup.
  - Code-specific `If`, `Let`, and application residualization is Lift-only, so
    Identity mode preserves the ground evaluator's values and type errors.
  - pure primitives use recursive `is_purely_static`, preventing folds over
    lists that contain dynamic Code.
  - closures crossing a Lift boundary reify their lambda syntax and specialize
    each dynamic body in its own `reify_block`; closures remain unliftable.
- Regression coverage in `test/unit/stage_test.ml` executes residual Quote and
  lambda programs and checks mode/IO safety, Identity Code behavior, primitive
  hygiene under same-name shadowing, nested dynamic data, and mutation-state
  preservation under a dynamic branch.
- Documentation: README and ADRs 0026–0027 now state the corrected contracts.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/stage_test.exe`,
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all pass.
- Known issues: none from this review. Store splitting remains deliberately
  deferred to Phase 7.
- Next: 5.3 — stage pure higher-order Core, recursion, and immutable data.

### 2026-08-24 — task 5.2

- Completed: hygienic let-insertion with scoped block buffers.
  - **Scoped block buffers.** `Ash_stage.Emit` implements ambient mutable block
    buffers (`create_buffer`, `with_buffer`, `emit`, `reify_block`).
  - **Let-insertion.** Non-trivial dynamic computations (`App`, `If`, `Let`, etc.)
    emitted into an ambient buffer allocate fresh identifiers (`Ident.fresh`),
    record `{ binder; value; span }` with provenance `"stage/let-insert"`, and
    return `Var binder`. Trivial variables and literals pass through directly.
  - **Isolated branch scopes.** Dynamic `If` evaluates consequent and alternative
    branches within distinct `reify_block` buffers so bindings do not leak across
    branches or into the parent block. Dynamic `Let` and top-level `run`/`fold`
    wrap expressions with `reify_block`.
  - **Linearity on duplication traps.** Repeated references to dynamic results
    pass the generated variable name rather than inlining syntax trees, keeping
    emission strictly linear $O(N)$ on $N$-nested duplication traps.
- Acceptance: `test/unit/stage_test.ml` proves:
  - Linearity on duplication traps: for $N$-nested `dbl(x)` calls up to $N=8$,
    number of `Let` bindings is exactly $N$ and AST node count scales linearly.
  - Distinct scoped branch buffers: dynamic `If` isolates branch bindings under
    its own let-inserted expression.
  - Correct let-insertion and alpha-equivalence for residualized primitives,
    dynamic applications, dynamic conditionals, and non-pure primitives.
- Decision and documentation: ADR 0027 records the LMS-style mutable accumulator
  design, buffer scoping, and duplication prevention.
- Known issues: none.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/stage_test.exe`,
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, and `opam exec -- dune exec ash -- --demos`
  all pass.
- Next: 5.3 — stage pure higher-order Core, recursion, and immutable data.

### 2026-08-24 — task 5.1

- Completed: static/dynamic values, stage polymorphism, and the `maybe-lift` evaluator mode.
  - **Value model.** Static data are real runtime values (`Value.value`), dynamic
    data are `Value.Code(Core.t)`. `Ash_stage.Stage_value` provides named policy
    predicates (`is_static`, `is_dynamic`, `is_purely_static`, `static_value`,
    `dynamic_code`) and stage-conversion helpers (`lift_to_code`, `maybe_lift`).
  - **Evaluation modes.** `Ash_stage.Mode` defines `Identity` (standard execution;
    `maybe_lift = id`) and `Lift` (staged execution; `maybe_lift = lift`).
  - **One evaluator source.** `Ash_stage.Staged_eval` implements the CPS staged
    evaluator parameterized by `Mode.t`. In `Identity` mode, it matches ground
    evaluation. In `Lift` mode, pure primitives fold on static arguments and
    residualize `Core.App` with lifted arguments when dynamic; `If` with a static
    condition evaluates only the taken branch; `Let` with static values propagates
    bindings without administrative lets; and pure static errors (division by zero,
    type errors) fail at stage time.
  - **Open recursion.** Every recursive call routes dynamically through
    `Machine.eval`, `Machine.apply`, and `Machine.eval_list`, keeping meta
    replacements and counters active across both modes.
  - **New library.** `lib/stage/` (`ash.stage`) with `Mode`, `Stage_value`,
    `Staged_eval`, and `Stage`. `Evaluator.lift_value` is exported from `ash.runtime`.
- Acceptance: `test/unit/stage_test.ml` proves:
  - Policy predicates and `maybe_lift` across all value shapes.
  - `Identity` mode agreement on arithmetic, conditionals, `let`, `letrec`,
    closures, list operations, continuations, and open recursion.
  - Constant folding of arithmetic, comparisons, logic, list operations,
    and higher-order functions in `Lift` mode.
  - Constant propagation through static `Let` chains.
  - Stage-polymorphic residualization with dynamic arguments (`Code`) for
    arithmetic, dynamic conditionals, and non-pure primitives (`print`).
  - Pure error preservation at stage time (division by zero, type errors).
  - Open recursion interception and static recursion folding.
- Decision and documentation: ADR 0026 records static/dynamic value representation,
  stage polymorphism, the `maybe_lift` mode split, and error attribution.
- Known issues: none.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/stage_test.exe`,
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, and `opam exec -- dune exec ash -- --demos`
  all pass. Full suite includes all unit tests, 91-program differential corpus,
  tower laws at depths 0–5, self-interpreter at layers 1 & 2, and golden tests.
- Next: 5.2 — implement hygienic let-insertion with scoped block buffers, fresh
  IDs, and distinct buffers for dynamic branch and lambda bodies.

### 2026-08-23 — tasks 4.4 and 4.5 (Phase 4 complete)

- Completed: the §5.7 law suite at depth, and both packaged demos.
  - **What "depth" means.** The project could not express "run this at depth k":
    `Tower.run` runs at level 0 and nothing ran a program underneath n levels.
    The obvious fix — materialize k levels — is vacuous, because ADR 0022's
    laziness and ADR 0024's inertness fast path make an untouched level
    observationally the default evaluator by construction; transparency over it
    would pass on the day the tower was deleted. `Ash_tower.Depth` instead
    interposes an Ash closure `fn(e, r, k) -> base(e, r, k)` into each level's
    evaluator cell, the way `up { eval := … }` does, so every step of a level is
    a term the level above evaluates. It reads before writing, so depths stack.
    It lives in `ash.tower`, not in a test, because 5.5 and 6.4 both need it, and
    is built in Core because `ash.tower` cannot see `ash.syntax`. ADR 0025.
  - **`test/laws/tower_laws_test.ml`.** Transparency over 96 programs at depths
    0–5 — the whole differential corpus, pulled in by a `copy_files#` rule so the
    laws cannot come to test an easier set than `test/differential/` does, plus
    five observable-output programs the corpus lacks. Compared: value, failure
    cause/span/phase/level, and the exact effect sequence. Also depth
    observation, OR at depth, level independence, reifier identity, error
    propagation, one-shot enforcement, and the excluded observations.
  - **Two findings worth keeping.** Level 0's own step count is *invariant* under
    depth — 162 at depth 0 and at depth 5 for `fact(5)` — so interposition
    changes who does the base program's work, not how much there is; this is
    asserted for every corpus program. And one interposed level costs a flat 5x,
    so cost is `steps × 5^depth`; `docs/progress/0001-depth-cost.md` records the
    tables and is explicit that 5 is a floor for the smallest possible
    interpreter, not the constant per-level factor §9 deleted.
  - **A gap pinned rather than closed.** A primitive's own argument diagnostics
    still carry no tower level (ADR 0023 deferred it). Two law fixtures had to
    use evaluator-raised failures instead, and a test now asserts the current
    behaviour so that closing the gap is a visible change.
  - **Demos.** `examples/tracing.ash` and `examples/level_2_counting.ash`,
    embedded into the new `ash.examples` by a dune rule, the way
    `lib/self/eval.ash` already is. `ash --demo NAME` and `ash --demos`.
    `test/golden/demos.expected` stores what the command prints, through the same
    renderer, and ends with the two acceptance numbers computed from the runs.
- Acceptance: tracing prints **59 lines for `fib(3)`** — one per evaluated Core
  node, which is invariant OR made visible; a regression to a direct
  self-reference would print a handful and still return 2. Level-2 counting
  reports **715 interpreter steps for 67 program steps**, level 2 counting what
  level 1 does while it interprets level 0, having first made level 1 interpret
  at all. Both are pinned.
- Decision and documentation: ADR 0025 records the definition of depth, the two
  rejected alternatives, why the interposed interpreter must have no effect of
  its own, and why excluded observations are asserted rather than omitted. The
  §5.7 checkboxes in `Ash Reflective Tower.md` are updated — six of seven marked,
  each naming what discharges it; overlay discipline stays open for Phase 8.
  README gains "Depth, and the tower laws" and "Demos" sections plus layout and
  build-command updates; AGENTS.md names the demo command; `examples/README.md`
  documents both programs.
- Known issues: unchanged from 4.3 — the `apply` cell carries no call site,
  `eval_list` is not a meta binding, and surface `reifier(…) -> …` has no parser
  support, so the reifier-identity law is written in Core notation. New: one
  corpus program (a 310 019-step loop) exceeds the 20 000 000-step depth budget
  above depth 2 and is reported rather than silently skipped. `dune runtest` is
  now ~31 s from clean, almost all of it transparency at depths 3–5.
- Verified with OCaml 5.4.1 and Dune 3.24.2, from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all pass, as do
  `opam exec -- dune exec ash -- --demo tracing`,
  `--demo level-2-counting`, and the focused
  `test/laws/tower_laws_test.exe`, `test/unit/up_test.exe`,
  `test/unit/reifier_test.exe`, and `test/laws/open_recursion_test.exe`.
- Next: 5.1 — static/dynamic values and a `maybe-lift` evaluator mode. Static
  data are real values, dynamic data are `Code(Core)`, and one evaluator source
  supports both identity and lifting modes; ordinary evaluation and
  constant-folding tests must both pass.

### 2026-08-23 — task 4.3

- Completed: `up` and every meta binding of spec §5.2.
  - `Surface.Up` is new; the parser accepts `up` followed by a block and nothing
    else, so `up 1` is a parse error naming the missing brace. Core is unchanged.
  - `Desugar.lower_up` expands `up { E }` to `App(Reifier(exp, env, cont), [])`
    whose body binds `eval = meta_eval()`, `apply = meta_apply()`,
    `global = meta_global()`, `level = tower_level()` and ends in
    `resume(cont, E)`. The reifier's own parameters carry the printed names the
    spec gives them, so a body writes `exp`/`env`/`cont` hygienically. `resume`
    and `meta_error` are ordinary globals and needed nothing.
  - `eval` and `apply` are bound with `open_cell = true`, so reading one lowers
    to `open_deref` and `eval := f` to `open_set` — the same lowering `open fn`
    members get (ADR 0015). The cell is the level below's real group cell:
    `Machine.meta_eval_cell` / `meta_apply_cell` create it on demand, memoize it,
    and install a dispatcher in the machine's own group cell.
  - Creating a cell is observationally inert: it holds a wrapper around the
    evaluator installed at that moment, and the dispatcher compares physical
    identity, so an untouched cell runs the original host function with the same
    counters and the same constant-stack tail calls. A replacement runs on the
    machine *above* the cell, because it was written there; running it on its own
    machine is non-terminating, which is the sharpest statement of the level
    split. `let base = eval` closes over the evaluator, not the cell, so a second
    replacement wraps the first rather than recursing into itself.
  - New: `Value.meta_query`/`meta_reader` and a fifth primitive callback `~meta`;
    `Machine.levels.level_tower_depth`, a thunk the tower installs; five
    Reflection primitives `meta_eval`, `meta_apply`, `meta_global`,
    `tower_level`, `tower_depth`. The registry is 49 primitives. `tower_depth()`
    reports the *materialized* depth, since unmaterialized levels are
    observationally indistinguishable from the default (ADR 0022).
- Acceptance: `test/unit/up_test.ml` proves the §5.3 replacement keeps the
  program's answer (12) while intercepting far past the outermost node, that each
  extra level of nesting costs strictly more intercepted steps with a constant
  increment, and that level 1's own body evaluation is *not* intercepted (the
  counter moves by less than the body's own node count while `up { … }` computes
  10). It also covers resumption and one-step materialization, laziness for
  ordinary code, `exp`/`env`/`cont`/`global`, `level` at 0/1/2, `tower_depth()`
  at 0/1/2, persistence and composition of two replacements, the `apply` cell,
  the inertness of untouched cells, `meta_error` at level 1, and both refusals
  without a tower.
- Decision and documentation: ADR 0024 records the expansion, the block-only
  body, cells over rebinding, the inertness fast path, the upper-machine rule,
  the `meta_query` protocol, the materialized reading of `tower_depth()`, the
  `apply` cell's missing call site as a declared boundary, and why `eval_list` is
  not exposed as a third cell. README gains an `up` section and a desugaring
  table row; `Desugar`, `Machine`, `Value`, `Primitives`, `Tower`, and
  `Evaluator` documentation agree. No spec semantics changed.
- Known issues: the `apply` cell's protocol carries no call site, so a
  replacement that falls back to the default attributes the application to the
  fallback's own site. `eval_list` is not a meta binding; §5.2's table does not
  name it, and the default `eval_list` calls `Machine.eval` per element, so a
  replaced `eval` still sees every argument. Surface `reifier(…) -> …` still has
  no parser support — only `up` does — so §5.4's `my_if` is written in Core
  notation for now.
- Verified with OCaml 5.4.1 and Dune 3.24.2, the full suite from a removed
  `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all pass, as do the focused
  `opam exec -- dune exec test/unit/up_test.exe`,
  `test/unit/reifier_test.exe`, `test/unit/primitives_test.exe`, and
  `test/laws/open_recursion_test.exe`. The full suite retains 91 oracle/CPS
  programs, 99 self-interpreter programs at layer 1, and 98 at layer 2.
- Next: 4.4 — complete tower law tests except overlays (transparency at depths
  0-5, OR, reifier identity, level independence, error propagation, one-shot
  enforcement, depth observation), explicitly excluding timing, host stack,
  resources, and gensym counters.

### 2026-08-23 — task 4.2

- Completed: reifiers and the up/down protocol.
  - Whole-call reification lives in `eval`'s `App` case, before `eval_list`, so
    a reifier's arguments are never evaluated. The call expression, the caller's
    environment, and the caller's one-shot continuation become values; the body
    runs on the machine of the adjacent level (via `Tower.materialize_above`) in
    the lexical environment the reifier was written in, under the identity
    continuation. Applying a reifier through `apply` — `invoke` and friends —
    stays refused: there is no whole call to reify.
  - `Machine.levels` is the neutral protocol the runtime reads and the tower
    writes: level index, a thunk for the level above, the machine below. The
    thunk keeps materialization lazy; a machine with no record installed is the
    base program, refuses reifier application, and refuses `reflect`.
  - New primitives: `reflect` (Reflection, drops one level and transfers through
    the caller's applier, so the one-shot check is the ordinary one), `resume`
    (Control), and `meta_error` (Reflection, new `Error.Meta_error` cause). The
    registry is 44 primitives. `Value.primitive` implementations now receive
    `~level` and `~reflect`.
  - Errors carry the level of the machine that raised them. `raise_at` uses the
    same level instead of the old fixed `Some 0` for continuation reuse, so the
    self-interpreter and the host still agree. `Error.to_string` names a level
    only above 0, since level 0 is the base program.
- Acceptance: `test/unit/reifier_test.ml` proves the identity reifier returns its
  argument's value and evaluates its effect exactly once, unreflected arguments
  produce no effect, `resume` returns to the caller, an unresumed reifier
  abandons the level below, a continuation stored across the boundary is
  one-shot, nesting materializes exactly two levels, a level-1 evaluator patch
  changes the reifier body and not the program (109, not 198), and error
  ownership is level 1 for `meta_error` and for an unbound identity in the body,
  level 0 for the same identity in reflected code, with no resumption of level 0
  in the failing cases.
- Decision and documentation: ADR 0023 records reification in `App`, the
  definition-environment/upper-machine split, the identity continuation, the
  `Machine.levels` protocol, the three new primitives and their classes, and
  per-level error attribution — including why catching and re-raising to
  attribute levels was rejected (it breaks constant-stack tail calls). README,
  `Evaluator`, `Primitives`, `Machine`, `Value`, `Error`, and `Tower` module
  documentation agree; no spec semantics changed.
- Verified with OCaml 5.4.1 and Dune 3.24.2, the full suite from a removed
  `_build`:
  `opam exec -- dune exec test/unit/reifier_test.exe`,
  `opam exec -- dune exec test/unit/primitives_test.exe`,
  `opam exec -- dune exec test/unit/error_test.exe`,
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all pass. The full suite retains 91
  oracle/CPS programs, 99 self-interpreter programs at layer 1, and 98 at
  layer 2.
- Known issues: primitive argument diagnostics (type and domain errors raised
  inside a primitive's own helpers) still carry no level; ADR 0023 records this
  as a deliberate gap rather than half-threaded state. The self-interpreter still
  refuses reifier application, so a tower whose level runs `eval.ash` would reify
  on the host and refuse in the interpreted level — an interpreter layer is not
  a tower level (ADR 0017), and giving an interpreted level its own tower is not
  4.2's protocol. `up`, the meta bindings, and `tower_depth()` are 4.3. The
  unrelated pre-existing `dune build @fmt` failure recorded in task 3.3 remains.
- Next: 4.3 — implement `up` and all meta bindings (`exp`, `env`, `cont`, the
  evaluator cells, `global`, resume/error helpers, relative `level`, and explicit
  `tower_depth()`), accepting when a persistent evaluator replacement intercepts
  arbitrary AST depth and does not change the evaluator running its own level.

### 2026-08-23 — task 4.1

- Completed: added the `ash.tower` library with explicit `Level` and `Tower`
  abstractions.
  - Ground level 0 is retained outside the upper-level collection, so a fresh
    tower reports zero materialized levels and ordinary `Tower.run` cannot
    allocate one.
  - `Tower.materialize_above` requires an existing source level, reuses an
    existing adjacent level, or creates exactly one new adjacent level. It is
    the ownership boundary task 4.2's reifier application will call.
  - Each level calls `Primitives.globals` once and owns a fresh
    `Evaluator.machine`; identities, global cells, group cells, replacements,
    and counters are independent, while primitive values and the IO stream are
    shared through one registry.
  - Size metrics keep actual runtime representation (upper levels, cloned
    global cells, evaluator-group cells, and reachable OCaml heap words) apart
    from expanded semantic Core nodes (`|program| + depth * |interpreter|`).
- Acceptance: `test/unit/tower_test.ml` proves ordinary Core creates no upper
  level, the first materialization request creates exactly level 1, repeated and
  nested requests reuse/create exactly one adjacent level, levels 0–2 own
  independent globals and evaluator cells, a level-1 evaluator replacement does
  not affect levels 0 or 2, and only the physical size changes when a level is
  materialized.
- Decision and documentation: ADR 0022 records the separate ground baseline,
  adjacent-only materialization, shared-registry/fresh-level ownership, and the
  distinct physical/semantic measurement units. README, runtime/tower module
  documentation, and this checklist agree; no spec semantics changed.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/tower_test.exe`,
  `opam exec -- dune exec test/unit/evaluator_test.exe`,
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, and `git diff --check` all pass. The
  full suite retains 91 oracle/CPS programs, 99 self-interpreter programs at
  layer 1, and 98 at layer 2.
- Known issues: reifier application still raises its deliberate refusal; 4.2
  must connect it to `materialize_above` and supply correct per-level continuation
  and error ownership. `raise_at` consequently still emits the pre-tower fixed
  level-0 continuation context. The unrelated pre-existing `dune build @fmt`
  failure recorded in task 3.3 remains.
- Next: 4.2 — implement whole-call reification plus `reflect`, `resume`, and
  `meta_error`, accepting when the identity reifier evaluates effects exactly
  once and errors reach only level *n+1*.

### 2026-08-23 — task 3.5 and Phase 3 complete

- Completed 3.5: the self-interpreter consumes real Code.
  - `Self.interpreting` writes the subject as `Quote term` and materializes only
    a Code-keyed primitive-global frame. `Ash_self.Encode` is deleted;
    comparison-only identity abstraction now lives as `Self.reveal`.
  - `lib/self/eval.ash` dispatches directly on all eleven Core constructor
    patterns. Identifier fields remain one-node Var Code, so ordinary lookup is
    exact-identity lookup and `code_name` exposes only the printed component for
    explicit `NamedVar` resolution.
  - The open-recursive Ash `apply` member carries the whole application Code.
    Control primitive `invoke_at` delegates with that node's span; Pure
    `raise_at` implements the closed structured protocol for errors detected by
    the interpreter. Named closure arity and continuation capture/first-use
    evidence now match the host.
- Acceptance: `self_host_test.ml` removes the four-error exemption and compares
  cause, span, phase, and level for every failure. It also checks quotation as
  common Code, a synthetic-span unbound variable, `NamedVar`, reifier refusal,
  and continuation reuse. `self_layers_test.ml` makes the same complete error
  comparison at depth; `open_recursion_test.ml` patches the four-argument
  `apply`; `primitives_test.ml` pins all three new operations and their
  source-directed failures.
- Decision and documentation: ADR 0021 records real-Code/global transport, the
  printed-name boundary, source-directed application/error protocols, and the
  registry growth from 38 to 41. It amends ADRs 0009 and 0016–0018; spec §6,
  the Phase 3 roadmap, README, library docs, and this checklist agree.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/differential/self_host_test.exe`,
  `opam exec -- dune exec test/differential/self_layers_test.exe`,
  `opam exec -- dune exec test/laws/open_recursion_test.exe`,
  `opam exec -- dune exec test/unit/primitives_test.exe`, and
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, and `git diff --check` all pass. The
  full suite retains 91 oracle/CPS programs, 99 self-interpreter programs at
  layer 1, and 98 at layer 2.
- Known issues: none within Phase 3. `raise_at` records continuation level 0,
  the only runtime level before Phase 4; task 4.1/4.2 must supply per-level
  context when materialized levels arrive. The optional `dune build @fmt` issue
  recorded in task 3.3 remains unrelated to canonical verification.
- Next: 4.1 — implement lazy machine/level materialization with cloned globals,
  fresh open-recursion cells, and separate actual/expanded size metrics.

### 2026-08-23 — task 3.4

- Completed 3.4: staged-power and quasiquote-simplifier regressions.
  - The exact spec §4.3 `power` generator constructs `pow5`; `run(pow5)(2)`
    answers 32. The generated lambda is checked both closed relative to its
    level globals and alpha-equivalent to five multiplications of its own
    hygienic parameter.
  - The §4.4 simplifier is run for recursive `+ 0`, `* 1`, `* 0`, application
    descent with alpha-renamed lambda binders, and unmatched fallthrough.
- Acceptance: `test/unit/staging_test.ml` is a dedicated end-to-end suite over
  parser, desugarer, Code matching/splicing, closedness, and execution.
- Decision and documentation: no semantic decision changed; README now includes
  the accepted staged-power example and describes the simplifier coverage.
- Verified with `opam exec -- dune exec test/unit/staging_test.exe` and the full
  `opam exec -- dune runtest --force` suite.
- Known issues: none.
- Next at completion: 3.5 — retire `Ash_self.Encode` in favour of real Code.

### 2026-08-23 — task 3.3

- Completed 3.3: exhaustive fixed-domain `lift`.
  - Numbers, booleans, strings, symbols, unit, and the empty list lift to Core
    literals. Non-empty immutable lists lift recursively to an application of
    the active evaluator level's exact hygienic `list` global. Existing Code
    passes through unchanged, retaining identity and provenance.
  - Closures, reifiers, continuations, environments, cells, and primitives are
    rejected. `Error.Unliftable_value` retains the rejected leaf's opaque value
    rendering and type plus a one-based path through enclosing lists; the error
    itself remains located at the source `lift` call.
  - `Value.primitive.prim_impl` gains an evaluator-supplied `~lift` callback.
    This avoids capturing one level's global identity in the shared registry and
    avoids emitting a reflective `NamedVar("list")`. The registry grows from 37
    to 38 primitives; Reflection is now `lift` and `run`.
- Acceptance: `test/unit/lift_test.ml` covers all scalar/unit forms, empty and
  nested immutable lists, exact hygienic list identity, generated provenance,
  Code identity and Code nested in data, every rejected runtime shape, call-site
  location, and nested origin paths. `primitives_test.ml` independently pins
  class, arity, and accepted input; `error_test.ml` pins the structured message.
- Decision and documentation: ADR 0020 records the whitelist, level-hygienic
  list representation, callback, origin paths, and Reflection classification.
  Spec D6/D7, README, and amended callback/classification ADR links agree.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/lift_test.exe`,
  `opam exec -- dune exec test/unit/primitives_test.exe`,
  `opam exec -- dune exec test/unit/error_test.exe`,
  `opam exec -- dune exec test/unit/oracle_test.exe`,
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, and `git diff --check` all pass. The
  full suite retains 91 oracle/CPS programs, 99 self-interpreter programs at
  layer 1, and 98 at layer 2.
- Known issues: none within 3.3. The optional `dune build @fmt` alias remains
  non-clean because pre-existing `lib/self/dune` and `test/golden/dune` formatting
  differs from Dune's formatter and the repository has no `.ocamlformat`; the
  canonical build/test/smoke commands are unaffected.
- Next: 3.4 — add staged-power and simplifier regressions.

### 2026-08-23 — task 3.2

- Completed 3.2: deterministic closed-code analysis and reflective `run`.
  - `Ash_core.Code.unresolved_dependencies` walks all eleven Core forms under
    hygienic binding structure. It reports every free identity absent from the
    explicit available set and every occurrence span, ordered by first source
    occurrence rather than ID-map order. `Set` targets and nested `Quote` bodies
    are dependencies; `NamedVar` remains explicit run-time name lookup.
  - `Error.Open_code` carries the complete structured report. The primary error
    span is the `run` call, while its message names every missing identity and
    quoted use site in one diagnostic.
  - A machine now retains the explicit environment installed by top-level
    `Evaluator.run`. Accepted Code re-enters that same machine and continuation
    with only this level-global environment. A caller's `Let`, lambda, or closure
    frames are never inherited; quoted primitive identities still resolve and
    effects use the same registry stream.
  - `Value.primitive.prim_impl` gains a `~run` callback beside `~apply`, keeping
    evaluator dependence out of the registry and leaving future levels able to
    provide their own machine/global pair. The registry grows from 36 to 37;
    Reflection is now exactly `run`.
- Acceptance: `test/unit/run_test.ml` runs closed arithmetic, a generated
  closure, recursive Code, and observable output. It rejects caller-local and
  multi-dependency Code, retaining both occurrences of a repeated free identity
  with exact source locations; it also covers nested quotation dependencies,
  explicit `NamedVar` isolation, binding-aware analysis, and `run` type errors.
  `primitives_test.ml` independently pins the new class, arity, and type rule.
- Decision and documentation: ADR 0019 records level-global closedness, complete
  source-ordered diagnostics, whole-tree traversal, and the evaluator callback.
  Spec D5/D7 and README document the same behavior; ADR 0009 points to the
  amendment.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/run_test.exe`,
  `opam exec -- dune exec test/unit/primitives_test.exe`,
  `opam exec -- dune exec test/unit/error_test.exe`,
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, and `git diff --check` all pass. The
  full suite retains 91 oracle/CPS programs, 99 self-interpreter programs at
  layer 1, and 98 at layer 2.
- Known issues: none within 3.2. The Phase 2 self-interpreter still uses its
  temporary data encoding and therefore retains the two boundaries assigned to
  task 3.5: transported spans and host-equivalent failures detected in Ash.
- Next: 3.3 — implement the fixed `lift` domain for scalars, unit, recursively
  liftable immutable lists, and Code, with origin-aware rejection of closures,
  continuations, environments, and cells.

### 2026-08-23 — task 3.1

- Completed 3.1: hygienic quotation, splicing, constructor patterns, and
  quasiquote patterns.
  - A quotation lowers to `Quote` of a Core template. Every `${...}` position is
    a fresh free `Var` marker replaced by the pure `code_splice` primitive using
    exact identifier identity. Quoted lexical binders remain visible to nested
    quotations inside splice expressions; otherwise unbound quoted names get a
    fresh identity so Code may be open while it is assembled.
  - `Ash_core.Code` implements the identity substitution and alpha-aware
    quasiquote template matcher. `Value.equal` now compares Code with
    `Alpha.equal`, so allocation order and parameter spelling are not Code
    observations.
  - `code?` and `code_view` expose all eleven Core forms without enlarging the
    value domain: syntactic fields are Code, identifiers are one-node `Var` Code,
    and recursive bindings are pairs of identifier and lambda Code. Constructor
    patterns lower to a guarded view; `code_match` supplies Code captures to the
    full patterns inside quasiquote holes. `NamedVar(string)` is the explicit
    runtime-string constructor required by D1.
  - The registry grows from 31 to 36 primitives. All five Code operations are
    Pure under D7 because they inspect or construct immutable values;
    `Effect_class.Reflection` remains empty until evaluator-dependent execution
    and tower operations arrive.
- Acceptance: `test/unit/code_test.ml` and `test/unit/desugar_test.ml` exercise
  both adversarial directions. A free `x` spliced under `fn(x)` remains free and
  distinct from the binder; a binder `x` carried by a splice remains distinct
  from same-named template code. They also cover nested quotation scope, open
  quoted names, explicit `NamedVar`, alpha-aware Code equality, constructor
  fields, quasiquote holes, and non-Code splice errors. `primitives_test.ml`
  enumerates all eleven `code_view` tags and independently pins class, arity,
  and type behavior.
- Settled the pre-Phase-3 match question: a structural pattern on the wrong
  value shape refutes and falls through. `match 5 { [] -> 'empty; _ -> 'other }`
  now answers `'other`; `list?` and `code?` guard accessors. Directly calling an
  accessor on a wrong value remains a type error. ADR 0018 records this semantic
  change, the Code representation, and the primitive classification.
- Parser/desugarer review: no grammar rewrite was needed. Added parser coverage
  for a nested quotation inside a splice and a quoted named definition. Quote
  bodies remain one statement-shaped expression; a multi-statement quoted body
  is written as an explicit inner block, consistently with the existing surface
  AST. Golden lowering now exposes quotation, constructor/quasiquote matches,
  and the wrong-shape guards.
- Scope decision: `lib/self/eval.ash`, `Ash_self.Encode`, and the layer tests are
  semantically unchanged. Added task 3.5 to retire the encoding only after
  3.2–3.4, accepting when constructor dispatch replaces tag dispatch, spans
  cross into the interpreted level, failure locations join causes in the
  differential comparison, and the encoding module is deleted.
- Verified from a clean `_build` with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`,
  `opam exec -- dune exec ash -- --help`, and `git diff --check` all pass. The
  suite reports 73 Core plus 18 surface differential programs; 99 programs at
  self-interpreter layer 1; and 98 at layer 2, with only the 310019-step loop
  above the unchanged 800-step budget.
- Known issues: the two Phase 2 interpreter boundaries deliberately remain —
  its temporary data encoding carries no spans, and failures detected in Ash do
  not yet have the host cause/location pair. Task 3.5 owns both. Closed-code
  checking and execution are not part of 3.1; open Code cannot be passed to
  `run` until 3.2.
- Next: 3.2 — implement closed-code analysis and `run`, reporting every
  unresolved dependency and never inheriting caller lexical state.

### 2026-08-23 — task 2.3 (Phase 2 complete)

- Completed 2.3: iteration and invariant OR at depth.
  - **A layer is a term transformer.** `Self.interpreting t` builds the Core term
    that interprets `t` — the interpreter applied to the encoded program and the
    encoded globals, with both written *into* the term rather than passed beside
    it — so the result is itself something a further layer can interpret and
    layer *n* is *n* applications of one function. `Encode.datum` is what makes a
    value writable into a term: a list becomes a call of `list` and a primitive
    becomes a reference to the global that denotes it, Core literals holding only
    constants.
  - **Layer 2 forced one change to 2.2's representation.** A primitive now
    crosses levels unwrapped. `Encode.datum` writes a primitive as a `Var`, and a
    `Var` is resolved by whatever level evaluates it, so a wrapped primitive
    would arrive at the bottom level as the *middle* level's wrapper — a list,
    not something applicable. Three things fell out, all improvements: the
    `'prim` case in `apply` disappeared (a primitive is not tagged, so it takes
    the branch that delegates below, which is what applying a primitive means);
    `callcc` is recognized by value, `f == callcc`, so a program that renames it
    is still caught and one that shadows it with its own function correctly is
    not; and `Encode.reveal` leaves a primitive alone, so a program that returns
    one is now comparable rather than merely tagged alike.
  - **Layer-2 coverage is decided by a step budget, not a clock.** A program runs
    at layer 2 when its layer-0 run takes at most 800 evaluator steps — a
    property of the program, not of the machine. That admits 98 of 99 programs;
    the ten-thousand-iteration loop is the exclusion and its step count is
    printed.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all passed. `git diff --check` passed.
  The suite takes about ten seconds, essentially all of it layer 2.
- Acceptance 2.3, all layers agree: `test/differential/self_layers_test.ml`
  compares layers 0, 1, and 2 on all 91 corpus programs plus eight written for
  this task — output and control, which are the two things most likely to be lost
  on the way down a second level, and closures and primitives as values, which
  are what `reveal` and the unwrapping decision are about. It was checked by
  re-wrapping primitives in `eval.ash`, which left layer 1 almost entirely
  passing and broke layer 2 across the board.
- Acceptance 2.3, still patchable: `test/laws/open_recursion_test.ml` gains the
  patch-depth fixture. §D3's `1 + (2 * (3 - (4 / 5)))` with the patch on the
  layer that runs it observes 13 nodes — exactly the count at depth 1, even
  though the patched interpreter is itself being interpreted; with the patch on
  the layer beneath, 3540 steps, because its subject is the interpreter rather
  than the program. `apply` and `eval_list` at depth observe 4 and 12, which are
  the four operator applications and the three `eval_list` calls each
  two-argument application makes. Every variant answers the ground value.
- Decisions: ADR 0017 records layer composition, the primitive representation
  change (amending ADR 0016, which now says so), the step budget, and why layer 3
  is not tested — it runs, but takes about two minutes on the smallest useful
  program, which is a suite nobody runs rather than a stronger claim. Spec §5.7's
  open-recursion law is ticked; it asked to be tested in Phase 2 and now is,
  at depth.
- Known issues: the two boundaries 2.2 declared are unchanged — an encoded term
  carries no spans, and Ash cannot construct a structured error. Both are Phase 3
  questions about `Code`, not about the interpreter. Layer 3 and beyond work but
  are untested for cost.
- Next: Phase 3, task 3.1. Note for that work: `Code` arriving is what replaces
  `Ash_self.Encode`, lets `eval.ash` dispatch with constructor patterns instead
  of an `if` chain over the form tag, and carries the spans that would close both
  known boundaries.

### 2026-08-23 — tasks 2.1 and 2.2

- Completed 2.1: open-recursive evaluator groups at the Ash level.
  - `open fn` is now a surface binding form. The lexer had reserved `open` since
    1.1; the parser accepts it only as the head of a definition, `Surface`
    records it as `function_open` on a named function, and adjacent declarations
    of the *same* kind form one group — a `fn` run ends where an `open fn` run
    begins.
  - Lowering is cells, not `LetRec`: one `open_cell` per member, an `open_set`
    filling each with its lambda, and every reference to a member — inside the
    group and after it — as `open_deref` of that cell. `member := …` writes
    through the cell with `open_set` rather than rebinding the name, so every
    dereference already written sees the replacement. Members are assignable;
    plain `fn` bindings still are not.
  - References *after* the group are dereferences too. §D3's wording is about the
    group's own recursion, but an external caller holding the function directly
    would be a reference no replacement reaches, and the spec's own test is
    written from outside the group.
  - Three primitives were added, spelled apart from `cell_new`/`deref`/`cell_set`
    so the collapse report can count evaluator dereferences without guessing
    which cells were an interpreter's: `open_cell`, `open_deref`, `open_set`,
    all allocation/mutation. `Primitives.open_dereferences` counts reads
    performed (after the read succeeds — a refused read is not a dereference) and
    is observationally inert.
- Completed 2.2: the CPS Core evaluator written in Ash, `lib/self/eval.ash`,
  loaded and run by the new `ash.self` library.
  - It is parallel to the host evaluator: same eleven forms, same evaluation
    order, same CPS, same open group. It reads a term as tagged list data because
    quotation is Phase 3, and dispatches on the form tag with an `if` chain
    because Core constructor patterns do not lower until Phase 3 either.
  - Interpreted scalars, lists, and cells represent themselves; closures,
    reifiers, continuations, and primitives are lists headed by a private cell
    the interpreted program cannot name or forge. Each closure carries a fresh
    cell as its identity, so `==` compares places rather than shapes.
  - Two primitives were added rather than worked around: `invoke(f, args)`,
    which is §6's `prim_apply` and applies a callee to a run-time-length argument
    list (control class — its class is its callee's), and `list?`, the one type
    test, needed to tell a tagged closure from a scalar without an accessor that
    refuses. No host escape hatch: the interpreted level gets exactly the globals
    a level-0 run gets, and delegates everything else to them, which is why its
    arity, type, and arithmetic diagnostics are the host's.
  - `callcc` is the one primitive it cannot delegate — the host would capture the
    interpreter's continuation — so the interpreted level builds its own one-shot
    continuation, marked used before transfer.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all passed. `git diff --check` passed.
- Acceptance 2.1: `test/laws/open_recursion_test.ml` shows a wrapper on `eval`
  observing every nested AST node — thirteen for §D3's `1 + (2 * (3 - (4 / 5)))`,
  against the nine the spec asks for as a lower bound, and equal to
  `Core.node_count` — plus `apply` and `eval_list` patchable on the same terms, a
  replacement installed mid-evaluation taking effect at the next step (counted
  exactly), restoration of the cell restoring the group, and the dereference
  counter being inert.
- Acceptance 2.2: `test/differential/self_host_test.ml` compares the host
  evaluator and the self-interpreter on all 91 corpus programs plus 4 output and
  4 control programs, on value, cause, and observable trace. The corpus moved to
  `test/differential/corpus.ml` and both differential tests read it, so the
  second comparison cannot be run against easier programs than the first. The
  harness was checked by reversing `eval_list`'s order in `eval.ash`, which
  produced a readable minimal difference on exactly the two evaluation-order
  programs.
- Decisions: ADR 0015 (`open fn`, why references outside the group dereference
  too, why the `open_*` trio is spelled apart, why the counter is on the
  registry) and ADR 0016 (the interpreter's encoding and value domain, `invoke`
  and `list?`, delegation as the way to keep diagnostics honest, and the two
  declared boundaries). Spec §6 gained a note saying which two things in its
  sketch are deferred and pointing at ADR 0016; AGENTS gained `lib/self/` in the
  layout. The registry is 31 primitives and `Effect_class.Control` is now
  `callcc` and `invoke`.
- Known issues: **locations do not cross the encoding.** A term encoded as data
  carries no spans, so a failure raised at the interpreted level is reported
  inside `eval.ash`; the differential test therefore compares cause and not
  location. **Ash cannot construct a structured error**, so four corpus programs
  — the three closure arity errors and the surface one — report as
  `No_matching_clause` naming the condition instead of the host's
  `Arity_error`. Both are listed in `self_host_test.ml`, and the exemption list
  is asserted to be exactly the set that needs it, so a program that starts
  agreeing fails rather than sitting under an exemption nobody rechecks. Both
  are Phase 3 questions: they are about `Code` carrying spans, not about the
  interpreter. Printing an interpreted closure would print its tagged list rather
  than `#<closure>`; nothing in the corpus does.
- Next: 2.3 — test iteration and invariant OR. Run the self-interpreter on
  itself (layers 1 and 2) plus the spec's patch-depth fixture, and check that all
  layers agree and that recursive evaluation stays patchable at depth. The
  encoding is the thing to watch: layer 2 interprets layer 1's *encoded* text, so
  `Ash_self.Encode` has to survive being applied to the lowering of `eval.ash`
  itself.

### 2026-08-23 — tasks 1.5 and 1.6 (Phase 1 complete)

- Completed 1.5: first-class one-shot continuations.
  - `callcc` is registered in the previously empty `Control` class. It reifies
    the continuation of its own call and applies its receiver to it. Nothing
    about control reaches Core: a surface `callcc(f)` lowers to an ordinary
    application, so the eleven forms and the future self-interpreter are
    untouched. Spelled without a slash because `/` is division and a control
    operator a program cannot write is not much of one.
  - Capturing exposed a real gap: `Value.primitive` claimed control primitives
    could be ordinary registry members, but `prim_impl` had no way to call an Ash
    function. It now takes `~apply`, supplied by the caller — the ground
    evaluator routes it through the machine's open-recursion cell, so a replaced
    `apply` intercepts a primitive's callback too (§D3), and the oracle passes
    its own direct-style apply read as CPS. A test asserts the interception.
  - Applying a continuation is handled in `Evaluator.apply`: exactly one
    argument, the `used` flag set **before** the transfer, and a second
    invocation raising `Error.Continuation_reuse` with both the capture site and
    the first-use site, reported at the second invocation and at the
    continuation's level.
  - The meta-context retained is the tower level: `Value.continuation` takes
    `~level` and `Value.continuation_level` reads it. Only level 0 exists before
    Phase 4; the field is there now because retrofitting it means revisiting
    every capture site.
- Completed 1.6: the oracle/CPS differential corpus, extended from 46 to 91
  programs and from one comparison to four.
  - Each program is compared on value, failure cause, failure location, and
    observable trace, and only the **first** difference is reported: a report
    that lists everything two runs disagree about buries the one fact that
    explains the rest.
  - The corpus has a Core half (73 programs in canonical notation, which is what
    the self-interpreter will read) and a surface half (18 Ash programs lowered
    by the desugarer, which puts the parser and desugarer under the same
    comparison). Both cover recursion, closures, shadowing, lists, mutation,
    evaluation order, and failures.
  - Every entry declares `Succeeds` or `Fails`. Agreement alone proves nothing —
    two evaluators that both refused everything would agree perfectly — and the
    check immediately caught one entry that had been filed under errors while
    succeeding by design.
  - The harness's own reporting is tested against outcomes known to differ, and
    the frozen boundary now also covers `callcc`, observable effects, and cells.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all passed. `git diff --check` passed.
- Acceptance 1.5: `test/unit/continuation_test.ml` covers storage in a mutable
  binding and in a list, capture in one function with invocation from another
  after that function returned, escape from a recursion, abandonment of the rest
  of the receiver, the second-use error with all three sites distinct and the
  level recorded, reuse reached through the continuation's own resumption, both
  arities, and the oracle's refusal of `callcc` and of applying a continuation.
- Acceptance 1.6: all 91 programs agree; the failure path reports one readable
  difference, checked directly.
- Decisions: ADR 0014 records `callcc` as a primitive rather than syntax, its
  spelling, the `~apply` widening of `prim_impl` and why the applier is the
  caller's, before-transfer marking, the three-site reuse diagnostic, the level
  field as the retained meta-context, and why multi-shot waits. Added the
  `Continuation_reuse` error cause. The registry is 26 primitives and
  `Effect_class.Control` is no longer empty; the test that asserted it was empty
  now asserts it is exactly `callcc`, so filling it stayed deliberate.
- Known issues: none within Phase 1. Multi-shot continuations, and therefore
  backtracking reifiers, `amb`, generator re-entry, and re-entrant `meta_with`,
  are deferred by §D4. `Effect_class.Reflection` is still honestly empty. The
  differential corpus compares traces but every pure program leaves an empty one,
  because the oracle refuses observable primitives by design; trace comparison
  becomes load-bearing when residual programs arrive.
- Next: 2.1 — the Ash-level open-recursive evaluator group. The host side is
  done (`Ash_runtime.Machine`, ADR 0008) with its acceptance test at host level;
  what remains is storing `eval`, `apply`, and `eval-list` in per-level cells in
  Ash, instrumenting every dereference, and testing the same law there: wrapping
  `eval` must observe every nested AST node, not just entry.

### 2026-08-23 — task 1.4

- Completed: `Ash_syntax.Desugar`, the hygienic lowering from the surface tree to
  the eleven Core forms.
  - Names become identities here and nowhere else: one `Ident.fresh` per binder,
    every occurrence resolved through a scope. A free name is a located desugar
    error rather than a `NamedVar`, so resolution by printed name stays a
    property of reflective code and of the collapse report's count.
  - Globals are a parameter (`Desugar.scope_of_globals`), so `ash.syntax` still
    does not depend on `ash.runtime` and task 4.1's per-level cloned globals will
    drop straight in. Generated calls resolve against the globals rather than the
    lexical scope, which is what makes the documented `fn length(xs)` work while
    it shadows the `length` primitive.
  - Sugar lowered: statement sequencing, `let`/`var` with static mutability,
    `:=`, named functions as `LetRec` groups over adjacent declarations, lambdas,
    blocks, conditionals, `&&`/`||` as `If`, `!`/unary `-`, list literals, cons,
    comparison and arithmetic operators, pipelines, and `match`.
  - `match` binds its scrutinee once and thunks each clause's failure
    continuation, so a pattern can mention failure repeatedly without copying the
    remaining clauses; alternative clauses bind their shared body as a function of
    the clause's binders. Falling off the end calls the new `match_error`
    primitive.
  - Provenance: a Core node produced by a surface node of the same shape keeps
    its span; every invented node keeps the same positions and records its
    rewrite (`desugar/seq`, `desugar/unit`, `desugar/fn`, `desugar/operator`,
    `desugar/negate`, `desugar/pipe`, `desugar/and`, `desugar/or`,
    `desugar/list`, `desugar/match`).
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest --force`, and
  `opam exec -- dune exec ash -- --help` all passed from a clean build. The full
  suite includes the new `test/unit/desugar_test.ml` and
  `test/golden/desugar.expected`, the updated `primitives_test`, and the retained
  46-program oracle/CPS differential corpus.
- Acceptance: `test/unit/desugar_test.ml` parses, lowers, and runs `fact(5)` and
  `fact(20)`, the documented §4.2 `length` over `[1,2,3]` and `[]`, pipeline
  chains into both a user function and a primitive, shadowing (`let x = 1; let x
  = x + 1; x` is 2, and a shadowed `list` does not change what `[…]` means), and
  `set` through a closure (`var c = 0; fn bump() = c := c + 1` is visible after
  two calls). Shape tests compare each sugar row against expected Core up to
  alpha-equivalence, and `test/golden/desugar.expected` pins the documented
  programs, the provenance table, and every diagnostic.
- Decisions: ADR 0013 records identity allocation here, free names as errors,
  globals as a parameter with generated calls bypassing the lexical scope,
  adjacent `fn` declarations as one `LetRec` group, a trailing definition
  evaluating to unit, static `var`/`let` mutability, the thunked `match`
  lowering, `match_error` as a pure primitive, the Elixir-style pipeline rule,
  and the shape-correspondence provenance rule. Added the `Immutable_binding` and
  `No_matching_clause` error causes and the `match_error` primitive (registry now
  25).
- Known issues: none within 1.4. Quotation, splicing, Core constructor patterns,
  and quasiquote patterns are refused with `Unsupported` naming the missing
  phase; 3.1 removes those refusals. Match compilation is intentionally
  unoptimized — an irrefutable last clause still allocates its failure thunk —
  because residualization, not the desugarer, is where size is meant to be won.
- Next: 1.5 — first-class one-shot continuations: retain the continuation
  procedure, used flag, capture site, and meta-context; mark used before
  transfer; report both capture and first-use sites on reuse; and cover storage,
  delayed and cross-function invocation, and the second-use error.

### 2026-08-23 — task 1.3

- Completed: the complete source-located pattern grammar and the match,
  quotation, and splice syntax needed to represent it.
  - `Surface.pattern` covers wildcard, integer/string/symbol/boolean/unit
    literals, variables, list patterns, right-associative cons, alternatives,
    all eleven Core constructors, quasiquote patterns, and grouping.
    `Surface.pattern_binders` retains source order for hygienic lowering.
  - `Parser.pattern` and match-clause parsing share the same implementation.
    Match clauses use newline/semicolon layout and cannot be empty. Core
    constructor spellings form a closed vocabulary with exact arity checks.
  - Quotation is syntax-only at this phase. A splice is tagged as either
    `Expression_splice` or `Pattern_splice`, so quasiquote holes can contain full
    patterns and participate in binder validation without being reinterpreted
    after parsing.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/parser_test.exe`,
  `opam exec -- dune exec test/unit/error_test.exe`,
  `opam exec -- dune runtest`, `opam exec -- dune build @all`, and
  `opam exec -- dune exec ash -- --help` all passed. The full suite retained the
  46-program oracle/CPS differential corpus. `git diff --check` passed.
- Acceptance: the exact documented `length` and `simplify` programs parse and
  are pinned structurally in `test/golden/parser.expected`. The same golden also
  shows every Core constructor pattern, both pattern precedence rows, expression
  versus pattern splices, and located failures for duplicate binders,
  inconsistent alternatives, unknown/wrong-arity constructors, stray splices,
  and malformed lists. Unit tests traverse expression and pattern trees to
  verify their source spans.
- Decisions: ADR 0012 records unique binders per match path; identical binder
  sets across alternative arms; right-associative pattern cons; the closed,
  arity-checked Core constructor vocabulary; context-tagged splices; and
  newline/semicolon match-clause layout. Added the structured
  `Inconsistent_pattern_binders` error cause. The spec's contradictory
  constructor illustration now uses separate clauses instead of one
  differently-binding alternative; ADR 0011 was clarified to place syntax-only
  quote/splice parsing here while retaining all hygiene and execution semantics
  for Phase 3.
- Known issues: none within 1.3. Quote/splice nodes deliberately have no dynamic
  or hygienic meaning yet; 1.4 only needs to preserve them, while Phase 3 defines
  code construction, hygiene, lifting, and execution.
- Next: 1.4 — hygienically desugar sequencing, `var`, named functions, match,
  Boolean sugar, lists, and pipelines to Core while preserving spans and
  generated-node provenance; prove `fact`, `length`, pipelines, shadowing, and
  mutation end to end.

### 2026-08-23 — task 1.2

- Completed: the source-located surface AST, handwritten precedence parser, and
  structural debug printer.
  - `Ash_syntax.Surface` preserves located names, binding mutability, recursive
    named declarations, anonymous functions, calls, blocks, conditionals, lists,
    mutation, grouping, and unary/binary operators for hygienic lowering in 1.4.
    Whole nodes and operator tokens retain spans; no hygienic ID is allocated by
    parsing.
  - `Ash_syntax.Parser.expression` accepts exactly one statement-shaped form;
    `Parser.program` accepts statement lists separated by newline or `;`.
    Newlines remain whitespace wherever the grammar already expects an
    expression, including after a function `=` and inside calls/lists.
  - The recursive-descent layers implement the spec table literally: pipeline,
    `||`, `&&`, comparisons, right-associative `::`, additive, multiplicative,
    unary, and left-associative calls. Other binary layers associate left.
    Mutation is right-associative below pipelines and requires a name target.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune exec test/unit/parser_test.exe`,
  `opam exec -- dune runtest`, `opam exec -- dune build @all`, and
  `opam exec -- dune exec ash -- --help` all passed. The full test run retained
  the 46-program oracle/CPS differential result. `git diff --check` passed.
- Acceptance: `test/golden/parser.expected` exposes every adjacent precedence
  boundary, the complete precedence ladder, and associativity at every level,
  plus bindings, mutation, named/anonymous functions, calls, blocks,
  conditionals, lists, pipelines, layout, and located diagnostics. Focused unit
  tests additionally traverse parsed trees to ensure all nodes have source spans.
- Decisions: ADR 0011 records contextual statement layout; explicit surface AST
  retention; left association for every binary row not marked otherwise by the
  spec; right association for cons and mutation; mutation below pipelines;
  trailing-comma rejection; and parser-level rejection of field access, which
  ADR 0010 had required because Ash has no field-bearing values.
- Known issues: none within 1.2. Reserved syntax for match/patterns, quotation,
  and tower forms remains deliberately unparsed until its checklist task, so no
  placeholder AST claims unsupported semantics.
- Next: 1.3 — add wildcard, literal, variable, list, alternative, Core
  constructor, and quasiquote patterns; reject inconsistent binders; make the
  documented `length` and `simplify` examples parse.

### 2026-08-23 — task 1.1

- Completed: the surface lexer, its token vocabulary, and the first golden tests.
  - `Ash_syntax.Token`: the 50-kind lexicon of spec §4, with three renderings —
    `spelling` (write it back as source), `describe` (the noun phrase after
    "expected" or "found"), and `name` (the tag reports print). Every token
    carries a span and whether a line break precedes it.
  - `Ash_syntax.Lexer`: `#` comments, integer/string/symbol/boolean literals,
    names and the thirteen reserved words, operators by maximal munch, `` `{ ``
    and `${` as single tokens, and punctuation. `is_name` is the single place
    that knows what a name looks like.
  - `Ash_syntax.Cursor`: extracted from the s-expression reader and now shared
    with it, so the two notations cannot disagree about where a character is.
    `Sexp` is unchanged apart from using it.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are
  `test/unit/lexer_test.ml` and `test/golden/`; both were validated by
  perturbing the lexer — dropping `|>` from the two-character table and letting
  a number run into a name — and confirming each produced a readable failure and
  a reviewable golden diff before being restored.
- Acceptance: `test/golden/lexer.expected` pins the maximal-munch table for
  every ambiguous operator prefix (`| || |>`, `= ==`, `! !=`, `< <=`, `> >=`,
  `: :: :=`, `- ->`, `&&`, `` ` ``/`$` plus brace) and the rendered diagnostic
  for every malformed literal and stray character, alongside the token stream
  for each §4–§6 sample in the spec. The unit test ends by checking the corpus
  produced every token kind, so a kind nobody lexes fails naming itself.
- Decisions: ADR 0010 records the surface lexicon and layout — `#` comments here
  and `;` there, a `starts_line` flag rather than newline tokens or mandatory
  semicolons, malformed literals refused rather than split, `?` allowed at the
  end of a name and `!` never in one, reserving a word only when the parser must
  recognize it before parsing what follows (which is why `meta_with` is reserved
  and `run`/`lift`/`reflect`/`eval` are not), maximal munch with `:` and `&`
  deliberately absent from the one-character table, and golden files compared by
  dune's `diff` action so the diff is the review.
- Known issues: none. `.` is lexed although no parser consumes it yet — Ash
  values have no fields, so 1.2 will reject it in the grammar, which gives a
  better message than rejecting it in the scanner.
- Next: 1.2 — the precedence parser: bindings, mutation, functions, calls,
  blocks, conditionals, lists, pipelines, and the spec's exact
  precedence/associativity table, with golden tests at every precedence
  boundary.

### 2026-08-23 — task 0.9 (Phase 0 complete)

- Completed: the classified primitive registry and the observable-effect stream.
  - `Ash_runtime.Io`: an injectable stream recording `Wrote` and `Read` events in
    order, with scripted input, an optional echo channel, and `trace`/`text`
    renderings. Observable effects are values a test can compare rather than
    characters that have left the process.
  - `Ash_runtime.Primitives` is now a registry instance over a stream, not a
    constant list. Added `cell_new`, `deref`, `cell_set` (allocation/mutation)
    and `print`, `println`, `read_line` (observable effect) to the existing
    eighteen pure primitives. `classification`, `class_of`, `by_class`, `names`,
    and `count` are derived from the registry rather than written twice;
    construction refuses a duplicate name, which is the only way two classes
    could attach to one name.
  - Control and reflection are registered empty. `call/cc` needs 1.5 and `lift`,
    `run`, `reflect`, `up` need staging and the tower; a primitive that exists
    but refuses to run would claim a capability Ash does not have.
  - `Error.End_of_input` is a new cause, for `read_line` past the last line.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/primitives_test.ml`; the harness was validated by perturbing the
  registry four ways — reclassifying `print` as pure, dropping `println`'s
  newline, making `cell_set` write a constant, and giving `not` the wrong arity —
  and confirming each produced a readable failure before being restored.
- Acceptance: every primitive has exactly one class (the classes partition the
  registry, checked over `Effect_class.all`, and the test carries its own
  classification table so an unclassified addition fails), and arity and type
  errors are consistent registry-wide — every primitive is applied at every wrong
  count, through the evaluator and directly, and both paths must report the same
  cause at the call site; each primitive's rejections are listed in a table whose
  keys must equal the registry's names.
- Decisions: ADR 0009 records the registry-as-instance shape, buffered and
  scripted IO, `print` writing a string's characters while a diagnostic writes its
  literal, `cell_set` rather than the spec's `set` (Core already has a `Set`
  form), immutable list operations staying pure because the allocation class is
  about cells, and empty control/reflection classes over stubs.
- Known issues: none. `test/unit/oracle_test.ml` now checks the frozen boundary
  against the registry — it refuses every non-pure primitive by class, so a
  primitive added to any other class is outside the oracle the day it is
  registered.
- Next: 1.1 — the lexer with source spans. Phase 0 is complete: Core, the
  reader/printer, the oracle, the CPS evaluator, and the primitive registry all
  pass their acceptance criteria from a clean process.

### 2026-08-23 — task 0.8

- Completed: added `Machine` and `Evaluator` to `ash.runtime`.
  - `Machine`: `eval`, `apply`, and `eval_list` in mutable cells, with every
    group call going through the module so each one re-reads its cell, plus
    counters for group calls, per-form dispatches, cell dereferences, and
    `NamedVar` lookups.
  - `Evaluator`: all eleven Core forms in CPS. `LetRec` preallocates cells then
    fills them with closures over the extended environment. `Quote` yields code
    and `Reifier` yields a reifier value; applying a reifier (needs 4.2) or a
    continuation (needs 1.5) is refused with `Error.Unsupported` naming the
    missing piece. Primitives receive the real continuation, not the identity
    one.
  - `Env.lookup_by_name` now returns the identity alongside the cell, and
    `Env.read_by_name_exn` is what `NamedVar` evaluates through; `Core` gained
    `kind_names`, `kind_count`, and `kind_index` for per-form counters.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/evaluator_test.ml` and `test/differential/oracle_cps_test.ml`; the
  differential harness was validated by reversing `eval_list` and confirming it
  reported a readable minimal difference before being restored.
- Acceptance: `fact(20)` gives 2432902008176640000, and the oracle and CPS
  evaluator agree on 46 programs — values, mutation, evaluation order, and
  failures compared by both cause and span. A hundred thousand Ash tail calls run
  in constant host stack, confirming the CPS/TCO assumption from ADR 0003.
- Decisions: ADR 0008 records making the evaluator open-recursive from the first
  line rather than at 2.1. The spec puts direct self-references first on its list
  of traps and AGENTS invariant 3 is unconditional, both of which outrank
  checklist ordering; retrofitting would touch every recursive call site and the
  failure it causes is silent. It also records instrumentation going in with the
  evaluator, refusing unbuilt operations by name, and comparing differential
  failures by location as well as cause.
- Known issues: none. Task 2.1's host side is satisfied and tested; its Ash-level
  half remains, and the checklist entry now says so.
- Next: 0.9 — the classified primitive registry: every primitive in exactly one
  effect class, buffered observable output for deterministic tests, and
  consistent arity and type errors.

### 2026-08-23 — task 0.7

- Completed: added the `ash.runtime` library (`lib/runtime/`) with `Primitives`
  and `Oracle`, plus the supporting core changes they needed.
  - `Oracle` (112 lines): direct-style evaluation of `Lit`, `Var`, `Lam`, `App`,
    `Let`, `LetRec`, `If`, and `Set`. It refuses `NamedVar`, `Quote`, `Reifier`,
    applying a continuation, and any primitive that is not `Pure`, reporting
    `Error.Unsupported` with the location of what it refused.
  - `Primitives`: the pure set — `+ - * / %`, `< <= > >=`, `== !=`, `not`,
    `cons`, `head`, `tail`, `empty?`, `length`, `list` — all `Effect_class.Pure`,
    with `globals ()` allocating fresh identities per call so a materialized
    level can clone them.
  - `Error` gained `Arity_error`, `Unsupported`, and `Division_by_zero`; `Value`
    gained `type_phrase` and `equal`, and `prim_impl` now takes `~call_site` so a
    primitive that rejects an argument can locate the complaint.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/oracle_test.ml`, checked to fail loudly by perturbing an expected
  value before restoring it.
- Acceptance: arithmetic, functions and closures, lexical scope, `If`, `Let`,
  `LetRec` (factorial, 20!, mutual recursion, empty group), and immutable-list
  fixtures including two recursive list functions all pass, alongside the
  refusals that keep the oracle frozen.
- Decisions: ADR 0007 fixes the dynamic semantics every later evaluator must
  match — function position first then arguments left to right, `If` requiring a
  boolean with no truthiness coercion, truncating division with a
  sign-of-dividend remainder and division by zero an error, and `==` structural
  on scalars and lists but identity elsewhere — plus the oracle's frozen
  boundary, central arity checking, and reusing `Error.Unexpected` for runtime
  type errors since `phase` already distinguishes them.
- Known issues: none. The primitive set is deliberately pure-only; 0.9 adds the
  other four classes, buffered output, and the completeness check. `truthy` is
  not implemented yet — the self-interpreter's `my_if` will need it in 2.2.
- Next: 0.8 — the real evaluator in CPS: explicit CPS `eval`, `apply`, and
  `eval-list`, `LetRec` via preallocated cells, evaluator-step and
  constructor-dispatch counters from the start, `fact(20)` working, and agreement
  with the oracle on the initial corpus.

### 2026-08-23 — task 0.6

- Completed: added `Alpha` to `ash.core` and `Core_printer` to `ash.syntax`.
  - `Alpha.equal` decides alpha-equivalence by walking both terms in step under a
    correspondence between their bound identifiers; free identifiers must be
    equal as identities. `Alpha.canonicalize` renumbers bound identifiers by
    first occurrence so that `Core.equal_structure` on canonicalized terms *is*
    alpha-equivalence. `Alpha.free_idents` supports both and the printer.
  - `Core.equal_structure`: structural equality ignoring spans, documented as
    explicitly not alpha-equivalence.
  - `Core_printer`: prints the canonical notation with capture-avoiding renaming.
    A printed binder never shadows a visible name, so within any scope one
    printed name denotes exactly one binder. Terms whose free identifiers print
    alike are refused rather than printed misleadingly.
  - `Sexp.is_readable_atom` keeps the lexical rules in one place.
  - `Ident.Canon` is now erase-only and numbers canonical slots negatively.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/alpha_test.ml` and `test/unit/printer_test.ml`, both checked to fail
  loudly by perturbing an expected value before restoring it.
- Acceptance: `read(print(core))` is alpha-equivalent for all twenty-two printer
  fixtures, covering every Core form plus shadowing binders, same-name
  parameters, same-name recursive binders, same-name reifier parameters,
  quotation of a variable bound outside the quote, a binder adjacent to a free
  name of the same spelling, and an unreadable binder name. Alpha-equivalence is
  additionally checked pairwise against canonical structural equality over a
  ten-term corpus.
- Decisions: ADR 0006 records deciding alpha-equivalence by lockstep walk rather
  than by canonicalizing both terms, the disjoint negative numbering for
  canonical identities, the never-shadow printing discipline, and refusing to
  print terms with indistinguishable free names. It also amends ADR 0002, whose
  `Keep_names` policy was predicted to serve the printer and did not — the
  printer must avoid capture, which renumbering does not do — so the policy was
  removed unused.
- Known issues: none. Note that printed-and-reread terms must never be compared
  with `Core.equal_structure`; reading allocates fresh identities, so the
  relationship is alpha-equivalence.
- Next: 0.7 — the frozen direct-style oracle: pure ordinary Core only, explicitly
  forbidding reflection, staging, and continuation extensions, with arithmetic,
  functions, lexical scope, `If`, `Let`, `LetRec`, and immutable-list fixtures.

### 2026-08-23 — task 0.5

- Completed: added the `ash.syntax` library (`lib/syntax/`) with `Sexp` and
  `Core_reader`, plus supporting changes in `ash.core`.
  - `Sexp`: s-expression data with spans — integers, `#t`/`#f`, strings with the
    same escapes `Constant.escape_string` emits, `'symbols`, bare atoms, and
    lists — with `of_string`, `one_of_string`, and a canonical `to_string` that
    is the round-trip partner of the reader. Comments use `;`, because the
    surface language's `#` collides with `#t`/`#f`.
  - `Core_reader`: one spelling per Core form, validating shape and arity and
    resolving printed names to fresh hygienic identities. Quoted code is read in
    the enclosing scope so a quoted variable keeps its binder ID; a name with no
    binder is an error unless a supplied `scope` provides one; one binder list
    may not bind a name twice.
  - `Error` gained six syntactic causes and the structural comparisons
    `cause_equal` and `equal`; `Core` gained `of_lambda`.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/reader_test.ml`, checked to fail loudly by perturbing an expected
  value before restoring it.
- Acceptance: every Core form's canonical text round-trips through
  `Sexp.of_string`/`to_string` unchanged and reads back as the expected form, and
  eighteen malformed inputs are each checked for both their structured cause and
  their exact rendered location, including across a newline.
- Decisions: ADR 0005 records the one-spelling-per-form notation, the split
  between the datum layer and Core validation, name-to-identity resolution with
  explicit scopes for open terms, quoted code reading in the enclosing scope, and
  rejecting a printed name bound twice in one binder list rather than resolving
  it by entry order.
- Known issues: none. Note that `read` is deliberately not idempotent on
  identities — two reads of the same text are alpha-equivalent, not equal — so
  cross-read comparison must wait for 0.6's alpha-equivalence.
- Next: 0.6 — the Core printer and alpha-equivalence: print deterministic
  readable binders and compare through canonical IDs, with
  `read(print(core))` alpha-equivalent for every form including shadowing,
  `LetRec`, quotation, and reifiers.

### 2026-08-23 — task 0.4

- Completed: added `Env` and `Error` to `lib/core/`.
  - `Env`: `lookup`, `lookup_exn`, `state`, `read_exn`, `lookup_by_name`,
    `lookup_by_name_exn`, `bind`, `bind_cell`, `extend`, `extend_cells`,
    `preallocate`, `assign`, `assign_exn`, `depth`, and `idents`. `state` is a
    three-way `Unbound | Unfilled | Bound` answer so a preallocated `LetRec` cell
    is never confused with an absent binding. Assignment fills an existing cell
    and never creates a binding, which is what makes `Set`, recursive filling,
    and meta-level writes one mechanism.
  - `Error`: phase, span, relative tower level, and a structured cause
    (`Unbound_ident`, `Unbound_name`, `Ambiguous_name`, `Unfilled_binding`),
    raised as `Error.Ash_error` and formatted only at the boundary.
  - `Value.frame_of_list` now rejects a repeated binder identity instead of
    silently dropping a binding.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/env_test.ml` and `test/unit/error_test.ml`; both were checked to
  fail loudly by perturbing an expected value before restoring it.
- Acceptance: tests cover shadowing by identity across frames, closure-visible
  mutation through shared cells (and that rebinding is deliberately *not*
  visible to a captured chain), recursive preallocation including the
  unfilled-read error, name lookup with innermost-frame resolution and the
  ambiguous case, and the failure behaviour of every `_exn` operation with its
  span, phase, level, and rendered message.
- Decisions: ADR 0004 records that a name bound twice in one frame is an error
  rather than a winner chosen by allocation order — deciding it by ID would make
  the gensym counter observable, and D9 excludes that channel — plus the
  three-way binding state, assignment never binding, one frame per extension, and
  errors propagating as an exception rather than through `answer`, with rendering
  that never prints unique IDs so golden diagnostics stay stable.
- Known issues: none. Note for 0.8 and 4.2 that if `meta_error` needs errors as
  ordinary values at level *n+1*, that is a level-crossing mechanism and must not
  quietly widen the ground `answer` type.
- Next: 0.5 — the canonical Core s-expression reader (debug/test format, not the
  surface parser): validate shape and arity, retain source spans, and report
  malformed forms with their location.

### 2026-08-23 — task 0.3

- Completed: added `Core`, `Value`, and `Effect_class` to `lib/core/`.
  - `Core`: all eleven forms with a span on every node, validating constructors
    (a lambda, `letrec`, or reifier that repeats a binder *identity* raises
    `Invalid_argument`, while repeating a printed name is legal), plus
    `kind_name`, `children`, `binders`, `node_count`, `with_span`, and
    `mark_generated`. `LetRec` bindings hold a `lambda` rather than an arbitrary
    expression, and `Reifier` has three named parameters.
  - `Value`: scalars, immutable lists, closures, reifiers, one-shot
    continuations, first-class environments, cells, `Code`, and CPS primitives.
    `answer = value`. `cell` and `continuation` are private records so mutation
    stays centralized in `fill_cell` and `mark_continuation_used`; cell contents
    are `value option` so a preallocated `LetRec` cell reads as unfilled rather
    than as a default. Environments and frames are immutable.
  - `Effect_class`: §D7's five classes with `may_fold_when_static` and
    `always_residualizes`, required on every primitive from the start.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`, and
  `opam exec -- dune exec ash -- --help` all passed. New tests are in
  `test/unit/data_model_test.ml` (93 assertion sites, several iterating over
  every fixture); the harness was checked to fail loudly by perturbing an
  expected value before restoring it.
- Acceptance: there is a fixture for every Core form and every value shape, the
  test asserts both enumerations are complete with distinct names, and no match
  over a Core form or value shape anywhere in the library uses a catch-all —
  including the negative arms of `to_constant` and the printers — so a new
  variant is a compile error rather than a fallthrough.
- Decisions: ADR 0003 records `answer = value` (relying on OCaml's guaranteed
  TCO, since host stack depth is an excluded observation), lambda-only `LetRec`
  bindings, the three-parameter reifier, private cells and continuations with
  option-typed cell contents, immutable frames, CPS primitives carrying an
  effect class, and separate runtime scalars bridged to `Constant.t`.
- Known issues: because frames are immutable, a level's global environment needs
  a per-level reference rather than a mutable frame — that lands with lazy level
  materialization in 4.1. `Core.children` deliberately includes a `Quote` body,
  so evaluator traversals must not use it to mean "evaluated positions".
- Next: 0.4 — explicit environments and cells (`lookup`, `lookup-by-name`,
  `bind`, `extend`, `preallocate`, `assign`, with located unbound-name errors).
  Note that `lookup-by-name` needs a documented rule for two same-name binders in
  one frame, since `Ident.Map` has no insertion order.

### 2026-08-23 — task 0.2

- Completed: added the `ash.core` library (`lib/core/`) with `Span`, `Constant`,
  and `Ident`.
  - `Span`: positions, joining, and a provenance model where a generated node
    inherits its origin's positions and adds a `Generated { by; from }` marker;
    `source_span` recovers the human-written region and `generators` reports the
    nested phase chain.
  - `Constant`: the closed literal domain `Num | Bool | Str | Sym | Unit | Nil`
    with structural equality, a total order, `type_name` for error messages, and
    escaping printers.
  - `Ident`: `private { name; id }` so allocation stays centralized in one
    `Atomic` counter; identity is the ID, the name is for humans;
    `Ident.Set`/`Ident.Map`; and `Ident.Canon` renumbering by first occurrence
    under `Erase_names` (alpha-equivalence) or `Keep_names` (readable printing),
    with `fix` for free identifiers.
- Verified with OCaml 5.4.1 and Dune 3.24.2 from a removed `_build`:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`,
  `opam exec -- dune exec ash -- --help`, and
  `opam exec -- dune exec ash -- --version` all passed. New unit tests live in
  `test/unit/core_test.ml` (88 assertions, all passing).
- Acceptance: same-name/different-ID binders stay distinct through `equal`,
  `compare`, `Set`, `Map`, and canonicalization; alpha-renamed identifier
  sequences canonicalize to structurally equal results, independently of
  allocation order.
- Decisions: ADR 0002 records the integer-only numeric domain, the private
  identifier record with a single atomic counter, first-occurrence
  canonicalization with explicit fixing of free identifiers, and the generated
  span provenance model.
- Known issues: canonicalization is currently sequence-level because Core does not
  exist yet; binding-aware alpha-equivalence over terms is task 0.6 and must call
  `Canon.fix` on the free identifiers of the terms it compares.
- Next: 0.3 — implement the complete Core and value data model.

### 2026-08-23 — task 0.1

- Completed: switched the host decision to OCaml, recorded ADR 0001, initialized
  Git, and added the Dune library/CLI/test/documentation skeleton.
- Verified with OCaml 5.4.1 and Dune 3.24.2:
  `opam exec -- dune build @all`, `opam exec -- dune runtest`,
  `opam exec -- dune exec ash -- --help`, and
  `opam exec -- dune exec ash -- --version` all passed.
- Known issues: none. The CLI intentionally contains only bootstrap help/version.
- Next: 0.2 — source spans, constants, and hygienic identifiers.

### 2026-08-23 — planning

- Completed: execution plan and repository-wide agent guidance.
- Verified: workspace originally contained only `Ash Reflective Tower.md` and was
  not a Git repository.
- Next: superseded by the completed task 0.1 entry above.
- Decisions: initially selected Racket; superseded by ADR 0001 selecting OCaml.
