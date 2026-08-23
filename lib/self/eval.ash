# The CPS Core evaluator, written in Ash. Spec §6; to-do tasks 2.1 and 2.2.
#
# This is the centre of the project, so every line here is paid for once per
# tower level. It is kept parallel to the host evaluator in `lib/runtime`: same
# eleven forms, same order of evaluation, same one-shot discipline, and the same
# open-recursive group. Where the two differ, the difference is written down.
#
# What a Core term looks like here
# --------------------------------
# A term is a tagged list, built by `Ash_self.Encode`. Quotation is Phase 3, so
# the interpreted program arrives as ordinary Ash data rather than as `Code`:
#
#   ['lit, c]            ['var, x]              ['named_var, "s"]
#   ['lam, params, body] ['app, func, args]     ['quote, q]
#   ['let, x, e, body]   ['letrec, bindings, b] ['if, c, t, f]
#   ['set, x, e]         ['reifier, params, body]
#
# An identifier is `[name, id]`: printed name plus unique id, never a string
# alone, so hygiene survives the encoding (spec §D1). A `letrec` binding is
# `[name, lam-node]`.
#
# What an interpreted value looks like here
# -----------------------------------------
# Scalars, lists, cells, and primitives are represented by themselves, so a
# primitive can be handed one directly and arithmetic needs no marshalling.
# Closures, reifiers, and continuations — the three this level constructs — are
# lists whose head is TAG, a cell this file allocates and nothing else can reach.
# An interpreted program cannot forge one: it has no way to name TAG, and every
# cell it can allocate is a different cell.
#
# A primitive stays a primitive rather than being wrapped, and that is what lets
# this interpreter run under itself. Wrapped, the primitive a level below hands
# down would arrive as that level's wrapper — a list, not something applicable —
# and the second layer would have nothing it could call. Unwrapped, `invoke`
# reaches the same primitive however many levels it passed through.
#
# Each closure and reifier carries a fresh cell as its identity, so `==` on two
# of them compares places rather than shapes, which is what the host means by
# "two closures with the same body are still two closures".

