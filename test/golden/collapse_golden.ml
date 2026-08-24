(* The collapse report, pinned (to-do task 5.4).

   The report is the deliverable: §9.4's point is that collapsibility becomes an
   observable property of the implementation rather than a yes/no compiler
   outcome, so what a reader sees is what has to be held still. These samples are
   chosen so that every counter in the report is non-zero in at least one of
   them — a report whose numbers were all zero would pin nothing.

   Everything here is reproducible by construction: counters and AST walks, no
   wall time, no heap words, no dependence on identifier-allocation order. *)

open Ash_collapse

let sample ?(depth = 1) ?budget name program =
  print_string (Collapse.report ~depth ?budget ~file:"sample.ash" ~name program);
  print_newline ()

(* The default budget is far above anything a working program reaches, which is
   the point of it — so the sample that shows a generalization has to ask for a
   small one. *)
let tight =
  { Ash_stage.Specialize.max_inline_depth = 6; max_residual_bindings = 10_000 }

let () =
  (* Static all the way down: the residual is the answer. *)
  sample "recursion on static data"
    (Metrics.Surface "fn fact(n) =\n  if n == 0 then 1 else n * fact(n - 1)\nfact(5)");

  (* The same program measured against a deeper tower. The tower's cost grows;
     the program's own cost and the residual do not. *)
  sample ~depth:0 "recursion on static data, no tower"
    (Metrics.Surface "fn fact(n) =\n  if n == 0 then 1 else n * fact(n - 1)\nfact(5)");
  sample ~depth:3 "recursion on static data, depth 3"
    (Metrics.Surface "fn fact(n) =\n  if n == 0 then 1 else n * fact(n - 1)\nfact(5)");

  (* An answer that still depends on something unknown: work survives, and it is
     the program's own work rather than an interpreter's. *)
  sample "a function of an unknown argument" (Metrics.Surface "fn(x) -> x * 2 + 1");

  (* Immutable data with a known spine and unknown contents (task 5.3): the
     traversal folds, the elements stay residual. *)
  sample "a traversal of a statically shaped list"
    (Metrics.Surface "fn(x) -> length([x, x, 1])");

  (* Recursion the specializer cannot see the end of (task 6.1): the control is
     an unknown argument, so unrolling has no end and the specializer stops at a
     memoized specialization point — a residual [LetRec] it calls instead. This
     is the sample where the specialization-point counter is not zero. *)
  sample "recursion on an unknown argument"
    (Metrics.Surface "fn sum(n) =\n  if n == 0 then 0 else n + sum(n - 1)\nfn(x) -> sum(x)");

  (* Recursion that never repeats a key, under a budget it exceeds (task 6.2):
     the accumulator grows at every step, so there is no cycle for 6.1 to find.
     The specializer gives up the accumulator and says so. This is the sample
     where the generalization counter is not zero. *)
  sample ~budget:tight "an accumulator too large for its budget"
    (Metrics.Core_notation
       "(letrec ((rev (lam (xs acc)\n\
       \                (if (app (var empty?) (var xs)) (var acc)\n\
       \                    (app (var rev) (app (var tail) (var xs))\n\
       \                         (app (var cons) (app (var head) (var xs)) (var acc)))))))\n\
       \  (lam (l) (app (var rev) (var l) (lit nil))))");

  (* An Ash open-recursion group is what an interpreter is made of, and its
     dereferences residualize until Phase 7 can reason about the store. This is
     the sample where the eval-cell counter is not zero. *)
  sample "an open-recursion group"
    (Metrics.Surface "open fn step(n) =\n  if n == 0 then 0 else step(n - 1)\nfn(x) -> step(x)");

  (* Dispatching on a Core constructor at runtime: interpretation that survived,
     counted as such. *)
  sample "dispatching on a Core node"
    (Metrics.Core_notation
       "(app (var head) (app (var code_view) (quote (app (var +) (lit 1) (lit 2)))))");

  (* The §D7 trap, pinned: the source run and the residual run print, and
     specialization does not. *)
  sample "observable output" (Metrics.Surface "println(\"hi\")\n42");

  (* Outside the fragment: the report says which program it could not stage and
     why, rather than reporting a residual it does not have. *)
  sample "a store operation"
    (Metrics.Core_notation "(let x (lit 1) (let _ (set x (lit 2)) (var x)))")
