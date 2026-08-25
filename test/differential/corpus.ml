(* The differential corpus (to-do tasks 0.8 and 1.6, extended in 2.2).

   One list of programs, read by every evaluator this project has. The oracle
   and the CPS evaluator compare over it in `oracle_cps_test.ml`; the CPS
   evaluator and the self-interpreter written in Ash compare over it in
   `self_host_test.ml`. Keeping it in one place is what makes the second
   comparison free of the temptation to pick easier programs than the first.

   The Core half is written in the canonical notation, which is what the
   self-interpreter reads; the surface half is written in Ash and lowered by the
   desugarer, which additionally puts the whole front end under comparison. *)

(* Values *)

let values =
  [
    ("a literal", "(lit 42)");
    ("unit", "(lit unit)");
    ("the empty list", "(lit nil)");
    ("addition", "(app (var +) (lit 1) (lit 2))");
    ("nested arithmetic", "(app (var +) (lit 2) (app (var *) (lit 3) (lit 4)))");
    ("truncating division", "(app (var /) (lit -7) (lit 2))");
    ("remainder", "(app (var %) (lit -7) (lit 2))");
    ("comparison", "(app (var <) (lit 1) (lit 2))");
    ("structural equality",
     "(app (var ==) (app (var list) (lit 1) (lit 2)) (app (var list) (lit 1) (lit 2)))");
    ("nested structural equality",
     "(app (var ==) (app (var list) (app (var list) (lit 1)) (lit nil)) (app (var list) (app (var list) (lit 1)) (lit nil)))");
    ("closure identity", "(app (var ==) (lam (x) (var x)) (lam (x) (var x)))");
    ("a symbol", "(lit 'tag)");
    ("string equality", "(app (var ==) (lit \"a\") (lit \"a\"))");
    ("negation", "(app (var not) (lit #f))");
    ("applying a lambda", "(app (lam (x) (var x)) (lit 1))");
    ("several parameters", "(app (lam (x y) (app (var -) (var x) (var y))) (lit 5) (lit 2))");
    ("a nullary lambda", "(app (lam () (lit 7)))");
    ("higher order",
     "(app (lam (f x) (app (var f) (var x))) (lam (n) (app (var +) (var n) (lit 1))) (lit 4))");
    ("currying", "(app (app (lam (x) (lam (y) (app (var +) (var x) (var y)))) (lit 1)) (lit 2))");
    ("a returned closure keeps its capture",
     "(let make (lam (n) (lam (x) (app (var +) (var x) (var n)))) (app (app (var make) (lit 10)) (lit 5)))");
    ("two closures from one binder do not share",
     "(let make (lam (n) (lam (x) (app (var +) (var x) (var n)))) (app (var +) (app (app (var make) (lit 1)) (lit 0)) (app (app (var make) (lit 2)) (lit 0))))");
    ("captured environment",
     "(let a (lit 1) (let f (lam (x) (app (var +) (var x) (var a))) (app (var f) (lit 10))))");
    ("a rebinding a closure must not see",
     "(let a (lit 1) (let f (lam (x) (app (var +) (var x) (var a))) (let a (lit 100) (app (var f) (lit 10)))))");
    ("shadowing", "(let x (lit 1) (let x (lit 2) (var x)))");
    ("a parameter shadows an outer binding",
     "(let x (lit 1) (app (lam (x) (var x)) (lit 2)))");
    ("a parameter shadows a global",
     "(app (lam (head) (var head)) (lit 3))");
    ("a recursive name shadows a global",
     "(letrec ((length (lam (n) (if (app (var ==) (var n) (lit 0)) (lit 0) (app (var length) (app (var -) (var n) (lit 1))))))) (app (var length) (lit 3)))");
    ("the true branch", "(if (lit #t) (lit 1) (lit 2))");
    ("the false branch", "(if (lit #f) (lit 1) (lit 2))");
    ("an unevaluated branch", "(if (lit #t) (lit 1) (app (var /) (lit 1) (lit 0)))");
    ("an empty recursive group", "(letrec () (lit 5))");
    (* A recursive binding is only ever read after every cell is filled, so the
       unfilled state the environment can represent is unreachable from Core. *)
    ("a recursive binding is filled before anything can read it",
     "(letrec ((f (lam (n) (var n)))) (app (var f) (lit 1)))");
    ("factorial",
     "(letrec ((fact (lam (n) (if (app (var ==) (var n) (lit 0)) (lit 1) (app (var *) (var n) (app (var fact) (app (var -) (var n) (lit 1)))))))) (app (var fact) (lit 20)))");
    ("mutual recursion",
     "(letrec ((even? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #t) (app (var odd?) (app (var -) (var n) (lit 1)))))) (odd? (lam (n) (if (app (var ==) (var n) (lit 0)) (lit #f) (app (var even?) (app (var -) (var n) (lit 1))))))) (app (var even?) (lit 10)))");
    (* Tail recursion is a host tail call in both, so the depth here is a
       statement about the evaluators, not about the host stack. *)
    ("a long tail-recursive loop",
     "(letrec ((loop (lam (n acc) (if (app (var ==) (var n) (lit 0)) (var acc) (app (var loop) (app (var -) (var n) (lit 1)) (app (var +) (var acc) (var n))))))) (app (var loop) (lit 10000) (lit 0)))");
    ("building a list", "(app (var cons) (lit 0) (app (var list) (lit 1) (lit 2)))");
    ("head and tail", "(app (var head) (app (var tail) (app (var list) (lit 1) (lit 2))))");
    ("a list of lists",
     "(app (var head) (app (var list) (app (var list) (lit 1) (lit 2)) (lit nil)))");
    ("length of a built list",
     "(app (var length) (app (var cons) (lit 1) (app (var list) (lit 2) (lit 3))))");
    ("a recursive list function",
     "(letrec ((len (lam (xs) (if (app (var empty?) (var xs)) (lit 0) (app (var +) (lit 1) (app (var len) (app (var tail) (var xs))))))))  (app (var len) (app (var list) (lit 7) (lit 8) (lit 9))))");
    ("a list built recursively",
     "(letrec ((double (lam (xs) (if (app (var empty?) (var xs)) (lit nil) (app (var cons) (app (var *) (lit 2) (app (var head) (var xs))) (app (var double) (app (var tail) (var xs)))))))) (app (var double) (app (var list) (lit 1) (lit 2))))");
    ("append written recursively",
     "(letrec ((append (lam (xs ys) (if (app (var empty?) (var xs)) (var ys) (app (var cons) (app (var head) (var xs)) (app (var append) (app (var tail) (var xs)) (var ys))))))) (app (var append) (app (var list) (lit 1) (lit 2)) (app (var list) (lit 3))))");
    ("reverse written with an accumulator",
     "(letrec ((rev (lam (xs acc) (if (app (var empty?) (var xs)) (var acc) (app (var rev) (app (var tail) (var xs)) (app (var cons) (app (var head) (var xs)) (var acc))))))) (app (var rev) (app (var list) (lit 1) (lit 2) (lit 3)) (lit nil)))");
    ("a higher-order fold over a list",
     "(letrec ((fold (lam (f acc xs) (if (app (var empty?) (var xs)) (var acc) (app (var fold) (var f) (app (var f) (var acc) (app (var head) (var xs))) (app (var tail) (var xs))))))) (app (var fold) (lam (a b) (app (var +) (var a) (var b))) (lit 0) (app (var list) (lit 1) (lit 2) (lit 3))))");
  ]

