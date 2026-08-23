# 0011 — Surface precedence and statement layout

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 1.2

## Context

Spec §4.1 fixes the expression precedence levels and marks cons as
right-associative, but its examples also rely on two pieces of grammar that are
not in that table. A newline separates statements inside a block, while the
newline after a named function's `=` merely precedes its body. Mutation uses
`:=`, but assignment is not an ordinary value-producing infix operator in the
table. ADR 0010 therefore recorded line starts on tokens and deliberately left
their interpretation to this task.

The parser must also retain enough surface structure for task 1.4 to distinguish
a recursive named function from an ordinary immutable binding and to allocate
hygienic identities only after the complete binding structure is known.

## Decision

**The parser produces a source-located `Surface` tree, not Core.** Names remain
located strings. `Binding`, `Named_function`, `Function`, `Block`, `Conditional`,
`List_literal`, `Call`, `Assignment`, and the operator nodes preserve the syntax
that the hygienic desugarer will lower. A `Group` node preserves the source span
of parentheses without pretending that the enclosed node itself occupied those
characters. Operator records retain the operator token's span as well as the
whole expression span.

**Programs and blocks are statement lists.** A newline (the next token's
`starts_line` flag) or `;` separates two statements only while parsing a program
or `{ ... }`. Elsewhere a newline is whitespace. This makes all of the following
unambiguous:

```ash
fn fact(n) =
  if n == 0 then 1
  else n * fact(n - 1)

{ f(x)
  g(y) }
```

A binary operator may begin a continuation line: `x\n+ y` is `x + y`. Writing
unary `-y` as a new statement after `x` therefore requires `x; -y`; this is the
only spelling where the token sequence itself distinguishes the intent.
Leading empty statements are rejected, while a trailing semicolon is accepted.

**The precedence table is implemented as one recursive-descent layer per row.**
From loosest to tightest it is pipeline, `||`, `&&`, comparisons, cons, additive,
multiplicative, unary, and postfix call. Every binary row associates left unless
the spec says otherwise; consequently comparisons associate left and `::`
associates right. Unary operators associate right and calls associate left.
Mutation is a right-associative syntactic layer below pipelines, and its left
side must be a bare name. `=` and `->` are grammar delimiters, never expression
operators.

**Field access is rejected at the parser.** The spec's table names its precedence
but Ash has no field-bearing value, as ADR 0010 notes. A dot after an expression
therefore produces a located `Unsupported field access` parse error rather than
being silently ignored or misread as application.

**This slice stops at the task boundary.** Pattern matching and patterns land in
1.3. Because quasiquote patterns contain the same quotation and splice grammar
as expressions, 1.3 also adds their syntax-only AST representation; quotation
and splicing acquire their hygienic meaning in Phase 3. Tower forms land with
their semantic phases. Their tokens are already reserved, but accepting a
placeholder AST node early would falsely claim that the surface construct is
implemented.

## Alternatives

**Newlines significant everywhere.** This would terminate the body immediately
after `fn fact(n) =` and make multiline calls and lists noisy. The lexer flag is
contextual precisely so grammar positions that expect an expression can ignore
layout.

**Semicolons only, or automatic semicolon insertion.** Mandatory semicolons
contradict the spec samples. Rewriting line breaks into semicolons before parsing
cannot distinguish a block statement boundary from a function body that begins
on the next line.

**A Pratt parser with numeric binding powers.** It is compact, but the language
has only nine fixed rows. Named recursive declarations, contextual newlines, and
assignment targets still need grammar-specific code, while explicit functions
make the published table directly reviewable and force later changes to name the
affected layer.

**Desugar during parsing.** Allocating identifiers or translating pipelines here
would combine syntax recovery, scope resolution, and semantic lowering. Keeping
the surface tree lets parser tests inspect grouping without depending on fresh-ID
allocation and gives task 1.4 one place to establish hygiene.

## Consequences

- `Parser.expression` parses exactly one statement-shaped expression;
  `Parser.program` parses a possibly empty statement list.
- Parameter lists reject duplicate printed names at the second binder. Calls and
  lists reject trailing commas rather than accepting an undocumented extension.
- `Surface_printer` uses fully parenthesized structural notation. It is a debug
  and golden-test rendering, not a source pretty-printer.
- Later surface features extend `Surface.shape` and the primary/statement parser;
  exhaustive consumers then fail to compile until they handle the new shape.

## Test impact

`test/unit/parser_test.ml` covers every implemented construct, contextual layout,
source and operator spans, duplicate binders, malformed delimiters, illegal
assignment targets, and explicit field-access rejection.

`test/golden/parser.expected` shows every adjacent precedence boundary, every
associativity rule, the complete precedence ladder, the required §4.1 examples,
and representative parser diagnostics. It uses the same Dune `diff` workflow as
the lexer golden: regenerate with `dune runtest --auto-promote` and review the
language change in the diff.
