open Options
open Smtlib_error
open Smtlib_syntax
open Smtlib_typed_env

(******************************************************************************)
let inst_and_unify (env,locals) m a b pos =
  let m, a = Smtlib_ty.inst locals m a in
  Smtlib_ty.unify a b pos

let find_par_ty (env,locals) symb pars args =
  try
    let res = SMap.find symb.c locals in
    symb.is_quantif <- true;
    res
  with Not_found -> try
      find_fun (env,locals) symb pars args
    with Not_found ->
      error (Typing_error ("Undefined fun : " ^ symb.c)) symb.p

let check_if_dummy t l =
  if Smtlib_ty.is_dummy t.ty then
    t :: l
  else
    l

let check_if_escaped l =
  List.iter (fun d ->
      if Smtlib_ty.is_dummy d.ty then begin
        error (Typing_error ("Escaped type variables")) d.p;
      end;
    ) l

let type_cst c pos=
  match c with
  | Const_Dec (s) -> Smtlib_ty.new_type Smtlib_ty.TReal
  | Const_Num (s) ->
    Smtlib_ty.new_type
      (if get_is_real () then Smtlib_ty.TReal else Smtlib_ty.TInt)
  | Const_Str (s) -> Smtlib_ty.new_type Smtlib_ty.TString
  | Const_Hex (s) ->
    Smtlib_ty.new_type
      (if get_is_fp () then Smtlib_ty.TBitVec(0)
       else if get_is_real () then Smtlib_ty.TReal
       else Smtlib_ty.TInt)
  | Const_Bin (s) ->
    Smtlib_ty.new_type
      (if get_is_fp () then Smtlib_ty.TBitVec(0)
       else if get_is_real () then Smtlib_ty.TReal
       else Smtlib_ty.TInt)

let type_qualidentifier (env,locals) q pars =
  match q.c with
  | QualIdentifierId (id) ->
    let symb,idl = get_identifier id in
    let ty = find_par_ty (env,locals) symb pars idl in
    inst_and_unify (env,locals) Smtlib_ty.IMap.empty ty q.ty q.p;
    ty
  | QualIdentifierAs (id, sort) ->
    let symb,idl = get_identifier id in
    let ty = find_par_ty (env,locals) symb pars idl in
    let ty_sort = find_sort (env,locals) sort in
    inst_and_unify (env,locals) Smtlib_ty.IMap.empty ty ty_sort symb.p;
    Smtlib_ty.unify sort.ty ty_sort sort.p;
    Smtlib_ty.unify q.ty ty q.p;
    ty

let type_pattern (env,locals) ty (symb, pars) =
  let locals,pars = List.fold_left (fun (locals,pars) par ->
      let ty = (Smtlib_ty.new_type (Smtlib_ty.TVar(par.c))) in
      SMap.add par.c ty locals, ty :: pars
    ) (locals,[]) (List.rev pars) in
  let ty = Smtlib_ty.new_type (Smtlib_ty.TFun (pars,ty)) in
  let cst_def = find_constr env symb in
  inst_and_unify (env,locals) Smtlib_ty.IMap.empty ty cst_def symb.p;
  locals

let rec type_match_case (env,locals,dums) ty (pattern,term) =
  let pars = type_pattern (env,locals) ty pattern in
  (* shadowing *)
  let locals = SMap.union (fun k v1 v2 -> Some v2) locals pars in
  type_term (env,locals,dums) term

and type_key_term (env,locals,dums) key_term =
  match key_term.c with
  | Pattern(term_list) ->
    List.fold_left (fun dums t ->
        let _,dums = type_term (env,locals,dums) t in
        dums
      ) [] term_list
  | Named(symb) ->
    if Options.verbose () > 0 then
      Printf.eprintf "[Warning] (! :named not yet supported)\n%!";
    dums

