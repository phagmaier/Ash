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

The CLI also runs the packaged milestone demos — `ash --demos` to list them,
`ash --demo tracing` and `ash --demo level-2-counting` to run one. Follow the
first unchecked task in `to-do.md` to continue implementation.

## Repository layout

| Path | Contents |
|------|----------|
| `bin/` | CLI entry point |
| `lib/core/` | `ash.core`: spans, constants, hygienic identifiers, the Core AST, values, environments, and errors |
| `lib/syntax/` | `ash.syntax`: the shared scanning cursor, s-expression data, the canonical Core reader/printer, and the surface lexer, AST, precedence parser, and desugarer |
| `lib/runtime/` | `ash.runtime`: the classified primitive registry, the observable-effect stream, the CPS evaluator, and the frozen oracle |
| `lib/self/` | `ash.self`: the self-interpreter written in Ash (`eval.ash`) and the real-Code layer harness |
| `lib/tower/` | `ash.tower`: independently stateful levels, one-step lazy materialization, the level neighbourhood the up/down protocol reads, and the depth harness the laws run on |
| `lib/` | `ash`: version metadata, and later the layers above Core |
| `examples/` | `ash.examples`: the packaged milestone demos, as Ash source embedded at build time |
| `test/unit/` | module-level behaviour tests |
| `test/differential/` | oracle/CPS and CPS/self-interpreter comparisons on one shared corpus |
| `test/laws/` | semantic invariants — open recursion at the Ash level, and the §5.7 tower laws at depths 0–5 |
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
| pure | `+ - * / %`, comparison, `==`, `!=`, `not`, immutable lists, `code?`, `code_view`, `code_name`, `code_splice`, `code_match`, `NamedVar`, `match_error`, `raise_at` | fold when everything the primitive inspects is static |
| allocation/mutation | `cell_new`, `deref`, `cell_set`, `open_cell`, `open_deref`, `open_set` | residualize until Phase 7's store splitting |
| observable effect | `print`, `println`, `read_line` | never executed at specialization time |
| control | `callcc`, `resume`, `invoke`, `invoke_at` | never folded: capturing at specialization time captures the specializer, and invocation's class is its callee's |
| reflection | `lift`, `run`, `reflect`, `meta_error`; later `up` | bespoke, and the classification target |

The class says *whether* a primitive may run during specialization. A second
field, `Ash_core.Observation`, says *how much of each argument* has to be known
first, and it defaults to "all of it". Only the immutable-data group departs
from that default: `cons` inspects the shape of its tail and nothing of its
head, `head`/`tail`/`empty?`/`length`/`list?` inspect only their argument's own
constructor, and `list` inspects nothing. That is what makes a list with a known
spine and dynamic elements a usable static value — the specializer can walk it
while the values it carries stay residual — without letting `==` compare
elements it does not know. `Ash_stage.Stage_value.may_fold` is the one predicate
that reads both fields.

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
remain structural and source-located. Nested quotations inside splices and
quoted named definitions have focused parser coverage; hygiene is assigned by
the desugarer, not by parsing. See
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
| `match s { … }` | nested `If` over shape tests, `empty?`, `head`, `tail`, and `==` |
| `` `{ e } `` / `${x}` | `Quote` of a hygienic template; pure `code_splice` calls at holes |
| `Lit(p)`, `App(p,p)`, … | guarded `code_view` followed by ordinary nested patterns |
| `` `{ ${p} … } `` pattern | alpha-aware `code_match`, then ordinary patterns over captures |
| `up { E }` | a `Reifier` applied to nothing, its body binding the meta names and ending in `resume(cont, E)` |

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
silently wrong answer. Structural patterns are refutable on the wrong value
shape: `match 5 { [] -> 'empty; _ -> 'other }` answers `'other`, with `list?`
guarding the accessors rather than letting `empty?` raise.

