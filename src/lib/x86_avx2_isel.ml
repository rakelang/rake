(** Legalization and instruction selection for [x86_64-avx2-fma]. *)

module N = Native_ir
module M = X86_avx2_mir

type error = { function_name : string; instruction : int option; message : string }

exception Selection_error of error

let format_error error =
  match error.instruction with
  | None -> Printf.sprintf "%s: AVX2 selection failed: %s" error.function_name error.message
  | Some index ->
      Printf.sprintf "%s: AVX2 selection failed at native instruction %d: %s"
        error.function_name index error.message

let fail function_name ?instruction message =
  raise (Selection_error { function_name; instruction; message })

let require_f32_rack function_name ?instruction description = function
  | N.Rack N.F32 -> ()
  | typ ->
      fail function_name ?instruction
        (Printf.sprintf "%s has type %s; x86_64-avx2-fma requires rack<f32>"
           description (N.string_of_typ typ))

let result function_name index (instruction : N.instruction) =
  match instruction.result with
  | Some result -> result
  | None -> fail function_name ~instruction:index "effect-only operations are not supported"

let literal_f32 function_name index = function
  | N.Float32_bits bits -> bits
  | literal ->
      fail function_name ~instruction:index
        ("uniform rack constant has unsupported element type " ^ N.string_of_literal literal)

let same_bits = function
  | [] -> None
  | N.Float32_bits bits :: rest ->
      if List.for_all (function N.Float32_bits other -> other = bits | _ -> false) rest then
        Some bits
      else None
  | _ -> None

let type_environment (func : N.func) =
  let add_result environment (instruction : N.instruction) =
    match instruction.result with
    | None -> environment
    | Some (id, typ) -> N.IntMap.add id typ environment
  in
  List.fold_left add_result
    (List.fold_left
       (fun environment (parameter : N.parameter) ->
         N.IntMap.add parameter.id parameter.typ environment)
       N.IntMap.empty func.parameters)
    func.body.instructions

let find_type function_name environment index value =
  match N.IntMap.find_opt value environment with
  | Some typ -> typ
  | None -> fail function_name ~instruction:index (Printf.sprintf "unknown native value %%%d" value)

let ensure_operand_f32 function_name environment index value =
  require_f32_rack function_name ~instruction:index
    (Printf.sprintf "operand %%%d" value)
    (find_type function_name environment index value)

let ensure_mask function_name environment index value =
  match find_type function_name environment index value with
  | N.Mask -> ()
  | typ ->
      fail function_name ~instruction:index
        (Printf.sprintf "operand %%%d has type %s; expected an AVX2 YMM mask" value
           (N.string_of_typ typ))

let const_definitions (func : N.func) =
  List.fold_left
    (fun constants (instruction : N.instruction) ->
      match (instruction.result, instruction.op) with
      | Some (id, N.Scalar N.F32), N.Const (N.Float32_bits bits) -> N.IntMap.add id bits constants
      | _ -> constants)
    N.IntMap.empty func.body.instructions

let scalar_constant_uses (func : N.func) =
  List.fold_left
    (fun uses (instruction : N.instruction) ->
      List.fold_left
        (fun uses operand ->
          let previous = Option.value ~default:[] (N.IntMap.find_opt operand uses) in
          N.IntMap.add operand (instruction.op :: previous) uses)
        uses (N.operands instruction.op))
    N.IntMap.empty func.body.instructions

let validate_deferred_constants function_name constants uses =
  N.IntMap.iter
    (fun id _ ->
      match N.IntMap.find_opt id uses with
      | Some operations
        when operations <> []
             && List.for_all (function N.Broadcast operand -> operand = id | _ -> false) operations ->
          ()
      | _ ->
          fail function_name
            (Printf.sprintf
               "scalar f32 value %%%d is only legal as the direct input to rack.broadcast; scalarization is forbidden"
               id))
    constants

