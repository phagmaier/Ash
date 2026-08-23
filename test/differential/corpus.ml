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
