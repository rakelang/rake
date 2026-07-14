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

let result function_name index (instruction : N.instruction) =
  match instruction.result with
  | Some result -> result
  | None -> fail function_name ~instruction:index "effect-only operations are not supported"

let literal_f32 function_name index = function
  | N.Float32_bits bits -> bits
  | literal ->
      fail function_name ~instruction:index
        ("uniform rack constant has unsupported element type "
        ^ N.string_of_literal literal)

let same_bits = function
  | [] -> None
  | N.Float32_bits bits :: rest ->
      if List.for_all (function N.Float32_bits other -> other = bits | _ -> false) rest
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
                  (function N.Broadcast operand -> operand = id | _ -> false)
                  operations ->
          ()
      | _ ->
          fail function_name
            (Printf.sprintf
               "scalar f32 value %%%d is only legal as the direct input to rack.broadcast; scalarization is forbidden"
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
              (Printf.sprintf
                 "parameter %%%d has unsupported type %s; only rack<f32>, scalar<f32>, and mask parameters use the AAPCS64 SIMD/FP boundary"
                 parameter.id (N.string_of_typ typ)))
      func.parameters;
    (match func.result with
    | None | Some (N.Rack N.F32) | Some N.Mask -> ()
    | Some typ ->
        fail func.name
          ("unsupported result type " ^ N.string_of_typ typ
         ^ "; NEON selection cannot scalarize a rack result"));
    let environment = type_environment func in
    let constants = const_definitions func in
    validate_deferred_constants func.name constants (scalar_constant_uses func);
    let next = next_virtual func in
    let internal_locations = ref [] in
    let fresh loc =
      let value = !next in
      incr next;
      internal_locations := (value, loc) :: !internal_locations;
      value
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
      match instruction.op with
      | N.Const (N.Float32_bits _) -> []
      | N.Const literal ->
          fail func.name ~instruction:index
            ("scalar constant " ^ N.string_of_literal literal
           ^ " cannot occupy a NEON rack register")
      | N.Mask_const value ->
          [ M.Mask_const { dst = mask_result (); value; provenance } ]
      | N.Rack_splat literal ->
          [ M.Uniform_f32
              { dst = rack_result (); bits = literal_f32 func.name index literal; provenance } ]
      | N.Rack_const literals ->
          let dst = rack_result () in
          if List.length literals <> 4 then
            fail func.name ~instruction:index
              (Printf.sprintf
                 "NEON rack constant has %d lanes; exactly 4 f32 lanes are required"
                 (List.length literals));
          (match same_bits literals with
          | Some bits -> [ M.Uniform_f32 { dst; bits; provenance } ]
          | None ->
              fail func.name ~instruction:index
                "non-uniform rack constants are not in the initial NEON selection contract")
      | N.Broadcast scalar ->
          let dst = rack_result () in
          (match N.IntMap.find_opt scalar constants with
          | Some bits -> [ M.Uniform_f32 { dst; bits; provenance } ]
          | None -> (
              match find_type func.name environment index scalar with
              | N.Scalar N.F32 ->
                  [ M.Broadcast_f32 { dst; source = scalar; provenance } ]
              | typ ->
                  fail func.name ~instruction:index
                    (Printf.sprintf "rack.broadcast requires scalar<f32>, got %s"
                       (N.string_of_typ typ))))
      | N.Unary (N.Neg, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          let sign = fresh instruction.loc in
          [ M.Uniform_f32 { dst = sign; bits = Int32.min_int; provenance };
            M.Eor { dst; left = source; right = sign; provenance } ]
      | N.Unary (N.Sqrt, source) ->
          let dst = rack_result () in
          ensure_operand_f32 func.name environment index source;
          [ M.Fsqrt { dst; source; provenance } ]
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
      | N.Binary ((N.Min | N.Max | N.And | N.Or | N.Xor), _, _) ->
          fail func.name ~instruction:index
            "operation has no strict f32-rack mapping in the initial NEON contract"
      | N.Fma (multiplicand, multiplier, addend) ->
          let dst = rack_result () in
          List.iter (ensure_operand_f32 func.name environment index)
            [ multiplicand; multiplier; addend ];
          [ M.Fma { dst; multiplicand; multiplier; addend; provenance } ]
      | N.Compare (comparison, left, right) ->
          let dst = mask_result () in
          ensure_operand_f32 func.name environment index left;
          ensure_operand_f32 func.name environment index right;
          (match comparison with
          | N.Eq -> [ M.Compare { dst; predicate = M.Ceq; left; right; provenance } ]
          | N.Lt -> [ M.Compare { dst; predicate = M.Cgt; left = right; right = left; provenance } ]
          | N.Le -> [ M.Compare { dst; predicate = M.Cge; left = right; right = left; provenance } ]
          | N.Gt -> [ M.Compare { dst; predicate = M.Cgt; left; right; provenance } ]
          | N.Ge -> [ M.Compare { dst; predicate = M.Cge; left; right; provenance } ]
          | N.Ne ->
              let greater = fresh instruction.loc in
              let less = fresh instruction.loc in
              [ M.Compare { dst = greater; predicate = M.Cgt; left; right; provenance };
                M.Compare
                  { dst = less; predicate = M.Cgt; left = right; right = left; provenance };
                M.Orr { dst; left = greater; right = less; provenance } ])
      | N.Select { condition; if_true; if_false } ->
          let dst = rack_result () in
          ensure_mask func.name environment index condition;
          ensure_operand_f32 func.name environment index if_true;
          ensure_operand_f32 func.name environment index if_false;
          [ M.Select { dst; mask = condition; if_true; if_false; provenance } ]
      | N.Sanitize { mask; active; benign } ->
          let dst = rack_result () in
          ensure_mask func.name environment index mask;
          ensure_operand_f32 func.name environment index active;
          ensure_operand_f32 func.name environment index benign;
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
      | N.Shuffle _ | N.Reduce _ | N.Scan _ | N.Extract _ | N.Insert _ ->
          fail func.name ~instruction:index
            "cross-lane operation is unavailable in the initial NEON selection contract"
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
              { M.reg = parameter.id; name = parameter.name })
            func.parameters;
        instructions;
        result;
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