let select_function (func : N.func) =
  try
    (match N.verify_function func with
    | Ok () -> ()
    | Error errors ->
        fail func.name
          ("invalid native IR: " ^ String.concat "; " (List.map N.format_error errors)));
    List.iter
      (fun (parameter : N.parameter) ->
        match parameter.typ with
        | N.Rack N.F32 | N.Scalar N.F32 | N.Mask -> ()
        | typ ->
            fail func.name
              (Printf.sprintf "parameter %%%d has unsupported type %s; only rack<f32>, scalar<f32>, and mask parameters use the AVX2 SSE-class boundary"
                 parameter.id (N.string_of_typ typ)))
      func.parameters;
    (match func.result with
    | None | Some (N.Rack N.F32) | Some (N.Scalar N.F32) | Some N.Mask -> ()
    | Some typ ->
        fail func.name
          ("unsupported result type " ^ N.string_of_typ typ
         ^ "; AVX2 selection cannot scalarize a rack result"));
    let environment = type_environment func in
    let constants = const_definitions func in
    validate_deferred_constants func.name constants (scalar_constant_uses func);
    let select index (instruction : N.instruction) =
      let provenance = instruction.provenance in
      let rack_result () =
        let dst, typ = result func.name index instruction in
        require_f32_rack func.name ~instruction:index "result" typ;
        dst
      in
      let mask_result () =
        match result func.name index instruction with
        | dst, N.Mask -> dst
        | _, typ ->
            fail func.name ~instruction:index
              ("operation requires a mask result, found " ^ N.string_of_typ typ)
      in
      match instruction.op with
      | N.Const (N.Float32_bits _) -> None
      | N.Mask_const value ->
          let dst = mask_result () in
          Some (M.Uniform_mask { dst; value; provenance })
      | N.Const literal ->
          fail func.name ~instruction:index
            ("scalar constant " ^ N.string_of_literal literal ^ " cannot occupy a YMM rack register")
      | N.Rack_splat literal ->
          let dst = rack_result () in
          Some (M.Uniform_f32 { dst; bits = literal_f32 func.name index literal; provenance })
      | N.Rack_const literals ->
          let dst = rack_result () in
          if List.length literals <> 8 then
            fail func.name ~instruction:index
              (Printf.sprintf "AVX2 rack constant has %d lanes; exactly 8 f32 lanes are required"
                 (List.length literals));
          (match same_bits literals with
          | Some bits -> Some (M.Uniform_f32 { dst; bits; provenance })
          | None ->
              fail func.name ~instruction:index
                "non-uniform rack constants are not in the initial AVX2 selection contract")
      | N.Broadcast scalar ->
          let dst = rack_result () in
          (match N.IntMap.find_opt scalar constants with
          | Some bits -> Some (M.Uniform_f32 { dst; bits; provenance })
          | None ->
              (match find_type func.name environment index scalar with
              | N.Scalar N.F32 ->
                  Some (M.Broadcastss { dst; source = scalar; provenance })
              | typ ->
                  fail func.name ~instruction:index
                    (Printf.sprintf "rack.broadcast requires scalar<f32>, got %s"
                       (N.string_of_typ typ))))
      | N.Unary (N.Neg, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          Some (M.Negps { dst; source; provenance })
      | N.Unary (N.Sqrt, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          Some (M.Sqrtps { dst; source; provenance })
      | N.Binary (((N.Add | N.Sub | N.Mul | N.Div) as operation), left, right) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index left;
          ensure_operand_f32 func.name environment index right;
          Some
            (match operation with
            | N.Add -> M.Addps { dst; left; right; provenance }
            | N.Sub -> M.Subps { dst; left; right; provenance }
            | N.Mul -> M.Mulps { dst; left; right; provenance }
            | N.Div -> M.Divps { dst; left; right; provenance }
            | _ -> assert false)
      | N.Binary ((N.Min | N.Max | N.And | N.Or | N.Xor), _, _) ->
          fail func.name ~instruction:index
            "operation has no strict f32-rack mapping in the initial AVX2 contract"
      | N.Fma (multiplicand, multiplier, addend) ->
          let dst = rack_result () in
          List.iter (ensure_operand_f32 func.name environment index)
            [ multiplicand; multiplier; addend ];
          Some (M.Fma_ps { dst; multiplicand; multiplier; addend; provenance })
      | N.Compare (comparison, left, right) ->
          let dst = mask_result () in
          ensure_operand_f32 func.name environment index left;
          ensure_operand_f32 func.name environment index right;
          let predicate, left, right =
            match comparison with
            | N.Eq -> (M.Oeq, left, right)
            | N.Ne -> (M.One, left, right)
            | N.Lt -> (M.Olt, left, right)
            | N.Le -> (M.Ole, left, right)
            | N.Gt -> (M.Olt, right, left)
            | N.Ge -> (M.Ole, right, left)
          in
          Some (M.Cmpps { dst; predicate; left; right; provenance })
      | N.Select { condition; if_true; if_false } ->
          let dst = rack_result () in
          ensure_mask func.name environment index condition;
          ensure_operand_f32 func.name environment index if_true;
          ensure_operand_f32 func.name environment index if_false;
          Some (M.Blendvps { dst; mask = condition; if_true; if_false; provenance })
      | N.Sanitize { mask; active; benign } ->
          let dst = rack_result () in
          ensure_mask func.name environment index mask;
          ensure_operand_f32 func.name environment index active;
          ensure_operand_f32 func.name environment index benign;
          Some (M.Blendvps { dst; mask; if_true = active; if_false = benign; provenance })
      | N.Mask_binary (((N.And | N.Or | N.Xor) as operation), left, right) ->
          let dst = mask_result () in
          ensure_mask func.name environment index left;
          ensure_mask func.name environment index right;
          Some
            (match operation with
            | N.And -> M.Mask_andps { dst; left; right; provenance }
            | N.Or -> M.Mask_orps { dst; left; right; provenance }
            | N.Xor -> M.Mask_xorps { dst; left; right; provenance }
            | _ -> assert false)
      | N.Mask_binary _ ->
          fail func.name ~instruction:index "mask arithmetic must be and, or, or xor"
      | N.Mask_not source ->
          let dst = mask_result () in
          ensure_mask func.name environment index source;
          Some (M.Mask_notps { dst; source; provenance })
      | N.Call { callee = "sqrt"; _ } ->
          fail func.name ~instruction:index
            "sqrt reached AVX2 selection as a call; native lowering must use Unary(Sqrt, value)"
      | N.Call { callee; _ } ->
          fail func.name ~instruction:index
            (Printf.sprintf "call @%s is forbidden in the initial leaf-function backend" callee)
      | N.Load _ | N.Store _ | N.Gather _ | N.Scatter _ ->
          fail func.name ~instruction:index
            "memory operations are not part of this isolated AVX2 register-selection slice"
      | N.Loop _ ->
          fail func.name ~instruction:index
            "loops are not part of this isolated AVX2 register-selection slice"
      | N.Reduce (((N.Reduce_add | N.Reduce_mul | N.Reduce_min | N.Reduce_max) as operation), source) ->
          let dst, typ = result func.name index instruction in
          if typ <> N.Scalar N.F32 then
            fail func.name ~instruction:index "f32 reduction must produce scalar<f32>";
          ensure_operand_f32 func.name environment index source;
          Some (M.Reduce_f32 { dst; source; operation; provenance })
      | N.Reduce ((N.Reduce_and | N.Reduce_or), _) ->
          fail func.name ~instruction:index
            "logical mask reductions are not implemented by the AVX2 f32 slice"
      | N.Scan (operation, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          Some (M.Scan_f32 { dst; source; operation; provenance })
      | N.Shuffle _ | N.Extract _ | N.Insert _ ->
          fail func.name ~instruction:index
            "cross-lane operation is unavailable in the initial AVX2 selection contract"
    in
    let instructions = List.filter_map Fun.id (List.mapi select func.body.instructions) in
    let result =
      match func.body.terminators with
      | [ N.Return result ] -> result
      | _ -> fail func.name "native function must have exactly one return terminator"
    in
    Ok
      {
        M.name = func.name;
        loc = func.loc;
        parameters =
          List.map
            (fun (parameter : N.parameter) -> { M.reg = parameter.id; name = parameter.name })
            func.parameters;
        instructions;
        result;
        result_type = func.result;
        value_locations =
          List.filter_map
            (fun (instruction : N.instruction) ->
              Option.map (fun (id, _) -> (id, instruction.loc)) instruction.result)
            func.body.instructions;
      }
  with Selection_error error -> Error error

let select module_ =
  let rec loop selected = function
    | [] -> Ok (List.rev selected)
    | func :: rest -> (
        match select_function func with
        | Ok selected_function -> loop (selected_function :: selected) rest
        | Error _ as error -> error)
  in
  loop [] module_
