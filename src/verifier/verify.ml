open Graph
open Cil
open Global
open InterCfg
open BasicDom
open Vocab
open Frontend
open IntraCfg
open ItvDom
open ItvSem
open ArrayBlk
open AlarmExp 
open Report 

module Analysis = SparseAnalysis.Make(ItvSem)
module Table = Analysis.Table
module Spec = Analysis.Spec
module AccessAnalysis = AccessAnalysis.Make (AccessSem.Make (ItvSem))
module DUGraph = Dug.Make (ItvSem.Dom)
module SsaDug = SsaDug.Make (DUGraph) (AccessAnalysis)

exception ConversionFailure

(* formulas *)
type ae = Var of string | Num of int | Mul of ae * ae | Add of ae * ae | Sub of ae * ae | ArrSize of ae | SizeOfE of ae
type formula = 
  | True | False | Not of formula | Eq of ae * ae | Lt of ae * ae | Le of ae * ae
  | And of formula * formula | Or of formula * formula

let rec varsof : formula -> string BatSet.t
= fun f -> 
  match f with
  | True | False -> BatSet.empty
  | Not f -> varsof f
  | Lt (e1,e2) | Le (e1,e2) | Eq (e1,e2) -> BatSet.union (varsof_e e1) (varsof_e e2)
  | And (f1,f2) | Or (f1,f2) -> BatSet.union (varsof f1) (varsof f2)

and varsof_e : ae -> string BatSet.t
= fun e ->
  match e with 
  | Var x -> BatSet.singleton x
  | Num _ -> BatSet.empty
  | Mul (e1,e2) | Add (e1,e2) | Sub (e1,e2) -> BatSet.union (varsof_e e1) (varsof_e e2)
  | ArrSize e | SizeOfE e -> varsof_e e

let rec string_of_ae e = 
  match e with
  | Var x -> x | Num n -> string_of_int n | ArrSize e -> ("arrsize(" ^ string_of_ae e ^ ")")
  | SizeOfE e -> "SizeOfE(" ^ string_of_ae e ^ ")"
  | Mul (e1,e2) -> ("(" ^ string_of_ae e1 ^ " * " ^ string_of_ae e2 ^ ")")
  | Add (e1,e2) -> ("(" ^ string_of_ae e1 ^ " + " ^ string_of_ae e2 ^ ")")
  | Sub (e1,e2) -> ("(" ^ string_of_ae e1 ^ " - " ^ string_of_ae e2 ^ ")")

let rec string_of_formula f =
  match f with
  | True -> "true" | False -> "false" | Not f -> ("not (" ^ string_of_formula f ^")")
  | Eq (e1, e2)  -> string_of_ae e1 ^ " = " ^ string_of_ae e2 
  | Lt (e1, e2)  -> string_of_ae e1 ^ " < " ^ string_of_ae e2
  | And (f1, f2) -> string_of_formula f1 ^ " ^ " ^ string_of_formula f2
  | Or (f1, f2)  -> "(" ^ string_of_formula f1 ^ " v " ^ string_of_formula f2 ^ ")"

let slice_dug : DUGraph.t -> Report.query -> DUGraph.t
= fun dug query ->
  let same_pid node = (InterCfg.Node.get_pid node = InterCfg.Node.get_pid query.node) in
  let reachable = 
    let add_preds nodes =
      BatSet.fold (fun node -> 
        let preds = List.filter same_pid (DUGraph.pred node dug) in
          list_fold BatSet.add preds
      ) nodes nodes in
      fix add_preds (BatSet.singleton query.node) in
    DUGraph.project dug reachable


(************************************************)
(* data-flow analysis for constraint generation *)
(************************************************)
module DFATable = struct
  type facts = formula BatSet.t
  type node = InterCfg.Node.t
  type t = (node, facts) BatMap.t
  let empty = BatMap.empty
  let find : node -> t -> facts 
  = fun n t -> try BatMap.find n t with _ -> BatSet.empty
  let add = BatMap.add
  let add_union : node -> facts -> t -> t 
  = fun node facts t ->
    let old = find node t in
      BatMap.add node (BatSet.union facts old) t
  let string_of_facts : facts -> string
  = fun facts -> 
    BatSet.fold (fun fact str -> str ^ " ^ " ^ string_of_formula fact) facts ""
  let print t = 
    BatMap.iter (fun node facts ->
      prerr_endline (InterCfg.Node.to_string node ^ " |-> " ^ string_of_facts facts)) t
