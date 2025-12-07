(** Rake 0.2.0 Type Checker

    Infers and validates types for the tine/through/sweep model.

    Key rules:
    - In rake/crunch functions, untyped params default to float rack
    - Scalars (<x>) broadcast to rack when combined with rack values
    - Tine predicates produce mask (vector<8xi1>)
    - Through blocks execute under mask, result has type of final expr
    - Sweep arms must all have the same type
*)

open Ast
open Types

(** Type environment *)
type env = {
  types: (ident, t) Hashtbl.t;      (** Type definitions (stack, single) *)
  vars: (ident, t) Hashtbl.t;       (** Variable bindings *)
  tines: (ident, unit) Hashtbl.t;   (** Declared tines (for validation) *)
  funcs: (ident, t list * t) Hashtbl.t;  (** Function signatures *)
  locations: (ident, unit) Hashtbl.t;    (** Mutable locations (from :=) *)
}

let create_env () = {
  types = Hashtbl.create 32;
  vars = Hashtbl.create 64;
  tines = Hashtbl.create 16;
  funcs = Hashtbl.create 32;
  locations = Hashtbl.create 32;
}

let copy_env env = {
  types = Hashtbl.copy env.types;
  vars = Hashtbl.copy env.vars;
  tines = Hashtbl.copy env.tines;
  funcs = Hashtbl.copy env.funcs;
  locations = Hashtbl.copy env.locations;
}

(** Error handling *)
exception TypeError of string * loc

let type_error msg loc =
  raise (TypeError (msg, loc))

let type_errorf loc fmt =
  Printf.ksprintf (fun msg -> type_error msg loc) fmt

(** Convert AST type to runtime type *)
let rec typ_to_t env (ty: typ) : t =
  match ty.v with
  | TRack p -> Rack (of_prim p)
  | TCompoundRack c -> CompoundRack (of_compound c)
  | TScalar p -> Scalar (of_prim p)
  | TCompoundScalar c -> CompoundScalar (of_compound c)
  | TStack name -> (
      match Hashtbl.find_opt env.types name with
      | Some t -> t
      | None -> type_errorf ty.loc "Unknown stack type: %s" name)
  | TPack name -> (
      match Hashtbl.find_opt env.types name with
      | Some (Stack (n, fields)) -> Pack (n, fields)  (* Convert stack to pack *)
      | Some t -> type_errorf ty.loc "Expected stack type for pack, got %s" (show_concise t)
      | None -> type_errorf ty.loc "Unknown type for pack: %s" name)
  | TSingle name -> (
      match Hashtbl.find_opt env.types name with
      | Some t -> t
      | None -> type_errorf ty.loc "Unknown single type: %s" name)
  | TMask -> Mask
  | TFun (args, ret) ->
      Fun (List.map (typ_to_t env) args, typ_to_t env ret)
  | TTuple ts -> Tuple (List.map (typ_to_t env) ts)
  | TUnit -> Unit

(** Register type definitions *)
let register_type_def env (def: def) =
  match def.v with
  | DStack (name, fields) ->
      let field_types = List.map (fun f ->
        (f.field_name, typ_to_t env f.field_type)
      ) fields in
      Hashtbl.add env.types name (Stack (name, field_types))
  | DSingle (name, fields) ->
      let field_types = List.map (fun f ->
        (f.field_name, typ_to_t env f.field_type)
      ) fields in
      Hashtbl.add env.types name (Single (name, field_types))
  | DType (name, ty) ->
      Hashtbl.add env.types name (typ_to_t env ty)
  | _ -> ()

(** Capitalize first letter of a string (for type name lookup) *)
let capitalize_first s =
  if String.length s = 0 then s
  else String.mapi (fun i c -> if i = 0 then Char.uppercase_ascii c else c) s

(** Look up type by name, trying both as-is and capitalized *)
let find_type env name =
  match Hashtbl.find_opt env.types name with
  | Some t -> Some t
  | None -> Hashtbl.find_opt env.types (capitalize_first name)

(** Expand a PSpread param into individual typed params.
    Returns list of (name, type) pairs. *)
let expand_spread env type_name names loc =
  match find_type env type_name with
  | Some (Stack (_, fields)) | Some (Single (_, fields)) ->
      if List.length names <> List.length fields then
        type_errorf loc "Type %s has %d fields, but %d names provided"
          type_name (List.length fields) (List.length names);
      List.map2 (fun name (_, field_type) -> (name, field_type)) names fields
  | Some _ ->
      type_errorf loc "Type %s is not a stack or single (cannot spread)" type_name
  | None ->
      type_errorf loc "Unknown type for spreading: %s" type_name