Quotation is hygienic construction, not textual substitution. The desugarer
places fresh-identity marker variables in a Core template and replaces those
exact identities with spliced `Code`; a binder that merely prints the same name
cannot capture the replacement, and a binder carried by the replacement cannot
capture adjacent template code. Quoted binders remain visible to nested quotes
inside splice expressions, while an otherwise free quoted name gets its own
hygienic identity so open Code can be assembled for later explicit evaluation.
Runtime name lookup is never inferred from an unbound source name:
`NamedVar("x")` constructs that reflective Core node explicitly. `Code` equality
and quasiquote matching are alpha-aware.

A Core node produced by a surface node of the same shape keeps its span. Anything
invented — the `Let` behind a statement separator, the `If` behind `&&`,
everything behind `match` — keeps the same positions and records the rewrite, so
`Span.source_span` still points diagnostics at user text while `Span.generators`
says which rewrite produced the node. Quotation, splicing, Core constructor
patterns, and quasiquote patterns now lower through immutable pure Code
operations. The Phase 2 data encoding has now been retired: the self-interpreter
reads real Code, so quoted child nodes retain both identity and spans across a
level. See
[`docs/decisions/0013-hygienic-desugaring-to-core.md`](docs/decisions/0013-hygienic-desugaring-to-core.md).

## Closed Code and `run`

`run(code)` accepts Code only when every hygienic `Var` dependency is bound
inside the Code or is one of the current level's explicit globals. It reports all
unresolved identities and all their source locations in one structured error.
The complete tree is checked, including `Set` targets and nested quotations;
`NamedVar` remains an explicit request for printed-name lookup during execution.

Accepted Code runs on the active open-recursive machine with the level-global
environment. It never receives a `let`, lambda, or closure frame from the call
site, so this fails rather than answering 42:

```ash
let x = 40
run(`{ x + 2 })
```

Quoted primitive references such as `+` do resolve because their exact global
identities are deliberately available. See
[`docs/decisions/0019-closed-code-run.md`](docs/decisions/0019-closed-code-run.md).

## Fixed-domain lifting

`lift(value)` constructs Code only for numbers, booleans, strings, symbols,
unit, recursively liftable immutable lists, and Code. Existing Code passes
through unchanged. Closures, reifiers, continuations, environments, cells, and
primitives are rejected rather than serialized.

Non-empty lists become calls to the active level's exact hygienic `list` global;
lifting never inserts a `NamedVar` lookup. Invented nodes retain the `lift` call
as generated provenance. A rejection points at that call and identifies the
offending leaf's one-based path through nested lists, so a closure inside item 2
of item 3 is distinguishable from a direct closure argument. See
[`docs/decisions/0020-fixed-lift-domain.md`](docs/decisions/0020-fixed-lift-domain.md).

The staging regression runs the spec's generator directly:

```ash
fn power(n, x) =
  if n == 0 then `{ 1 }
  else `{ ${x} * ${power(n - 1, x)} }

