(** Legalization and instruction selection for [aarch64-neon-aapcs64]. *)

module N = Native_ir
module M = Aarch64_neon_mir

type error = { function_name : string; instruction : int option; message : string }
exception Selection_error of error

let format_error error =
  match error.instruction with
  | None -> Printf.sprintf "%s: NEON selection failed: %s" error.function_name error.message
  | Some index ->
      Printf.sprintf "%s: NEON selection failed at native instruction %d: %s"
        error.function_name index error.message

let fail function_name ?instruction message =
  raise (Selection_error { function_name; instruction; message })

let require_f32_rack function_name ?instruction description = function
  | N.Rack N.F32 -> ()
  | typ ->
      fail function_name ?instruction
        (Printf.sprintf "%s has type %s; aarch64-neon requires rack<f32>"
           description (N.string_of_typ typ))

let require_word_rack function_name ?instruction description = function
  | N.Rack (N.F32 | N.I32 | N.U32) -> ()
  | typ -> fail function_name ?instruction
      (Printf.sprintf "%s has type %s; NEON requires a rack of 32-bit lanes"
         description (N.string_of_typ typ))

let result function_name index (instruction : N.instruction) =
  match instruction.result with
  | Some result -> result
  | None -> fail function_name ~instruction:index "effect-only operations are not supported"

let literal_word_bits function_name index = function
  | N.Float32_bits bits | N.Int32 bits | N.Uint32 bits -> bits
  | literal ->
      fail function_name ~instruction:index
        ("uniform rack constant has unsupported element type "
        ^ N.string_of_literal literal)

let same_bits = function
  | [] -> None
  | ((N.Float32_bits bits | N.Int32 bits | N.Uint32 bits) as first) :: rest ->
      if List.for_all (( = ) first) rest
      then Some bits
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
  | None ->
      fail function_name ~instruction:index
        (Printf.sprintf "unknown native value %%%d" value)

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
        (Printf.sprintf "operand %%%d has type %s; expected a four-lane NEON mask"
           value (N.string_of_typ typ))

let const_definitions (func : N.func) =
  List.fold_left
    (fun constants (instruction : N.instruction) ->
      match (instruction.result, instruction.op) with
      | Some (id, N.Scalar N.F32), N.Const (N.Float32_bits bits) ->
          N.IntMap.add id bits constants
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
             && List.for_all
                  (function
                    | N.Broadcast operand -> operand = id
                    | N.Insert { inserted; _ } -> inserted = id
                    | _ -> false)
                  operations ->
          ()
      | _ ->
          fail function_name
            (Printf.sprintf
               "scalar f32 value %%%d is only legal as the direct input to rack.broadcast or rack.insert; scalarization is forbidden"
               id))
    constants

let next_virtual (func : N.func) =
  let maximum = ref (-1) in
  let see value = maximum := max !maximum value in
  List.iter (fun (parameter : N.parameter) -> see parameter.id) func.parameters;
  List.iter
    (fun (instruction : N.instruction) ->
      Option.iter (fun (id, _) -> see id) instruction.result;
      List.iter see (N.operands instruction.op))
    func.body.instructions;
  ref (!maximum + 1)

