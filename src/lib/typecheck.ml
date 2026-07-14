(** Rake type checker

    Infers and validates types for the tine/through/sweep model.

    Key rules:
    - In rake/crunch functions, untyped params default to float rack
    - Scalars (<x>) broadcast to rack when combined with rack values
    - Tine predicates produce lane masks
    - Through blocks execute under mask, result has type of final expr
    - Sweep arms must all have the same type
*)

open Ast
open Types

(** Type environment *)
type env = {
  target: Capabilities.target;
  types: (ident, t) Hashtbl.t;      (** Type definitions (stack, single) *)
  vars: (ident, t) Hashtbl.t;       (** Variable bindings *)
  tines: (ident, unit) Hashtbl.t;   (** Declared tines (for validation) *)
  funcs: (ident, t list * t) Hashtbl.t;  (** Function signatures *)
  locations: (ident, unit) Hashtbl.t;    (** Mutable locations (from :=) *)
}

let create_env target = {
  target;
  types = Hashtbl.create 32;
  vars = Hashtbl.create 64;
  tines = Hashtbl.create 16;
  funcs = Hashtbl.create 32;
  locations = Hashtbl.create 32;
}

let copy_env env = {
  target = env.target;
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

let require_feature env loc feature =
  if not (Capabilities.is_available env.target feature) then
    type_errorf loc "WIP: feature '%s' (%s) is unavailable for target '%s'"
      (Capabilities.id feature)
      (Capabilities.description feature)
      (Capabilities.string_of_target env.target)

let unavailable_invariant feature =
  failwith (Printf.sprintf
    "Internal error: unavailable feature '%s' passed the capability gate"
    (Capabilities.id feature))

(** Convert AST type to runtime type *)
let rec typ_to_t env (ty: typ) : t =
  require_feature env ty.loc (Capabilities.feature_of_type ty.v);
  (match ty.v with
   | TRack p | TScalar p ->
       require_feature env ty.loc (Capabilities.feature_of_prim p)
   | _ -> ());
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

(** A run annotates its stored output element, while each traversal iteration
    produces one rack of those elements. *)
let run_result_to_t env ty =
  match typ_to_t env ty with
  | Scalar scalar -> Rack scalar
  | other -> other

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
        | Some ty -> run_result_to_t env ty
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
  ) ["min"; "max"; "pow"; "atan2"];
  Hashtbl.add env.funcs "select"
    ([Mask; Rack SFloat; Rack SFloat], Rack SFloat)

(** Get field type from a struct type *)
let get_field_type t field loc =
  match t with
  | Stack (_, fields) | Single (_, fields) -> (
      match List.assoc_opt field fields with
      | Some ft -> ft
      | None -> type_errorf loc "Unknown field: %s" field)
  | _ -> type_errorf loc "Cannot access field of non-struct type"

let scalar_bits = function
  | SBool -> 1
  | SInt8 | SUint8 -> 8
  | SInt16 | SUint16 -> 16
  | SFloat | SInt | SUint -> 32
  | SDouble | SInt64 | SUint64 -> 64

let widened_scalar stored domain loc =
  let target_bits = scalar_bits domain in
  if scalar_bits stored >= target_bits then
    type_errorf loc
      "widen requires a stored element narrower than the traversal domain; got %s in %s"
      (show_concise (Scalar stored)) (show_concise (Rack domain));
  match stored, target_bits with
  | (SInt8 | SInt16), 32 -> SInt
  | (SInt8 | SInt16 | SInt), 64 -> SInt64
  | (SUint8 | SUint16), 32 -> SUint
  | (SUint8 | SUint16 | SUint), 64 -> SUint64
  | SFloat, 64 -> SDouble
  | _ ->
      type_errorf loc "No lossless widening from %s to the lane width of %s"
        (show_concise (Scalar stored)) (show_concise (Rack domain))

let traversal_field domain (name, field_t) =
  let loaded = match field_t with
    | Scalar stored when scalar_bits stored = scalar_bits domain -> Rack stored
    | Scalar stored -> StorageSlice (stored, domain)
    | Rack _ as legacy_rack -> legacy_rack
    | other -> other
  in
  (name, loaded)

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