and type_term (env,locals,dums) t =
  match t.c with
  | TermSpecConst (cst) ->
    Smtlib_ty.unify t.ty (type_cst cst t.p) t.p;
    t.ty, dums

  | TermQualIdentifier (qualid) ->
    let ty_q = type_qualidentifier (env,locals) qualid [] in
    Smtlib_ty.unify t.ty ty_q t.p;
    t.ty, check_if_dummy t dums

  | TermQualIdTerm (qualid,term_list) ->
    let pars,dums =
      List.fold_left (fun (pars,dums) t ->
          let ty, dums = type_term (env,locals,dums) t in
          ty :: pars, dums
        ) ([],dums) term_list in
    let pars = List.rev pars in
    let q = (type_qualidentifier (env,locals) qualid pars) in
    Smtlib_ty.unify t.ty q t.p;
    t.ty, check_if_dummy t dums

  | TermLetTerm (varbinding_list,term) ->
    let locals,dums = List.fold_left (fun (locals,dums) (symb,term) ->
        let ty, dums = type_term (env,locals,dums) term in
        SMap.add symb.c ty locals, dums
      ) (locals,dums) varbinding_list in
    let ty,dums = type_term (env,locals,dums) term in
    Smtlib_ty.unify t.ty ty t.p;
    t.ty, dums

  | TermForAllTerm (sorted_var_list, term) ->
    let locals = List.fold_left (fun locals (symb,sort) ->
        SMap.add symb.c (find_sort (env,locals) sort) locals
      ) locals sorted_var_list in
    let ty,dums = type_term (env,locals,dums) term in
    Smtlib_ty.unify t.ty ty t.p;
    t.ty, dums

  | TermExistsTerm (sorted_var_list, term) ->
    let locals = List.fold_left (fun locals (symb,sort) ->
        SMap.add symb.c (find_sort (env,locals) sort) locals
      ) locals sorted_var_list in
    let ty,dums = type_term (env,locals,dums) term in
    Smtlib_ty.unify t.ty ty t.p;
    t.ty, dums

  | TermExclimationPt (term, key_term_list) ->
    let dums = List.fold_left (fun dums kt ->
        type_key_term (env,locals,dums) kt
      ) dums key_term_list in
    let ty,dums = type_term (env,locals,dums) term in
    ty, dums

  | TermMatch (term, match_case_list) ->
    let ty,dums = type_term (env,locals,dums) term in
    (* check if term is datatype *)
    Smtlib_ty.unify (Smtlib_ty.new_type (Smtlib_ty.TDatatype("",[]))) ty term.p;
    let res,dums = List.fold_left (fun (res,dums) mc ->
        let ty_mc, dums = type_match_case (env,locals,dums) ty mc in
        Smtlib_ty.unify res ty_mc term.p;
        res,dums
      ) ((Smtlib_ty.new_type (Smtlib_ty.TVar "A")),dums) match_case_list in
    res,dums

let get_term (env,locals) pars term =
  let locals = Smtlib_typed_env.extract_pars locals pars in
  let ty,dums = type_term (env,locals,[]) term in
  check_if_escaped dums;
  ty

let get_sorted_locals (env,locals) params =
  List.fold_left (fun locals (symb,sort) ->
      SMap.add symb.c (Smtlib_typed_env.find_sort (env,locals) sort) locals
    ) locals (List.rev params)

let get_fun_def_locals (env,locals) (name,pars,params,return) =
  let locals = Smtlib_typed_env.extract_pars locals pars in
  let locals = get_sorted_locals (env,locals) params in
  let ret = (Smtlib_typed_env.find_sort (env,locals) return) in
  let params = List.map (fun (_,sort) -> sort) params in
  locals, ret, (name,params,return)