let pow5 = `{ fn(y) -> ${power(5, `{ y })} }
run(pow5)(2) # 32
```

The resulting lambda is closed relative to the level globals and
alpha-equivalent to five multiplications by its own parameter. The documented
quasiquote simplifier is also exercised end to end for `+ 0`, `* 1`, `* 0`,
recursive application simplification, and fallthrough.

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

A primitive receives evaluator callbacks alongside its call site, arguments,
and continuation: `~apply` is how `callcc` calls its argument, `~lift` constructs
Code using the active level's hygienic globals, `~run` analyzes and executes
closed Code without capturing caller lexical state, and `~reflect` drops one
level. It is also told the `~level` it is running at, because one registry serves
the whole tower and the primitive values are shared. The applying evaluator
supplies all of them, so callbacks use the active machine and a meta-level
replacement can intercept evaluator work. See
[`docs/decisions/0014-one-shot-continuations-and-the-applier.md`](docs/decisions/0014-one-shot-continuations-and-the-applier.md)
[`docs/decisions/0019-closed-code-run.md`](docs/decisions/0019-closed-code-run.md),
and [`docs/decisions/0020-fixed-lift-domain.md`](docs/decisions/0020-fixed-lift-domain.md).

## Open-recursive groups

`open fn` is the surface form of spec §D3. A run of adjacent `open fn`
declarations is not a `LetRec`: the desugarer binds one cell per member with
`open_cell`, fills each with `open_set`, and lowers **every** reference to a
member — inside the group and after it — as `open_deref` of that cell, and every
`member := …` as `open_set`. Core does not grow; an open group is ordinary `Let`,
`Lam`, and primitive application.

```ash
open fn eval(e, r, k) = …          # every `eval`, `apply`, `eval_list` below
open fn apply(f, vs, k, site) = …  # is a dereference of this level's cell
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
`ash.self` is the harness: `Self` lowers the interpreter with the ordinary parser
and desugarer, quotes the subject as real Code, writes its Code-keyed primitive
global frame into the layer term, and runs that term on the ground evaluator.
`Ash_self.Encode` has been deleted.

The interpreter dispatches directly with all eleven constructor patterns:
`Lit`, `Var`, `NamedVar`, `Lam`, `App`, `Let`, `LetRec`, `If`, `Set`, `Quote`,
and `Reifier`. Identifier fields are one-node `Var` Code values, retaining exact
hygienic identity without exposing allocation IDs. `code_name` exposes only the
printed component needed for explicit `NamedVar` lookup.

Interpreted scalars, lists, cells, and primitives represent themselves, so a
primitive can be handed one directly. The three things the interpreted level
constructs — closures, reifiers, continuations — are lists headed by a private
cell the interpreted program has no way to name or forge, and each closure
carries a fresh cell as its identity so that `==` on two of them compares places
rather than shapes.

Nothing here is a host escape hatch. The interpreted level receives exactly the
globals a level-0 run receives, and everything it cannot do itself it does by
applying those same primitives through `invoke_at`, which is why its arity, type,
and arithmetic diagnostics are the host's rather than a restatement of them. The
one primitive it cannot delegate is `callcc`, since the host would capture the
interpreter's continuation instead of the program's; the interpreted level builds
its own one-shot continuation, marked used before transfer.

`invoke_at` attributes delegated application failures to the subject `App`, and
`raise_at` accepts a closed structured-cause protocol for failures the
interpreter detects itself. Both use the span retained by Code, so the host and
self-interpreter now agree on cause, phase, level, and source location across the
full differential failure corpus. See
[`docs/decisions/0021-real-code-self-interpreter.md`](docs/decisions/0021-real-code-self-interpreter.md).

## Layers

`Self.interpreting t` is the Core term that interprets `t` — the interpreter
applied to quoted Code and Code-keyed globals, with both written *into*
the term rather than passed beside it. The result is an ordinary Core term, so it
is itself something a further layer can interpret, and layer *n* is *n*
applications of one function:

```text
layer 0   the ground evaluator runs the program
layer 1   the ground evaluator runs the interpreter, which runs the program
layer 2   … which runs the interpreter, which runs the program
```

Every layer answers the same value and leaves the same trace. That is a stronger
statement than layer 1's agreement alone: layer 2 only passes if Code transport
survives being applied to the interpreter's own lowering, and if a primitive
handed down two levels is still something the bottom level can apply. The second
of those is why a primitive crosses **unwrapped** — a wrapped one would arrive at
the bottom as the middle level's wrapper, a list rather than something callable —
and why `callcc` is recognized by value (`f == callcc`) rather than by a name in
a wrapper.