let is_float_rack = function
  | Rack SFloat -> true
  | _ -> false

let is_float_scalar = function
  | Scalar SFloat -> true
  | _ -> false

let is_supported_value_type = function
  | Rack SFloat | Scalar SFloat | Mask -> true
  | _ -> false

let ensure_supported_value env loc _context t =
  if not (is_supported_value_type t) then
    require_feature env loc Capabilities.Value_non_f32

let ensure_float_rack_result env loc = function
  | Rack SFloat -> ()
  | StorageSlice (stored, domain) ->
      type_errorf loc
        "Column stored as %s cannot be used as a %s value; call widen(column) explicitly"
        (show_concise (Scalar stored)) (show_concise (Rack domain))
  | _ -> require_feature env loc Capabilities.Result_non_float_rack

let ensure_rack_result env loc = function
  | Rack _ -> ()
  | StorageSlice (stored, domain) ->
      type_errorf loc
        "Column stored as %s cannot be used as a %s value; call widen(column) explicitly"
        (show_concise (Scalar stored)) (show_concise (Rack domain))
  | _ -> require_feature env loc Capabilities.Result_non_float_rack

let ensure_supported_pack_fields env loc _pack_name fields =
  List.iter (fun (field_name, field_t) ->
    if not (is_float_rack field_t) then
      let _ = field_name in
      require_feature env loc Capabilities.Pack_non_f32_field
  ) fields

let ensure_supported_crunch_param env loc = function
  | PRack (_pname, None) as param ->
      require_feature env loc (Capabilities.feature_of_param param)
  | PRack (_pname, Some ty) ->
      require_feature env loc Capabilities.Param_rack;
      let t = typ_to_t env ty in
      if not (is_float_rack t) then
        require_feature env ty.loc Capabilities.Value_non_f32
  | PScalar (_pname, annotation) ->
      require_feature env loc Capabilities.Crunch_scalar_param;
      (match annotation with
       | None -> ()
       | Some ty ->
           let t = typ_to_t env ty in
           if not (is_float_scalar t) then
             require_feature env ty.loc Capabilities.Value_non_f32)
  | PSpread (names, type_name) ->
      require_feature env loc Capabilities.Param_spread;
      let expanded = expand_spread env type_name names loc in
      List.iter (fun (name, t) ->
        if not (is_float_rack t) then
          let _ = name in
          require_feature env loc Capabilities.Value_non_f32
      ) expanded

let ensure_supported_rake_param env loc = function
  | PRack (pname, None) -> (
      require_feature env loc Capabilities.Param_rack;
      match find_type env pname with
      | Some t ->
          let _ = t in
          require_feature env loc Capabilities.Value_non_f32
      | None -> ())
  | PRack (_pname, Some ty) ->
      require_feature env loc Capabilities.Param_rack;
      let t = typ_to_t env ty in
      if not (is_float_rack t) then
        require_feature env ty.loc Capabilities.Value_non_f32
  | PScalar (pname, None) -> (
      require_feature env loc Capabilities.Param_scalar;
      match find_type env pname with
      | Some t ->
          let _ = t in
          require_feature env loc Capabilities.Value_non_f32
      | None -> ())
  | PScalar (_pname, Some ty) ->
      require_feature env loc Capabilities.Param_scalar;
      let t = typ_to_t env ty in
      if not (is_float_scalar t) then
        require_feature env ty.loc Capabilities.Value_non_f32
  | PSpread _ ->
      require_feature env loc Capabilities.Rake_spread_param

