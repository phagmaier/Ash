# Ash

Ash is a small hygienic language with a CPS self-interpreter, a lazily
materialized reflective tower, and a staged partial evaluator that explains where
interpreter behavior can and cannot be erased.

The detailed design is in [`Ash Reflective Tower.md`](Ash%20Reflective%20Tower.md),
and the ordered implementation plan is in [`to-do.md`](to-do.md).

## Requirements

- OCaml 5.2 or newer
- Dune 3.16 or newer
- opam is recommended for managing the toolchain

The currently verified development environment uses OCaml 5.4.1 and Dune 3.24.2.

## Build and test

Run commands inside the active opam switch:

```sh
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune exec ash -- --help
```

The CLI is only a bootstrap shell at present. Follow the first unchecked task in
`to-do.md` to continue implementation.

## Repository layout

| Path | Contents |
|------|----------|
| `bin/` | CLI entry point |
| `lib/core/` | `ash.core`: spans, constants, hygienic identifiers, the Core AST, values, environments, and errors |
| `lib/syntax/` | `ash.syntax`: the shared scanning cursor, s-expression data, the canonical Core reader/printer, and the surface lexer, AST, precedence parser, and desugarer |
| `lib/runtime/` | `ash.runtime`: the classified primitive registry, the observable-effect stream, the CPS evaluator, and the frozen oracle |
| `lib/self/` | `ash.self`: the self-interpreter written in Ash (`eval.ash`), its Core-to-data encoding, and the harness that runs it |
| `lib/` | `ash`: version metadata, and later the layers above Core |
| `test/unit/` | module-level behaviour tests |
| `test/differential/` | oracle/CPS and CPS/self-interpreter comparisons on one shared corpus |
| `test/laws/` | semantic invariants — currently open recursion at the Ash level |
| `test/golden/` | pinned token streams, diagnostics, and reports |
| `docs/decisions/` | numbered architecture decision records |
| `docs/progress/` | experiment and reproducibility notes |

Lower layers never import higher ones: `ash.core` knows nothing about the tower,
staging, or classification.

## Core identity model

Ash identifiers are hygienic by construction. `Ash_core.Ident.t` pairs a printed
name with a unique ID, so `fn(x) -> x` and an unrelated `x` are different terms
even though they print alike, and only `Ident.fresh` (and its derivatives) can
allocate one. The ID counter is an excluded observation: never compare terms by
raw IDs, canonicalize them with `Ident.Canon` first. `Erase_names` (the default)
renumbers and erases printed names, so alpha-renamed terms become structurally
equal; `Keep_names` renumbers but keeps names for readable printing. Register any
identifier that is free in the compared term with `Canon.fix` before traversal.

`Ash_core.Span` carries locations through surface syntax, Core, residual
provenance, and errors. A node invented by a later phase is not location-less: it
keeps the positions of the source it came from and adds a `Generated` marker
naming the phase, so `Span.source_span` still points diagnostics at user text
while `Span.generators` explains where the node came from.

See [`docs/decisions/0002-core-constants-and-identifiers.md`](docs/decisions/0002-core-constants-and-identifiers.md)
for the numeric domain and alpha-equivalence rationale.

## Core and values

`Ash_core.Core` is the eleven-form Core language — `Lit`, `Var`, `NamedVar`,
`Lam`, `App`, `Let`, `LetRec`, `If`, `Set`, `Quote`, `Reifier` — with a span on
every node. `NamedVar` is a distinct form rather than a `Var` with a null ID,
because a name resolved against an environment that is not statically known is a
specialization barrier the collapse report has to count. `LetRec` is a Core form
and binds lambdas in the type, so the preallocate-then-fill implementation cannot
observe an unfilled cell.

`Ash_core.Value` is the runtime domain: scalars, immutable lists, closures,
reifiers, one-shot continuations, first-class environments, cells, `Code`, and
primitives. `Code` lives in the same domain as everything else, which is what
makes the collapser online — a static value is a real value, a dynamic value is
`Code`. Cells are the only mutable part and can only be mutated through
`Value.fill_cell`; environments and frames are immutable. Primitives are CPS and
carry an `Ash_core.Effect_class`, so no primitive can exist without a staging
policy.