(* Mutation and evaluation order: the two places where two implementations most
   easily drift apart without either looking wrong on its own. *)

let effects =
  [
    ("set evaluates to unit", "(let x (lit 1) (set x (lit 2)))");
    ("set updates the binding", "(let x (lit 1) (let _ (set x (lit 2)) (var x)))");
    ("mutation reaches a closure",
     "(let a (lit 1) (let f (lam (x) (app (var +) (var x) (var a))) (let _ (set a (lit 100)) (app (var f) (lit 10)))))");
    ("a closure mutates what it captured",
     "(let n (lit 0) (let bump (lam () (set n (app (var +) (var n) (lit 1)))) (let _ (app (var bump)) (let _ (app (var bump)) (var n)))))");
    ("two closures share one captured binding",
     "(let n (lit 0) (let bump (lam () (set n (app (var +) (var n) (lit 1)))) (let peek (lam () (var n)) (let _ (app (var bump)) (app (var peek))))))");
    ("arguments evaluate left to right",
     "(let x (lit 0) (app (var list) (set x (lit 1)) (var x)))");
    ("a later argument sees an earlier one's effect",
     "(let x (lit 0) (app (var list) (let _ (set x (lit 1)) (var x)) (var x)))");
    ("mutation inside a recursive group",
     "(let n (lit 0) (letrec ((bump (lam (k) (if (app (var ==) (var k) (lit 0)) (var n) (let _ (set n (app (var +) (var n) (lit 1))) (app (var bump) (app (var -) (var k) (lit 1)))))))) (app (var bump) (lit 5))))");
  ]