let ensure_supported_run_param env loc = function
  | PRack (pname, Some ty) -> (
      require_feature env loc Capabilities.Param_rack;
      match typ_to_t env ty with
      | Pack (_, fields) -> ensure_supported_pack_fields env ty.loc pname fields
      | Rack SFloat -> ()
      | _ -> require_feature env ty.loc Capabilities.Value_non_f32)
  | PRack (_pname, None) -> require_feature env loc Capabilities.Param_rack
  | PScalar (_pname, None) -> require_feature env loc Capabilities.Param_scalar
  | PScalar (_pname, Some ty) -> (
      require_feature env loc Capabilities.Param_scalar;
      match typ_to_t env ty with
      | Scalar SFloat | Scalar SInt | Scalar SInt64 -> ()
      | _ -> require_feature env ty.loc Capabilities.Value_non_f32)
  | PSpread _ ->
      require_feature env loc Capabilities.Run_spread_param

(** Infer expression type *)
let rec infer_expr env (expr: Ast.expr) : t =
  require_feature env expr.loc (Capabilities.feature_of_expr expr.v);
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

  | ECall ("widen", [arg]) -> (
      match infer_expr env arg with
      | StorageSlice (stored, domain) -> Rack (widened_scalar stored domain expr.loc)
      | actual ->
          type_errorf expr.loc
            "widen expects a narrower stack column selected by an over domain, got %s"
            (show_concise actual))

  | ECall ("widen", args) ->
      type_errorf expr.loc "widen expects exactly one argument, got %d" (List.length args)

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

  | ERecord _ -> unavailable_invariant Capabilities.Expr_record

  | EWith _ -> unavailable_invariant Capabilities.Expr_record_update

  | ELaneIndex -> Rack SInt
  | ELanes -> Scalar SInt

  | EExtract _ -> unavailable_invariant Capabilities.Expr_extract

  | EInsert _ -> unavailable_invariant Capabilities.Expr_insert

  | EReduce (operation, operand) ->
      let operand_t = infer_expr env operand in
      (match operation, operand_t with
      | (RAdd | RMul | RMin | RMax), Rack SFloat -> Scalar SFloat
      | (RAnd | ROr), _ ->
          type_errorf expr.loc
            "Logical mask reductions are specified but not implemented in this f32 compiler slice"
      | (RAdd | RMul | RMin | RMax), actual ->
          type_errorf expr.loc
            "Floating-point reduction requires float rack, got %s"
            (show_concise actual))

  | EScan (operation, operand) ->
      let operand_t = infer_expr env operand in
      (match operation, operand_t with
      | (RAdd | RMul | RMin | RMax), Rack SFloat -> Rack SFloat
      | (RAnd | ROr), _ ->
          type_errorf expr.loc "Logical prefix scans are not defined"
      | (RAdd | RMul | RMin | RMax), actual ->
          type_errorf expr.loc
            "Floating-point prefix scan requires float rack, got %s"
            (show_concise actual))

  | EShuffle _ -> unavailable_invariant Capabilities.Expr_shuffle
  | EShift _ | ERotate _ -> unavailable_invariant Capabilities.Expr_shift_rotate

  | EGather _ -> unavailable_invariant Capabilities.Expr_gather
  | EScatter _ -> unavailable_invariant Capabilities.Expr_scatter
  | ECompress _ -> unavailable_invariant Capabilities.Expr_compress
  | EExpand _ -> unavailable_invariant Capabilities.Expr_expand

  | ETines _ -> unavailable_invariant Capabilities.Expr_inline_tines

  | EFma (a, b, c) ->
      let a_t = infer_expr env a in
      let b_t = infer_expr env b in
      let c_t = infer_expr env c in
      if a_t = Rack SFloat && b_t = a_t && c_t = a_t then a_t
      else
        let describe = function
          | Rack SFloat -> "float rack"
          | t -> show_concise t
        in
        type_errorf expr.loc
          "fma requires exactly three equal float rack operands, got %s, %s, and %s"
          (describe a_t) (describe b_t) (describe c_t)
  | EOuter _ -> unavailable_invariant Capabilities.Expr_outer

  | ETuple _ -> unavailable_invariant Capabilities.Expr_tuple
  | EBroadcast e ->
      let t = infer_expr env e in
      ensure_supported_value env expr.loc "broadcast" t;
      broadcast t

  | EUnit -> unavailable_invariant Capabilities.Expr_unit
  | ELambda _ -> unavailable_invariant Capabilities.Expr_lambda
  | EPipe _ -> unavailable_invariant Capabilities.Expr_pipeline
  | EFusedPipe _ -> unavailable_invariant Capabilities.Expr_fused_pipeline

