(** Legalization and instruction selection for x86-64 SIMD profiles. *)

module N = Native_ir
module M = X86_simd_mir

type error = { function_name : string; instruction : int option; message : string }

exception Selection_error of error

let format_error error =
  match error.instruction with
  | None -> Printf.sprintf "%s: x86 SIMD selection failed: %s" error.function_name error.message
  | Some index ->
      Printf.sprintf "%s: x86 SIMD selection failed at native instruction %d: %s"
        error.function_name index error.message

let fail function_name ?instruction message =
  raise (Selection_error { function_name; instruction; message })

let require_f32_rack function_name ?instruction description = function
  | N.Rack N.F32 -> ()
  | typ ->
      fail function_name ?instruction
        (Printf.sprintf "%s has type %s; x86 SIMD requires rack<f32>"
           description (N.string_of_typ typ))

let require_word_rack function_name ?instruction description = function
  | N.Rack (N.F32 | N.I32 | N.U32) -> ()
  | typ -> fail function_name ?instruction
      (Printf.sprintf "%s has type %s; x86 SIMD requires a rack of 32-bit lanes"
         description (N.string_of_typ typ))

let result function_name index (instruction : N.instruction) =
  match instruction.result with
  | Some result -> result
  | None -> fail function_name ~instruction:index "effect-only operations are not supported"

let literal_word_bits function_name index = function
  | N.Float32_bits bits | N.Int32 bits | N.Uint32 bits -> bits
  | literal ->
      fail function_name ~instruction:index
        ("uniform rack constant has unsupported element type " ^ N.string_of_literal literal)

let same_bits = function
  | [] -> None
  | ((N.Float32_bits bits | N.Int32 bits | N.Uint32 bits) as first) :: rest ->
      if List.for_all (( = ) first) rest then
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

let ensure_operand_i32 function_name environment index value =
  match find_type function_name environment index value with
  | N.Rack (N.I32 | N.U32) -> ()
  | typ -> fail function_name ~instruction:index
      (Printf.sprintf "operand %%%d has type %s; expected rack<i32> or rack<u32>" value (N.string_of_typ typ))

let ensure_mask function_name environment index value =
  match find_type function_name environment index value with
  | N.Mask -> ()
  | typ ->
      fail function_name ~instruction:index
        (Printf.sprintf "operand %%%d has type %s; expected an x86 vector mask" value
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
             && List.for_all (function
                  | N.Broadcast operand -> operand = id
                  | N.Insert { inserted; _ } -> inserted = id
                  | _ -> false) operations ->
          ()
      | _ ->
          fail function_name
            (Printf.sprintf
               "scalar f32 value %%%d is only legal as the direct input to rack.broadcast or rack.insert; scalarization is forbidden"
               id))
    constants