(* Failures: same cause, same place. *)

let errors =
  [
    ("division by zero", "(app (var /) (lit 1) (lit 0))");
    (* Both operands are bad, so which one is reported says which position was
       evaluated first. *)
    ("the function position evaluates first",
     "(app (app (var /) (lit 1) (lit 0)) (app (var head) (lit nil)))");
    ("remainder by zero", "(app (var %) (lit 1) (lit 0))");
    ("a type error in arithmetic", "(app (var +) (lit \"a\") (lit 1))");
    ("the first bad argument wins", "(app (var +) (lit #t) (lit \"a\"))");
    ("comparing non-numbers", "(app (var <) (lit 'a) (lit 'b))");
    ("negating a number", "(app (var not) (lit 1))");
    ("a non-boolean condition", "(if (lit 1) (lit 1) (lit 2))");
    ("applying a number", "(app (lit 1) (lit 2))");
    ("applying unit", "(app (lit unit))");
    ("an anonymous arity error", "(app (lam (x y) (var x)) (lit 1))");
    ("a nullary lambda given an argument", "(app (lam () (lit 1)) (lit 2))");
    ("a named arity error", "(letrec ((f (lam (n) (var n)))) (app (var f) (lit 1) (lit 2)))");
    ("a primitive arity error", "(app (var +) (lit 1) (lit 2) (lit 3))");
    ("head of the empty list", "(app (var head) (lit nil))");
    ("tail of the empty list", "(app (var tail) (lit nil))");
    ("empty? of a number", "(app (var empty?) (lit 1))");
    ("length of a string", "(app (var length) (lit \"abc\"))");
    ("consing onto a number", "(app (var cons) (lit 1) (lit 2))");
    (* The location matters as much as the cause: the failure is reported at the
       inner call, not at the call that led to it. *)
    ("a failure deep inside a recursion",
     "(letrec ((down (lam (n) (if (app (var ==) (var n) (lit 0)) (app (var head) (lit nil)) (app (var down) (app (var -) (var n) (lit 1))))))) (app (var down) (lit 5)))");
    ("a failure inside a closure the caller built",
     "(let f (lam (x) (app (var /) (var x) (lit 0))) (app (var f) (lit 1)))");
  ]