Which layer carries a patch decides what the patch sees. Patching the layer that
runs the program observes the program's thirteen nodes for §D3's fixture, whether
that layer is running on the host or is itself being interpreted; patching the
layer beneath it observes the interpreter's own execution, some 3500 steps for
the same fixture. Same fixture, same answer, a different subject. See
[`docs/decisions/0017-interpreter-layers.md`](docs/decisions/0017-interpreter-layers.md).

## Lazy tower materialization

`Ash_tower.Tower` always has a ground level, but starts with zero materialized
upper levels. Ordinary `Tower.run` stays on that fast path. A reflective caller
asks for the adjacent level with `materialize_above`: the first request from
level 0 creates exactly level 1, another request reuses it, and a request from
level 1 creates exactly level 2. A caller cannot skip an unmaterialized source
level. Reifier application is what asks.

Every `Ash_tower.Level` calls `Primitives.globals` for fresh hygienic identities
and binding cells and owns a fresh evaluator machine with independent `eval`,
`apply`, and `eval_list` cells. Levels share the primitive values and registry,
so observable output remains one event stream for the entire tower. Replacing a
machine cell at one level therefore changes that level only.

The tower reports two sizes without conflating them. Materialized runtime size
records the upper-level/global-cell/evaluator-cell structure that exists and the
actual OCaml heap words reachable from the tower. Expanded semantic size is the
conceptual eager formula `program nodes + depth × interpreter nodes`; physically
creating a level changes the first measurement and never the second. See
[`docs/decisions/0022-lazy-level-materialization.md`](docs/decisions/0022-lazy-level-materialization.md).

## Reifiers and the up/down protocol

Applying a reifier shifts one level up. It happens in `eval`'s `App` case rather
than in `apply`, because a reifier receives the whole *unevaluated* call, and an
applier sees values with no call expression to hand up. The call, the caller's
environment, and the caller's one-shot continuation become values; the reifier's
body then runs on the machine of the level above, materialized on demand.

The body keeps the lexical environment the reifier was written in. Which machine
evaluates a term does not change what its free hygienic identities mean; what
changes is that replacing the upper level's `eval` cell intercepts the body and
replacing the lower one's does not. The body runs under the identity
continuation, so a reifier that never resumes does not return to the level below
at all: its value is the answer of the run, and the caller's pending work never
happens.

`reflect(code, env, cont)` is the way back down: it evaluates Code on the machine
below and transfers to a continuation captured there, through the caller's own
applier, so the one-shot check is the ordinary one. That makes the identity
reifier

```text
(reifier (e r k) (reflect (first-argument e) r k))
```

observationally the identity function, effects included and evaluated once.
`resume(k, v)` is the same transfer named, and `meta_error(msg)` fails at the
level running it.

Errors carry the level of the machine that raised them, counted from the base
program. An error inside a reifier body belongs to the level above and never
resumes the level below; the same error in reflected code belongs to the level
that evaluated it. A diagnostic names its level only above 0, since level 0 is
the base program. A machine with no tower installed refuses both reifier
application and `reflect` rather than materializing a level no tower knows
about. See
[`docs/decisions/0023-reifiers-and-the-up-down-protocol.md`](docs/decisions/0023-reifiers-and-the-up-down-protocol.md).

## `up` and the meta bindings

`up { … }` is the surface form of that protocol. It is sugar, and the sugar is
visible in the golden output: a reifier applied to no arguments — there are none
to reify, only a level to reach — whose body binds the meta names of spec §5.2
and ends in `resume(cont, E)`, which is why the level below resumes with the
body's value unless the body resumed it earlier itself.

| Name | What it is |
|------|------------|
| `exp` | the call the sugar expanded to, as `Code`: what the level below was evaluating |
| `env` | the level below's environment at the `up` |
| `cont` | its one-shot continuation |
| `eval`, `apply` | the level below's open-recursion cells |
| `global` | the level below's own global environment |
| `level` | the relative level of the body, so an `up` body is 1 and a nested one is 2 |
| `resume`, `meta_error` | ordinary globals, needing nothing added |