(** Infer binary operation result type *)
and infer_binop t1 t2 op loc =
  match op with
  | Add | Sub | Mul | Div | Mod ->
      if compatible t1 t2 && (is_float_rack t1 || is_float_rack t2 || is_float_scalar t1 || is_float_scalar t2) then
        binop_result t1 t2
      else
        type_errorf loc "Unsupported arithmetic operands: %s and %s"
          (show_concise t1) (show_concise t2)
  | Lt | Le | Gt | Ge | Eq | Ne ->
      if compatible t1 t2 && (is_float_rack t1 || is_float_rack t2 || is_float_scalar t1 || is_float_scalar t2) then
        Mask
      else
        type_errorf loc "Unsupported comparison operands: %s and %s"
          (show_concise t1) (show_concise t2)
  | And | Or ->
      if t1 = Mask && t2 = Mask then Mask
      else
        type_errorf loc "Logical operators require mask operands, got %s and %s"
          (show_concise t1) (show_concise t2)
  | Pipe ->
      let _ = loc in unavailable_invariant Capabilities.Expr_pipeline_operator
  | Shl | Shr | Rol | Ror ->
      let _ = loc in unavailable_invariant Capabilities.Expr_shift_rotate
  | Interleave ->
      let _ = loc in unavailable_invariant Capabilities.Expr_interleave

(** Infer unary operation result type *)
and infer_unop t op loc =
  match op with
  | Neg | FNeg ->
      if is_float_rack t || is_float_scalar t then t
      else type_errorf loc "Unary minus requires float rack/scalar, got %s" (show_concise t)
  | Not ->
      if t = Mask then Mask
      else type_errorf loc "Logical not requires mask operand, got %s" (show_concise t)

(** Built-ins whose implementation is compiler-known and has no observable
    side effects. Fused bindings may contain calls only from this set; Rake
    does not yet infer effects for user-defined functions. *)
let pure_builtin_functions =
  [ "sqrt"; "sin"; "cos"; "tan"; "exp"; "log"; "abs";
    "floor"; "ceil"; "min"; "max"; "pow"; "atan2"; "select" ]

(** Validate the source-level fused-binding contract.

    Accepted expressions are immutable SSA computations which the current
    emitter can place directly in the surrounding block. This deliberately
    says nothing about backend registers or instruction selection. Returning
    a reason rather than a boolean keeps rejection diagnostics deterministic. *)
let rec fused_contract_rejection (expr: Ast.expr) : string option =
  let first_rejection expressions =
    List.find_map fused_contract_rejection expressions
  in
  match expr.v with
  | EInt _ | EFloat _ | EBool _ | EVar _ | EScalarVar _ -> None
  | EBinop (l, _, r) -> first_rejection [l; r]
  | EUnop (_, e) | EField (e, _) | EBroadcast e ->
      fused_contract_rejection e
  | ECall (name, args) ->
      if List.mem name pure_builtin_functions then first_rejection args
      else Some (Printf.sprintf
        "call to '%s' is not a compiler-known pure built-in" name)
  | ELet (binding, body) ->
      first_rejection [binding.bind_expr; body]
  | ELaneIndex | ELanes -> None
  | EExtract _ -> Some "lane extraction is not an inlineable expression shape"
  | EInsert _ -> Some "lane insertion may update a value"
  | EReduce _ -> Some "reduction is not an inlineable expression shape"
  | EScan _ -> Some "scan is not an inlineable expression shape"
  | EShuffle _ | EShift _ | ERotate _ ->
      Some "lane rearrangement is not an inlineable expression shape"
  | EPipe _ | EFusedPipe _ -> Some "pipeline is not an inlineable expression shape"
  | EUnit -> Some "unit does not produce an inlineable value"
  | EScatter _ -> Some "scatter may write memory"
  | EGather _ -> Some "gather may read observable memory"
  | ECompress _ | EExpand _ -> Some "masked memory operation is not an inlineable expression shape"
  | ERecord _ | EWith _ -> Some "record construction is not an inlineable expression shape"
  | ETines _ -> Some "inline tine expression is not an inlineable expression shape"
  | ELambda _ -> Some "lambda is not an inlineable expression shape"
  | EFma (a, b, c) -> first_rejection [a; b; c]
  | EOuter _ -> Some "outer product is not an inlineable expression shape"
  | ETuple _ -> Some "tuple construction is not an inlineable expression shape"

