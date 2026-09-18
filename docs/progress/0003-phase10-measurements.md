# Phase 10 classification and depth sweep

Run `python3 scripts/measure_phase10.py` from any directory. It rewrites
`docs/progress/phase10-measurements.json` with the exact JSON reports from
`ash --collapse ... --depth N --json` for five checked-in programs at depths
0–3, records the host/tool versions, and calculates each tower-step ratio as
`steps(depth N) / steps(depth N−1)`. The JSON file is the raw data; this page
is an index, not a replacement for it. The command does not assume a scaling
curve.

| Program | Class | Depth 0/1/2/3 tower steps | Depth 1/2/3 ratios | Residual nodes |
|---|---|---:|---:|---:|
| `classification_invariant.ash` | DEPTH-INVARIANT, FULL | 8 / 56 / 292 / 1472 | 7.000 / 5.214 / 5.041 | 1 |
| `classification_sensitive.ash` | DEPTH-SENSITIVE, FULL | 11 / 71 / 366 / 1841 | 6.455 / 5.155 / 5.030 | 6 |
| `classification_partial.ash` | PARTIAL | 65 / 577 / 3184 / 16223 | 8.877 / 5.518 / 5.095 | 50 |
| `classification_opaque.ash` | OPAQUE | 49 / 465 / 2600 / 13279 | 9.490 / 5.591 / 5.107 | 45 |
| `classification_persistent.ash` | OPAQUE | 25 / 316 / 1896 / 9802 | 12.640 / 6.000 / 5.170 | 48 |

All 20 tower/residual pairs agree on value or failure and output. The partial
sample folds `40 + 2` to `42` while retaining the runtime evaluator choice and
its source-located `meta_current_eval`/`meta_with_run` boundary. Its 50-node
residual exceeds the 47-node source because the boundary retains exact syntax
and adds runtime plumbing; partiality is evidenced by the folded `42`, not net
size reduction. The opaque scoped sample grows from 39 to 45 nodes with no
static computation outside the choice. The persistent sample stays at 48 nodes
and retains one `open_deref`. The report's `materialized_reachable_words` is host dependent;
its environment is pinned in the data file. Expanded semantic nodes use the
requested interposed depth, while materialized levels reflect runtime `up` or
scoped override use even at depth zero (ADR 0040).
