# The CPS Core evaluator, written in Ash. Spec §6.
#
# A subject is real Code. Constructor patterns expose its eleven Core forms,
# preserving every child node's hygienic identities and source span. The
# interpreter's environments therefore use one-node Var Code as keys; printed
# lookup is explicit through code_name, just as NamedVar is explicit in Core.
#
# Scalars, lists, cells, Code, and primitives represent themselves. Closures,
# reifiers, and continuations constructed by this interpreted level are lists
# headed by the private TAG cell, so an interpreted program cannot forge them.

let TAG = cell_new('interpreted_value)

fn nth(xs, n) = if n == 0 then head(xs) else nth(tail(xs), n - 1)

fn tagged?(v) = list?(v) && !empty?(v) && head(v) == TAG
fn tag_of(v) = nth(v, 1)

# A closure's final field is [] for an anonymous lambda and [binder] for a
# LetRec member. Keeping the binder lets arity diagnostics name recursive and
# surface-named functions exactly as the ground evaluator does.
fn clo(params, body, r, name) =
  [TAG, 'clo, params, body, r, cell_new('identity), name]

fn reif(params, body, r) =
  [TAG, 'reif, params, body, r, cell_new('identity)]

# The used cell contains [] before use and [application-Code] afterwards. This
# both enforces one-shot transfer and preserves the first-use span for a reuse
# diagnostic.
fn cont(k, capture) = [TAG, 'cont, k, cell_new([]), capture]

# Environments are lists of frames, innermost first; frames are lists of
# [identifier-Code, cell] pairs. Identity comparison on Code is alpha-aware and
# compares free variables by exact hygienic identity.

fn frame_find(f, x) =
  if empty?(f) then 'miss
  else if head(head(f)) == x then nth(head(f), 1)
  else frame_find(tail(f), x)

fn lookup(r, x, site) =
  if empty?(r) then raise_at(site, ['unbound_ident, x])
  else {
    let found = frame_find(head(r), x)
    if found == 'miss then lookup(tail(r), x, site) else found
  }

fn frame_matches_by_name(f, s) =
  if empty?(f) then []
  else {
    let binding = head(f)
    let rest = frame_matches_by_name(tail(f), s)
    if code_name(head(binding)) == s then binding :: rest else rest
  }

fn binding_idents(bindings) =
  if empty?(bindings) then []
  else head(head(bindings)) :: binding_idents(tail(bindings))

fn lookup_by_name(r, s, site) =
  if empty?(r) then raise_at(site, ['unbound_name, s])
  else {
    let matches = frame_matches_by_name(head(r), s)
    if empty?(matches) then lookup_by_name(tail(r), s, site)
    else if length(matches) == 1 then nth(head(matches), 1)
    else raise_at(site, ['ambiguous_name, s, binding_idents(matches)])
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

fn fill(r, bs) =
  if empty?(bs) then {}
  else {
    let binding = head(bs)
    let name = head(binding)
    match nth(binding, 1) {
      Lam(params, body) ->
        cell_set(lookup(r, name, name), clo(params, body, r, [name]))
    }
    fill(r, tail(bs))
  }

fn assign(r, x, w, site) = cell_set(lookup(r, x, site), w)

# Every recursive occurrence of eval/apply/eval_list dereferences its current
# open-group cell. apply carries the whole application Code as well as the
# callee and values so every diagnostic is attributed to the interpreted
# program rather than this file.

open fn eval(e, r, k) =
  match e {
    Lit(c) -> k(c)
    Var(x) -> k(deref(lookup(r, x, e)))
    NamedVar(s) -> k(deref(lookup_by_name(r, s, e)))
    Quote(q) -> k(q)
    Lam(params, body) -> k(clo(params, body, r, []))
    Reifier(params, body) -> k(reif(params, body, r))
    If(condition, consequent, alternative) ->
      eval(condition, r, fn(value) ->
        if value == true then eval(consequent, r, k)
        else if value == false then eval(alternative, r, k)
        else raise_at(condition, ['unexpected, value, "a boolean"]))
    Let(name, value, body) ->
      eval(value, r, fn(result) ->
        eval(body, bind(r, name, cell_new(result)), k))
    LetRec(bindings, body) -> {
      let inner = prealloc(r, bindings)
      fill(inner, bindings)
      eval(body, inner, k)
    }
    Set(name, value) ->
      eval(value, r, fn(result) -> k(assign(r, name, result, e)))
    App(func, args) ->
      eval(func, r, fn(callee) ->
        if tagged?(callee) && tag_of(callee) == 'reif then
          raise_at(e, ['unsupported, "reifier application", "the ground evaluator"])
        else eval_list(args, r, fn(values) -> apply(callee, values, k, e)))
  }

open fn apply(f, vs, k, site) =
  # A primitive stays unwrapped across levels. callcc is the one primitive this
  # level cannot delegate because the lower evaluator would capture the
  # interpreter's continuation rather than the interpreted program's.
  if !tagged?(f) then
    if f == callcc then
      if length(vs) != 1 then raise_at(site, ['arity, ["callcc"], 1, length(vs)])
      else apply(head(vs), [cont(k, site)], k, site)
    else k(invoke_at(site, f, vs))
  else {
    let what = tag_of(f)
    if what == 'clo then {
      let params = nth(f, 2)
      if length(params) != length(vs) then {
        let stored_name = nth(f, 6)
        let callee =
          if empty?(stored_name) then [] else [code_name(head(stored_name))]
        raise_at(site, ['arity, callee, length(params), length(vs)])
      }
      else eval(nth(f, 3), extend(nth(f, 4), params, vs), k)
    }
    else if what == 'cont then
      if length(vs) != 1 then
        raise_at(site, ['arity, ["continuation"], 1, length(vs)])
      else {
        let used = nth(f, 3)
        if !empty?(deref(used)) then
          raise_at(site,
            ['continuation_reuse, nth(f, 4), head(deref(used))])
        else {
          cell_set(used, [site])
          nth(f, 2)(head(vs))
        }
      }
    else raise_at(site,
      ['unsupported, "reifier application", "the ground evaluator"])
  }

# Left to right, with the tail inside the head's continuation so captured
# control cannot change argument order.
open fn eval_list(es, r, k) =
  if empty?(es) then k([])
  else eval(head(es), r, fn(v) -> eval_list(tail(es), r, fn(vs) -> k(v :: vs)))

# A level receives one [identifier-Code, primitive] pair per global. It gets a
# single global frame, exactly like the ground evaluator.
fn globals_frame(prims) =
  if empty?(prims) then []
  else {
    let p = head(prims)
    [head(p), cell_new(nth(p, 1))] :: globals_frame(tail(prims))
  }

fn reveal(v) =
  if tagged?(v) then tag_of(v)
  else if list?(v) then reveal_list(v)
  else v

fn reveal_list(vs) =
  if empty?(vs) then [] else reveal(head(vs)) :: reveal_list(tail(vs))

fn interpret(e, prims) = reveal(eval(e, [globals_frame(prims)], fn(v) -> v))