(** Check a statement, return updated env *)
let rec check_stmt env (stmt: stmt) : env =
  require_feature env stmt.loc (Capabilities.feature_of_stmt stmt.v);
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
      let actual_t = infer_expr env e in
      let expected_t = match Hashtbl.find_opt env.vars name with
        | Some t -> t
        | None -> type_errorf stmt.loc "Location '%s' has no recorded type" name
      in
      if not (compatible expected_t actual_t) then
        type_errorf stmt.loc "Assignment type mismatch for '%s': expected %s, got %s"
          name (show_concise expected_t) (show_concise actual_t);
      env

  | SFused fb ->
      (* Contract binding: immutable, pure, and directly representable as SSA. *)
      if Hashtbl.mem env.vars fb.fused_name then
        type_errorf stmt.loc "Cannot rebind '%s' (SSA violation, use := for mutable storage)"
          fb.fused_name;
      (match fused_contract_rejection fb.fused_expr with
       | Some reason ->
           type_errorf stmt.loc "Fused binding contract for '%s' rejected: %s"
             fb.fused_name reason
       | None -> ());
      let t = infer_expr env fb.fused_expr in
      let final_t =
        match fb.fused_type with
        | None -> t
        | Some annotation ->
            let expected = typ_to_t env annotation in
            if compatible expected t then expected
            else
              type_errorf stmt.loc
                "Fused binding '%s' type mismatch: expected %s, got %s"
                fb.fused_name (show_concise expected) (show_concise t)
      in
      Hashtbl.add env.vars fb.fused_name final_t;
      env

  | SExpr e ->
      let _ = infer_expr env e in
      env
  | SOver over ->
      let _ = check_over_result env stmt.loc over in
      env

and check_over_result env statement_loc over =
  let count_t = infer_expr env over.over_count in
  (match count_t with
  | Scalar SInt | Scalar SInt64 -> ()
  | _ ->
      type_errorf over.over_count.loc
        "Over loop count must be scalar int/int64, got %s"
        (show_concise count_t));
  let chunk_t =
    match Hashtbl.find_opt env.vars over.over_pack with
    | Some (Pack (name, fields)) ->
        let domain = of_prim over.over_domain in
        Stack (name, List.map (traversal_field domain) fields)
    | Some t ->
        type_errorf statement_loc "Expected pack type, got %s" (show_concise t)
    | None -> type_errorf statement_loc "Undefined pack: %s" over.over_pack
  in
  let body_env = { env with vars = Hashtbl.copy env.vars } in
  Hashtbl.add body_env.vars over.over_chunk chunk_t;
  List.iter (fun statement -> ignore (check_stmt body_env statement)) over.over_body;
  match List.rev over.over_body with
  | { v = SExpr expression; _ } :: _ ->
      let result = infer_expr body_env expression in
      ensure_rack_result body_env expression.loc result;
      result
  | [] ->
      type_errorf statement_loc
        "Over loop must have a body ending in a result expression"
  | final_statement :: _ ->
      type_errorf final_statement.loc
        "Over loop body must end in a result expression"