(** Get types from a param, expanding spreads *)
let param_types_of env p loc =
  match p with
  | PRack (_, Some ty) -> [typ_to_t env ty]
  | PRack (_, None) -> [Rack SFloat]
  | PScalar (_, Some ty) -> [typ_to_t env ty]
  | PScalar (_, None) -> [Scalar SFloat]
  | PSpread (names, type_name) ->
      let expanded = expand_spread env type_name names loc in
      List.map snd expanded

(** Register function signatures *)
let register_func_def env (def: def) =
  match def.v with
  | DCrunch (name, params, result, _) ->
      let param_types = List.concat_map (fun p ->
        param_types_of env p def.loc
      ) params in
      let ret_type = match result.result_type with
        | Some ty -> typ_to_t env ty
        | None -> Rack SFloat  (* default *)
      in
      Hashtbl.add env.funcs name (param_types, ret_type)
  | DRake (name, params, result, _, _, _, _) ->
      let param_types = List.concat_map (fun p ->
        match p with
        | PRack (_pname, Some ty) -> [typ_to_t env ty]
        | PRack (pname, None) ->
            (* Look up if parameter name matches a type (e.g., ray -> Ray) *)
            (match find_type env pname with
             | Some t -> [t]
             | None -> [Rack SFloat])
        | PScalar (_pname, Some ty) -> [typ_to_t env ty]
        | PScalar (pname, None) ->
            (match find_type env pname with
             | Some (Single _ as t) -> [t]
             | _ -> [Scalar SFloat])
        | PSpread (names, type_name) ->
            let expanded = expand_spread env type_name names def.loc in
            List.map snd expanded
      ) params in
      let ret_type = match result.result_type with
        | Some ty -> typ_to_t env ty
        | None ->
            (* Look up result name as type (e.g., hit -> Hit) *)
            (match find_type env result.result_name with
             | Some t -> t
             | None -> Rack SFloat)
      in
      Hashtbl.add env.funcs name (param_types, ret_type)
  | DRun (name, params, result, _) ->
      let param_types = List.concat_map (fun p ->
        match p with
        | PRack (_, Some ty) -> [typ_to_t env ty]
        | PRack (_, None) -> [Rack SFloat]
        | PScalar (_, Some ty) -> [typ_to_t env ty]
        | PScalar (_, None) -> [Scalar SFloat]
        | PSpread (names, type_name) ->
            let expanded = expand_spread env type_name names def.loc in
            List.map snd expanded
      ) params in
      let ret_type = match result.result_type with
        | Some ty -> typ_to_t env ty
        | None -> Unit
      in
      Hashtbl.add env.funcs name (param_types, ret_type)
  | _ -> ()

(** Add built-in functions *)
let add_builtins env =
  (* Math functions: rack -> rack *)
  List.iter (fun name ->
    Hashtbl.add env.funcs name ([Rack SFloat], Rack SFloat)
  ) ["sqrt"; "sin"; "cos"; "tan"; "exp"; "log"; "abs"; "floor"; "ceil"];
  (* Math functions: rack, rack -> rack *)
  List.iter (fun name ->
    Hashtbl.add env.funcs name ([Rack SFloat; Rack SFloat], Rack SFloat)
  ) ["min"; "max"; "pow"; "atan2"]

(** Get field type from a struct type *)
let get_field_type t field loc =
  match t with
  | Stack (_, fields) | Single (_, fields) -> (
      match List.assoc_opt field fields with
      | Some ft -> ft
      | None -> type_errorf loc "Unknown field: %s" field)
  | _ -> type_errorf loc "Cannot access field of non-struct type"

(** Check if two types are compatible (with broadcast) *)
let compatible t1 t2 =
  match (t1, t2) with
  | Rack s1, Rack s2 -> s1 = s2
  | Rack s, Scalar s' | Scalar s', Rack s -> s = s'
  | Scalar s1, Scalar s2 -> s1 = s2
  | Mask, Mask -> true
  | Stack (n1, _), Stack (n2, _) -> n1 = n2
  | Single (n1, _), Single (n2, _) -> n1 = n2
  | _ -> t1 = t2

