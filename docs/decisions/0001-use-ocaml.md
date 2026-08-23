# 0001 — Use OCaml for the host implementation

- **Status:** accepted
- **Date:** 2026-08-23

## Context

Ash needs mutually recursive algebraic data, garbage-collected closures and
environments, mutable language-level cells, explicit CPS continuations, extensive
AST transformation, and reliable changes across many implementation sessions.

Racket offers the shortest route to an exploratory tower, but its dynamic type
system moves incomplete evaluator matches and value-shape mistakes to runtime.
Rust and Zig would add substantial ownership or memory-management work. Haskell's
lazy evaluation and effect plumbing would complicate Ash's exact step and effect
semantics.

## Decision

Use OCaml 5.2 or newer with Dune 3.16 or newer. Model Core and runtime values with
algebraic data types, use explicit CPS closures rather than host effect handlers,
and use ordinary references only where Ash semantics require identity or mutation.
Prefer the OCaml standard library until a dependency has a documented need.

## Consequences

- Exhaustiveness and type checking protect evaluator and specializer refactors.
- OCaml's garbage collector supports cyclic closure/environment graphs without a
  custom memory manager.
- The implementation is somewhat more explicit than Racket, particularly around
  recursive runtime types and staged values.
- Black's Scheme source remains a conceptual reference and must be translated,
  not copied mechanically.
- The initial backend remains residual Core interpreted by the ground evaluator.

## Alternatives

- **Racket:** fastest exploratory prototype, weaker compile-time guarantees.
- **Haskell:** strong types, but added strictness and effect-order engineering.
- **Rust:** suitable for a later runtime/backend, expensive for cyclic semantics.
- **Zig:** suitable for low-level runtime work, requires explicit allocation.

## Test impact

All completed tasks must pass `dune build @all` and `dune runtest`. Warnings are
treated as errors in development so new Core constructors force relevant matches
to be revisited.