let select_function (func : N.func) =
  try
    (match N.verify_function ~floating_point_exceptions:true func with
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
              (Printf.sprintf
                 "parameter %%%d has unsupported type %s; NEON kernels take 32-bit racks, masks, and f32/i32/u32/bool uniforms"
                 parameter.id (N.string_of_typ typ)))
      func.parameters;
    (match func.result with
    | None | Some (N.Rack (N.F32 | N.I32 | N.U32)) | Some (N.Scalar (N.F32 | N.I1 | N.I32 | N.U32)) | Some N.Mask -> ()
    | Some typ ->
        fail func.name
          ("unsupported result type " ^ N.string_of_typ typ
         ^ "; NEON selection cannot scalarize a rack result"));
    let environment = type_environment func in
    let constants = const_definitions func in
    let integer_constants = N.constant_i32_definitions func in
    let constant_uses = scalar_constant_uses func in
    validate_deferred_constants func.name constants constant_uses;
    let next = next_virtual func in
    let internal_locations = ref [] in
    let fresh loc =
      let value = !next in
      incr next;
      internal_locations := (value, loc) :: !internal_locations;
      value
    in
    let fold_rack ~scan operation ~dst ~source ~loc ~provenance =
      (* Keep the specified left fold. Pairwise/tree instructions would change
         binary32 rounding. Every intermediate is a complete vector register. *)
      let initial = fresh loc in
      let strict_extreme = operation = N.Reduce_min || operation = N.Reduce_max in
      let canonical_nan = if strict_extreme then Some (fresh loc) else None in
      let combine prefix lane combined =
        match operation, canonical_nan with
        | N.Reduce_add, _ -> [ M.Fadd { dst = combined; left = prefix; right = lane; provenance } ]
        | N.Reduce_mul, _ -> [ M.Fmul { dst = combined; left = prefix; right = lane; provenance } ]
        | (N.Reduce_min | N.Reduce_max), Some nan ->
            let candidate = fresh loc and ordered = fresh loc in
            [ (if operation = N.Reduce_min then M.Fmin { dst = candidate; left = prefix; right = lane; provenance }
               else M.Fmax { dst = candidate; left = prefix; right = lane; provenance });
              M.Compare { dst = ordered; predicate = M.Ceq; left = candidate; right = candidate; provenance };
              M.Select { dst = combined; mask = ordered; if_true = candidate; if_false = nan; provenance } ]
        | _ -> invalid_arg "NEON float fold requires an arithmetic reduction"
      in
      let rec steps prefix previous = function
        | [] -> []
        | lane_index :: rest ->
            let lane = fresh loc in
            let combined = if rest = [] && not scan then dst else fresh loc in
            let accumulated = if not scan then previous else if rest = [] then dst else fresh loc in
            [ M.Broadcast_word32 { dst = lane; source; lane = lane_index; provenance } ]
            @ combine prefix lane combined
            @ (if scan then [ M.Insert_word32 { dst = accumulated; previous; inserted = combined; lane = lane_index; provenance } ] else [])
            @ steps combined accumulated rest
      in
      [ M.Broadcast_word32 { dst = initial; source; lane = M.Lane0; provenance } ]
      @ (match canonical_nan with None -> [] | Some dst -> [ M.Uniform_f32 { dst; bits = 0x7fc00000l; provenance } ])
      @ steps initial source [ M.Lane1; M.Lane2; M.Lane3 ]
    in
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
            [ M.Uniform_f32 { dst; bits; provenance } ]
          else []
      | N.Const (N.Int32 bits | N.Uint32 bits) ->
          let id, _ = result func.name index instruction in
          let returned = List.exists (function N.Return (Some value) -> value = id | _ -> false) func.body.terminators in
          (match N.IntMap.find_opt id constant_uses with
          | Some operations when not returned && operations <> []
              && List.for_all (function
                  | N.Extract { lane; _ } | N.Insert { lane; _ } -> lane = id
                  | N.Shift { count; _ } -> count = id
                  | _ -> false) operations -> []
          | _ -> [ M.Uniform_f32 { dst = id; bits; provenance } ])
      | N.Const (N.Bool value) ->
          let dst, _ = result func.name index instruction in
          [ M.Uniform_f32 { dst; bits = (if value then 1l else 0l); provenance } ]
      | N.Const literal ->
          fail func.name ~instruction:index
            ("scalar constant " ^ N.string_of_literal literal
           ^ " cannot occupy a NEON rack register")
      | N.Mask_const value ->
          [ M.Mask_const { dst = mask_result (); value; provenance } ]
      | N.Rack_splat literal ->
          [ M.Uniform_f32
              { dst = word_rack_result (); bits = literal_word_bits func.name index literal; provenance } ]
      | N.Rack_const literals ->
          let dst = word_rack_result () in
          if List.length literals <> 4 then
            fail func.name ~instruction:index
              (Printf.sprintf
                 "NEON rack constant has %d lanes; exactly 4 32-bit lanes are required"
                 (List.length literals));
          (match same_bits literals with
          | Some bits -> [ M.Uniform_f32 { dst; bits; provenance } ]
          | None ->
              fail func.name ~instruction:index
                "non-uniform rack constants are not in the initial NEON selection contract")
      | N.Broadcast scalar when find_type func.name environment index scalar = N.Scalar N.I1 ->
          [ M.Broadcast_bool { dst = mask_result (); source = scalar; provenance } ]
      | N.Broadcast scalar ->
          let dst = word_rack_result () in
          (match N.IntMap.find_opt scalar constants with
          | Some bits -> [ M.Uniform_f32 { dst; bits; provenance } ]
          | None -> (
              match find_type func.name environment index scalar with
              | N.Scalar (N.F32 | N.I32 | N.U32) ->
                  [ M.Broadcast_word32 { dst; source = scalar; lane = M.Lane0; provenance } ]
              | typ ->
                  fail func.name ~instruction:index
                    (Printf.sprintf "rack.broadcast requires a 32-bit uniform, got %s"
                       (N.string_of_typ typ))))
      | N.Unary (N.Neg, source)
          when find_type func.name environment index source = N.Rack N.I32 ->
          let dst = word_rack_result () in
          [ M.Neg_i32 { dst; source; provenance } ]
      | N.Unary (N.Neg, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          let sign = fresh instruction.loc in
          [ M.Uniform_f32 { dst = sign; bits = Int32.min_int; provenance };
            M.Eor { dst; left = source; right = sign; provenance } ]
      | N.Unary (N.Abs, source)
          when find_type func.name environment index source = N.Rack N.I32 ->
          let dst = word_rack_result () in
          [ M.Abs_i32 { dst; source; provenance } ]
      | N.Unary (N.Abs, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          let magnitude = fresh instruction.loc in
          [ M.Uniform_f32 { dst = magnitude; bits = Int32.max_int; provenance };
            M.And { dst; left = source; right = magnitude; provenance } ]
      | N.Unary (N.Sqrt, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          [ M.Fsqrt { dst; source; provenance } ]
      | N.Unary (((N.Floor | N.Ceil | N.Trunc | N.Nearest) as operation), source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          let mode = match operation with
            | N.Floor -> N.Toward_negative | N.Ceil -> N.Toward_positive
            | N.Trunc -> N.Toward_zero | N.Nearest -> N.Nearest_even
            | _ -> assert false in
          [ M.Round_f32 { dst; source; mode; provenance } ]
      | N.Binary (((N.Add | N.Sub | N.Mul) as operation), left, right)
          when List.mem (find_type func.name environment index left) [ N.Rack N.I32; N.Rack N.U32 ] ->
          let dst = word_rack_result () in
          ensure_operand_i32 func.name environment index right;
          [ (match operation with
            | N.Add -> M.Add_i32 { dst; left; right; provenance }
            | N.Sub -> M.Sub_i32 { dst; left; right; provenance }
            | N.Mul -> M.Mul_i32 { dst; left; right; provenance }
            | _ -> assert false) ]
      | N.Binary (((N.Add | N.Sub | N.Mul | N.Div) as operation), left, right) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index left;
          ensure_operand_f32 func.name environment index right;
          [ (match operation with
            | N.Add -> M.Fadd { dst; left; right; provenance }
            | N.Sub -> M.Fsub { dst; left; right; provenance }
            | N.Mul -> M.Fmul { dst; left; right; provenance }
            | N.Div -> M.Fdiv { dst; left; right; provenance }
            | _ -> assert false) ]
      | N.Binary (((N.Min | N.Max) as operation), left, right)
          when List.mem (find_type func.name environment index left) [N.Rack N.I32; N.Rack N.U32] ->
          let dst = word_rack_result () in
          ensure_operand_i32 func.name environment index right;
          let unsigned = find_type func.name environment index left = N.Rack N.U32 in
          [ (if operation = N.Min then M.Min_i32 { dst; left; right; unsigned; provenance }
             else M.Max_i32 { dst; left; right; unsigned; provenance }) ]
      | N.Binary (((N.Min | N.Max) as operation), left, right) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index left;
          ensure_operand_f32 func.name environment index right;
          [ (if operation = N.Min then M.Fmin { dst; left; right; provenance }
             else M.Fmax { dst; left; right; provenance }) ]
      | N.Binary (((N.And | N.Andnot | N.Or | N.Xor) as operation), left, right) ->
          let dst = word_rack_result () in
          ensure_operand_i32 func.name environment index left;
          ensure_operand_i32 func.name environment index right;
          [ (match operation with
            | N.And -> M.And { dst; left; right; provenance }
            | N.Andnot -> M.Bic { dst; left; right; provenance }
            | N.Or -> M.Orr { dst; left; right; provenance }
            | N.Xor -> M.Eor { dst; left; right; provenance }
            | _ -> assert false) ]
      | N.Shift { operand; count; shift } ->
          let dst = word_rack_result () in
          ensure_operand_i32 func.name environment index operand;
          (match Option.bind (Option.map (fun bits -> Int32.logand bits 31l)
              (N.IntMap.find_opt count integer_constants)) N.I32_shift_count.of_int32 with
          | Some count -> [ M.Shift_i32 { dst; source = operand; count; shift; provenance } ]
          | None ->
              (match find_type func.name environment index count with
              | N.Scalar N.U32 -> [ M.Shift_uniform_i32 { dst; source = operand; count; shift; provenance } ]
              | _ -> fail func.name ~instruction:index
                  "32-bit rack shifts require a literal count from 0 to 31 or a uniform u32"))
      | N.Fma (multiplicand, multiplier, addend) ->
          let dst = rack_result () in
          List.iter (ensure_operand_f32 func.name environment index)
            [ multiplicand; multiplier; addend ];
          [ M.Fma { dst; multiplicand; multiplier; addend; provenance } ]
      | N.Compare (predicate, left, right)
          when List.mem (find_type func.name environment index left) [ N.Rack N.I32; N.Rack N.U32 ] ->
          let dst = mask_result () in
          ensure_operand_i32 func.name environment index right;
          [ M.Compare_i32 { dst; predicate; unsigned = (find_type func.name environment index left = N.Rack N.U32); left; right; provenance } ]
      | N.Compare (comparison, left, right) ->
          let dst = mask_result () in
          ensure_operand_f32 func.name environment index left;
          ensure_operand_f32 func.name environment index right;
          if comparison = N.Eq then
            [ M.Compare { dst; predicate = M.Ceq; left; right; provenance } ]
          else (
            (* FCMEQ is quiet for QNaN; FCMGT/FCMGE are signaling. Clear
               unordered operands before the comparison and mask its result,
               keeping every ordered condition false for either NaN. *)
            let left_ordered = fresh instruction.loc in
            let right_ordered = fresh instruction.loc in
            let ordered = fresh instruction.loc in
            let safe_left = fresh instruction.loc in
            let safe_right = fresh instruction.loc in
            let compared = fresh instruction.loc in
            let predicate, comparison_left, comparison_right = match comparison with
              | N.Lt -> M.Cgt, safe_right, safe_left
              | N.Le -> M.Cge, safe_right, safe_left
              | N.Gt -> M.Cgt, safe_left, safe_right
              | N.Ge -> M.Cge, safe_left, safe_right
              | N.Ne -> M.Ceq, safe_left, safe_right
              | N.Eq -> assert false in
            let different = if comparison = N.Ne then fresh instruction.loc else compared in
            [ M.Compare { dst = left_ordered; predicate = M.Ceq; left; right = left; provenance };
              M.Compare { dst = right_ordered; predicate = M.Ceq; left = right; right; provenance };
              M.And { dst = ordered; left = left_ordered; right = right_ordered; provenance };
              M.And { dst = safe_left; left; right = ordered; provenance };
              M.And { dst = safe_right; left = right; right = ordered; provenance };
              M.Compare { dst = compared; predicate; left = comparison_left; right = comparison_right; provenance } ]
            @ (if comparison = N.Ne then [ M.Mvn { dst = different; source = compared; provenance } ] else [])
            @ [ M.And { dst; left = different; right = ordered; provenance } ])
      | N.Select { condition; if_true; if_false } ->
          let dst = word_rack_result () in
          ensure_mask func.name environment index condition;
          List.iter (fun value -> require_word_rack func.name ~instruction:index "selected operand"
              (find_type func.name environment index value)) [ if_true; if_false ];
          [ M.Select { dst; mask = condition; if_true; if_false; provenance } ]
      | N.Sanitize { mask; active; benign } ->
          let dst = word_rack_result () in
          ensure_mask func.name environment index mask;
          List.iter (fun value -> require_word_rack func.name ~instruction:index "sanitized operand"
            (find_type func.name environment index value)) [ active; benign ];
          [ M.Select
              { dst; mask; if_true = active; if_false = benign; provenance } ]
      | N.Mask_binary (((N.And | N.Or | N.Xor) as operation), left, right) ->
          let dst = mask_result () in
          ensure_mask func.name environment index left;
          ensure_mask func.name environment index right;
          [ (match operation with
            | N.And -> M.And { dst; left; right; provenance }
            | N.Or -> M.Orr { dst; left; right; provenance }
            | N.Xor -> M.Eor { dst; left; right; provenance }
            | _ -> assert false) ]
      | N.Mask_binary _ ->
          fail func.name ~instruction:index "mask arithmetic must be and, or, or xor"
      | N.Mask_not source ->
          let dst = mask_result () in
          ensure_mask func.name environment index source;
          [ M.Mvn { dst; source; provenance } ]
      | N.Reduce (((N.Reduce_add | N.Reduce_mul | N.Reduce_min | N.Reduce_max) as operation), source) ->
          let dst, _ = result func.name index instruction in
          ensure_operand_f32 func.name environment index source;
          fold_rack ~scan:false operation ~dst ~source ~loc:instruction.loc ~provenance
      | N.Reduce (((N.Reduce_and | N.Reduce_or | N.Reduce_bitmask) as operation), source) ->
          let dst, _ = result func.name index instruction in
          ensure_mask func.name environment index source;
          let operation = match operation with
            | N.Reduce_and -> N.Mask_all | N.Reduce_or -> N.Mask_any
            | N.Reduce_bitmask -> N.Mask_bits | _ -> assert false in
          [ M.Reduce_mask { dst; source; operation; provenance } ]
      | N.Scan (operation, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          let operation = match operation with
            | N.Scan_add -> N.Reduce_add | N.Scan_mul -> N.Reduce_mul
            | N.Scan_min -> N.Reduce_min | N.Scan_max -> N.Reduce_max in
          fold_rack ~scan:true operation ~dst ~source ~loc:instruction.loc ~provenance
      | N.Call { callee = "sqrt"; _ } ->
          fail func.name ~instruction:index
            "sqrt reached NEON selection as a call; native lowering must use Unary(Sqrt, value)"
      | N.Call { callee; _ } ->
          fail func.name ~instruction:index
            (Printf.sprintf "call @%s is forbidden in the initial leaf-function backend" callee)
      | N.Load _ | N.Store _ | N.Gather _ | N.Scatter _ ->
          fail func.name ~instruction:index
            "memory operations are not part of this isolated NEON register-selection slice"
      | N.Loop _ ->
          fail func.name ~instruction:index
            "loops are not part of this isolated NEON register-selection slice"
      | N.Extract { rack; lane } ->
          let dst, typ = result func.name index instruction in
          let rack_type = find_type func.name environment index rack in
          require_word_rack func.name ~instruction:index "extraction input" rack_type;
          (match rack_type with
          | N.Rack element when typ = N.Scalar element -> ()
          | _ -> fail func.name ~instruction:index "extraction must preserve the lane's scalar type");
          let lane = match N.IntMap.find_opt lane integer_constants with
            | Some 0l -> M.Lane0 | Some 1l -> M.Lane1
            | Some 2l -> M.Lane2 | Some 3l -> M.Lane3
            | _ -> fail func.name ~instruction:index
                "extract requires a literal lane within the four-lane NEON rack" in
          [ M.Broadcast_word32 { dst; source = rack; lane; provenance } ]
      | N.Insert { rack; inserted; lane } ->
          let dst = word_rack_result () in
          let rack_type = find_type func.name environment index rack in
          require_word_rack func.name ~instruction:index "insertion input" rack_type;
          (match rack_type with
          | N.Rack element when find_type func.name environment index inserted = N.Scalar element -> ()
          | _ -> fail func.name ~instruction:index "insertion requires the lane's scalar type");
          let lane = match N.IntMap.find_opt lane integer_constants with
            | Some 0l -> M.Lane0 | Some 1l -> M.Lane1
            | Some 2l -> M.Lane2 | Some 3l -> M.Lane3
            | _ -> fail func.name ~instruction:index
                "insert requires a literal lane within the four-lane NEON rack" in
          [ M.Insert_word32 { dst; previous = rack; inserted; lane; provenance } ]
      | N.Shuffle { racks; indices } ->
          let dst = word_rack_result () in
          List.iter (fun rack -> require_word_rack func.name ~instruction:index "shuffle input"
            (find_type func.name environment index rack)) racks;
          if List.length indices <> 4
              || List.exists (fun lane -> lane < 0 || lane >= 4 * List.length racks) indices then
            fail func.name ~instruction:index "shuffle indices must cover four lanes and stay within its inputs";
          let selected lane =
            let input = List.nth indices lane in
            let element = match input mod 4 with
              | 0 -> M.Lane0 | 1 -> M.Lane1 | 2 -> M.Lane2 | _ -> M.Lane3 in
            List.nth racks (input / 4), element in
          let initial = fresh instruction.loc in
          let source, lane = selected 0 in
          let rec steps previous = function
            | [] -> []
            | output_lane :: rest ->
                let index = M.word32_lane_index output_lane in
                let source, lane = selected index in
                let picked = fresh instruction.loc in
                let accumulated = if rest = [] then dst else fresh instruction.loc in
                [ M.Broadcast_word32 { dst = picked; source; lane; provenance };
                  M.Insert_word32 { dst = accumulated; previous; inserted = picked; lane = output_lane; provenance } ]
                @ steps accumulated rest in
          [ M.Broadcast_word32 { dst = initial; source; lane; provenance } ]
          @ steps initial [ M.Lane1; M.Lane2; M.Lane3 ]
      | N.Convert { operand; element = N.F32 } ->
          let dst = rack_result () in
          let conversion = match find_type func.name environment index operand with
            | N.Rack N.I32 -> N.I32_to_f32 | N.Rack N.U32 -> N.U32_to_f32
            | _ -> fail func.name ~instruction:index "float conversion requires a signed or unsigned 32-bit rack" in
          [ M.Convert_word_f32 { dst; source = operand; conversion; provenance } ]
      | N.Convert { operand; element = (N.I32 | N.U32) as element } ->
          let dst = word_rack_result () in
          ensure_operand_f32 func.name environment index operand;
          let conversion = if element = N.U32 then N.F32_to_u32 else N.F32_to_i32 in
          [ M.Convert_word_f32 { dst; source = operand; conversion; provenance } ]
      | N.Reinterpret { operand; element = (N.F32 | N.I32 | N.U32) } ->
          let dst = word_rack_result () in
          require_word_rack func.name ~instruction:index "bitcast input"
            (find_type func.name environment index operand);
          [ M.Copy_word { dst; source = operand; provenance } ]
      | N.Reinterpret _ | N.Relaxed _
      | N.Dot _ | N.Narrow _ | N.Widen _ | N.Convert _ ->
          fail func.name ~instruction:index
            "operation has no mapping in this native 32-bit rack profile"
    in
    let instructions = List.concat (List.mapi select func.body.instructions) in
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
          List.rev_append !internal_locations
            (List.filter_map
               (fun (instruction : N.instruction) ->
                 Option.map (fun (id, _) -> (id, instruction.loc)) instruction.result)
               func.body.instructions);
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