let TAG = cell_new('interpreted_value)

fn nth(xs, n) = if n == 0 then head(xs) else nth(tail(xs), n - 1)

fn tagged?(v) = list?(v) && !empty?(v) && head(v) == TAG
fn tag_of(v) = nth(v, 1)

fn clo(params, body, r) = [TAG, 'clo, params, body, r, cell_new('identity)]
fn reif(params, body, r) = [TAG, 'reif, params, body, r, cell_new('identity)]
fn cont(k) = [TAG, 'cont, k, cell_new(false)]

# Ash has no way to build a structured error: a cause carries a span, and the
# encoding carries none until `Code` does (Phase 3). A failure this level
# detects itself therefore says what happened and stops, rather than pretending
# to be the diagnostic the host would have written. Failures the host detects —
# every primitive's arity, type, and division error — come through unchanged.
fn die(what) = match_error(what)

# Environments: a list of frames, innermost first; a frame is a list of
# `[identifier, cell]`. Values are reached through cells, so an assignment is
# visible to every closure that already captured the binding.

fn frame_find(f, x) =
  if empty?(f) then 'miss
  else if head(head(f)) == x then nth(head(f), 1)
  else frame_find(tail(f), x)

fn lookup(r, x) =
  if empty?(r) then die(['unbound, x])
  else {
    let found = frame_find(head(r), x)
    if found == 'miss then lookup(tail(r), x) else found
  }

# `named_var` resolves by printed name against whatever environment it is given.
# Two bindings in one frame that print alike have no non-arbitrary answer, and
# choosing by allocation order would make the gensym counter observable, so the
# ambiguity is reported instead.
fn frame_find_by_name(f, s) =
  if empty?(f) then 'miss
  else if head(head(head(f))) == s then
    if frame_find_by_name(tail(f), s) == 'miss then nth(head(f), 1)
    else die(['ambiguous, s])
  else frame_find_by_name(tail(f), s)

fn lookup_by_name(r, s) =
  if empty?(r) then die(['unbound_name, s])
  else {
    let found = frame_find_by_name(head(r), s)
    if found == 'miss then lookup_by_name(tail(r), s) else found
  }

fn bind(r, x, c) = [[x, c]] :: r

fn frame_of(xs, vs) =
  if empty?(xs) then []
  else [head(xs), cell_new(head(vs))] :: frame_of(tail(xs), tail(vs))

fn extend(r, xs, vs) = frame_of(xs, vs) :: r

fn placeholders(bs) =
  if empty?(bs) then []
  else [head(head(bs)), cell_new('unfilled)] :: placeholders(tail(bs))

fn prealloc(r, bs) = placeholders(bs) :: r

# Allocate every cell, then fill each with a closure over the extended
# environment. Evaluating a lambda calls nothing, so no cell can be read while
# it still holds the placeholder.
fn fill(r, bs) =
  if empty?(bs) then {}
  else {
    let b = head(bs)
    let lam = nth(b, 1)
    cell_set(lookup(r, head(b)), clo(nth(lam, 1), nth(lam, 2), r))
    fill(r, tail(bs))
  }

fn assign(r, x, w) = cell_set(lookup(r, x), w)

# The group. Every occurrence of `eval`, `apply`, and `eval_list` below is a
# dereference of this level's cell, which is what `open` means (spec §D3): a
# meta level that replaces one of them intercepts every nested step, not just
# the entry. No name in this group is ever captured directly by a closure.

open fn eval(e, r, k) = {
  let form = head(e)
  if form == 'lit then k(nth(e, 1))
  else if form == 'var then k(deref(lookup(r, nth(e, 1))))
  else if form == 'named_var then k(deref(lookup_by_name(r, nth(e, 1))))
  else if form == 'quote then k(nth(e, 1))
  else if form == 'lam then k(clo(nth(e, 1), nth(e, 2), r))
  else if form == 'reifier then k(reif(nth(e, 1), nth(e, 2), r))
  else if form == 'if then
    eval(nth(e, 1), r, fn(b) ->
      if b then eval(nth(e, 2), r, k) else eval(nth(e, 3), r, k))
  else if form == 'let then
    eval(nth(e, 2), r, fn(v) -> eval(nth(e, 3), bind(r, nth(e, 1), cell_new(v)), k))
  else if form == 'letrec then {
    let bs = nth(e, 1)
    let inner = prealloc(r, bs)
    fill(inner, bs)
    eval(nth(e, 2), inner, k)
  }
  else if form == 'set then
    eval(nth(e, 2), r, fn(w) -> k(assign(r, nth(e, 1), w)))
  else if form == 'app then
    eval(nth(e, 1), r, fn(f) ->
      if tagged?(f) && tag_of(f) == 'reif then die(['reifier_application, e])
      else eval_list(nth(e, 2), r, fn(vs) -> apply(f, vs, k)))
  else die(['unknown_form, e])
}

open fn apply(f, vs, k) =
  # Not one of the three callables this level constructs: a primitive, or
  # something that is not callable at all. `callcc` is the one primitive this
  # level cannot delegate — the level below would capture the interpreter's
  # continuation instead of the interpreted program's — and it is recognized by
  # value rather than by name, so a program that renames it is still caught and a
  # program that shadows it with its own function is not. Everything else is
  # applied below, so its arity, type, and arithmetic diagnostics are the ones a
  # level-0 run would give, and anything uncallable is refused in those words.
  if !tagged?(f) then
    if f == callcc then
      if length(vs) != 1 then die(['arity, 1, length(vs)])
      else apply(head(vs), [cont(k)], k)
    else k(invoke(f, vs))
  else {
    let what = tag_of(f)
    if what == 'clo then
      if length(nth(f, 2)) != length(vs) then
        die(['arity, length(nth(f, 2)), length(vs)])
      else eval(nth(f, 3), extend(nth(f, 4), nth(f, 2), vs), k)
    else if what == 'cont then
      if length(vs) != 1 then die(['arity, 1, length(vs)])
      else {
        let used = nth(f, 3)
        # Marked before the transfer, so a continuation reached again through
        # its own resumption is caught rather than looping (spec §D4).
        if deref(used) then die(['continuation_reuse, f])
        else {
          cell_set(used, true)
          nth(f, 2)(head(vs))
        }
      }
    # Applying a reifier runs one level up. There is no level above yet; the
    # tower is task 4.2.
    else die(['reifier_application, f])
  }

# Left to right, with the tail evaluated inside the head's continuation, so the
# order does not change when an argument captures control.
open fn eval_list(es, r, k) =
  if empty?(es) then k([])
  else eval(head(es), r, fn(v) -> eval_list(tail(es), r, fn(vs) -> k(v :: vs)))

# The interface the level below calls. `prims` is a list of `[identifier, op]`,
# one per primitive of that level, which becomes the interpreted program's single
# global frame — the same bindings a level-0 run is given.
fn globals_frame(prims) =
  if empty?(prims) then []
  else {
    let p = head(prims)
    [head(p), cell_new(nth(p, 1))] :: globals_frame(tail(prims))
  }

# An interpreted closure has no host counterpart, so it is reported as its tag
# rather than handed back as a list the host would compare structurally. Scalars,
# lists, cells, and primitives are already themselves.
fn reveal(v) =
  if tagged?(v) then tag_of(v)
  else if list?(v) then reveal_list(v)
  else v

fn reveal_list(vs) =
  if empty?(vs) then [] else reveal(head(vs)) :: reveal_list(tail(vs))

fn interpret(e, prims) = reveal(eval(e, [globals_frame(prims)], fn(v) -> v))