`eval` and `apply` are bound exactly the way an `open fn` group's members are:
reading one is `open_deref` and assigning to one is `open_set`. So

```ash
up {
  let base = eval
  eval := fn(e, r, k) -> { print(show(e)); base(e, r, k) }
}
fib(3)
```

writes through the cell the level below already dereferences on every step. The
replacement is *persistent*: it outlives the `up` that installed it, it wraps
whatever was there before rather than replacing it, and because §D3 makes every
recursive evaluator call a cell dereference it intercepts every nested node, not
the outermost one. It does not intercept the level running it — a replacement
that was its own interpreter would not survive its first step.

`tower_depth()` is the separate, deliberate opt-in of §D9: `level` is relative
and says nothing about the tower, while `tower_depth()` reports how many levels
are materialized. A program that calls it is depth-sensitive by construction,
which is what lets the collapse report detect depth sensitivity syntactically.

Behind the bindings are five Reflection primitives — `meta_eval`, `meta_apply`,
`meta_global`, `tower_level`, and `tower_depth` — because each answers a question
about *which machine is asking*, which only the applying evaluator knows. Read at
the base program, the first three refuse in the same words `reflect` does: there
is no level below. See
[`docs/decisions/0024-up-and-the-meta-bindings.md`](docs/decisions/0024-up-and-the-meta-bindings.md).

## Depth, and the tower laws

`Ash_tower.Depth` runs a program under a tower of a stated depth. Depth here
means levels that are *actually interpreting*: `Depth.interpose` writes an Ash
closure — `fn(e, r, k) -> base(e, r, k)`, semantically the identity — into a
level's evaluator cell, exactly as `up { eval := … }` does from inside the
language, so every step of that level becomes a term the level above evaluates.

The alternative definition, "levels that are materialized", would make the
transparency law vacuous: a materialized level whose cell is untouched runs the
identical host function with identical counters, by construction. See
[`docs/decisions/0025-what-tower-depth-means.md`](docs/decisions/0025-what-tower-depth-means.md).

`test/laws/tower_laws_test.ml` proves the §5.7 laws over that, at depths 0–5, on
the same corpus `test/differential/` uses plus observable-output programs:

| Law | How it is tested |
|-----|------------------|
| Transparency | 96 programs at depths 0–5: same value, same failure (cause, span, phase, level), same effects in the same order. Level 0's own step count is invariant too, which is stronger than the law asks. |
| Open recursion | A patched evaluator's interception count is large, grows with nesting, and does not depend on the tower's depth. |
| Reifier identity | Value, effect order, closure, and two failure shapes; nontermination by a counted Ash step cap. |
| Level independence | The counter moves for level 0's work and not for level 1's own body. |
| Error propagation | Ownership plus non-resumption — Core has no handler form, so that is what "catchable at *n+1*" means here. |
| One-shot | A continuation stored in a shared cell, resumed, then invoked again. |
| Depth observation | `tower_level()` is 0 at every depth; `tower_depth()` is the depth. |

Overlay discipline is the one §5.7 law still open; it needs `meta_with`, which is
Phase 8. Timing, host stack, resource exhaustion, and gensym counters are
excluded per §D9 — and the exclusion is a test, not a silence: the suite asserts
that top-of-tower work *does* vary with depth.

Cost is `steps × 5^depth` for this harness, so depth is budgeted in counted Ash
steps rather than wall time; one corpus program stops at depth 2 and says so.
[`docs/progress/0001-depth-cost.md`](docs/progress/0001-depth-cost.md) has the
numbers.

## Demos

Two packaged demos, both Ash programs in `examples/`, embedded at build time so
the CLI and the golden test cannot run different source:

```sh
opam exec -- dune exec ash -- --demos
opam exec -- dune exec ash -- --demo tracing
opam exec -- dune exec ash -- --demo level-2-counting
```