end

let rec convert_exp : exp -> ae
= fun exp ->
  match exp with
  | Const (CInt64 (i64,_,_)) -> Num (Cil.i64_to_int i64)
  | Lval (Var vi, NoOffset)  -> Var vi.vname
  | Lval (Mem (Lval (Var vi, NoOffset)), Field (fi, NoOffset)) -> Var (vi.vname ^ "->" ^ fi.fname)
  | Lval (Mem (Lval (Var vi, NoOffset)), NoOffset) -> Var (vi.vname ^ "->this") (* FIXME *)
  | BinOp (PlusA, e1, e2, _) -> Add (convert_exp e1, convert_exp e2)
  | CastE (_,e) -> convert_exp e
  | SizeOfE e -> SizeOfE (convert_exp e)
  | _ -> raise ConversionFailure

let rec convert_lv : lval -> ae
= fun lv -> convert_exp (Lval lv)

let convert_allocsite_to_size allocsite = Var (Allocsite.to_string allocsite ^ ".size")

let deref2vc : Report.query -> exp * exp -> Mem.t -> formula
= fun query (e1,e2) mem -> 
  let arr = ArrSize (convert_exp e1) in
  let idx = convert_exp e2 in
    Lt (idx, arr)
 
let query2vc : Report.query -> ItvAnalysis.Table.t -> formula
= fun query inputof -> 
  let mem = Table.find query.node inputof in
    match query.exp with
    | ArrayExp (lv, e, _) -> deref2vc query (Lval lv, e) mem
    | DerefExp (BinOp (PlusPI,e1,e2,_), _) -> deref2vc query (e1,e2) mem
    | _ -> True


(* genset for assignment *)
let gen_set : Global.t -> Cil.lval * Cil.exp -> DFATable.facts
= fun global (lv,exp) -> 
  try BatSet.singleton (Eq (convert_lv lv, convert_exp exp))
  with ConversionFailure -> BatSet.empty

(* genset for external call *)
let gen_ext : Global.t -> Cil.lval -> DFATable.facts
= fun global lv -> BatSet.empty

(* genset for alloc *)
let gen_alloc : Global.t -> Cil.lval * IntraCfg.Cmd.alloc -> DFATable.facts
= fun global (lv,alloc) ->
  match lv, alloc with
  | (Cil.Var vi, NoOffset), Array e -> BatSet.singleton (Eq (ArrSize (Var vi.vname), convert_exp e))
  | _ -> BatSet.empty

(* genset for assume *)
let gen_assume : Global.t -> Cil.exp -> DFATable.facts
= fun global exp -> 
  let rec helper exp = 
    match exp with
    | UnOp (Cil.LNot, exp, _) -> BatSet.map (fun fact -> Not fact) (helper exp)
    | BinOp (Cil.Lt, e1, e2, _) -> BatSet.singleton (Lt (convert_exp  e1, convert_exp e2))
    | _ -> BatSet.empty in
    helper exp 

(* genset for call *)
let gen_call : Global.t -> (Cil.lval option * Cil.exp * Cil.exp list) -> DFATable.facts
= fun global (lvo, func, el) ->
  match lvo, func, el with
    (* handling phi-function *)
  | Some (Var vi, NoOffset), Lval (Var f, NoOffset), (Lval (Var a1, NoOffset))::(Lval (Var a2, NoOffset))::tl when f.vname = "phi" -> 
    BatSet.singleton (Or (Eq (Var vi.vname, Var a1.vname), Eq (Var vi.vname, Var a2.vname)))
  | _ -> BatSet.empty

let gen_node : Global.t -> InterCfg.Node.t -> DFATable.facts
= fun global node -> 
  match InterCfg.cmdof global.icfg node with
  | Cset (lv, exp, _) -> gen_set global (lv,exp) 
  | Cexternal (lv, _) -> gen_ext global lv
  | Calloc (lv,alloc,_,_) -> gen_alloc global (lv,alloc)
  | Cassume (exp,_) -> gen_assume global exp
  | Cskip -> BatSet.empty
  | Ccall (lv, f, el, _) -> gen_call global (lv, f, el)
  | _ -> BatSet.empty