let select_function ?(profile = Target.X86_avx2) (func : N.func) =
  try
    (match N.verify_function func with
    | Ok () -> ()
    | Error errors ->
        fail func.name
          ("invalid native IR: " ^ String.concat "; " (List.map N.format_error errors)));
    List.iter
      (fun (parameter : N.parameter) ->
        match parameter.typ with
        | N.Rack (N.F32 | N.I32 | N.U32) | N.Scalar (N.F32 | N.I32 | N.U32 | N.I1) | N.Mask -> ()
        | typ ->
            fail func.name
              (Printf.sprintf "parameter %%%d has unsupported type %s; x86 kernels take 32-bit racks, masks, and f32/i32/u32/bool uniforms"
                 parameter.id (N.string_of_typ typ)))
      func.parameters;
    (match func.result with
    | None | Some (N.Rack (N.F32 | N.I32 | N.U32)) | Some (N.Scalar (N.F32 | N.I1 | N.I32 | N.U32)) | Some N.Mask -> ()
    | Some typ ->
        fail func.name
          ("unsupported result type " ^ N.string_of_typ typ
         ^ "; x86 SIMD selection cannot scalarize a rack result"));
    let environment = type_environment func in
    let constants = const_definitions func in
    let integer_constants = N.constant_i32_definitions func in
    let constant_uses = scalar_constant_uses func in
    validate_deferred_constants func.name constants constant_uses;
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
      let word_rack_result () =
        let dst, typ = result func.name index instruction in
        require_word_rack func.name ~instruction:index "result" typ;
        dst
      in
      match instruction.op with
      | N.Const (N.Float32_bits bits) ->
          let dst, _ = result func.name index instruction in
          let uses = Option.value ~default:[] (N.IntMap.find_opt dst constant_uses) in
          if List.exists (function N.Insert { inserted; _ } -> inserted = dst | _ -> false) uses then
            Some (M.Uniform_f32 { dst; bits; provenance })
          else None
      | N.Const (N.Int32 bits | N.Uint32 bits) ->
          let id, _ = result func.name index instruction in
          let returned = List.exists (function N.Return (Some value) -> value = id | _ -> false) func.body.terminators in
          (match N.IntMap.find_opt id constant_uses with
          | Some operations when not returned && operations <> []
              && List.for_all (function
                  | N.Extract { lane; _ } | N.Insert { lane; _ } -> lane = id
                  | N.Shift { count; _ } -> count = id
                  | _ -> false) operations -> None
          | _ -> Some (M.Uniform_f32 { dst = id; bits; provenance }))
      | N.Mask_const value ->
          let dst = mask_result () in
          Some (M.Uniform_mask { dst; value; provenance })
      | N.Const (N.Bool value) ->
          let dst, _ = result func.name index instruction in
          Some (M.Uniform_f32 { dst; bits = (if value then 1l else 0l); provenance })
      | N.Const literal ->
          fail func.name ~instruction:index
            ("scalar constant " ^ N.string_of_literal literal ^ " cannot occupy a vector rack register")
      | N.Rack_splat literal ->
          let dst = word_rack_result () in
          Some (M.Uniform_f32 { dst; bits = literal_word_bits func.name index literal; provenance })
      | N.Rack_const literals ->
          let dst = word_rack_result () in
          let lanes = (Target.info profile).f32_lanes in
          if List.length literals <> lanes then
            fail func.name ~instruction:index
              (Printf.sprintf "%s rack constant has %d lanes; exactly %d 32-bit lanes are required"
                 (Target.profile_name profile) (List.length literals) lanes);
          (match same_bits literals with
          | Some bits -> Some (M.Uniform_f32 { dst; bits; provenance })
          | None ->
              fail func.name ~instruction:index
                "non-uniform rack constants are not in the initial x86 SIMD selection contract")
      | N.Broadcast scalar when find_type func.name environment index scalar = N.Scalar N.I1 ->
          Some (M.Broadcast_bool { dst = mask_result (); source = scalar; provenance })
      | N.Broadcast scalar ->
          let dst = word_rack_result () in
          (match N.IntMap.find_opt scalar constants with
          | Some bits -> Some (M.Uniform_f32 { dst; bits; provenance })
          | None ->
              (match find_type func.name environment index scalar with
              | N.Scalar (N.F32 | N.I32 | N.U32) ->
                  Some (M.Broadcastss { dst; source = scalar; provenance })
              | typ ->
                  fail func.name ~instruction:index
                    (Printf.sprintf "rack.broadcast requires a 32-bit uniform, got %s"
                       (N.string_of_typ typ))))
      | N.Unary (N.Neg, source)
          when find_type func.name environment index source = N.Rack N.I32 ->
          let dst = word_rack_result () in
          Some (M.Neg_i32 { dst; source; provenance })
      | N.Unary (N.Neg, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          Some (M.Negps { dst; source; provenance })
      | N.Unary (N.Abs, source)
          when find_type func.name environment index source = N.Rack N.I32 ->
          let dst = word_rack_result () in
          Some (M.Abs_i32 { dst; source; provenance })
      | N.Unary (N.Abs, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          Some (M.Absps { dst; source; provenance })
      | N.Unary (N.Sqrt, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          Some (M.Sqrtps { dst; source; provenance })
      | N.Unary (((N.Floor | N.Ceil | N.Trunc | N.Nearest) as operation), source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          let mode = match operation with
            | N.Floor -> N.Toward_negative | N.Ceil -> N.Toward_positive
            | N.Trunc -> N.Toward_zero | N.Nearest -> N.Nearest_even
            | _ -> assert false in
          Some (M.Round_f32 { dst; source; mode; provenance })
      | N.Binary (((N.Add | N.Sub | N.Mul) as operation), left, right)
          when List.mem (find_type func.name environment index left) [ N.Rack N.I32; N.Rack N.U32 ] ->
          let dst = word_rack_result () in
          ensure_operand_i32 func.name environment index right;
          Some (match operation with
            | N.Add -> M.Add_i32 { dst; left; right; provenance }
            | N.Sub -> M.Sub_i32 { dst; left; right; provenance }
            | N.Mul -> M.Mul_i32 { dst; left; right; provenance }
            | _ -> assert false)
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
      | N.Binary (((N.Min | N.Max) as operation), left, right)
          when List.mem (find_type func.name environment index left) [N.Rack N.I32; N.Rack N.U32] ->
          let dst = word_rack_result () in
          ensure_operand_i32 func.name environment index right;
          Some (M.Extreme_i32 {
            dst; left; right;
            operation = (if operation = N.Min then M.Minimum else M.Maximum);
            unsigned = (find_type func.name environment index left = N.Rack N.U32);
            provenance;
          })
      | N.Binary (((N.Min | N.Max) as operation), left, right) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index left;
          ensure_operand_f32 func.name environment index right;
          Some (M.Extreme_f32 {
            dst; left; right;
            operation = (if operation = N.Min then M.Minimum else M.Maximum);
            provenance;
          })
      | N.Binary (((N.And | N.Andnot | N.Or | N.Xor) as operation), left, right) ->
          let dst = word_rack_result () in
          ensure_operand_i32 func.name environment index left;
          ensure_operand_i32 func.name environment index right;
          Some (match operation with
            | N.And -> M.Mask_andps { dst; left; right; provenance }
            | N.Andnot -> M.Mask_andnotps { dst; left; right; provenance }
            | N.Or -> M.Mask_orps { dst; left; right; provenance }
            | N.Xor -> M.Mask_xorps { dst; left; right; provenance }
            | _ -> assert false)
      | N.Shift { operand; count; shift } ->
          let dst = word_rack_result () in
          ensure_operand_i32 func.name environment index operand;
          (match Option.bind (N.IntMap.find_opt count integer_constants) N.I32_shift_count.of_int32 with
          | Some count -> Some (M.Shift_i32 { dst; source = operand; count; shift; provenance })
          | None -> fail func.name ~instruction:index
              "32-bit rack shifts require a literal count from 0 to 31; native uniform counts remain work in progress")
      | N.Fma (multiplicand, multiplier, addend) ->
          if profile = Target.X86_sse2 then
            fail func.name ~instruction:index
              "x86-sse2 has no fused multiply-add instruction; explicit fma cannot be replaced with separately rounded multiply and add";
          let dst = rack_result () in
          List.iter (ensure_operand_f32 func.name environment index)
            [ multiplicand; multiplier; addend ];
          Some (M.Fma_ps { dst; multiplicand; multiplier; addend; provenance })
      | N.Compare (predicate, left, right)
          when List.mem (find_type func.name environment index left) [ N.Rack N.I32; N.Rack N.U32 ] ->
          let dst = mask_result () in
          ensure_operand_i32 func.name environment index right;
          Some (M.Compare_i32 { dst; predicate; unsigned = (find_type func.name environment index left = N.Rack N.U32); left; right; provenance })
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
          let dst = word_rack_result () in
          ensure_mask func.name environment index condition;
          List.iter (fun value -> require_word_rack func.name ~instruction:index "selected operand"
              (find_type func.name environment index value)) [ if_true; if_false ];
          Some (M.Blendvps { dst; mask = condition; if_true; if_false; provenance })
      | N.Sanitize { mask; active; benign } ->
          let dst = word_rack_result () in
          ensure_mask func.name environment index mask;
          List.iter (fun value -> require_word_rack func.name ~instruction:index "sanitized operand"
            (find_type func.name environment index value)) [ active; benign ];
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
            "sqrt reached x86 SIMD selection as a call; native lowering must use Unary(Sqrt, value)"
      | N.Call { callee; _ } ->
          fail func.name ~instruction:index
            (Printf.sprintf "call @%s is forbidden in the initial leaf-function backend" callee)
      | N.Load _ | N.Store _ | N.Gather _ | N.Scatter _ ->
          fail func.name ~instruction:index
            "memory operations are not part of this isolated x86 SIMD register-selection slice"
      | N.Loop _ ->
          fail func.name ~instruction:index
            "loops are not part of this isolated x86 SIMD register-selection slice"
      | N.Reduce (((N.Reduce_add | N.Reduce_mul | N.Reduce_min | N.Reduce_max) as operation), source) ->
          let dst, typ = result func.name index instruction in
          if typ <> N.Scalar N.F32 then
            fail func.name ~instruction:index "f32 reduction must produce scalar<f32>";
          ensure_operand_f32 func.name environment index source;
          Some (M.Reduce_f32 { dst; source; operation; provenance })
      | N.Reduce (((N.Reduce_and | N.Reduce_or | N.Reduce_bitmask) as operation), source) ->
          let dst, _ = result func.name index instruction in
          ensure_mask func.name environment index source;
          let operation = match operation with
            | N.Reduce_and -> N.Mask_all | N.Reduce_or -> N.Mask_any
            | N.Reduce_bitmask -> N.Mask_bits | _ -> assert false in
          Some (M.Reduce_mask { dst; source; operation; provenance })
      | N.Scan (operation, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          Some (M.Scan_f32 { dst; source; operation; provenance })
      | N.Extract { rack; lane } ->
          let dst, typ = result func.name index instruction in
          let rack_type = find_type func.name environment index rack in
          require_word_rack func.name ~instruction:index "extraction input" rack_type;
          (match rack_type with
          | N.Rack element when typ = N.Scalar element -> ()
          | _ -> fail func.name ~instruction:index "extraction must preserve the lane's scalar type");
          (match N.IntMap.find_opt lane integer_constants with
          | Some lane when lane >= 0l && lane < Int32.of_int (Target.info profile).f32_lanes ->
              let lane = Option.get (M.word32_lane_of_int (Int32.to_int lane)) in
              Some (M.Extract_word32 { dst; source = rack; lane; provenance })
          | _ -> fail func.name ~instruction:index
              "extract requires a literal lane within the selected profile's rack")
      | N.Insert { rack; inserted; lane } ->
          let dst = word_rack_result () in
          let rack_type = find_type func.name environment index rack in
          require_word_rack func.name ~instruction:index "insertion input" rack_type;
          (match rack_type with
          | N.Rack element when find_type func.name environment index inserted = N.Scalar element -> ()
          | _ -> fail func.name ~instruction:index "insertion requires the lane's scalar type");
          (match N.IntMap.find_opt lane integer_constants with
          | Some lane when lane >= 0l && lane < Int32.of_int (Target.info profile).f32_lanes ->
              let lane = Option.get (M.word32_lane_of_int (Int32.to_int lane)) in
              Some (M.Insert_word32 { dst; previous = rack; inserted; lane; provenance })
          | _ -> fail func.name ~instruction:index
              "insert requires a literal lane within the selected profile's rack")
      | N.Shuffle { racks; indices } ->
          let dst = word_rack_result () in
          List.iter (fun rack -> require_word_rack func.name ~instruction:index "shuffle input"
            (find_type func.name environment index rack)) racks;
          let lanes = (Target.info profile).f32_lanes in
          if List.length indices <> lanes
              || List.exists (fun lane -> lane < 0 || lane >= lanes * List.length racks) indices then
            fail func.name ~instruction:index "shuffle indices must cover one rack and stay within its inputs";
          Some (M.Shuffle_word { dst; racks; indices; provenance })
      | N.Convert { operand; element = N.F32 } ->
          let dst = rack_result () in
          let conversion = match find_type func.name environment index operand with
            | N.Rack N.I32 -> N.I32_to_f32 | N.Rack N.U32 -> N.U32_to_f32
            | _ -> fail func.name ~instruction:index "float conversion requires a signed or unsigned 32-bit rack" in
          Some (M.Convert_word_f32 { dst; source = operand; conversion; provenance })
      | N.Convert { operand; element = (N.I32 | N.U32) as element } ->
          let dst = word_rack_result () in
          ensure_operand_f32 func.name environment index operand;
          let conversion = if element = N.U32 then N.F32_to_u32 else N.F32_to_i32 in
          Some (M.Convert_word_f32 { dst; source = operand; conversion; provenance })
      | N.Reinterpret { operand; element = (N.I32 | N.U32) } ->
          let dst = word_rack_result () in
          ensure_operand_i32 func.name environment index operand;
          Some (M.Copy_word { dst; source = operand; provenance })
      | N.Reinterpret _ | N.Relaxed _
      | N.Dot _ | N.Narrow _ | N.Widen _ | N.Convert _ ->
          fail func.name ~instruction:index
            "operation has no mapping in this native 32-bit rack profile"
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
            (fun (parameter : N.parameter) ->
              { M.reg = parameter.id; name = parameter.name;
                argument_class = (match parameter.typ with
                  | N.Scalar (N.I32 | N.U32) -> Native_register_assignment.Integer32
                  | N.Scalar N.I1 -> Native_register_assignment.Boolean
                  | _ -> Native_register_assignment.Vector) })
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

let select ?(profile = Target.X86_avx2) module_ =
  let rec loop selected = function
    | [] -> Ok (List.rev selected)
    | func :: rest -> (
        match select_function ~profile func with
        | Ok selected_function -> loop (selected_function :: selected) rest
        | Error _ as error -> error)
  in
  loop [] module_
