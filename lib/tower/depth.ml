open Ash_core
open Ash_runtime

let by = "tower/depth"
let span = Span.generated ~by ~from:Span.unknown

(* The interpreter interposed at one level: [fn(e, r, k) -> base(e, r, k)].

   It is an Ash closure, not a host function, and that is the entire point. The
   level below's [eval] cell now holds a term, so every step that level takes is
   a term the level above must evaluate — which is what makes depth cost
   something and what the collapser will later have to erase. A host function in
   the cell would run natively and depth would be a number with no referent.

   Semantically it is the identity: it forwards all three arguments to the
   evaluator that was in the cell and adds nothing. Transparency is the claim
   that this is observationally true however many times it is stacked. *)
let interpreter ~base =
  let base_name = Ident.fresh "base" in
  let e = Ident.fresh "e" in
  let r = Ident.fresh "r" in
  let k = Ident.fresh "k" in
  let body =
    Core.app ~span
      ~func:(Core.var ~span base_name)
      ~args:[ Core.var ~span e; Core.var ~span r; Core.var ~span k ]
  in
  Value.Closure
    {
      Value.clo_lambda = Core.lambda ~params:[ e; r; k ] ~body;
      clo_env = Env.extend [ (base_name, base) ] Value.empty_env;
      clo_name = Some (Ident.fresh "interpreter");
    }

(* One level of interpretation, installed the way a program installs one: read
   the cell, wrap what is there, write it back. Reading first is what makes
   [interpose] stack rather than replace — at depth 3 the level-0 cell holds an
   interpreter whose [base] is the previous one. *)
let interpose tower ~level =
  let lower =
    match Tower.find_level tower level with
    | Some lower -> lower
    | None -> invalid_arg "Depth.interpose: the level to interpret is not materialized"
  in
  (* The interposed term is evaluated by the level above, so it has to exist
     before the first step reaches it. *)
  ignore (Tower.materialize_above tower ~level);
  let cell = Machine.meta_eval_cell (Level.machine lower) in
  match Value.cell_contents cell with
  | Some base -> Value.fill_cell cell (interpreter ~base)
  | None ->
      (* [Machine.meta_eval_cell] returns a filled cell. *)
      invalid_arg "Depth.interpose: the level's evaluator cell is empty"

let materialize tower ~depth =
  if depth < 0 then invalid_arg "Depth.materialize: depth must be non-negative";
  for level = 0 to depth - 1 do
    interpose tower ~level
  done

let run tower ~depth term =
  materialize tower ~depth;
  Tower.run tower term