`tracing` is spec §5.3: a program replaces the evaluator running it and prints
one line per evaluated Core node — 59 of them for `fib(3)`, which is the visible
form of invariant OR. `level-2-counting` is §5.6: level 1 is made to interpret
level 0, and level 2 counts what level 1 then does, reporting 715 interpreter
steps for 67 program steps. What both print is stored in
`test/golden/demos.expected`.

## Staging and the maybe-lift evaluator

`Ash_stage` (`ash.stage`) implements the staged specializer foundation (spec §7):

- **Values (`Ash_stage.Stage_value`):** static data are real values (`Value.value`),
  while dynamic data are `Code(Core.t)`. Named policy predicates (`is_static`,
  `is_dynamic`, `is_purely_static`, `is_shape_static`, `static_value`,
  `dynamic_code`, `may_fold`) control specialization choices. Data are
  *partially* static: a list whose spine is known and whose elements are `Code`
  is shape-static but not purely static, which is what lets a traversal of it
  unroll while the elements stay residual.
- **Modes (`Ash_stage.Mode`):** `Identity` mode evaluates terms as standard
  ground evaluation; `Lift` mode folds static computations and lifts static results
  at stage boundaries. Machines carry the mode of their evaluator wiring, and
  `run` rejects an explicitly mismatching mode before evaluating anything.
- **Evaluator (`Ash_stage.Staged_eval`):** a single CPS evaluator source supporting
  both `Identity` and `Lift` modes with open recursion across `eval`, `apply`, and
  `eval_list`. Pure primitives are stage-polymorphic (spec §D7): folding only
  when everything a primitive inspects is static and residualizing `Core.App`
  otherwise. Residual calls retain the exact hygienic primitive binding.
  Observable effects always residualize; Core `Set` is rejected in Lift mode
  until Phase 7 supplies store splitting. Quotes retain their `Quote` node.
- **Stage boundaries (`Staged_eval.reify_value`):** one conversion is used
  wherever a value crosses into residual code. A closure is reified into its
  lambda syntax, its parameters made dynamic and its body specialized in its own
  emission buffer; a non-empty list is rebuilt as a residual `list` call over
  reified elements; everything else is converted by `lift`. This is not the
  `lift` primitive, which keeps the fixed §D6 domain and still refuses to
  serialize a closure: the specializer holds a closure's syntax and environment
  and a program does not.

Recursion controlled by static data unrolls completely, so a staged
`power(3, x)` becomes three multiplications and a traversal of a statically
shaped list disappears into the arithmetic it performed.

- **Specialization points (`Ash_stage.Specialize`):** recursion controlled by
  *dynamic* data has no end to unroll to, so inlining is the default and a call
  becomes a memoized specialization point only when its own key is already being
  inlined. A key is the function's identity — its lambda and the environment it
  closed over — plus a projection of each argument: fully static values and
  partially static ones (a list with a known spine and unknown elements) are
  specialized into the residual function's body, and residual code becomes a
  parameter. The point belongs to the call that *started* the inlining, not the
  one that found the cycle, so it is bound in a block the next call with the
  same key can still reach; a point is bound by a `LetRec` where it was created
  and never hoisted, because its body may mention binders that let-insertion
  introduced earlier in that block. Because a key only repeats when unrolling
  has stopped making progress, everything Phase 5 collapsed still collapses:
  `power(3, x)` walks four different keys and creates no point at all. Mutual
  recursion closes on one function, with its partner inlined into it. Recursion
  whose static argument *grows* never repeats a key, and is stopped by the
  budget instead. See
  [`docs/decisions/0031-memoized-specialization-points.md`](docs/decisions/0031-memoized-specialization-points.md).