No match over a Core form or value shape in this project uses a catch-all case:
adding a variant is meant to be a compile error at every site that interprets
one. See
[`docs/decisions/0003-core-and-value-representation.md`](docs/decisions/0003-core-and-value-representation.md).

## Environments and errors

`Ash_core.Env` operates on the frame chains in `Value`: `lookup`, `state`,
`lookup_by_name`, `bind`, `extend`, `preallocate`, and `assign`. Frames are
immutable and searched innermost first, so shadowing is frame order; values are
reached through cells, so an assignment is visible to every closure that already
captured the binding. `Env.state` distinguishes unbound from bound-but-unfilled,
which `LetRec` preallocation needs. Assignment never creates a binding.

A single frame that binds two distinct identifiers printing alike makes a
`NamedVar` lookup ambiguous, and Ash reports that rather than picking one:
resolving by allocation order would make the gensym counter observable, and that
channel is explicitly excluded from Ash's equivalence claims.

`Ash_core.Error` carries the phase, span, tower level, and a structured cause,
and is formatted only at the boundary. Rendered diagnostics print identifiers by
printed name and never by unique ID, so golden output cannot depend on allocation
order; `Error.to_string_debug` adds IDs for interactive use only. See
[`docs/decisions/0004-environments-and-structured-errors.md`](docs/decisions/0004-environments-and-structured-errors.md).

## Writing Core down

`Ash_syntax.Core_reader` reads the canonical Core notation — a debug and test
format, not the Ash surface syntax, which is Phase 1. Every form has exactly one
spelling:

```text
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
```

The notation is written in printed names, but Core is hygienic, so the reader
resolves names to identities: each binder allocates a fresh identifier and
occurrences under it read as that identifier. Two reads of the same text are
alpha-equivalent, not equal. A name with no binder in scope is an error — pass a
`scope` to read open terms. Quoted code is read in the enclosing scope, so a
quoted variable keeps the binder ID of the binding it was written under, and one
binder list may not bind a printed name twice. Comments start with `;`, since
`#t` and `#f` need the hash. See
[`docs/decisions/0005-canonical-core-notation.md`](docs/decisions/0005-canonical-core-notation.md).

`Ash_syntax.Core_printer` prints that notation back. Because several binders can
print alike, it renames as it goes, and further than capture-avoidance strictly
requires: **a printed binder never shadows a name already visible**, so within
any scope one printed name denotes exactly one binder. A term whose *free*
identifiers print alike has no faithful written form and is refused rather than
printed misleadingly.

## Comparing terms

Binder identities come from a global counter, so terms that mean the same thing
are almost never structurally equal. Every equivalence claim Ash makes is up to
alpha-equivalence, and `Ash_core.Alpha` is where that lives:

- `Alpha.equal` decides alpha-equivalence directly, walking both terms in step.
  It is the comparison to reach for by default.
- `Alpha.canonicalize` rewrites a term so that `Core.equal_structure` on
  canonicalized terms *is* alpha-equivalence — for normalizers and for report
  keys. Canonical identities are numbered negatively so they can never collide
  with an allocated one.
- `Core.equal_structure` is plain structural equality ignoring spans. It is
  deliberately *not* alpha-equivalence.

`read (print t)` is alpha-equivalent to `t`, never equal to it: reading allocates
fresh identities. `Core_printer.to_string (Alpha.canonicalize t)` is the stable
textual key for a term. See
[`docs/decisions/0006-core-printing-and-alpha-equivalence.md`](docs/decisions/0006-core-printing-and-alpha-equivalence.md).

## Running Core

`Ash_runtime.Oracle` is the frozen direct-style oracle: about a hundred lines of
ordinary recursive evaluation whose only job is to say what a pure Core program
means, so the CPS evaluator, the tower, and every residual program can be checked
against something independent. It is deliberately never extended — it refuses
`NamedVar`, `Quote`, `Reifier`, continuations, and any primitive that is not
pure. Its value comes entirely from being simple enough to believe by reading,
and every feature it grew would be a feature it could no longer check.

The dynamic semantics the oracle fixes, which every later evaluator must match:

- the function position is evaluated first, then arguments left to right;
- `If` requires a boolean — there is no truthiness coercion in Core;
- integer division truncates toward zero, the remainder takes the sign of the
  dividend, and dividing by zero is an error;