let dfa_gen : Global.t -> InterCfg.Node.t -> DFATable.facts
= fun global node -> gen_node global node

(* TODO: call SMT solver *)
let no_contradiction : DFATable.facts -> bool
= fun facts -> 
  BatSet.for_all (fun fact -> BatSet.for_all (fun fact' -> fact <> Not fact') facts) facts

let dfa_kill : Global.t -> InterCfg.Node.t -> DFATable.facts -> DFATable.facts
= fun global node input_facts -> 
  let gen = gen_node global node in
  let facts = BatSet.filter (fun fact -> no_contradiction (BatSet.add fact gen)) input_facts in
  let facts = BatSet.filter (fun fact -> no_contradiction (BatSet.singleton fact)) facts in
    facts

let get_input : InterCfg.Node.t -> DUGraph.t -> DFATable.t -> DFATable.facts
= fun node dug table ->
  list_fold (fun p -> BatSet.union (DFATable.find p table)) 
    (DUGraph.pred node dug) BatSet.empty
 
let perform_dfa : Global.t -> DUGraph.t -> DFATable.t
= fun global dug -> 
  let nodes = DUGraph.nodesof dug in
  let table0 = BatSet.fold (fun n -> DFATable.add n BatSet.empty) nodes DFATable.empty in
  let workset = DUGraph.nodesof dug in
  let dfa_transfer node input = dfa_kill global node (BatSet.union input (dfa_gen global node)) in
  let rec iterate workset table = 
    if BatSet.is_empty workset then table
    else 
      let node = BatSet.choose workset in
    (* let _ = prerr_endline ("dfa: "^InterCfg.Node.to_string node) in *)
      let workset = BatSet.remove node workset in
      let input = get_input node dug table in
      let new_output = dfa_transfer node input in
    (* let _ = prerr_endline (DFATable.string_of_facts input) in *)
    (* let _ = prerr_endline (DFATable.string_of_facts new_output) in *)
      let old_output = DFATable.find node table in
        if BatSet.subset new_output old_output then iterate workset table
        else iterate (BatSet.union (list2set (DUGraph.succ node dug)) workset) 
                     (DFATable.add_union node new_output table) in
    iterate workset table0

let generate_vc : Report.query -> Global.t -> ItvAnalysis.Table.t * ItvAnalysis.Table.t -> DUGraph.t -> formula
= fun query global (inputof, outputof) dug -> 
  let vc_query = query2vc query inputof in
  let table = perform_dfa global dug in
  let facts = get_input query.node dug table in
  let vc = BatSet.fold (fun fact formula -> And (formula, fact)) facts vc_query in
  prerr_endline (string_of_formula vc);
    vc

let solve_vc : formula -> bool
= fun formula -> true (* TODO *)

let verify : Global.t -> DUGraph.t -> ItvAnalysis.Table.t -> ItvAnalysis.Table.t -> Report.query -> bool
= fun global dug inputof outputof query -> 
  prerr_endline ("** verifying " ^ Report.string_of_query query);
  let dug_sliced = slice_dug dug query in
  let formula  = generate_vc query global (inputof, outputof) dug_sliced in
  let verified = solve_vc formula in
  (* print_string (DUGraph.to_dot dug_sliced); *)
    verified

let perform : Global.t * ItvAnalysis.Table.t * ItvAnalysis.Table.t * Report.query list -> 
              Global.t * ItvAnalysis.Table.t * ItvAnalysis.Table.t * Report.query list
= fun (global, inputof, outputof, queries) -> 
  let spec = ItvAnalysis.get_spec global in
  let access = AccessAnalysis.perform global spec.Spec.locset (ItvSem.run Strong spec) spec.Spec.premem in
  let dug = SsaDug.make (global, access, spec.Spec.locset_fs) in
  let queries_unproven = Report.get queries Report.UnProven in
  let queries_unproven = List.filter (fun q -> not (verify global dug inputof outputof q)) queries_unproven in
    (global, inputof, outputof, queries_unproven)