(** Check tine predicate *)
let rec check_predicate env (pred: predicate) : unit =
  require_feature env pred.loc (Capabilities.feature_of_predicate pred.v);
  match pred.v with
  | PExpr e ->
      let t = infer_expr env e in
      if t <> Mask then
        type_errorf pred.loc "Predicate must be mask type, got %s" (show_concise t)
  | PCmp (l, cmp, r) ->
      let lt = infer_expr env l in
      let rt = infer_expr env r in
      let op = match cmp with
        | CLt -> Lt | CLe -> Le | CGt -> Gt | CGe -> Ge | CEq -> Eq | CNe -> Ne
      in
      ignore (infer_binop lt rt op pred.loc)
  | PIs (l, r) | PIsNot (l, r) ->
      let lt = infer_expr env l in
      let rt = infer_expr env r in
      ignore (infer_binop lt rt Eq pred.loc)
  | PAnd (l, r) | POr (l, r) ->
      check_predicate env l;
      check_predicate env r
  | PNot p ->
      check_predicate env p
  | PTineRef name ->
      if not (Hashtbl.mem env.tines name) then
        type_errorf pred.loc "Reference to undefined tine: #%s" name

(** Audit an expression for CPU-predicated execution.  This is deliberately
    separate from ordinary type inference: a call can be valid in unmasked
    code while lacking a sound inactive-lane lowering inside [through]. *)
let rec check_masked_expr env (expr: expr) =
  match expr.v with
  | EBinop (l, op, r) ->
      if not (Masked_safety.supports_binop op) then
        require_feature env expr.loc Capabilities.Masked_modulo;
      check_masked_expr env l;
      check_masked_expr env r
  | EUnop (_, e) | EBroadcast e | EField (e, _) ->
      check_masked_expr env e
  | ECall (name, args) ->
      (match Masked_safety.classify_builtin name with
       | Masked_safety.Sanitized -> ()
       | Masked_safety.Unsupported ->
           require_feature env expr.loc Capabilities.Masked_user_call);
      List.iter (check_masked_expr env) args
  | ELet (binding, body) ->
      check_masked_expr env binding.bind_expr;
      check_masked_expr env body
  | EInt _ | EFloat _ | EBool _ | EVar _ | EScalarVar _ | ELaneIndex
  | ELanes | EUnit -> ()
  | ERecord (_, inits) ->
      List.iter (fun init -> check_masked_expr env init.init_value) inits
  | EWith (base, inits) ->
      check_masked_expr env base;
      List.iter (fun init -> check_masked_expr env init.init_value) inits
  | EExtract (v, i) -> check_masked_expr env v; check_masked_expr env i
  | EInsert (v, i, x) ->
      check_masked_expr env v; check_masked_expr env i; check_masked_expr env x
  | EReduce _ | EScan _ ->
      require_feature env expr.loc Capabilities.Masked_cross_lane
  | EShuffle (e, _) | EShift (e, _, _) | ERotate (e, _, _) ->
      check_masked_expr env e
  | EGather (base, indices) ->
      check_masked_expr env base; check_masked_expr env indices
  | EScatter (base, indices, values) ->
      check_masked_expr env base;
      check_masked_expr env indices;
      check_masked_expr env values
  | ECompress (v, mask) ->
      check_masked_expr env v; check_masked_expr env mask
  | EExpand (v, mask, passthru) ->
      check_masked_expr env v;
      check_masked_expr env mask;
      check_masked_expr env passthru
  | ETines (_, throughs, sweep) ->
      List.iter (fun th ->
        List.iter (check_masked_stmt env) th.through_body;
        check_masked_expr env th.through_result
      ) throughs;
      List.iter (fun arm -> check_masked_expr env arm.arm_value) sweep.sweep_arms
  | EFma (a, b, c) ->
      check_masked_expr env a; check_masked_expr env b; check_masked_expr env c
  | EOuter (a, b) -> check_masked_expr env a; check_masked_expr env b
  | ETuple es -> List.iter (check_masked_expr env) es
  | ELambda (_, body) -> check_masked_expr env body
  | EPipe (l, r) | EFusedPipe (l, r) ->
      check_masked_expr env l; check_masked_expr env r