- `==` compares scalars and lists structurally and everything else by identity.

See
[`docs/decisions/0007-oracle-semantics-and-pure-primitives.md`](docs/decisions/0007-oracle-semantics-and-pure-primitives.md).

`Ash_runtime.Evaluator` is the real one: Core in continuation-passing style,
because a reflective procedure receives the continuation of the level below and
in direct style that lives on the host stack where nothing can reach it. Ash tail
calls pass the continuation through unchanged and every host call is in tail
position, so a tail-recursive Ash loop runs in constant host stack.

`eval`, `apply`, and `eval_list` live in mutable cells on an
`Ash_runtime.Machine`, and every call between them reads its cell. That is the
invariant the whole tower rests on: a meta level replacing `eval` must intercept
*every* nested step, not just the one at the top. An evaluator with a direct
self-reference produces a meta-patch that fires once and looks almost right,
which is the most expensive mistake on the spec's list of traps — so it is done
from the first line rather than retrofitted.

The machine counts group calls, per-form dispatches, cell dereferences, and
`NamedVar` lookups from the start. These are the raw material for the step
metrics and the collapse report, and they are observationally inert: nothing in
the evaluator reads them and no Ash value can depend on them.

The oracle and the CPS evaluator are compared on a shared corpus in
`test/differential/`, agreeing on values, on mutation and evaluation order, on
failures by both cause and location, and on the observable trace. See
[`docs/decisions/0008-cps-evaluator-and-open-recursion.md`](docs/decisions/0008-cps-evaluator-and-open-recursion.md).

## Primitives and effects

`Ash_runtime.Primitives` is the classified registry. Every primitive carries
exactly one `Ash_core.Effect_class`, as a field rather than as something a
specializer infers, because "every primitive is stage-polymorphic" is wrong in a
way that produces incorrect compilers rather than slow ones: folding
`print("hi")` when its argument is static means *compiling* prints and *running*
does not.

| Class | Members | Specialization |
|-------|---------|----------------|
| pure | `+ - * / %`, comparison, `==`, `!=`, `not`, `cons`, `head`, `tail`, `empty?`, `length`, `list`, `list?`, `match_error` | fold when every argument is static |
| allocation/mutation | `cell_new`, `deref`, `cell_set`, `open_cell`, `open_deref`, `open_set` | residualize until Phase 7's store splitting |
| observable effect | `print`, `println`, `read_line` | never executed at specialization time |
| control | `callcc`, `invoke` | never folded: capturing at specialization time captures the specializer, and `invoke`'s class is its callee's |
| reflection | — awaits staging and the tower | bespoke, and the classification target |

A registry is created over an `Ash_runtime.Io` stream: observable primitives
write events to it and read scripted lines from it, so a program's *trace* is a
value tests can compare rather than characters that have left the process. That
is what makes "the residual program produced exactly the source program's
effects" checkable. A stream can also echo to a channel, but echoing is an
addition to the record, never a replacement. `print` writes a string's
characters, while a diagnostic writes its escaped literal.

Arity is checked by whatever applies a primitive, so an arity error reads the
same wherever the call came from, and again inside the primitive because an
implementation is a total function; argument types are checked by the primitive,
left to right, and reported at the call site. See
[`docs/decisions/0009-classified-primitive-registry.md`](docs/decisions/0009-classified-primitive-registry.md).

## Surface syntax

`Ash_syntax.Lexer` scans the surface language of spec §4 into `Ash_syntax.Token`
values, each with a span. It is not the Core reader: Core is written in the
canonical s-expression notation above, so the self-interpreter's corpus does not
move when surface syntax does. Comments are `#` here and `;` there — the Core
reader cannot use `#` because `#t` and `#f` start with one, and Ash spells those
`true` and `false`, which leaves `;` free to be the sequencing operator.

What the lexicon settles:

- **Layout is recorded, not consumed.** Every token says whether a line break
  precedes it, because the spec's blocks separate statements by newline as well
  as by `;`. The lexer does not decide what that means; it declines to throw the
  information away.
- **Integers only, and a malformed literal is refused rather than split.**
  `12abc` is an error naming the text, not `12` followed by `abc`; so are `1.5`
  and an integer too large for a machine word.