(* The same comparison over programs the front end produced, which is the only
   way the desugarer's output is checked against two evaluators rather than one. *)

let surface =
  [
    ("factorial", "fn fact(n) =\n  if n == 0 then 1 else n * fact(n - 1)\nfact(10)");
    ( "the documented length",
      "fn length(xs) =\n\
      \  match xs {\n\
      \    []      -> 0\n\
      \    _ :: ys -> 1 + length(ys)\n\
      \  }\n\
       length([1, 2, 3])" );
    ( "map written in Ash",
      "fn map(f, xs) =\n\
      \  match xs {\n\
      \    []      -> []\n\
      \    x :: ys -> f(x) :: map(f, ys)\n\
      \  }\n\
       map(fn(n) -> n * 2, [1, 2, 3])" );
    ( "a pipeline chain",
      "fn add(a, b) = a + b\nfn double(n) = n * 2\n3 |> add(4) |> double |> add(1)" );
    ("shadowing", "let x = 1\nlet x = x + 1\nlet x = x * 10\nx");
    ("a shadowed global", "let head = 5\nhead + head");
    ("mutation through a closure", "var c = 0\nfn bump() = c := c + 1\nbump()\nbump()\nc");
    ("short-circuit and", "fn boom() = 1 / 0\nfalse && boom() == 1");
    ("short-circuit or", "fn boom() = 1 / 0\ntrue || boom() == 1");
    ("nested blocks", "fn f(n) = {\n  let a = n + 1\n  {\n    let b = a * 2\n    b - 1\n  }\n}\nf(3)");
    ("alternatives in a pattern", "match 3 { 1 | 2 | 3 -> 'small\n_ -> 'big }");
    ("alternatives that bind", "match [7] { [x] | x :: [] -> x * 2\n_ -> 0 }");
    ("a nested list pattern", "match [1, [2, 3]] { [a, [b, c]] -> a + b + c\n_ -> 0 }");
    ("mutual recursion in one group",
     "fn even(n) = if n == 0 then true else odd(n - 1)\n\
      fn odd(n) = if n == 0 then false else even(n - 1)\n\
      even(10)");
  ]

let surface_errors =
  [
    ("a match that runs out of clauses", "match 9 { 1 -> 'one\n2 -> 'two }");
    ("division by zero inside a function", "fn f(n) = 10 / n\nf(0)");
    ("an arity error on a named function", "fn f(a, b) = a + b\nf(1)");
    ("a type error in a lowered operator", "let s = \"a\"\ns + 1");
  ]

(* Effect order (to-do task 7.3).

   Everything above asks whether two implementations agree on an answer. These
   ask whether they agree on *when*: which write a read sees, what reached the
   output stream in what order, and what the store holds once the program is
   done. That is the half a specializer gets wrong silently. A fold that moves a
   read across a write still produces a program, and a [print] that ran at
   compile time still produces a program; only a comparison of traces says which
   program it is.

   {1 Writing "dynamic" without leaving a function unapplied}

   Several samples need a value the specializer cannot decide, and still have to
   run to an answer two runs can compare — a residual that is a function could
   only be compared by applying it, and what a tower run recorded cannot be
   applied afterwards. [deref(cell_new(v))] is how that is written here: the
   allocation primitives always residualize (spec 7.4, ADR 0036), so the value
   is dynamic to the specializer and is plainly [v] to every run.

   {1 The observable store}

   A store is not comparable across two runs: cells carry identity and each run
   allocates its own (D1). What is comparable is what a program reads back out
   of one, so each sample states its store observation as [store] — expressions
   evaluated after [answer], in the order written. The harness composes the
   three parts into one program, so a single run yields the value, the trace and
   the final store together, and a difference can still be named as whichever of
   the three it is. A sample that fails has no store observation left to make,
   which is why the failing programs are their own list. *)

type effect_sample = {
  name : string;
  setup : string;  (** Statements, run for what they do. *)
  answer : string;  (** The expression whose value is compared. *)
  store : string list;  (** Read after [answer]: the observable store. *)
}

let effect_sample_program sample =
  sample.setup ^ "\n[" ^ String.concat ", " (sample.answer :: sample.store) ^ "]"

let sample name setup answer store = { name; setup; answer; store }

let effect_order =
  [
    (* Reads on both sides of a write, in one argument list: the order of the
       three reads is the whole content of the answer. *)
    sample "a read on each side of a write" "var x = 0"
      "[x, { x := 1; x }, x]" [ "x" ];
    (* Every read here folds and every [println] residualizes, so the residual
       is a sequence of prints around constants — which is right only if the
       constants are the values the reads had at those points. *)
    sample "output ordered around folded reads"
      "var x = 0\nfn note(tag, v) = { println(tag); v }"
      "[note(\"first\", { x := x + 1; x }), note(\"second\", x), \
       note(\"third\", { x := x * 10; x })]"
      [ "x" ];
    (* A binding two closures share is the residual program's, so these writes
       and reads are residual [Set]s and variables rather than folds, and the
       prints between them fix their order. *)
    sample "output between two writes to a shared binding"
      "var n = 0\n\
       fn bump() = n := n + 1\n\
       fn peek() = n\n\
       println(\"start\")\n\
       bump()\n\
       println(peek())\n\
       bump()\n\
       println(peek())"
      "peek()" [ "n" ];
    (* ADR 0033's store guard, end to end: [a] is bound to a bare read of a
       binding a later write changes, which is exactly the binding the
       normalizer may not substitute away. Substituting it answers 4. *)
    sample "a read of a binding a later write changes"
      "var x = 1\nfn bump() = x := x + 1\nlet a = x\nbump()" "a + x"
      [ "a"; "x" ];
    (* D7's compile-time channel beside the program's own stream: [static_log]
       runs while specializing and leaves no call behind, so the two runs write
       the same output despite one of them never reaching it. *)
    sample "the compile-time channel is not the program's output"
      "var n = 0\n\
       fn bump() = n := n + 1\n\
       fn peek() = n\n\
       bump()\n\
       static_log(peek())\n\
       println(peek())\n\
       bump()"
      "peek()" [ "n" ];
    (* Spec 7.4's own example, both ways round, with a second binding no branch
       writes: [x] is given up before the fork and [y] stays the specializer's,
       which is what makes it a *split* store rather than a residualized one. *)
    sample "a dynamic branch chooses the write, taken"
      "var x = 0\nvar y = 5\nlet b = deref(cell_new(true))\nif b then x := 1 else x := 2"
      "x + y" [ "x"; "y" ];
    sample "a dynamic branch chooses the write, not taken"
      "var x = 0\nvar y = 5\nlet b = deref(cell_new(false))\nif b then x := 1 else x := 2"
      "x + y" [ "x"; "y" ];
    (* The branch not taken carries both a print and a division that would fail:
       neither may happen, and the residual has to keep both where they are. *)
    sample "a dynamic branch prints and writes"
      "var x = 0\n\
       let z = deref(cell_new(0))\n\
       let b = deref(cell_new(false))\n\
       if b then { println(\"yes\"); x := 1 / z } else { println(\"no\"); x := 7 }"
      "x" [ "x" ];
    (* Short-circuit is a dynamic conditional the front end wrote, so the write
       inside the operand happens exactly when the operator says it does. *)
    sample "short-circuit skips the write"
      "var x = 0\nfn boom() = { x := x + 1; true }\nlet b = deref(cell_new(false))"
      "b && boom()" [ "x" ];
    sample "short-circuit performs the write"
      "var x = 0\nfn boom() = { x := x + 1; true }\nlet b = deref(cell_new(true))"
      "b && boom()" [ "x" ];
    (* A binding written from inside an inlined call, under a branch the
       specializer cannot decide: the write is not written in the branch it
       happens in, which is why a binder free in a lambda is never held. *)
    sample "a captured binding written under a dynamic branch, taken"
      "var c = 0\n\
       fn bump() = c := c + 1\n\
       fn peek() = c\n\
       let b = deref(cell_new(true))\n\
       if b then bump() else println(\"skipped\")"
      "peek()" [ "c" ];
    sample "a captured binding written under a dynamic branch, not taken"
      "var c = 0\n\
       fn bump() = c := c + 1\n\
       fn peek() = c\n\
       let b = deref(cell_new(false))\n\
       if b then bump() else println(\"skipped\")"
      "peek()" [ "c" ];
    (* The heap, which the store discipline does not cover: allocation always
       residualizes, so nothing here folds and the residual is the program's own
       order of reads and writes. *)
    sample "a heap cell the specializer never owns"
      "let c = cell_new(0)\n\
       println(deref(c))\n\
       cell_set(c, deref(c) + 1)\n\
       println(deref(c))"
      "deref(c)" [ "deref(c)" ];
    (* A specialization point over a binding it assigns, printing on the way:
       one residual function, called with the counts the source visits, in the
       order the source visits them. *)
    sample "recursion the specializer cannot finish, printing and accumulating"
      "var total = 0\n\
       fn down(k) =\n\
      \  if k == 0 then total\n\
      \  else {\n\
      \    println(k)\n\
      \    total := total + k\n\
      \    down(k - 1)\n\
      \  }\n\
       let n = deref(cell_new(3))"
      "down(n)" [ "total" ];
    (* One binder, three activations, three places — and three prints that say
       which activation each write belonged to. *)
    sample "a local binding in a function called repeatedly, with output"
      "fn twice(n) = {\n\
      \  var t = n\n\
      \  println(t)\n\
      \  t := t * 2\n\
      \  t\n\
       }"
      "twice(1) + twice(2) + twice(3)" [];
  ]

(* Failures the residual raises rather than folds, which is what makes the
   effects *before* them comparable: a folded failure never reaches a residual
   at all, so the output and the writes that preceded it are only observable
   when the failing operation is one the specializer had to leave behind. *)

let effect_order_failures =
  [
    ("a residualized division by zero after output and a write",
     "var x = 0\n\
      println(\"a\")\n\
      x := x + 1\n\
      println(x)\n\
      let z = deref(cell_new(0))\n\
      1 / z");
    ("a dynamic branch that fails, taken",
     "var x = 0\n\
      let z = deref(cell_new(0))\n\
      let b = deref(cell_new(true))\n\
      if b then { println(\"yes\"); x := 1 / z } else { println(\"no\"); x := 7 }\n\
      x");
    ("a failure after a shared binding was written",
     "var n = 0\n\
      fn bump() = n := n + 1\n\
      bump()\n\
      println(n)\n\
      head(deref(cell_new([])))");
  ]

(* Where specialization stops. The program runs; the specializer refuses it,
   because a failure it can decide inside a branch it cannot decide aborts the
   whole specialization rather than becoming a residual failure in that branch.
   Residualizing a decided failure is error-and-control work no step of spec
   7.4's fragment ordering owns, so the boundary is recorded here rather than
   hidden: a refusal is not a
   disagreement, but it is a limit, and a corpus that dropped the sample would
   stop reporting the limit the day it moved. *)

let effect_order_boundaries =
  [
    ("a statically failing branch the program never takes",
     "var x = 0\n\
      let b = deref(cell_new(false))\n\
      if b then { println(\"yes\"); x := 1 / 0 } else { println(\"no\"); x := 7 }\n\
      x");
  ]
