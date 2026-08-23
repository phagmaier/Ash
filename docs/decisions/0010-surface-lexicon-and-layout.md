# 0010 — The surface lexicon, layout, and golden diagnostics

- **Status:** accepted
- **Date:** 2026-08-23
- **Task:** 1.1

## Context

Spec §4 gives the surface language by example: bindings, functions, blocks,
pattern matching, quotation and splicing, and a precedence table. Turning
examples into a lexer forces decisions the examples leave implicit — what ends a
statement, what may appear in a name, which words are reserved, and what happens
to input the examples never show.

The lexer is also the first place Ash produces a diagnostic a user will read
about their own text, so the shape of a lexical error matters as much as the
token stream.

## Decision

**The surface lexicon is separate from the canonical Core notation.** `Sexp`
keeps reading Core, and `Lexer` scans Ash. Comments are `#` here and `;` there:
the Core reader could not use `#` because `#t` and `#f` begin with one, and Ash
spells those `true` and `false`, which frees `#` and leaves `;` to be the
sequencing operator §3 asks for. The two share `Cursor`, extracted in this
change, because line and column counting feeds `Span` and two implementations of
it would be two chances to underline the wrong character.

**Line structure is recorded, not consumed.** Every token carries
`starts_line`: whether a line break, or the start of the file, precedes it with
only whitespace and comments between. The spec's blocks separate statements by
newline (`{ let m = n % 3 ⏎ if m == 0 then … }`) as well as by `;`, so a token
stream that discarded layout would force the parser to scan the source again.
Emitting newline *tokens* was the alternative; it makes every grammar rule that
does not care about layout say so explicitly, which is most of them. Whether the
parser uses the flag is task 1.2's decision — the lexer's job is only to not
throw the information away.

**Integers are the numeric domain, and a malformed literal is refused rather
than split.** `12abc` does not lex as `12` then `abc`: that would parse as an
application in some positions and a syntax error in others, both confusing, and
neither says what is wrong. `1.5` is refused with a message naming the reason
(Ash has no floating-point numbers) rather than lexing as `1`, `.`, `5`. A
literal too large for a machine word is refused rather than wrapped. All three
report the offending text and the span it occupies.

**A name may end in `?`; it may never contain `!`.** `empty?` is a registered
primitive (ADR 0009), so the surface has to be able to write it. `!` is prefix
negation, and a name that could end in one would make `x!y` depend on spacing.
`_` alone is the wildcard pattern, while `_x` is an ordinary name, which the
desugarer needs for the fresh binders its sequencing sugar introduces.

**A word is reserved only when the parser must recognize it before it can parse
what follows.** That gives `true false let var fn if then else match open up
meta_with reifier` and nothing else. `meta_with` is on the list because
`meta_with(eval = tracing(eval))` puts an `=` inside an argument list and that is
not an expression. `run`, `lift`, `reflect`, `resume`, `eval`, `apply`, and
`print` are deliberately *not* reserved: they are ordinary bindings, and
reserving them would stop a program from shadowing the very thing it is
reflecting on, which is much of the point of a tower.

**Operators are resolved by maximal munch.** The longest operator that matches
wins, so `|>` is never `|` then `>` and `::` is never a failed `:`. The
one-character table is what remains after the two-character one, which is why `:`
and `&` are absent: neither means anything alone, so the scanner reports the
character rather than inventing a token the parser would have to reject.

**`` `{ `` and `${` are single tokens.** The brace must follow immediately, and
when it does not, the diagnostic names the character that actually followed —
"expected `{` after a backtick, found `x`" — because that is the correction the
writer has to make.

**`.` is lexed although nothing parses it.** The spec's precedence table lists
field access. Ash values have no fields, so task 1.2 will reject a `.`, but
rejecting it in the grammar produces a better message than rejecting it in the
scanner, and the lexicon should match the spec's rather than quietly drop an
entry.

**String literals do not span lines**, and their escapes are exactly the ones
`Constant.escape_string` produces, so a printed literal reads back as itself. An
unterminated literal is reported at its opening quote, which is where the mistake
is, rather than at the end of the file.

## Alternatives

**Newline tokens, or significant indentation.** Newline tokens push layout into
every rule; indentation is a larger commitment than a language whose blocks are
already braced needs. The flag is the smaller mechanism that supports both
statement styles the spec uses.

**Mandatory semicolons.** Would contradict the spec's own samples.

**No keywords: let the parser recognize words as identifiers.** Workable for
`let` and `fn`, but not for `meta_with`, whose argument list is not an
expression. A partial keyword set decided per-construct is harder to explain than
one table.

**Allowing `!` in names** (Scheme's `set!`). Rejected above; ADR 0009 had already
chosen `cell_set` over `set!`, so nothing needs it.

## Consequences

- `Token` is the parser's vocabulary. Its three renderings — `spelling`,
  `describe`, `name` — are what golden output and parser diagnostics use, so the
  parser never formats a token by hand.
- `Lexer.is_name` is the single place that knows what a name looks like; the
  desugarer asks before inventing one.
- A new token kind is a change to `Token.kind`, which forces every exhaustive
  match over it to be revisited, and shows up in the lexer test's coverage list.

## Test impact

`test/unit/lexer_test.ml` covers literals, names and reserved words, operators
and maximal munch, staging tokens, layout, spans, malformed literals, stray
characters, and every §4–§6 sample in the spec. It ends by checking that the
corpus produced every token kind, so a kind nobody lexes is a failure naming
itself.

`test/golden/` is new, and is where the acceptance criterion for this task lives.
It pins the token stream for each spec sample, the maximal-munch table as
something a reviewer can check against the precedence list at a glance, and the
rendered diagnostic for every malformed literal and stray character. Golden files
are compared by dune's `diff` action, so `dune runtest --auto-promote` updates
them and the diff is the review: a change there is a change to the language's
lexicon or to a message a user reads, and both should be seen deliberately.