- **A name may end in `?`** — that is how `empty?` is written — **and never
  contains `!`**, which is prefix negation. `_` alone is the wildcard; `_x` is a
  name.
- **A word is reserved only when the parser must recognize it before parsing
  what follows**: `true false let var fn if then else match open up meta_with
  reifier`. `run`, `lift`, `reflect`, `eval`, and `print` are ordinary bindings,
  because a program must be able to shadow what it is reflecting on.
- **Maximal munch**, so `|>` is never `|` then `>`. `:` and `&` mean nothing
  alone and are reported as stray characters rather than lexed.
- **`` `{ `` and `${` are one token each**, and a backtick without a brace says
  which character followed it instead.

See
[`docs/decisions/0010-surface-lexicon-and-layout.md`](docs/decisions/0010-surface-lexicon-and-layout.md).
Golden output for every spec sample, the maximal-munch table, and each lexical
diagnostic is in `test/golden/lexer.expected`; regenerate it with
`dune runtest --auto-promote` and read the diff.

`Ash_syntax.Parser` turns that token stream into a source-located `Surface` tree.
`Parser.program` accepts statements separated by either a newline or `;` at the
top level and inside braces; newlines remain whitespace in expression positions,
so the body after a function's `=` and multiline calls parse naturally. The
precedence rows are, loosest to tightest, pipeline, `||`, `&&`, comparisons,
right-associative `::`, additive, multiplicative, unary, and left-associative
calls. Other binary rows associate left. Mutation is right-associative below
pipelines and requires a name on its left.

The structural `Surface_printer` makes grouping explicit rather than trying to
reproduce source formatting. `test/golden/parser.expected` uses it to pin every
adjacent precedence boundary and associativity rule. Field access remains an
explicit parse error because Ash has no field-bearing values. The layout and AST
decisions are recorded in
[`docs/decisions/0011-surface-precedence-and-statement-layout.md`](docs/decisions/0011-surface-precedence-and-statement-layout.md).

Pattern parsing covers wildcard, literal, variable, list, right-associative cons,
alternatives, and every Core constructor. Alternative arms must bind the same
set of names, and a single path may not bind one name twice. Match clauses are
separated by newline or `;`. Quasiquote pattern holes carry `Pattern_splice`,
distinct from the `Expression_splice` in an ordinary quotation, so binder checks
remain structural and source-located. Parsing these quote nodes does not assign
their Phase 3 hygiene or execution semantics. See
[`docs/decisions/0012-patterns-binders-and-quasiquotation.md`](docs/decisions/0012-patterns-binders-and-quasiquotation.md).

## Desugaring to Core

`Ash_syntax.Desugar` is where names become identities. The parser works in
printed strings because that is all source text has; the desugarer walks the
binding structure once, allocates one `Ident.t` per binder, and resolves every
occurrence through it. Hygiene is therefore not a pass that runs afterwards — the
`head` and `scrutinee` binders a `match` lowering invents cannot capture a user's
`head`, because they were never the same identity.

| Surface | Core |
|---------|------|
| `e1` newline or `;` `e2` | `Let _ = e1 in e2` |
| `let x = v` / `var x = v` | `Let x = v in <rest of the list>` |
| `x := v` | `Set x v`, and only when `x` came from `var` |
| `fn f(a) = b` | `LetRec ((f (Lam (a) b))) <rest of the list>` |
| `open fn f(a) = b` | `Let f = open_cell(())` then `open_set(f, Lam (a) b)`; every `f` is `open_deref(f)` |
| `a && b` / `a \|\| b` | `If a b false` / `If a true b` |
| `-a` / `!a` | `0 - a` / `not(a)` |
| `a <op> b`, `[a, b]` | primitive calls; `[]` is the `Nil` literal |
| `x \|> f(a)` | `f(x, a)`, and `x \|> f` is `f(x)` |
| `match s { … }` | nested `If` over `empty?`, `head`, `tail`, and `==` |

Adjacent `fn` declarations in one statement list form a single `LetRec` group, so
mutual recursion is written by writing it, and a statement list ending in a
definition evaluates to unit so that a file of definitions is a program. Adjacent
`open fn` declarations form a single *open* group instead — same scoping, but the
names denote cells; see below.

A name with no binding is a desugar error, never a `NamedVar`: resolution by
printed name is what reflective code does, not a fallback, and the collapse
report counts the ones that survive. The globals are a parameter —
`Desugar.scope_of_globals` takes the identities a registry produced, so
`ash.syntax` still knows nothing about `ash.runtime` and a materialized tower
level can lower under its own cloned globals. Generated calls resolve against
those globals rather than the lexical scope, so the documented `fn length(xs)`
gets its own `length` where it wrote one and the primitive `empty?`, `head`, and
`tail` in the code the desugarer wrote.

`match` binds its scrutinee once and gives each clause a nullary thunk holding
the clauses after it, so a pattern can mention failure repeatedly without copying
what follows; a clause with an alternative pattern binds its body as a function
of the clause's binders and every arm calls it. Running out of clauses calls
`match_error`, because Core has no way to raise and answering unit would be a
silently wrong answer.

A Core node produced by a surface node of the same shape keeps its span. Anything
invented — the `Let` behind a statement separator, the `If` behind `&&`,
everything behind `match` — keeps the same positions and records the rewrite, so
`Span.source_span` still points diagnostics at user text while `Span.generators`
says which rewrite produced the node. Quotation, splicing, Core constructor
patterns, and quasiquote patterns parse but do not lower: they are refused by
name until Phase 3 gives them hygienic code construction. See
[`docs/decisions/0013-hygienic-desugaring-to-core.md`](docs/decisions/0013-hygienic-desugaring-to-core.md).

## Continuations

`callcc` reifies the continuation of its own call as a value and hands it to its
argument. It is a primitive in the control class, not syntax: a surface
`callcc(f)` lowers to an ordinary application, so the eleven Core forms are
untouched and the self-interpreter has nothing new to handle. It is spelled
without a slash because `/` is division and a control operator a program cannot
write is not much of a control operator.

Continuations are **first class and one-shot** (spec §D4). First class means
storable in a binding or a list, passable across function boundaries, and
invocable after the call that captured them has already returned — not
escape-only, because a reifier receives the continuation of the level below and
resumes it after doing work at its own level. One-shot means a second invocation
is an error, enforced dynamically: the `used` flag is set *before* the transfer,
so a continuation reached again through its own resumption is caught rather than
looping. The diagnostic names three places — where the continuation was captured,
where it already went, and where the second invocation was written — because none
of them alone explains the mistake. A continuation also records the tower level it
would resume, so Phase 4 cannot resume one on the wrong machine.

Multi-shot continuations wait: backtracking reifiers, `amb`, generator re-entry,
and re-entrant `meta_with` all need them, and none is needed for the headline
result. The `used` flag is what makes lifting that restriction a decision rather
than a discovery.

A primitive receives an `~apply` alongside its call site, arguments, and
continuation — that is how `callcc` calls its argument. The caller supplies it, so
the callback runs on whatever evaluator is executing: the ground evaluator routes
it through the machine's open-recursion cell, and a meta level that replaces
`apply` therefore intercepts a primitive's callback too. See
[`docs/decisions/0014-one-shot-continuations-and-the-applier.md`](docs/decisions/0014-one-shot-continuations-and-the-applier.md).

## Open-recursive groups

`open fn` is the surface form of spec §D3. A run of adjacent `open fn`
declarations is not a `LetRec`: the desugarer binds one cell per member with
`open_cell`, fills each with `open_set`, and lowers **every** reference to a
member — inside the group and after it — as `open_deref` of that cell, and every
`member := …` as `open_set`. Core does not grow; an open group is ordinary `Let`,
`Lam`, and primitive application.

```ash
open fn eval(e, r, k) = …          # every `eval`, `apply`, `eval_list` below
open fn apply(f, vs, k) = …        # is a dereference of this level's cell
open fn eval_list(es, r, k) = …

let base = eval                    # the function the cell holds
eval := fn(e, r, k) -> { hits := hits + 1; base(e, r, k) }
```

Members are assignable and plain `fn` bindings are not, because replacing a
member is what a meta level does. Assignment writes *through* the cell rather
than rebinding the name, so every dereference already written sees the
replacement — including the ones inside `base`, which is why a wrapper installed
this way observes every nested step rather than only the entry.

`open_cell`, `open_deref`, and `open_set` do what `cell_new`, `deref`, and
`cell_set` do, and are spelled apart from them on purpose: an `open_deref` in a
term is one evaluator-group dereference and nothing else, so
`Primitives.open_dereferences` counts steps the collapse report can measure
against. The surviving dereferences in a residual program are precisely the
interpreter residue. See
[`docs/decisions/0015-open-recursive-groups-in-ash.md`](docs/decisions/0015-open-recursive-groups-in-ash.md).

## The self-interpreter

`lib/self/eval.ash` is a CPS evaluator for the eleven Core forms, written in Ash,
open-recursive, and parallel to the host evaluator in `lib/runtime`. It is the
centre of the project, and every line in it is paid for once per tower level.
`ash.self` is the harness: `Encode` writes a Core term as data, and `Self` lowers
the interpreter with the ordinary parser and desugarer, runs it on the ground
evaluator, and applies what it exports.

Quotation is Phase 3, so the interpreted program arrives as tagged lists —
`['app, func, args]`, `['lam, params, body]`, and an identifier as `[name, id]`,
printed name plus unique id, so hygiene survives the encoding. Dispatch is an
`if` chain over the form tag rather than the constructor patterns spec §6 sketches,
because those parse but do not lower until Phase 3.

Interpreted scalars, lists, and cells represent themselves, so a primitive can be
handed one directly. Everything the host distinguishes by identity — closures,
reifiers, continuations, primitives — is a list headed by a private cell the
interpreted program has no way to name or forge, and each closure carries a fresh
cell as its identity so that `==` on two of them compares places rather than
shapes.

Nothing here is a host escape hatch. The interpreted level receives exactly the
globals a level-0 run receives, and everything it cannot do itself it does by
applying those same primitives through `invoke`, which is why its arity, type,
and arithmetic diagnostics are the host's rather than a restatement of them. The
one primitive it cannot delegate is `callcc`, since the host would capture the
interpreter's continuation instead of the program's; the interpreted level builds
its own one-shot continuation, marked used before transfer.

Two boundaries are declared rather than smoothed over: an encoded term carries no
spans, so a failure raised at the interpreted level is reported inside
`eval.ash`, and a failure this level detects itself — an arity mismatch on an
interpreted closure, a reused continuation, an unbound identifier, reifier
application — reports as `No_matching_clause` naming the condition, because Ash
cannot construct a structured error. See
[`docs/decisions/0016-the-ash-self-interpreter.md`](docs/decisions/0016-the-ash-self-interpreter.md).

## The differential corpus

`test/differential/` runs one program on both evaluators and compares four
things, reporting only the first difference: the value, the failure's cause, the
failure's location, and the observable trace. Each entry also declares whether it
is meant to produce a value or a diagnostic — two evaluators that both refused
everything would agree perfectly, so agreement alone proves nothing — and the
comparison's own reporting is checked against outcomes known to differ.

The corpus has two halves. The Core half is written in the canonical notation,
which is what the self-interpreter reads. The surface half is written in Ash and
lowered by the desugarer, which puts the parser and desugarer under the same
comparison. Both halves cover recursion, closures, shadowing, lists, mutation,
evaluation order, and failures.

`corpus.ml` holds the programs and both comparisons read it: the oracle against
the CPS evaluator, and the CPS evaluator against the self-interpreter. Sharing
one list is what keeps the second comparison from being run against easier
programs than the first. The self-interpreter comparison adds output and control
programs, which are the two areas the oracle refuses and the shared corpus
therefore cannot exercise; it compares value, cause, and trace but not location,
for the reason given above.

The oracle's refusals are checked too, as a boundary rather than as agreement:
quotation, reifiers, `callcc`, observable effects, and cells are all outside the
pure corpus by construction, and a change that quietly moved that line would fail
here. The self-interpreter has a boundary of its own, checked the same way:
applying a reifier needs the level above, and a quotation answers an encoded term
where the host answers `Code`.

## Development workflow

Read `AGENTS.md` before changing code. At the end of each completed task, update
the checklist's Current state and Handoff log so a later session can resume from
the single prompt `continue`.
