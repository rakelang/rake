(** Rake type checker

    Infers and validates types for the tine/through/sweep model.

    Key rules:
    - In rake/scratch functions, untyped params default to float rack
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
  types: (ident, t) Hashtbl.t;      (** Type definitions (pack, single) *)
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
  | TPack name -> (
      match Hashtbl.find_opt env.types name with
      | Some t -> t
      | None -> type_errorf ty.loc "Unknown pack type: %s" name)
  | TStack name -> (
      match Hashtbl.find_opt env.types name with
      | Some (Pack (n, fields)) -> Stack (n, fields)  (* Convert pack to stack *)
      | Some t -> type_errorf ty.loc "Expected pack type for stack, got %s" (show_concise t)
      | None -> type_errorf ty.loc "Unknown type for stack: %s" name)
  | TSingle name -> (
      match Hashtbl.find_opt env.types name with
      | Some t -> t
      | None -> type_errorf ty.loc "Unknown single type: %s" name)
  | TMask -> Mask
  | TFun _ -> type_errorf ty.loc "C function pointers belong to slow definitions"
  | TTuple ts -> Tuple (List.map (typ_to_t env) ts)
  | TUnit -> Unit
  | TArray _ | TView _ | TPtr _ | TMut _ | TNamed _ ->
      type_errorf ty.loc "%s types belong to runs and slow definitions"
        (Capabilities.id (Capabilities.feature_of_type ty.v))

(** A run annotates its stored output element, while each traversal iteration
    produces one rack of those elements. *)
let run_result_to_t env ty =
  match typ_to_t env ty with
  | Scalar scalar -> Rack scalar
  | other -> other

(** Register type definitions *)
let register_type_def env (def: def) =
  match def.v with
  | DPack (name, fields) ->
      let field_types = List.map (fun f ->
        (f.field_name, typ_to_t env f.field_type)
      ) fields in
      Hashtbl.add env.types name (Pack (name, field_types))
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
  | Some (Pack (_, fields)) | Some (Single (_, fields)) ->
      if List.length names <> List.length fields then
        type_errorf loc "Type %s has %d fields, but %d names provided"
          type_name (List.length fields) (List.length names);
      List.map2 (fun name (_, field_type) -> (name, field_type)) names fields
  | Some _ ->
      type_errorf loc "Type %s is not a pack or single (cannot spread)" type_name
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

(** Whether a run uses forms that only the tier checker ({!Tier_check}) knows:
    a general body, view, mutable or rack parameters, or statements beyond the
    first traversal contract. Such a run is checked and lowered there alone. *)
let run_needs_tier params (result : result_spec) body =
  let new_type (t : typ) = match t.v with TArray _ | TView _ | TPtr _ | TMut _ | TNamed _ | TRack _ -> true | _ -> false in
  let rec new_stmt (s : stmt) =
    match s.v with
    | SExpr { v = ESlow _; _ } -> true
    | SLet _ | SFused _ | SExpr _ -> false
    | SOver o -> List.exists new_stmt o.over_body
    | _ -> true
  in
  result.result_type = None
  || List.exists (function PRack (_, Some t) | PScalar (_, Some t) -> new_type t | _ -> false) params
  || List.exists new_stmt body
  || (match List.rev body with { v = SOver _; _ } :: before -> List.exists (fun (s : stmt) -> match s.v with SOver _ -> true | _ -> false) before | _ -> true)

(** Register function signatures *)
let register_func_def env (def: def) =
  match def.v with
  | DScratch (name, params, result, _) ->
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
  | DRun (_, params, result, body) when run_needs_tier params result body -> ()
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
  ) ["sqrt"; "sin"; "cos"; "tan"; "tanh"; "exp"; "log"; "log2"; "abs"; "floor"; "ceil"; "trunc"; "nearest"];
  (* Math functions: rack, rack -> rack *)
  List.iter (fun name ->
    Hashtbl.add env.funcs name ([Rack SFloat; Rack SFloat], Rack SFloat)
  ) ["min"; "max"; "pow"; "atan2"];
  List.iter (fun name ->
    Hashtbl.add env.funcs name ([Rack SFloat; Rack SFloat; Rack SFloat], Rack SFloat)
  ) ["relaxed_madd"; "relaxed_nmadd"];
  List.iter (fun name ->
    Hashtbl.add env.funcs name ([Rack SFloat; Rack SFloat], Rack SFloat)
  ) ["relaxed_min"; "relaxed_max"];
  Hashtbl.add env.funcs "select"
    ([Mask; Rack SFloat; Rack SFloat], Rack SFloat)

