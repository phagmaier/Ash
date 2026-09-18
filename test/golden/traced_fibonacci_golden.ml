(* Task 9.2's reproducible collapse artifact. The printed report is exactly
   `ash --collapse examples/traced_fibonacci.ash --depth 1 --show-residual`; assertions
   make the golden more than a snapshot of whatever the CLI happened to say. *)

open Ash_core
open Ash_syntax
open Ash_runtime
open Ash_collapse

let require condition message = if not condition then failwith message

let output_bytes events =
  String.concat ""
    (List.filter_map (function Io.Wrote text -> Some text | Io.Read _ -> None) events)

let is_print_call env func =
  match Core.shape func with
  | Core.Var ident -> (
      match Env.lookup env ident with
      | Some cell -> (
          match Value.cell_contents cell with
          | Some (Value.Primitive primitive) ->
              String.equal primitive.Value.prim_name "println"
          | Some _ | None -> false)
      | None -> false)
  | Core.Lit _ | Core.NamedVar _ | Core.Lam _ | Core.App _ | Core.Let _
  | Core.LetRec _ | Core.If _ | Core.Set _ | Core.Quote _ | Core.Reifier _ ->
      false

let rec print_sites env node =
  match Core.shape node with
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Quote _ -> 0
  | Core.Lam lambda -> print_sites env lambda.Core.lam_body
  | Core.App { Core.func; args } ->
      (if is_print_call env func then 1 else 0)
      + print_sites env func
      + List.fold_left (fun n arg -> n + print_sites env arg) 0 args
  | Core.Let { Core.let_value; let_body; _ } ->
      print_sites env let_value + print_sites env let_body
  | Core.LetRec { Core.rec_bindings; rec_body } ->
      List.fold_left
        (fun n binding -> n + print_sites env binding.Core.rec_lambda.Core.lam_body)
        (print_sites env rec_body) rec_bindings
  | Core.If { Core.condition; consequent; alternative } ->
      print_sites env condition + print_sites env consequent + print_sites env alternative
  | Core.Set { Core.set_value; _ } -> print_sites env set_value
  | Core.Reifier { Core.reifier_body; _ } -> print_sites env reifier_body

let rec has_traced_recursion env node =
  match Core.shape node with
  | Core.Quote _ -> false
  | Core.LetRec { Core.rec_bindings; _ } ->
      List.exists
        (fun binding -> print_sites env binding.Core.rec_lambda.Core.lam_body > 0)
        rec_bindings
      || List.exists (has_traced_recursion env) (Core.children node)
  | Core.Lit _ | Core.Var _ | Core.NamedVar _ | Core.Lam _ | Core.App _
  | Core.Let _ | Core.If _ | Core.Set _ | Core.Reifier _ ->
      List.exists (has_traced_recursion env) (Core.children node)

let () =
  let source =
    match Ash_examples.Demo.find "traced-fibonacci" with
    | Some demo -> demo.Ash_examples.Demo.source
    | None -> failwith "missing packaged traced-Fibonacci source"
  in
  let measured =
    Metrics.measure ~depth:1 ~file:"examples/traced_fibonacci.ash"
      ~name:"examples/traced_fibonacci.ash" (Metrics.Surface source)
  in
  let residual =
    match measured.Metrics.residual with
    | Ok residual -> residual
    | Error error -> failwith ("traced Fibonacci did not specialize: " ^ Error.to_string error)
  in
  let tower = measured.Metrics.tower.Metrics.run in
  let trace = output_bytes tower.Metrics.output in
  require (Metrics.agreement tower.Metrics.outcome residual.Metrics.run.Metrics.outcome = Metrics.Agrees)
    "tower and residual answers differ";
  require
    (List.equal Io.event_equal tower.Metrics.output residual.Metrics.run.Metrics.output)
    "tower and residual events differ";
  require (String.equal trace (output_bytes residual.Metrics.run.Metrics.output))
    "tower and residual output bytes differ";
  require (List.length tower.Metrics.output = 59) "the expected 59 trace writes changed";
  require (measured.Metrics.specialization.Metrics.output = [])
    "specialization performed program output";
  let residue = residual.Metrics.residue in
  require
    (Residue.interpreter_residue residue ~own:"examples/traced_fibonacci.ash" = 0
    && residue.Residue.eval_cell_dereferences = 0
    && residue.Residue.evaluator_calls = 0
    && residue.Residue.dispatch_sites = 0
    && residue.Residue.named_var_lookups = 0
    && residue.Residue.reflection_boundaries = [])
    "interpreter residue survived";
  require (print_sites measured.Metrics.globals residual.Metrics.term > 0)
    "trace writes were not inlined at former eval sites";
  require (has_traced_recursion measured.Metrics.globals residual.Metrics.term)
    "residual does not retain recursive Fibonacci with inlined trace calls";
  let printed = Core_printer.to_string residual.Metrics.term in
  let reread =
    Core_reader.read ~scope:(Core_printer.free_scope residual.Metrics.term) printed
  in
  require (Alpha.equal reread residual.Metrics.term)
    "printed residual Core does not round-trip";
  print_string (Report.to_string ~show_residual:true measured)