and check_masked_stmt env (stmt: stmt) =
  match stmt.v with
  | SLet binding -> check_masked_expr env binding.bind_expr
  | SFused binding -> check_masked_expr env binding.fused_expr
  | SExpr expr -> check_masked_expr env expr
  | SLocBind _ | SAssign _ ->
      require_feature env stmt.loc Capabilities.Masked_mutation
  | SOver _ -> require_feature env stmt.loc Capabilities.Masked_loop

(** Check through block *)
let check_through env (th: through) : t =
  (* Use through_result's location as the block location *)
  let block_loc = th.through_result.loc in
  require_feature env block_loc Capabilities.Rake_through;
  (* Check tine reference *)
  (match th.through_tine with
   | TRSingle name ->
       if not (Hashtbl.mem env.tines name) then
         type_errorf block_loc "Reference to undefined tine: #%s" name
   | TRComposed pred ->
       check_predicate env pred);
  (* Check body statements *)
  let env' = copy_env env in
  List.iter (fun s ->
    check_masked_stmt env' s;
    ignore (check_stmt env' s)
  ) th.through_body;
  (* Infer result type *)
  let result_t = infer_expr env' th.through_result in
  check_masked_expr env' th.through_result;
  ensure_float_rack_result env th.through_result.loc result_t;
  (match th.through_passthru with
   | Some passthru ->
       (* Passthrough is outside the masked body and cannot observe its locals. *)
       let passthru_t = infer_expr env passthru in
       ensure_float_rack_result env passthru.loc passthru_t;
       if not (compatible result_t passthru_t) then
         type_errorf passthru.loc "Through passthru type mismatch: expected %s, got %s"
           (show_concise result_t) (show_concise passthru_t)
   | None -> ());
  Hashtbl.add env.vars th.through_binding result_t;
  result_t

(** Check sweep block *)
let check_sweep env (sw: sweep) expected_loc : t =
  require_feature env expected_loc Capabilities.Rake_sweep;
  (* A total sweep has exactly one final catch-all and mentions each named tine
     at most once. Keeping this as a source invariant lets emission start from
     a real value rather than inventing an unmatched-lane seed. *)
  let rec check_arms seen_tines saw_catchall = function
    | [] ->
        if not saw_catchall then
          type_error "Sweep must end with a catch-all (_) arm" expected_loc
    | arm :: rest ->
        if saw_catchall then
          type_error "Sweep arm after catch-all (_) is unreachable" expected_loc;
        (match arm.arm_tine with
         | Some name ->
             if List.mem name seen_tines then
               type_errorf expected_loc "Duplicate tine arm in sweep: #%s" name;
             check_arms (name :: seen_tines) false rest
         | None -> check_arms seen_tines true rest)
  in
  check_arms [] false sw.sweep_arms;

  let arm_types = List.map (fun arm ->
    (match arm.arm_tine with
     | Some name ->
         if not (Hashtbl.mem env.tines name) then
           type_errorf expected_loc "Reference to undefined tine in sweep: #%s" name
     | None -> ());  (* catch-all *)
    check_masked_expr env arm.arm_value;
    let arm_t = infer_expr env arm.arm_value in
    ensure_float_rack_result env expected_loc arm_t;
    arm_t
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

  require_feature env' loc Capabilities.Rake_tines;
  List.iter (ensure_supported_rake_param env' loc) params;

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

  (* Tines are source ordered.  A reference may name only an earlier tine,
     which gives native lowering a deterministic acyclic mask graph. *)
  List.iter (fun tine ->
    if Hashtbl.mem env'.tines tine.tine_name then
      type_errorf tine.tine_pred.loc "Duplicate tine declaration: #%s" tine.tine_name;
    check_predicate env' tine.tine_pred;
    Hashtbl.add env'.tines tine.tine_name ()
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
    | Some ty ->
        let t = typ_to_t env ty in
        require_feature env' ty.loc Capabilities.Result_annotation;
        ensure_float_rack_result env' ty.loc t;
        t
    | None ->
        (match Hashtbl.find_opt env.types result.result_name with
         | Some t ->
             ensure_float_rack_result env' loc t;
             t
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

  List.iter (ensure_supported_crunch_param env' loc) params;
  (match _result.result_type with
   | Some ty ->
       require_feature env' ty.loc Capabilities.Result_annotation;
       let t = typ_to_t env' ty in
       if t <> Rack SFloat && t <> Scalar SFloat then
         require_feature env' ty.loc Capabilities.Value_non_f32
   | None -> ());

  (* Add parameters, expanding any spreads *)
  add_params_to_env env' params loc;

  (* Check body *)
  List.iter (fun s -> ignore (check_stmt env' s)) body;

  let actual_t = match Hashtbl.find_opt env'.vars _result.result_name with
    | Some t -> t
    | None ->
        let has_trailing_expr = match List.rev body with
          | { v = SExpr _; _ } :: _ -> true
          | _ -> false
        in
        if has_trailing_expr then
          (require_feature env' loc Capabilities.Crunch_implicit_result;
           unavailable_invariant Capabilities.Crunch_implicit_result)
        else
          type_errorf loc "Crunch result '%s' is not bound; bind it with let or a fused binding"
            _result.result_name
  in
  if actual_t <> Rack SFloat && actual_t <> Scalar SFloat then
    require_feature env' loc Capabilities.Result_non_float_rack;
  let expected_t = match _result.result_type with
    | Some ty -> typ_to_t env' ty
    | None -> Rack SFloat
  in
  if not (compatible expected_t actual_t) then
    type_errorf loc "Return type mismatch: expected %s, got %s"
      (show_concise expected_t) (show_concise actual_t)

(** Check run function definition *)
let check_run env _name params result body loc =
  let env' = copy_env env in
  List.iter (ensure_supported_run_param env' loc) params;
  (match result.result_type with
   | Some ty ->
       require_feature env' ty.loc Capabilities.Result_annotation;
       let t = run_result_to_t env' ty in
       if not (is_float_rack t) then
         require_feature env' ty.loc Capabilities.Value_non_f32
  | None -> ());
  add_params_to_env env' params loc;
  let actual_t =
    match List.rev body with
    | { v = SOver over; loc = over_loc } :: preceding_reversed ->
        List.rev preceding_reversed
        |> List.iter (fun statement -> ignore (check_stmt env' statement));
        check_over_result env' over_loc over
    | [] ->
        type_errorf loc
          "Run result '%s' is not produced; the body must end in an over loop"
          result.result_name
    | final_statement :: _ ->
        type_errorf final_statement.loc
          "Run result '%s' is not produced; the body must end in an over loop"
          result.result_name
  in
  ensure_rack_result env' loc actual_t;
  let expected_t =
    match result.result_type with
    | Some ty -> run_result_to_t env' ty
    | None -> Rack SFloat
  in
  if not (compatible expected_t actual_t) then
    type_errorf loc "Run result '%s' type mismatch: expected %s, got %s"
      result.result_name (show_concise expected_t) (show_concise actual_t)

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
      check_run env name params result body def.loc

(** Check a module *)
let check_module env (m: module_) =
  (* This exhaustive top-level audit runs before any registration pass. *)
  List.iter (fun def ->
    require_feature env def.loc (Capabilities.feature_of_def def.v)
  ) m.mod_defs;
  (* First pass: register all type definitions *)
  List.iter (register_type_def env) m.mod_defs;
  (* Second pass: register function signatures *)
  List.iter (register_func_def env) m.mod_defs;
  (* Third pass: check function bodies *)
  List.iter (check_def env) m.mod_defs

(** Check a program *)
let check_program ?(target = Capabilities.Frontend) (prog: program) =
  let env = create_env target in
  add_builtins env;
  List.iter (check_module env) prog;
  env

(** Check and return result or error message *)
let check ?(target = Capabilities.Frontend) prog =
  try
    let env = check_program ~target prog in
    Ok env
  with TypeError (msg, loc) ->
    Error (Printf.sprintf "%s:%d:%d: Type error: %s"
      loc.file loc.line loc.col msg)