- **Budgets and generalization (`Ash_stage.Specialize`):** two deterministic
  limits — nested calls into one function, and residual bindings emitted. The
  size limit is the discriminating one, because *an unrolling that is working
  folds and emits nothing*: the corpus's deepest static unrolling is a
  10,000-step loop that collapses to a single literal and emits no bindings,
  while one going nowhere emits at every step. On pressure the call becomes a
  specialization point, after giving up one more argument — the leftmost
  position that *differs* from the nearest enclosing call to the same function,
  because that is what the unrolling is following. Generalizing is sticky per
  function and monotone, so a function with *k* parameters generalizes at most
  *k* times and then must meet the memo table. Every decision is recorded with
  its function, parameter, and reason, and printed by the collapse report. The
  defaults leave the whole corpus alone, and the collapse criterion asserts zero
  generalizations across all 73 samples — §7.5's point being that a program
  which collapses *without* generalizing says more than one that does. The one
  place the specializer can only refuse is reification: a closure that reaches a
  dynamic position inside its own reified body is not a call and has no argument
  to give up, so it raises `Budget_exhausted` naming the budget and the
  function. See
  [`docs/decisions/0032-specialization-budgets-and-generalization.md`](docs/decisions/0032-specialization-budgets-and-generalization.md).
- **The residual normalizer (`Ash_collapse.Normalize`):** one canonical shape
  for residuals, so claims that compare them — the depth-invariance claim above
  all — are about programs rather than about which identities a run allocated
  or how deeply let-insertion happened to nest. Three rewrites, each
  semantics-preserving by construction: administrative lets flatten (a let
  whose value is a let emits its inner binding first, however deep the nesting),
  trivial bindings substitute away (literals and unassigned variables only —
  never code, so nothing duplicates and nothing reorders), and alpha-canonical
  renaming runs last. A mention that cannot follow a substitution keeps its
  binding: a `Set` target reads its cell, quoted code is data, a reifier body
  is another level's code. Nor is a variable substituted when the term assigns
  it anywhere — the binding captured the value it held then, and the body would
  otherwise read what a later write put there. Effects never move — nothing hoists out of a lambda or branch,
  an unused effectful binding still happens, and idempotence is exact, which is
  what lets normal forms be compared structurally. The measurement normalizes
  before surveying and running the residual, so every reported figure describes
  the deliverable. See
  [`docs/decisions/0033-the-residual-normalizer.md`](docs/decisions/0033-the-residual-normalizer.md).

## The collapse report

`Ash_collapse` (`ash.collapse`) turns collapsibility into something you can look
at (spec §9.4):

```sh
opam exec -- dune exec ash -- --collapse examples/fact.ash --depth 1
```

One program, three runs, and one walk of what specialization left behind: the
ground run (what the program means), the run at a stated tower depth (what
interposed interpretation costs), specialization itself, and the residual run
(what the collapsed program costs). Interpretation surviving in the residual is
decided syntactically and by hygienic identity — `open_deref` applications are
evaluator-group dereferences, an application of an `open_deref` is a surviving
evaluator call, `code_view`/`code_match` are constructor dispatch, `NamedVar`
nodes are lookups by printed name — so a local binder that happens to print
`open_deref` is counted as nothing. Residual nodes are attributed to the source
file their provenance points at, which is what makes "interpreter residue" mean
something once the input contains an interpreter's text.

Two things the report deliberately does not do. It does not call two runs
equal when the answer carries identity: closure equality is identity, so it
prints `carries identity: not comparable across runs` rather than comparing
lambda syntax and calling it agreement. And it does not claim to have collapsed
the tower: the residual is the program specialized on its own, so the tower
figures are the measured cost that collapse is set against, and the report ends
by saying exactly that. Erasing a level's interposed evaluator is Phase 9.

`test/golden/collapse.expected` pins the report; `test/unit/collapse_test.ml`
pins what its numbers mean. See
[`docs/decisions/0029-the-collapse-report.md`](docs/decisions/0029-the-collapse-report.md).

