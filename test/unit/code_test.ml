(* Hygienic Core template operations behind surface quotation (task 3.1). *)

open Ash_core

let failures = ref 0

let check name condition =
  if not condition then (
    incr failures;
    Printf.printf "FAIL %s\n" name)

let span = Span.unknown
let var ident = Core.var ~span ident

let test_splice () =
  let marker = Ident.fresh "x" in
  let template_binder = Ident.fresh "x" in
  let replacement_ident = Ident.fresh "x" in
  let template =
    Core.lam ~span ~params:[ template_binder ] ~body:(var marker)
  in
  let replacement = var replacement_ident in
  let spliced = Code.splice ~marker ~replacement template in
  match Core.shape spliced with
  | Core.Lam { Core.params = [ binder ]; lam_body } -> (
      match Core.shape lam_body with
      | Core.Var reference ->
          check "splicing retains the template binder"
            (Ident.equal binder template_binder);
          check "a same-name binder does not capture the replacement"
            (Ident.equal reference replacement_ident
            && not (Ident.equal binder reference));
          check "the replacement remains free"
            (Ident.Set.mem replacement_ident (Alpha.free_idents spliced))
      | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          check "the replacement keeps its variable shape" false)
  | Core.Lam _ | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.App _
  | Core.Let _ | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _
  | Core.Reifier _ ->
      check "the template keeps its lambda shape" false

let test_template_match () =
  let hole = Ident.fresh "body" in
  let pattern_param = Ident.fresh "x" in
  let subject_param = Ident.fresh "y" in
  let template = Core.lam ~span ~params:[ pattern_param ] ~body:(var hole) in
  let subject = Core.lam ~span ~params:[ subject_param ] ~body:(var subject_param) in
  (match Code.match_template ~holes:[ hole ] ~template subject with
  | Some [ captured ] -> (
      match Core.shape captured with
      | Core.Var ident ->
          check "a hole captures the subject node with its identity"
            (Ident.equal ident subject_param)
      | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
      | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
          check "the hole captures a variable node" false)
  | None | Some [] | Some (_ :: _ :: _) ->
      check "an alpha-renamed binder matches around a hole" false);
  let exact_pattern =
    Core.lam ~span ~params:[ pattern_param ] ~body:(var pattern_param)
  in
  check "a template without holes matches modulo alpha-equivalence"
    (Code.match_template ~holes:[] ~template:exact_pattern subject = Some []);
  check "a different constructor does not match"
    (Code.match_template ~holes:[] ~template:exact_pattern
       (Core.lit ~span (Constant.Num 1))
    = None)

let () =
  test_splice ();
  test_template_match ();
  if !failures > 0 then (
    Printf.printf "%d code assertion(s) failed\n" !failures;
    exit 1)