(******************************************************************************)
(************************************ Commands ********************************)
let type_command (env,locals) c =
  match c.c with
  | Cmd_Assert(dec) | Cmd_CheckEntailment(dec) ->
    let pars,t = dec in
    Smtlib_ty.unify
      (Smtlib_ty.new_type Smtlib_ty.TBool) (get_term (env,locals) pars t) t.p;
    env
  | Cmd_CheckSat -> env
  | Cmd_CheckSatAssum prop_lit ->
    Options.check_command "check-sat-assuming";
    env
  | Cmd_DeclareConst (symbol,(pars,sort)) ->
    Smtlib_typed_env.mk_const (env,locals) (symbol,pars,sort)
  | Cmd_DeclareDataType (symbol,(pars,datatype_dec)) ->
    Smtlib_typed_env.mk_datatype (env,locals) symbol pars datatype_dec
  | Cmd_DeclareDataTypes (sort_dec_list, datatype_dec_list) ->
    Smtlib_typed_env.mk_datatypes (env,locals) sort_dec_list datatype_dec_list
  | Cmd_DeclareFun (name,fun_dec) ->
    Smtlib_typed_env.mk_fun_dec (env,locals) (name,fun_dec)
  | Cmd_DeclareSort (symbol,arit) ->
    Smtlib_typed_env.mk_sort_decl (env,locals) symbol arit false
  | Cmd_DefineFun (fun_def,term) ->
    let locals,ret,fun_dec = get_fun_def_locals (env,locals) fun_def in
    let ty,dums = type_term (env,locals,[]) term in
    check_if_escaped dums;
    let env = Smtlib_typed_env.mk_fun_def (env,locals) fun_dec in
    inst_and_unify (env,locals) Smtlib_ty.IMap.empty ret ty term.p;
    env
  | Cmd_DefineFunRec (fun_def,term) ->
    let locals,ret,fun_dec = get_fun_def_locals (env,locals) fun_def in
    let env = Smtlib_typed_env.mk_fun_def (env,locals) fun_dec in
    let ty,dums = type_term (env,locals,[]) term in
    check_if_escaped dums;
    inst_and_unify (env,locals) Smtlib_ty.IMap.empty ret ty term.p;
    env
  | Cmd_DefineFunsRec (fun_def_list, term_list) ->
    let env,locals_term_list =
      List.fold_left (fun (env,locals_term_list) fun_def ->
          let locals,ret,fun_dec = get_fun_def_locals (env,locals) fun_def in
          let env = Smtlib_typed_env.mk_fun_def (env,locals) fun_dec in
          env, (locals,ret) :: locals_term_list
        ) (env,[]) (List.rev fun_def_list)
    in
    List.iter2 (fun (locals,ret) term ->
        let ty,dums = type_term (env,locals,[]) term in
        check_if_escaped dums;
        inst_and_unify (env,locals) Smtlib_ty.IMap.empty ret ty term.p;
      ) locals_term_list term_list;
    env
  | Cmd_DefineSort (symbol, symbol_list, sort) ->
    Smtlib_typed_env.mk_sort_def (env,locals) symbol symbol_list sort
  | Cmd_Echo (attribute_value) -> Options.check_command "echo"; env
  | Cmd_GetAssert -> Options.check_command "get-assertions"; env
  | Cmd_GetProof -> Options.check_command "get-proof"; env
  | Cmd_GetUnsatCore -> Options.check_command "get-unsat-core"; env
  | Cmd_GetValue (term_list) -> Options.check_command "get-value"; env
  | Cmd_GetAssign -> Options.check_command "get-assignement"; env
  | Cmd_GetOption (keyword) -> Options.check_command "get-option"; env
  | Cmd_GetInfo (key_info) -> Options.check_command "get-info"; env
  | Cmd_GetModel -> Options.check_command "get-model"; env
  | Cmd_GetUnsatAssumptions -> Options.check_command "get-unsat-core"; env
  | Cmd_Reset -> Options.check_command "reset"; env
  | Cmd_ResetAssert -> Options.check_command "reset-assertions"; env
  | Cmd_SetLogic(symb) -> Smtlib_typed_logic.set_logic env symb
  | Cmd_SetOption (option) -> Options.check_command "set-option"; env
  | Cmd_SetInfo (attribute) -> Options.check_command "set-info"; env
  | Cmd_Push _ | Cmd_Pop _ ->
    error (Incremental_error ("incremental command not suported")) c.p
  | Cmd_Exit -> env

let typing parsed_ast =
  let env =
    if not (get_logic ()) then
      try
        let c = List.hd parsed_ast in
        Smtlib_typed_logic.set_logic
          (Smtlib_typed_env.empty ()) {c with c="ALL"}
      with _ -> assert false
    else Smtlib_typed_env.empty ()
  in
  let env =
    List.fold_left (fun env c ->
        let env = type_command (env,SMap.empty)  c in
        if Options.verbose () > 0 then Smtlib_printer.print_command c;
        env
      ) env parsed_ast
  in if Options.verbose () > 1 then begin
    Smtlib_printer.print_env env;
  end