(** Infer expression type *)
let rec infer_expr env (expr: Ast.expr) : t =
  match expr.v with
  | EInt _ -> Rack SInt  (* integer literals are rack by default in vector context *)
  | EFloat _ -> Rack SFloat
  | EBool _ -> Mask

  | EVar name -> (
      match Hashtbl.find_opt env.vars name with
      | Some t -> t
      | None -> type_errorf expr.loc "Undefined variable: %s" name)

  | EScalarVar name -> (
      match Hashtbl.find_opt env.vars name with
      | Some t -> t
      | None -> type_errorf expr.loc "Undefined scalar variable: %s" name)

  | EBinop (l, op, r) ->
      let lt = infer_expr env l in
      let rt = infer_expr env r in
      infer_binop lt rt op expr.loc

  | EUnop (op, e) ->
      let t = infer_expr env e in
      infer_unop t op expr.loc

  | ECall (name, args) -> (
      match Hashtbl.find_opt env.funcs name with
      | Some (param_types, ret) ->
          let arg_types = List.map (infer_expr env) args in
          if List.length arg_types <> List.length param_types then
            type_errorf expr.loc "Function %s expects %d args, got %d"
              name (List.length param_types) (List.length arg_types);
          List.iter2 (fun expected actual ->
            if not (compatible expected actual) then
              type_errorf expr.loc "Argument type mismatch: expected %s, got %s"
                (show_concise expected) (show_concise actual)
          ) param_types arg_types;
          ret
      | None -> type_errorf expr.loc "Unknown function: %s" name)

  | ELet (binding, body) ->
      let t = infer_expr env binding.bind_expr in
      Hashtbl.add env.vars binding.bind_name t;
      infer_expr env body

  | EField (e, field) ->
      let t = infer_expr env e in
      get_field_type t field expr.loc

  | ERecord (name, _inits) -> (
      match Hashtbl.find_opt env.types name with
      | Some (Stack _ as t) -> t
      | Some (Single _ as t) -> t
      | _ -> type_errorf expr.loc "Unknown record type: %s" name)

  | EWith (e, _) -> infer_expr env e

  | ELaneIndex -> Rack SInt
  | ELanes -> Scalar SInt

  | EExtract (e, _) ->
      let t = infer_expr env e in
      element_type t

  | EInsert (e, _, _) -> infer_expr env e

  | EReduce (_, e) ->
      let t = infer_expr env e in
      element_type t

  | EScan (_, e) -> infer_expr env e

  | EShuffle (e, _) -> infer_expr env e
  | EShift (e, _, _) -> infer_expr env e
  | ERotate (e, _, _) -> infer_expr env e

  | EGather (base, _indices) ->
      (* Gather returns rack of base's element type *)
      let base_t = infer_expr env base in
      (match base_t with
       | Rack s -> Rack s
       | Scalar s -> Rack s  (* gathering scalars produces rack *)
       | _ -> Rack SFloat)   (* default for unknown base types *)
  | EScatter (_, _, _) -> Unit
  | ECompress (e, _) -> infer_expr env e
  | EExpand (e, _, _) -> infer_expr env e

  | ETines (_, _, sweep) ->
      (* Type is determined by sweep result *)
      if List.length sweep.sweep_arms > 0 then
        infer_expr env (List.hd sweep.sweep_arms).arm_value
      else
        type_errorf expr.loc "Tines expression requires at least one sweep arm"

  | EFma (a, _, _) -> infer_expr env a
  | EOuter (_, _) ->
      type_errorf expr.loc "Outer product not yet implemented"

  | ETuple es -> Tuple (List.map (infer_expr env) es)
  | EBroadcast e ->
      let t = infer_expr env e in
      broadcast t

  | EUnit -> Unit
  | ELambda (params, body) ->
      (* Infer parameter types and body type to form function type *)
      let env' = copy_env env in
      let param_types = List.concat_map (fun p ->
        match p with
        | PRack (pname, Some ty) ->
            let t = typ_to_t env' ty in
            Hashtbl.add env'.vars pname t;
            [t]
        | PRack (pname, None) ->
            Hashtbl.add env'.vars pname (Rack SFloat);
            [Rack SFloat]
        | PScalar (pname, Some ty) ->
            let t = typ_to_t env' ty in
            Hashtbl.add env'.vars pname t;
            [t]
        | PScalar (pname, None) ->
            Hashtbl.add env'.vars pname (Scalar SFloat);
            [Scalar SFloat]
        | PSpread (names, type_name) ->
            let expanded = expand_spread env' type_name names expr.loc in
            List.iter (fun (name, t) -> Hashtbl.add env'.vars name t) expanded;
            List.map snd expanded
      ) params in
      let body_type = infer_expr env' body in
      Fun (param_types, body_type)
  | EPipe (_l, r) -> infer_expr env r
  | EFusedPipe (l, r) ->
      (* Fused pipe: verify fusion is possible, then return right-hand type *)
      let _ = infer_expr env l in
      infer_expr env r

(** Infer binary operation result type *)
and infer_binop t1 t2 op _loc =
  match op with
  | Add | Sub | Mul | Div | Mod ->
      binop_result t1 t2
  | Lt | Le | Gt | Ge | Eq | Ne ->
      Mask  (* comparisons produce masks *)
  | And | Or ->
      Mask
  | Pipe ->
      t2  (* result is right-hand side *)
  | Shl | Shr | Rol | Ror ->
      t1
  | Interleave ->
      t1

(** Infer unary operation result type *)
and infer_unop t op _loc =
  match op with
  | Neg | FNeg -> t
  | Not -> Mask

(** Check if an expression is fusible (pure, no side effects) *)
let rec is_fusible env (expr: Ast.expr) : bool =
  match expr.v with
  | EInt _ | EFloat _ | EBool _ -> true
  | EVar _ | EScalarVar _ -> true
  | EBinop (l, _, r) -> is_fusible env l && is_fusible env r
  | EUnop (_, e) -> is_fusible env e
  | ECall (name, args) ->
      (* Only pure built-in functions are fusible *)
      let pure_funcs = ["sqrt"; "sin"; "cos"; "tan"; "exp"; "log"; "abs";
                        "floor"; "ceil"; "min"; "max"; "pow"; "atan2"] in
      List.mem name pure_funcs && List.for_all (is_fusible env) args
  | EField (e, _) -> is_fusible env e
  | EBroadcast e -> is_fusible env e
  | EReduce (_, e) -> is_fusible env e
  | EFma (a, b, c) -> is_fusible env a && is_fusible env b && is_fusible env c
  | ETuple es -> List.for_all (is_fusible env) es
  | ELet (binding, body) ->
      is_fusible env binding.bind_expr && is_fusible env body
  | ELaneIndex | ELanes -> true
  | EExtract (e, i) -> is_fusible env e && is_fusible env i
  | EScan (_, e) | EShuffle (e, _) | EShift (e, _, _) | ERotate (e, _, _) ->
      is_fusible env e
  | EPipe (l, r) | EFusedPipe (l, r) -> is_fusible env l && is_fusible env r
  | EUnit -> true
  (* Side-effecting or unknown expressions are not fusible *)
  | EScatter _ | EGather _ | ECompress _ | EExpand _ -> false
  | ERecord _ | EWith _ | ETines _ | ELambda _ | EInsert _ | EOuter _ -> false

(** Check a statement, return updated env *)
let rec check_stmt env (stmt: stmt) : env =
  match stmt.v with
  | SLet binding ->
      (* SSA: cannot rebind existing variables *)
      if Hashtbl.mem env.vars binding.bind_name then
        type_errorf stmt.loc "Cannot rebind '%s' (SSA violation, use := for mutable storage)"
          binding.bind_name;
      let t = infer_expr env binding.bind_expr in
      let declared_t = match binding.bind_type with
        | Some ty -> Some (typ_to_t env ty)
        | None -> None
      in
      let final_t = match declared_t with
        | Some dt when compatible dt t -> dt
        | Some dt -> type_errorf stmt.loc "Type mismatch: expected %s, got %s"
            (show_concise dt) (show_concise t)
        | None -> t
      in
      Hashtbl.add env.vars binding.bind_name final_t;
      env

  | SLocBind lb ->
      (* Location binding: creates mutable storage *)
      if Hashtbl.mem env.locations lb.loc_name then
        type_errorf stmt.loc "Location '%s' already exists (use <- to mutate)"
          lb.loc_name;
      let t = infer_expr env lb.loc_expr in
      let final_t = match lb.loc_type with
        | Some ty ->
            let dt = typ_to_t env ty in
            if compatible dt t then dt
            else type_errorf stmt.loc "Type mismatch: expected %s, got %s"
              (show_concise dt) (show_concise t)
        | None -> t
      in
      Hashtbl.add env.locations lb.loc_name ();
      Hashtbl.add env.vars lb.loc_name final_t;
      env

  | SAssign (name, e) ->
      (* Assignment: requires existing location *)
      if not (Hashtbl.mem env.locations name) then
        type_errorf stmt.loc "Cannot assign to '%s': not a location (use := to create)"
          name;
      let _ = infer_expr env e in
      env

  | SFused fb ->
      (* Fused binding: verify fusion is possible *)
      if not (is_fusible env fb.fused_expr) then
        type_errorf stmt.loc "Expression for '%s' cannot be fused (contains side effects or non-pure calls)"
          fb.fused_name;
      let t = infer_expr env fb.fused_expr in
      Hashtbl.add env.vars fb.fused_name t;
      env

  | SExpr e ->
      let _ = infer_expr env e in
      env
  | SOver over ->
      (* Check the count expression *)
      let _count_t = infer_expr env over.over_count in
      (* Look up pack type and derive stack type for chunk binding *)
      let pack_t = match Hashtbl.find_opt env.vars over.over_pack with
        | Some (Pack (name, fields)) -> Pack (name, fields)
        | Some t -> type_errorf stmt.loc "Expected pack type, got %s" (show_concise t)
        | None -> type_errorf stmt.loc "Undefined pack: %s" over.over_pack
      in
      (* The chunk binding gets the corresponding stack type *)
      let chunk_t = match pack_t with
        | Pack (name, fields) -> Stack (name, fields)
        | _ -> type_errorf stmt.loc "Expected pack type"
      in
      (* Add chunk to env and check body *)
      let body_env = { env with vars = Hashtbl.copy env.vars } in
      Hashtbl.add body_env.vars over.over_chunk chunk_t;
      List.iter (fun s -> ignore (check_stmt body_env s)) over.over_body;
      env

(** Check tine predicate *)
let rec check_predicate env (pred: predicate) : unit =
  match pred.v with
  | PExpr e ->
      let t = infer_expr env e in
      if t <> Mask then
        type_errorf pred.loc "Predicate must be mask type, got %s" (show_concise t)
  | PCmp (l, _, r) ->
      let _ = infer_expr env l in
      let _ = infer_expr env r in
      ()  (* comparisons always produce mask *)
  | PIs (l, r) | PIsNot (l, r) ->
      let _ = infer_expr env l in
      let _ = infer_expr env r in
      ()
  | PAnd (l, r) | POr (l, r) ->
      check_predicate env l;
      check_predicate env r
  | PNot p ->
      check_predicate env p
  | PTineRef name ->
      if not (Hashtbl.mem env.tines name) then
        type_errorf pred.loc "Reference to undefined tine: #%s" name

(** Check through block *)
let check_through env (th: through) : t =
  (* Use through_result's location as the block location *)
  let block_loc = th.through_result.loc in
  (* Check tine reference *)
  (match th.through_tine with
   | TRSingle name ->
       if not (Hashtbl.mem env.tines name) then
         type_errorf block_loc "Reference to undefined tine: #%s" name
   | TRComposed pred ->
       check_predicate env pred);
  (* Check body statements *)
  let env' = copy_env env in
  List.iter (fun s -> ignore (check_stmt env' s)) th.through_body;
  (* Infer result type *)
  let result_t = infer_expr env' th.through_result in
  Hashtbl.add env.vars th.through_binding result_t;
  result_t

(** Check sweep block *)
let check_sweep env (sw: sweep) expected_loc : t =
  (* Check for catch-all arm (arm with no tine reference) *)
  let has_catchall = List.exists (fun arm -> arm.arm_tine = None) sw.sweep_arms in
  if not has_catchall then
    Printf.eprintf "Warning at %s:%d: sweep has no catch-all (_) arm; lanes not matching any tine will have undefined values\n"
      expected_loc.file expected_loc.line;

  let arm_types = List.map (fun arm ->
    (match arm.arm_tine with
     | Some name ->
         if not (Hashtbl.mem env.tines name) then
           type_errorf expected_loc "Reference to undefined tine in sweep: #%s" name
     | None -> ());  (* catch-all *)
    infer_expr env arm.arm_value
  ) sw.sweep_arms in
  (* All arms should have compatible types *)
  match arm_types with
  | [] -> type_error "Sweep must have at least one arm" expected_loc
  | first :: rest ->
      List.iter (fun t ->
        if not (compatible first t) then
          type_errorf expected_loc "Sweep arm type mismatch: %s vs %s"
            (show_concise first) (show_concise t)
      ) rest;
      first

(** Check rake function definition *)
let check_rake env _name params result setup tines throughs sweep loc =
  let env' = copy_env env in

  (* Add parameters to environment (rake uses name-based inference) *)
  List.iter (fun p ->
    match p with
    | PRack (pname, Some ty) ->
        Hashtbl.add env'.vars pname (typ_to_t env' ty)
    | PRack (pname, None) ->
        (* Check if parameter name matches a type (e.g., ray -> Ray) *)
        (match find_type env' pname with
         | Some t -> Hashtbl.add env'.vars pname t
         | None -> Hashtbl.add env'.vars pname (Rack SFloat))
    | PScalar (pname, Some ty) ->
        Hashtbl.add env'.vars pname (typ_to_t env' ty)
    | PScalar (pname, None) ->
        (* Check if parameter name matches a single type (e.g., sphere -> Sphere) *)
        (match find_type env' pname with
         | Some (Single _ as t) -> Hashtbl.add env'.vars pname t
         | _ -> Hashtbl.add env'.vars pname (Scalar SFloat))
    | PSpread (names, type_name) ->
        (* Spread type fields to named parameters *)
        let expanded = expand_spread env' type_name names loc in
        List.iter (fun (name, t) ->
          Hashtbl.add env'.vars name t
        ) expanded
  ) params;

  (* Check setup statements *)
  List.iter (fun s -> ignore (check_stmt env' s)) setup;

  (* Register tines *)
  List.iter (fun tine ->
    Hashtbl.add env'.tines tine.tine_name ()
  ) tines;

  (* Check tine predicates *)
  List.iter (fun tine ->
    check_predicate env' tine.tine_pred
  ) tines;

  (* Check through blocks *)
  List.iter (fun th ->
    ignore (check_through env' th)
  ) throughs;

  (* Check sweep *)
  let sweep_t = check_sweep env' sweep loc in
  Hashtbl.add env'.vars sweep.sweep_binding sweep_t;

  (* Verify result type matches *)
  let expected_t = match result.result_type with
    | Some ty -> typ_to_t env ty
    | None ->
        (match Hashtbl.find_opt env.types result.result_name with
         | Some t -> t
         | None -> sweep_t)
  in
  if not (compatible expected_t sweep_t) then
    type_errorf loc "Return type mismatch: expected %s, got %s"
      (show_concise expected_t) (show_concise sweep_t)

(** Add params to environment, expanding spreads *)
let add_params_to_env env params loc =
  List.iter (fun p ->
    match p with
    | PRack (pname, Some ty) ->
        Hashtbl.add env.vars pname (typ_to_t env ty)
    | PRack (pname, None) ->
        Hashtbl.add env.vars pname (Rack SFloat)
    | PScalar (pname, Some ty) ->
        Hashtbl.add env.vars pname (typ_to_t env ty)
    | PScalar (pname, None) ->
        Hashtbl.add env.vars pname (Scalar SFloat)
    | PSpread (names, type_name) ->
        let expanded = expand_spread env type_name names loc in
        List.iter (fun (name, t) ->
          Hashtbl.add env.vars name t
        ) expanded
  ) params

(** Check crunch function definition *)
let check_crunch env _name params _result body loc =
  let env' = copy_env env in

  (* Add parameters, expanding any spreads *)
  add_params_to_env env' params loc;

  (* Check body *)
  List.iter (fun s -> ignore (check_stmt env' s)) body

(** Check a definition *)
let check_def env (def: def) =
  match def.v with
  | DStack _ | DSingle _ | DType _ ->
      ()  (* already registered *)
  | DCrunch (name, params, result, body) ->
      check_crunch env name params result body def.loc
  | DRake (name, params, result, setup, tines, throughs, sweep) ->
      check_rake env name params result setup tines throughs sweep def.loc
  | DRun (name, params, result, body) ->
      check_crunch env name params result body def.loc

(** Check a module *)
let check_module env (m: module_) =
  (* First pass: register all type definitions *)
  List.iter (register_type_def env) m.mod_defs;
  (* Second pass: register function signatures *)
  List.iter (register_func_def env) m.mod_defs;
  (* Third pass: check function bodies *)
  List.iter (check_def env) m.mod_defs

(** Check a program *)
let check_program (prog: program) =
  let env = create_env () in
  add_builtins env;
  List.iter (check_module env) prog;
  env

(** Check and return result or error message *)
let check prog =
  try
    let env = check_program prog in
    Ok env
  with TypeError (msg, loc) ->
    Error (Printf.sprintf "%s:%d:%d: Type error: %s"
      loc.file loc.line loc.col msg)