(** Get field type from a struct type *)
let get_field_type t field loc =
  match t with
  | Pack (_, fields) | Single (_, fields) -> (
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
  | Pack (n1, _), Pack (n2, _) -> n1 = n2
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

let ensure_supported_stack_fields env loc _stack_name fields =
  List.iter (fun (field_name, field_t) ->
    if not (is_float_rack field_t) then
      let _ = field_name in
      require_feature env loc Capabilities.Stack_non_f32_field
  ) fields

let ensure_supported_scratch_param env loc = function
  | PRack (_pname, None) as param ->
      require_feature env loc (Capabilities.feature_of_param param)
  | PRack (_pname, Some ty) ->
      require_feature env loc Capabilities.Param_rack;
      let t = typ_to_t env ty in
      if not (is_float_rack t) then
        require_feature env ty.loc Capabilities.Value_non_f32
  | PScalar (_pname, annotation) ->
      require_feature env loc Capabilities.Scratch_scalar_param;
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
      | Stack (_, fields) -> ensure_supported_stack_fields env ty.loc pname fields
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

(** An integer literal, written bare or as a uniform <n>. *)
let is_integer_literal (expr: Ast.expr) =
  match expr.v with
  | EInt _ | EBroadcast { v = EInt _; _ } -> true
  | _ -> false

let integer_literal_value (expr: Ast.expr) =
  match expr.v with
  | EInt value | EBroadcast { v = EInt value; _ } -> value
  | _ -> invalid_arg "integer_literal_value: not an integer literal"

(** Whether an integer literal fits a lane of this integer rack. *)
let literal_fits rack value =
  match rack with
  | Rack SUint8 -> value >= 0L && value <= 255L
  | Rack SInt64 -> true
  | Rack SInt16 -> value >= -32768L && value <= 32767L
  | Rack SInt -> value >= -2147483648L && value <= 2147483647L
  | _ -> false

let is_integer_rack = function Rack (SInt16 | SInt) -> true | _ -> false

let is_integer_scalar_type = function
  | SInt8 | SInt16 | SInt | SInt64 | SUint8 | SUint16 | SUint | SUint64 -> true
  | SFloat | SDouble | SBool -> false

let literal_fits_scalar s value =
  match s with
  | SInt8 -> value >= -128L && value <= 127L
  | SUint8 -> value >= 0L && value <= 255L
  | SInt16 -> value >= -32768L && value <= 32767L
  | SUint16 -> value >= 0L && value <= 65535L
  | SInt -> value >= -2147483648L && value <= 2147483647L
  | SUint -> value >= 0L && value <= 4294967295L
  | _ -> true

(** Integer rack arithmetic: + and - of any integer rack, * of 16-, 32- and
    64-bit lanes; there is no lane division. *)
let integer_arithmetic loc op t =
  match (op, t) with
  | (Add | Sub), _ -> t
  | Mul, (Rack (SInt16 | SUint16 | SInt | SUint | SInt64 | SUint64) | Scalar _) -> t
  | Mul, _ -> type_errorf loc "wasm-simd128 has no byte multiply; widen the bytes first"
  | _ -> type_errorf loc "integer racks have no lane division"

(** The lane bits of a rack that bitwise operations and shifts take. *)
let lane_bits = function
  | Rack (SUint8 | SInt8) -> Some 8
  | Rack (SUint16 | SInt16) -> Some 16
  | Rack (SUint | SInt) -> Some 32
  | Rack (SUint64 | SInt64) -> Some 64
  | _ -> None

(** A scalar written where it meets a rack, marked as a uniform: <name>, a
    literal, or arithmetic of those. *)
let rec marked_uniform (e : Ast.expr) =
  match e.v with
  | EScalarVar _ | EBroadcast _ | EInt _ | EFloat _ -> true
  | EBinop (a, _, b) -> marked_uniform a && marked_uniform b
  | EUnop (_, a) -> marked_uniform a
  | _ -> false

(** A scalar becomes a rack only where the source marks it. *)
let require_marked loc (l : Ast.expr) lt (r : Ast.expr) rt =
  let unmarked (e : Ast.expr) =
    match e.v with
    | EVar name -> Printf.sprintf "'%s' is a uniform scalar: write <%s> where it meets a rack" name name
    | _ -> "this scalar meets a rack unmarked: bind it with let, then write <name>"
  in
  match (lt, rt) with
  | (Rack _ | Mask), Scalar _ when not (marked_uniform r) -> type_errorf r.loc "%s" (unmarked r)
  | Scalar _, (Rack _ | Mask) when not (marked_uniform l) -> type_errorf l.loc "%s" (unmarked l)
  | _ -> ignore loc

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

  | EBinop (l, ((Lt | Le | Gt | Ge | Eq | Ne) as op), r)
    when is_integer_literal l || is_integer_literal r ->
      (* An integer literal takes the element type of the integer rack it is compared with. *)
      let rack, literal = if is_integer_literal l then (r, l) else (l, r) in
      let rack_t = infer_expr env rack in
      require_feature env expr.loc Capabilities.Integer_rack_comparison;
      (match rack_t with
       | Rack SUint8 ->
           let value = integer_literal_value literal in
           if value < 0L || value > 255L then
             type_errorf literal.loc "integer literal %Ld does not fit a u8 lane" value;
           let _ = op in
           Mask
       | Rack (SInt16 | SInt | SInt64) | Rack SFloat ->
           let value = integer_literal_value literal in
           if not (literal_fits rack_t value || rack_t = Rack SInt64 || rack_t = Rack SFloat) then
             type_errorf literal.loc "integer literal %Ld does not fit a %s lane" value (show_concise (element_type rack_t));
           Mask
       | Scalar s when s <> SBool -> Scalar SBool
       | actual ->
           type_errorf expr.loc "integer literal comparison requires a u8 rack, got %s"
             (show_concise actual))

  | EBinop (l, ((Add | Sub | Mul | Div) as op), r)
    when (is_integer_literal l || is_integer_literal r)
         && not (is_integer_literal l && is_integer_literal r) ->
      (* An integer literal takes the type of the rack or scalar beside it. *)
      let other = if is_integer_literal l then r else l in
      let literal = if is_integer_literal l then l else r in
      let t = infer_expr env other in
      (match t with
       | Rack s | Scalar s when is_integer_scalar_type s ->
           if not (literal_fits_scalar s (integer_literal_value literal)) then
             type_errorf literal.loc "integer literal %Ld does not fit a %s lane" (integer_literal_value literal) (show_concise (Scalar s));
           integer_arithmetic expr.loc op t
       | Rack SFloat | Scalar SFloat -> t
       | actual -> type_errorf expr.loc "Unsupported arithmetic operands: %s and an integer literal" (show_concise actual))
  | EBinop (l, op, r) ->
      let lt = infer_expr env l in
      let rt = infer_expr env r in
      require_marked expr.loc l lt r rt;
      (match op with
       | (Add | Sub | Mul | Div)
         when (match (lt, rt) with
               | (Rack s | Scalar s), (Rack s' | Scalar s') -> s = s' && is_integer_scalar_type s
               | _ -> false) ->
           require_feature env expr.loc Capabilities.Integer_rack_arithmetic;
           integer_arithmetic expr.loc op (match lt with Rack _ -> lt | _ -> rt)
       | (Lt | Le | Gt | Ge | Eq | Ne)
         when (match (lt, rt) with
               | (Rack s | Scalar s), (Rack s' | Scalar s') -> s = s' && is_integer_scalar_type s && s <> SUint8
               | _ -> false) -> (
           match (lt, rt) with
           | Scalar _, Scalar _ -> Scalar SBool
           | Rack (SUint | SUint16 | SInt8 | SUint64), _ | _, Rack (SUint | SUint16 | SInt8 | SUint64) ->
               type_errorf expr.loc "wasm-simd128 compares u8 and signed i16, i32 and i64 lanes; this rack has unsigned or i8 lanes"
           | _ -> Mask)
       | (Add | Sub) when lt = rt && is_integer_rack lt ->
           require_feature env expr.loc Capabilities.Integer_rack_arithmetic;
           lt
       | _ -> infer_binop lt rt op expr.loc)

  | EUnop (op, e) ->
      let t = infer_expr env e in
      infer_unop t op expr.loc

  | ECall ("widen", [arg]) -> (
      match infer_expr env arg with
      | StorageSlice (stored, domain) -> Rack (widened_scalar stored domain expr.loc)
      | actual ->
          type_errorf expr.loc
            "widen expects a narrower pack column selected by an over domain, got %s"
            (show_concise actual))

  | ECall ("widen", args) ->
      type_errorf expr.loc "widen expects exactly one argument, got %d" (List.length args)

  | ECall (("min" | "max") as name, [a; b])
    when not (is_integer_literal a && is_integer_literal b)
         && (let t = infer_expr env (if is_integer_literal a then b else a) in is_integer_rack t || t = Rack SUint8) ->
      (* An integer literal takes the element type of the integer rack beside it. *)
      require_feature env expr.loc Capabilities.Integer_rack_arithmetic;
      let rack, other = if is_integer_literal a then (b, a) else (a, b) in
      let t = infer_expr env rack in
      if is_integer_literal other then begin
        let value = integer_literal_value other in
        if not (literal_fits t value) then
          type_errorf other.loc "integer literal %Ld does not fit a %s lane" value (show_concise (element_type t))
      end
      else if (match infer_expr env other with o -> o <> t && o <> element_type t) then
        type_errorf expr.loc "%s requires two equal integer racks" name;
      t

  | ECall (("dot" | "narrow") as name, [a; b]) ->
      require_feature env expr.loc Capabilities.Integer_rack_conversion;
      let operand, result = if name = "dot" then (Rack SInt16, Rack SInt) else (Rack SInt, Rack SInt16) in
      List.iter (fun arg ->
        let actual = infer_expr env arg in
        if actual <> operand then
          type_errorf arg.loc "%s requires %s racks, got %s" name (show_concise operand) (show_concise actual))
        [a; b];
      result

  | ECall (("widen_low" | "widen_high" | "to_f32" | "to_i32") as name, [x]) ->
      require_feature env expr.loc Capabilities.Integer_rack_conversion;
      let operand, result =
        match name with
        | "widen_low" | "widen_high" -> (Rack SUint8, Rack SInt16)
        | "to_f32" -> (Rack SInt, Rack SFloat)
        | _ -> (Rack SFloat, Rack SInt)
      in
      let actual = infer_expr env x in
      if actual <> operand then
        type_errorf x.loc "%s requires a %s rack, got %s" name (show_concise operand) (show_concise actual);
      result

  | ECall (("dot" | "narrow" | "widen_low" | "widen_high" | "to_f32" | "to_i32") as name, args) ->
      type_errorf expr.loc "%s expects %d argument(s), got %d" name
        (if name = "dot" || name = "narrow" then 2 else 1) (List.length args)

  | ECall (("bit_and" | "bit_or" | "bit_xor" | "bit_andnot") as name, [a; b]) ->
      require_feature env expr.loc Capabilities.Integer_rack_bits;
      (* An integer literal takes the type of the integer rack beside it. *)
      let rack, other = if is_integer_literal a && not (is_integer_literal b) then (b, a) else (a, b) in
      let t = infer_expr env rack in
      if lane_bits t = None then
        type_errorf rack.loc "%s requires integer racks, got %s" name (show_concise t);
      if is_integer_literal other then begin
        let value = integer_literal_value other in
        if not (literal_fits t value) then
          type_errorf other.loc "integer literal %Ld does not fit a %s lane" value (show_concise (element_type t))
      end
      else begin
        let o = infer_expr env other in
        if o <> t then
          type_errorf other.loc "%s requires two equal integer racks, got %s and %s" name
            (show_concise t) (show_concise o)
      end;
      t

  | ECall (("shift_bits_left" | "shift_bits_right" | "shift_bits_right_signed") as name, [x; count]) ->
      require_feature env expr.loc Capabilities.Integer_rack_bits;
      let t = infer_expr env x in
      (match lane_bits t with
       | None -> type_errorf x.loc "%s shifts an integer rack, got %s" name (show_concise t)
       | Some bits ->
           if is_integer_literal count then begin
             let value = integer_literal_value count in
             if value < 0L || value >= Int64.of_int bits then
               type_errorf count.loc "a shift of %d-bit lanes takes a count from 0 to %d, got %Ld"
                 bits (bits - 1) value
           end
           else (match count.v with
             | EScalarVar _ | EBroadcast { v = EScalarVar _; _ } ->
                 (match infer_expr env count with
                  | Scalar SUint | Rack SUint -> ()
                  | actual ->
                      type_errorf count.loc "%s takes a uniform u32 count, got %s" name (show_concise actual))
             | _ -> type_errorf count.loc "%s takes its count as an integer literal or a uniform u32" name));
      t

  | ECall (("bit_and" | "bit_or" | "bit_xor" | "bit_andnot" | "shift_bits_left" | "shift_bits_right"
           | "shift_bits_right_signed") as name, args) ->
      type_errorf expr.loc "%s expects 2 arguments, got %d" name (List.length args)

  | ECall ("bitmask", [mask]) ->
      require_feature env expr.loc Capabilities.Bitmask_reduction;
      (match infer_expr env mask with
       | Mask -> Scalar SUint
       | actual ->
           type_errorf expr.loc "bitmask requires a mask, got %s" (show_concise actual))

  | ECall ("bitmask", args) ->
      type_errorf expr.loc "bitmask expects exactly one argument, got %d" (List.length args)

  | ECall (("abs" | "floor" | "ceil" | "trunc" | "nearest") as name, [ x ]) -> (
      match infer_expr env x with
      | Rack SFloat -> Rack SFloat
      | Rack (SInt8 | SInt16 | SInt | SInt64 | SUint8) as t when name = "abs" -> t
      | t -> type_errorf expr.loc "%s of %s is not available" name (show_concise t))
  | ECall ("select", [ c; a; b ]) when (match infer_expr env a with Rack SFloat -> false | Rack _ -> true | _ -> false) ->
      let a_t = infer_expr env a and b_t = infer_expr env b in
      if infer_expr env c <> Mask then type_errorf c.loc "select chooses lanes by a mask";
      if a_t <> b_t then type_errorf expr.loc "select arms have types %s and %s" (show_concise a_t) (show_concise b_t);
      a_t
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

  | ERecord (name, _) | EStack (name, _) ->
      type_errorf expr.loc "a %s literal is a slow-tier value; scratches and rakes compute on racks" name

  | EWith _ -> unavailable_invariant Capabilities.Expr_record_update

  | ELaneIndex -> Rack SInt
  | ELanes -> Scalar SInt


  | EReduce (operation, operand) ->
      let operand_t = infer_expr env operand in
      (match operation, operand_t with
      | (RAdd | RMul | RMin | RMax), Rack SFloat -> Scalar SFloat
      | (RAnd | ROr), Mask -> Scalar SBool
      | (RAnd | ROr), actual ->
          type_errorf expr.loc "all and any reduce a mask, got %s" (show_concise actual)
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

  | EShuffle (operand, indices) ->
      if List.exists (fun index -> index < 0) indices then
        type_errorf expr.loc "shuffle indices must not be negative";
      let racks = match operand.v with ETuple [left; right] -> [left; right] | _ -> [operand] in
      (match List.map (infer_expr env) racks with
       | (Rack _ as first) :: rest when List.for_all (fun t -> t = first) rest -> first
       | types ->
           type_errorf expr.loc "shuffle requires one rack or two equal racks, got %s"
             (String.concat " and " (List.map show_concise types)))
  | EShift _ | ERotate _ -> unavailable_invariant Capabilities.Expr_shift_rotate

  | EGather _ -> type_errorf expr.loc "a gather is written view[indices] in a run"
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
  | EIf (c, a, b) ->
      let condition = infer_expr env c in
      (match condition with
       | Mask | Scalar SBool -> ()
       | t -> type_errorf c.loc "an if condition is a mask or a uniform bool, got %s" (show_concise t));
      let a_t, b_t =
        if is_integer_literal a && not (is_integer_literal b) then let b_t = infer_expr env b in (b_t, b_t)
        else if is_integer_literal b && not (is_integer_literal a) then let a_t = infer_expr env a in (a_t, a_t)
        else (infer_expr env a, infer_expr env b)
      in
      if not (compatible a_t b_t) then
        type_errorf expr.loc "if branches have types %s and %s" (show_concise a_t) (show_concise b_t);
      (match a_t with
       | Rack _ | Mask -> ()
       | Scalar _ when condition = Scalar SBool -> ()
       | t -> type_errorf expr.loc "a lane-wise if chooses racks, got %s" (show_concise t));
      (match (a_t, b_t) with Rack _, _ -> a_t | _, Rack _ -> b_t | _ -> a_t)
  | EExtract (rack, lane) -> (
      match infer_expr env rack with
      | Rack s ->
          if not (is_integer_literal lane) then type_errorf lane.loc "a lane is chosen by an integer literal";
          Scalar s
      | t -> type_errorf rack.loc "extract takes a rack, got %s" (show_concise t))
  | EInsert (rack, lane, value) -> (
      match infer_expr env rack with
      | Rack s as t ->
          if not (is_integer_literal lane) then type_errorf lane.loc "a lane is chosen by an integer literal";
          (match value.v with
           | EInt _ | EFloat _ | EBroadcast { v = EInt _ | EFloat _; _ } -> ()
           | _ -> (
               match infer_expr env value with
               | Scalar s' when s' = s -> ()
               | v -> type_errorf value.loc "insert takes a uniform %s, got %s" (show_concise (Scalar s)) (show_concise v)));
          t
      | t -> type_errorf rack.loc "insert takes a rack, got %s" (show_concise t))
  | EConvert (Convert_bitcast, target, operand) -> (
      match typ_to_t env target with
      | Rack _ as target_t -> (
          match infer_expr env operand with
          | Rack _ | Mask | Scalar _ -> target_t
          | t -> type_errorf operand.loc "bitcast reinterprets a rack, got %s" (show_concise t))
      | t -> type_errorf target.loc "in vector code bitcast targets a rack type, got %s" (show_concise t))
  | EString _ | EIndex _ | EConvert _ | EArray _ | ESlow _ ->
      type_errorf expr.loc "%s belongs to runs and slow definitions"
        (Capabilities.id (Capabilities.feature_of_expr expr.v))

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
      else if t1 = Rack SUint8 && t2 = Rack SUint8 then Mask
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
      else (match t with
        | Rack (SInt8 | SInt16 | SInt | SInt64) | Scalar (SInt8 | SInt16 | SInt | SInt64) -> t
        | _ -> type_errorf loc "Unary minus requires a float or signed integer rack/scalar, got %s" (show_concise t))
  | Not ->
      if t = Mask then Mask
      else type_errorf loc "Logical not requires mask operand, got %s" (show_concise t)

(** Built-ins whose implementation is compiler-known and has no observable
    side effects. Fused bindings may contain calls only from this set; Rake
    does not yet infer effects for user-defined functions. *)
let pure_builtin_functions =
  [ "sqrt"; "sin"; "cos"; "tan"; "exp"; "log"; "abs";
    "floor"; "ceil"; "min"; "max"; "pow"; "atan2"; "select";
    "dot"; "narrow"; "widen_low"; "widen_high"; "to_f32"; "to_i32"; "log2"; "trunc"; "nearest"; "tanh"; "relaxed_madd"; "relaxed_nmadd"; "relaxed_min"; "relaxed_max";
    "bit_and"; "bit_or"; "bit_xor"; "bit_andnot"; "shift_bits_left"; "shift_bits_right"; "shift_bits_right_signed" ]

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
  | EShuffle ({ v = ETuple racks; _ }, _) -> first_rejection racks
  | EShuffle (e, _) -> fused_contract_rejection e
  | EShift _ | ERotate _ ->
      Some "lane rearrangement is not an inlineable expression shape"
  | EPipe _ | EFusedPipe _ -> Some "pipeline is not an inlineable expression shape"
  | EUnit -> Some "unit does not produce an inlineable value"
  | EScatter _ -> Some "scatter may write memory"
  | EGather _ -> Some "gather may read observable memory"
  | ECompress _ | EExpand _ -> Some "masked memory operation is not an inlineable expression shape"
  | ERecord _ | EStack _ | EWith _ -> Some "aggregate construction is not an inlineable expression shape"
  | ETines _ -> Some "inline tine expression is not an inlineable expression shape"
  | ELambda _ -> Some "lambda is not an inlineable expression shape"
  | EFma (a, b, c) -> first_rejection [a; b; c]
  | EOuter _ -> Some "outer product is not an inlineable expression shape"
  | ETuple _ -> Some "tuple construction is not an inlineable expression shape"
  | EString _ -> Some "a string is not a rack value"
  | EIndex _ -> Some "indexing reads memory"
  | EConvert _ -> Some "a scalar conversion is not a rack operation"
  | EArray _ -> Some "array construction is not an inlineable expression shape"
  | ESlow _ -> Some "a slow block is a scalar escape, not fused vector work"
  | EIf (c, a, b) -> first_rejection [c; a; b]

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
  | SLoop ({ loop_repeat = true; _ } as l) ->
      if not (is_integer_literal l.loop_from && is_integer_literal l.loop_to) then
        type_errorf stmt.loc "repeat's bounds are integer literals";
      let body_env = { env with vars = Hashtbl.copy env.vars } in
      Hashtbl.replace body_env.vars l.loop_var (Scalar SInt);
      List.iter (fun s -> ignore (check_stmt body_env s)) l.loop_body;
      env
  | SUniform b ->
      if Hashtbl.mem env.vars b.bind_name then
        type_errorf stmt.loc "Cannot rebind '%s' (SSA violation, use := for mutable storage)" b.bind_name;
      let t = infer_expr env b.bind_expr in
      (match t with
       | Scalar _ -> ()
       | t -> type_errorf stmt.loc "<%s> is a uniform scalar, but its value is %s" b.bind_name (show_concise t));
      Option.iter (fun ty -> let d = typ_to_t env ty in if d <> t then type_errorf stmt.loc "Type mismatch: expected %s, got %s" (show_concise d) (show_concise t)) b.bind_type;
      Hashtbl.add env.vars b.bind_name t;
      env
  | SStore _ | SReturn _ | SYield _ | SBreak | SContinue | SIf _ | SWhile _ | SLoop _ ->
      type_errorf stmt.loc "%s is not available here"
        (Capabilities.id (Capabilities.feature_of_stmt stmt.v))

and check_over_result env statement_loc over =
  let count_t = infer_expr env over.over_count in
  (match count_t with
  | Scalar SInt | Scalar SInt64 -> ()
  | _ ->
      type_errorf over.over_count.loc
        "Over loop count must be scalar int/int64, got %s"
        (show_concise count_t));
  let chunk_t =
    match Hashtbl.find_opt env.vars over.over_stack with
    | Some (Stack (name, fields)) ->
        let domain = of_prim over.over_domain in
        Pack (name, List.map (traversal_field domain) fields)
    | Some t ->
        type_errorf statement_loc "Expected stack type, got %s" (show_concise t)
    | None -> type_errorf statement_loc "Undefined stack: %s" over.over_stack
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
      require_marked pred.loc l lt r rt;
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
  | ERecord (_, inits) | EStack (_, inits) ->
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
  | EString _ | EArray _ -> ()
  | ESlow _ -> type_errorf expr.loc "slow blocks belong to runs and slow functions, not a masked kernel"
  | EIndex (b, i, _) -> check_masked_expr env b; check_masked_expr env i
  | EConvert (_, _, e) -> check_masked_expr env e
  | EIf (c, a, b) -> check_masked_expr env c; check_masked_expr env a; check_masked_expr env b

and check_masked_stmt env (stmt: stmt) =
  match stmt.v with
  | SLet binding -> check_masked_expr env binding.bind_expr
  | SFused binding -> check_masked_expr env binding.fused_expr
  | SExpr expr -> check_masked_expr env expr
  | SLocBind _ | SAssign _ ->
      require_feature env stmt.loc Capabilities.Masked_mutation
  | SOver _ -> require_feature env stmt.loc Capabilities.Masked_loop
  | SLoop _ | SWhile _ -> require_feature env stmt.loc Capabilities.Masked_loop
  | SUniform _ | SStore _ | SReturn _ | SYield _ | SBreak | SContinue | SIf _ ->
      require_feature env stmt.loc Capabilities.Masked_mutation

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

(** Check scratch function definition *)
let check_scratch env _name params _result body loc =
  let env' = copy_env env in
  require_feature env' loc Capabilities.Scratch_implicit_result;

  List.iter (ensure_supported_scratch_param env' loc) params;
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
        type_errorf loc "a scratch must end with the expression that supplies its result"
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

(** C's reserved words. A scratch, rake or run is a C function with its own
    name, so its name can't be one of these. *)
let c_reserved_words =
  [ "auto"; "break"; "case"; "char"; "const"; "continue"; "default"; "do"; "double"; "else"; "enum";
    "extern"; "float"; "for"; "goto"; "if"; "inline"; "int"; "long"; "register"; "restrict"; "return";
    "short"; "signed"; "sizeof"; "static"; "struct"; "switch"; "typedef"; "union"; "unsigned"; "void";
    "volatile"; "while"; "bool"; "true"; "false"; "main" ]

(** Check a definition *)
let check_def env (def: def) =
  (match def.v with
   | DScratch (name, _, _, _) | DRake (name, _, _, _, _, _, _) | DRun (name, _, _, _)
     when List.mem name c_reserved_words ->
       type_errorf def.loc "'%s' is a C keyword, and vector code is a C function of its own name: choose another" name
   | _ -> ());
  match def.v with
  | DPack _ | DSingle _ | DType _ ->
      ()  (* already registered *)
  | DScratch (name, params, result, body) ->
      check_scratch env name params result body def.loc
  | DRake (name, params, result, setup, tines, throughs, sweep) ->
      check_rake env name params result setup tines throughs sweep def.loc
  | DRun (name, params, result, body) ->
      if not (run_needs_tier params result body) then check_run env name params result body def.loc
  | DRecord _ | DUnion _ | DSlow _ | DExtern _ | DState _ | DEmbed _ | DConst _ ->
      ()  (* the slow tier checks these (Tier) *)

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