`test/laws/collapse_criterion_test.ml` is the milestone-2 claim itself: 73 pure
samples at depth 1, each agreeing across the source, tower, and residual runs
with zero surviving eval-cell dereferences, evaluator calls, constructor
dispatch, `NamedVar` lookups, and reflection boundaries. Three things keep it
from being a tautology — a closed pure program folds to a literal, and a literal
trivially contains no dispatch. The premise is asserted (the tower run must have
performed the interpretation the residual is claimed not to contain: 906,708
dispatches and 2,125,589 cell reads, against 250 residual nodes). Eight samples
do not fold to a literal, and are compared by applying source and residual to
the same arguments; two of those keep a residual `LetRec` of their own, which is
the program's recursion rather than an interpreter's. And the criterion is shown to be failable: an `open fn` group
and a runtime `code_view` leave interpretation that the measurement reports, and
those uncollapsed residuals are still checked to be correct. See
[`docs/decisions/0030-what-the-pure-collapse-criterion-claims.md`](docs/decisions/0030-what-the-pure-collapse-criterion-claims.md).

## Depth results

`test/laws/depth_invariance_test.ml` is Phase 6's claim over the same pure
corpus, at depths 0–5: ordinary programs specialize to residuals that are
alpha-equal at every depth — `collapse(n, p) ≅α collapse(1, p)` — while
programs that read `tower_depth()` produce one residual per depth, each
semantically equivalent to what that depth's tower did. That is §9.3's first
two classes measured rather than asserted.

Two things make the comparison mean anything. Specialization is depth-aware:
attached to a configuration, the specializer folds the statically known
`tower_depth()` reading to its number (ADR 0034), so `C(n,p)` is genuinely a
function of n instead of one term compared with itself. And all syntactic
comparisons run against one shared environment, because cloned globals give
each environment its own identities; two environments' residuals could never
agree, so the law suite resolves every sample once and specializes under each
depth through `Metrics.specialize`. The suite also proves the normalizer is
load-bearing — two raw specializations differ by fresh identities while their
normal forms coincide — and requires depth-sensitive samples to fail the
invariance check rather than allowing them to pass vacuously.

```sh
opam exec -- dune exec ash -- --collapse examples/depth.ash --depth 3
```

prints the shape of it: source says 0 (the ground world), the tower says 3,
the residual specialized at depth 3 says 3 — and the report states plainly
that they differ rather than calling that agreement.

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

`corpus.ml` holds the programs and every comparison reads it: the oracle against
the CPS evaluator, the CPS evaluator against the self-interpreter, and — for the
pure half — the source program against its residual, which is how the staged
evaluator's lift mode is held to the ground evaluator's semantics. Sharing
one list is what keeps the second comparison from being run against easier
programs than the first. The self-interpreter comparison adds output and control
programs, which are the two areas the oracle refuses and the shared corpus
therefore cannot exercise; it compares value, cause, location, error context,
and trace.

A third comparison runs the same corpus at layers 0, 1, and 2. Layer 2 costs the
product of two interpretations, so which programs it runs is decided by a
deterministic Ash-level step budget — a program is compared at layer 2 when its
layer-0 run takes at most 800 evaluator steps — rather than by wall time. That
admits every corpus program but the ten-thousand-iteration loop, whose step count
is printed so a change in either direction is visible.

The oracle's refusals are checked too, as a boundary rather than as agreement:
quotation, reifiers, `callcc`, observable effects, and cells are all outside the
pure corpus by construction, and a change that quietly moved that line would fail
here. Applying a reifier is still outside both the oracle and the
self-interpreter: the oracle refuses reflection by construction, and an
interpreter layer is not a tower level, so an interpreted level has no level to
shift to. Quotation is no longer a representation boundary, and both the host and
self-interpreter answer the same alpha-equivalent Code.

## Development workflow

Read `AGENTS.md` before changing code. At the end of each completed task, update
the checklist's Current state and Handoff log so a later session can resume from
the single prompt `continue`.
