(** Instruction selection for the [wasm-simd128] profile.

    One rack is one [v128] value. WebAssembly is a stack machine with typed
    local variables instead of a fixed register file, so selection here also
    schedules the stack: a value used once is computed where it is used, and a
    value used more than once is computed at its first use and kept in a
    scratch local with [local.tee]. Every rack operation selects one SIMD
    instruction or is rejected; nothing is scalarized or called. *)

module N = Native_ir
module IntMap = Map.Make (Int)

type value_class = V128 | I32 | I64 | F32

(** A local of the emitted function: the result, a parameter, or a scratch value. *)
type local = Result_local | Parameter_local of int | Scratch_local of int

type instruction =
  | Local_get of local
  | Local_set of local
  | Local_tee of local
  | I32_const of int32
  | I64_const of int64
  | Operation of string  (** one WebAssembly instruction, immediates included *)

type parameter = { parameter_name : string; parameter_class : value_class }

type func = {
  name : string;
  parameters : parameter list;
  result_class : value_class;
  scratch_classes : value_class list;  (** scratch local [i] has class [i] *)
  instructions : instruction list;
}

type error = { function_name : string; message : string }

let format_error error = error.function_name ^ ": " ^ error.message

exception Selection_error of string

let reject format = Printf.ksprintf (fun message -> raise (Selection_error message)) format

let class_of_type = function
  | N.Rack (N.U8 | N.I16 | N.I32 | N.U32 | N.I64 | N.F32) | N.Mask -> V128
  | N.Scalar (N.I32 | N.U32 | N.I16 | N.U8 | N.I1) -> I32
  | N.Scalar N.I64 -> I64
  | N.Scalar N.F32 -> F32
  | typ -> reject "values of type %s have no wasm-simd128 representation" (N.string_of_typ typ)

(** Bytes in one lane of a rack element, for turning lane indices into byte indices. *)
let lane_bytes = function
  | N.U8 -> 1
  | N.I16 -> 2
  | N.I32 | N.U32 | N.F32 -> 4
  | N.I64 -> 8
  | element -> reject "racks of %s are not part of the wasm-simd128 slice" (N.string_of_element element)

let shape = function
  | N.U8 -> "i8x16"
  | N.I16 -> "i16x8"
  | N.I32 | N.U32 -> "i32x4"
  | N.I64 -> "i64x2"
  | N.F32 -> "f32x4"
  | element -> reject "racks of %s are not part of the wasm-simd128 slice" (N.string_of_element element)

(** The integer shape of a mask over lanes of this element: an f32 comparison
    gives 32-bit lanes of all ones or zeros. *)
let mask_shape = function N.F32 -> "i32x4" | element -> shape element

(** The byte indices of a shuffle of 32-bit lanes. *)
let shuffle_bytes lanes =
  String.concat ", " (List.concat_map (fun lane -> List.init 4 (fun byte -> string_of_int ((lane * 4) + byte))) lanes)

let reduction_name = function
  | N.Reduce_add -> "add" | N.Reduce_mul -> "mul" | N.Reduce_min -> "min" | N.Reduce_max -> "max"
  | _ -> reject "not an f32 reduction"

let comparison_instruction element comparison =
  match (element, comparison) with
  | N.U8, N.Eq -> "i8x16.eq"
  | N.U8, N.Ne -> "i8x16.ne"
  | N.U8, N.Lt -> "i8x16.lt_u"
  | N.U8, N.Le -> "i8x16.le_u"
  | N.U8, N.Gt -> "i8x16.gt_u"
  | N.U8, N.Ge -> "i8x16.ge_u"
  | N.U32, _ -> "i32x4" ^ (match comparison with
      | N.Eq -> ".eq" | N.Ne -> ".ne" | N.Lt -> ".lt_u" | N.Le -> ".le_u" | N.Gt -> ".gt_u" | N.Ge -> ".ge_u")
  | N.F32, N.Eq -> "f32x4.eq"
  | N.F32, N.Lt -> "f32x4.lt"
  | N.F32, N.Le -> "f32x4.le"
  | N.F32, N.Gt -> "f32x4.gt"
  | N.F32, N.Ge -> "f32x4.ge"
  | (N.I16 | N.I32 | N.I64), _ ->
      let prefix = match element with N.I16 -> "i16x8" | N.I32 | N.U32 -> "i32x4" | _ -> "i64x2" in
      prefix ^ (match comparison with
                | N.Eq -> ".eq" | N.Ne -> ".ne" | N.Lt -> ".lt_s" | N.Le -> ".le_s" | N.Gt -> ".gt_s" | N.Ge -> ".ge_s")
  | N.F32, N.Ne ->
      (* f32x4.ne is true for NaN lanes; Rake's ordered comparison is false there. *)
      reject "f32 != needs an ordered comparison that the wasm-simd128 slice does not select yet"
  | element, _ ->
      reject "comparisons of %s racks are not part of the wasm-simd128 slice"
        (N.string_of_element element)

let select_function ?(mask_parameter = fun _ _ -> None) (func : N.func) =
  let definitions =
    List.fold_left
      (fun definitions (instruction : N.instruction) ->
        match instruction.result with
        | Some (value, typ) -> IntMap.add value (instruction.op, typ) definitions
        | None -> reject "effect-only %s is not part of the wasm-simd128 slice" (N.instruction_name instruction.op))
      IntMap.empty func.body.instructions
  in
  let parameter_index =
    List.mapi (fun index (parameter : N.parameter) -> (parameter.id, index)) func.parameters
  in
  let type_of value =
    match List.assoc_opt value parameter_index with
    | Some index -> (List.nth func.parameters index).typ
    | None -> snd (IntMap.find value definitions)
  in
  (* A single-rack shuffle feeds i8x16.shuffle the same rack twice, so it counts as two uses. *)
  let uses =
    let add value counts = IntMap.update value (fun n -> Some (Option.value n ~default:0 + 1)) counts in
    List.fold_left
      (fun counts (instruction : N.instruction) ->
        let operands =
          match instruction.op with
          | N.Shuffle { racks = [ rack ]; _ } -> [ rack; rack ]
          | op -> N.operands op
        in
        List.fold_left (fun counts operand -> add operand counts) counts operands)
      IntMap.empty func.body.instructions
  in
  (* The lane width of each mask comes from the racks compared to produce it. *)
  let rec mask_element value =
    match IntMap.find_opt value definitions with
    | Some (N.Compare (_, left, _), _) -> (
        match type_of left with N.Rack element -> Some element | _ -> None)
    | Some (N.Mask_binary (_, left, right), _) -> (
        match (mask_element left, mask_element right) with
        | Some a, Some b when a = b -> Some a
        | Some a, None | None, Some a -> Some a
        | _ -> None)
    | Some (N.Mask_not mask, _) -> mask_element mask
    | Some (N.Select { if_true; _ }, _) -> mask_element if_true
    | None -> (
        match List.assoc_opt value parameter_index with
        | Some index -> mask_parameter func.name index
        | None -> None)
    | _ -> None
  in
  let scratch = ref [] in
  let scratch_local cls =
    let local = Scratch_local (List.length !scratch) in
    scratch := !scratch @ [ cls ];
    local
  in
  (* One strict combine of two f32 racks given as instruction lists. Minimum and
     maximum take IEEE 754 minimum and maximum, then the canonical NaN 0x7fc00000
     wherever either lane is NaN, as Rake's strict reductions require. *)
  let strict_step name acc operand =
    match name with
    | "min" | "max" ->
        let a = scratch_local V128 and b = scratch_local V128 in
        acc @ [ Local_set a ] @ operand @ [ Local_set b ]
        @ [ I32_const 0x7fc00000l; Operation "f32.reinterpret_i32"; Operation "f32x4.splat" ]
        @ [ Local_get a; Local_get b; Operation ("f32x4." ^ name) ]
        @ [ Local_get a; Local_get a; Operation "f32x4.ne"; Local_get b; Local_get b; Operation "f32x4.ne";
            Operation "v128.or"; Operation "v128.bitselect" ]
    | _ -> acc @ operand @ [ Operation ("f32x4." ^ name) ]
  in
  let materialized = Hashtbl.create 16 in
  let rec emit value =
    match List.assoc_opt value parameter_index with
    | Some index -> [ Local_get (Parameter_local index) ]
    | None -> (
        match Hashtbl.find_opt materialized value with
        | Some local -> [ Local_get local ]
        | None ->
            let computed = compute value in
            if Option.value (IntMap.find_opt value uses) ~default:0 <= 1 then computed
            else
              let local = Scratch_local (List.length !scratch) in
              scratch := !scratch @ [ class_of_type (type_of value) ];
              Hashtbl.add materialized value local;
              computed @ [ Local_tee local ])
  (* Operands must be emitted first to last: the first use of a shared value is where it is
     computed and teed, and OCaml evaluates the operands of [@] right to left. *)
  and emit_in_order values = List.concat_map emit values
  and compute value =
    let op, typ = IntMap.find value definitions in
    match (op, typ) with
    | N.Const (N.Int32 value), N.Scalar N.I32
    | N.Const (N.Uint32 value), N.Scalar N.U32 -> [ I32_const value ]
    | N.Rack_splat (N.Uint8 byte), _ -> [ I32_const (Int32.of_int byte); Operation "i8x16.splat" ]
    | N.Rack_splat (N.Float32_bits bits), _ ->
        [ I32_const bits; Operation "f32.reinterpret_i32"; Operation "f32x4.splat" ]
    | N.Rack_splat (N.Int16 value), _ -> [ I32_const (Int32.of_int value); Operation "i16x8.splat" ]
    | N.Rack_splat (N.Int32 value), N.Rack N.I32
    | N.Rack_splat (N.Uint32 value), N.Rack N.U32 -> [ I32_const value; Operation "i32x4.splat" ]
    | N.Mask_const set, _ -> [ I32_const (if set then -1l else 0l); Operation "i32x4.splat" ]
    | N.Broadcast scalar, N.Rack N.F32 -> emit scalar @ [ Operation "f32x4.splat" ]
    | N.Broadcast scalar, N.Rack (N.I32 | N.U32) -> emit scalar @ [ Operation "i32x4.splat" ]
    | N.Binary (((N.Add | N.Sub) as operation), left, right), N.Rack N.U32 ->
        emit_in_order [ left; right ] @ [ Operation (if operation = N.Add then "i32x4.add" else "i32x4.sub") ]
    | N.Binary (((N.Add | N.Sub | N.Min | N.Max) as operation), left, right), N.Rack ((N.I16 | N.I32) as element) ->
        let shape = if element = N.I16 then "i16x8" else "i32x4" in
        let name =
          match operation with
          | N.Add -> "add" | N.Sub -> "sub" | N.Min -> "min_s" | _ -> "max_s"
        in
        emit_in_order [ left; right ] @ [ Operation (shape ^ "." ^ name) ]
    | N.Binary (((N.And | N.Or | N.Xor | N.Andnot) as operation), left, right), N.Rack (N.U8 | N.I16 | N.I32 | N.U32 | N.I64) ->
        let name =
          match operation with
          | N.And -> "v128.and" | N.Or -> "v128.or" | N.Xor -> "v128.xor" | _ -> "v128.andnot"
        in
        emit_in_order [ left; right ] @ [ Operation name ]
    | N.Shift { operand; count; shift }, N.Rack element ->
        let shape =
          match element with
          | N.U8 -> "i8x16" | N.I16 -> "i16x8" | N.I32 | N.U32 -> "i32x4" | N.I64 -> "i64x2"
          | _ -> reject "shifts of %s racks are not part of the wasm-simd128 slice" (N.string_of_element element)
        in
        let name = match shift with N.Shift_left -> "shl" | N.Shift_right -> "shr_u" | N.Shift_right_signed -> "shr_s" in
        emit_in_order [ operand; count ] @ [ Operation (shape ^ "." ^ name) ]
    | N.Dot (left, right), N.Rack N.I32 -> emit_in_order [ left; right ] @ [ Operation "i32x4.dot_i16x8_s" ]
    | N.Narrow (left, right), N.Rack N.I16 -> emit_in_order [ left; right ] @ [ Operation "i16x8.narrow_i32x4_s" ]
    | N.Widen { operand; high }, N.Rack N.I16 ->
        emit operand @ [ Operation (if high then "i16x8.extend_high_i8x16_u" else "i16x8.extend_low_i8x16_u") ]
    | N.Convert { operand; element = N.F32 }, N.Rack N.F32 -> emit operand @ [ Operation "f32x4.convert_i32x4_s" ]
    | N.Convert { operand; element = N.I32 }, N.Rack N.I32 ->
        (* trunc_sat alone rounds toward zero; nearest first gives Rake's round to nearest, ties to even. *)
        emit operand @ [ Operation "f32x4.nearest"; Operation "i32x4.trunc_sat_f32x4_s" ]
    | N.Binary (((N.Add | N.Sub | N.Mul | N.Div) as operation), left, right), N.Rack N.F32 ->
        let name =
          match operation with
          | N.Add -> "f32x4.add" | N.Sub -> "f32x4.sub" | N.Mul -> "f32x4.mul" | _ -> "f32x4.div"
        in
        emit_in_order [ left; right ] @ [ Operation name ]
    | N.Binary (((N.Min | N.Max) as operation), left, right), N.Rack N.F32 ->
        (* IEEE 754 minimum and maximum: NaN if either lane is, and -0 below +0, as the reference computes. *)
        emit_in_order [ left; right ] @ [ Operation (if operation = N.Min then "f32x4.min" else "f32x4.max") ]
    | N.Unary (N.Neg, operand), N.Rack N.F32 -> emit operand @ [ Operation "f32x4.neg" ]
    | N.Unary (N.Sqrt, operand), N.Rack N.F32 -> emit operand @ [ Operation "f32x4.sqrt" ]
    | N.Compare (N.Ne, left, right), N.Mask when type_of left = N.Rack N.F32 ->
        (* Rake's != is ordered, false where either lane is NaN: less or greater. *)
        let a = scratch_local V128 and b = scratch_local V128 in
        emit left @ [ Local_set a ] @ emit right @ [ Local_set b ]
        @ [ Local_get a; Local_get b; Operation "f32x4.lt"; Local_get a; Local_get b; Operation "f32x4.gt"; Operation "v128.or" ]
    | N.Compare (comparison, left, right), N.Mask -> (
        match type_of left with
        | N.Rack element -> emit_in_order [ left; right ] @ [ Operation (comparison_instruction element comparison) ]
        | typ -> reject "comparison of %s is not a rack comparison" (N.string_of_typ typ))
    | N.Select { condition; if_true; if_false }, N.Rack _ when type_of condition <> N.Scalar N.I1 ->
        emit_in_order [ if_true; if_false; condition ] @ [ Operation "v128.bitselect" ]
    | N.Sanitize { mask; active; benign }, N.Rack _ ->
        emit_in_order [ active; benign; mask ] @ [ Operation "v128.bitselect" ]
    | N.Mask_binary (operation, left, right), N.Mask ->
        let name =
          match operation with
          | N.And -> "v128.and" | N.Or -> "v128.or" | N.Xor -> "v128.xor"
          | _ -> reject "mask operation %s is not selected" (N.string_of_binary operation)
        in
        emit_in_order [ left; right ] @ [ Operation name ]
    | N.Mask_not mask, N.Mask -> emit mask @ [ Operation "v128.not" ]
    | N.Shuffle { racks; indices }, N.Rack element ->
        let bytes = lane_bytes element in
        let lanes = 16 / bytes in
        if List.length indices <> lanes then
          reject "a shuffle of %s racks needs %d indices on wasm-simd128, got %d"
            (N.string_of_element element) lanes (List.length indices);
        let available = lanes * List.length racks in
        List.iter
          (fun index ->
            if index >= available then
              reject "shuffle index %d is outside its %d lanes" index available)
          indices;
        let byte_indices =
          List.concat_map (fun index -> List.init bytes (fun byte -> (index * bytes) + byte)) indices
        in
        let operands =
          match racks with
          | [ rack ] -> emit_in_order [ rack; rack ]
          | [ first; second ] -> emit_in_order [ first; second ]
          | _ -> reject "shuffle takes one or two racks"
        in
        operands
        @ [ Operation ("i8x16.shuffle " ^ String.concat ", " (List.map string_of_int byte_indices)) ]
    | N.Reduce (N.Reduce_bitmask, mask), N.Scalar N.U32 -> (
        match mask_element mask with
        | Some element -> emit mask @ [ Operation (mask_shape element ^ ".bitmask") ]
        | None -> reject "bitmask needs a mask whose lane width is known from a comparison")
    | N.Rack_splat (N.Int64 value), N.Rack N.I64 -> [ I64_const value; Operation "i64x2.splat" ]
    | N.Broadcast scalar, N.Rack N.I16 -> emit scalar @ [ Operation "i16x8.splat" ]
    | N.Broadcast scalar, N.Rack N.U8 -> emit scalar @ [ Operation "i8x16.splat" ]
    | N.Broadcast scalar, N.Rack N.I64 -> emit scalar @ [ Operation "i64x2.splat" ]
    | N.Const (N.Int16 value), N.Scalar N.I16 -> [ I32_const (Int32.of_int value) ]
    | N.Const (N.Uint8 value), N.Scalar N.U8 -> [ I32_const (Int32.of_int value) ]
    | N.Const (N.Int64 value), N.Scalar N.I64 -> [ I64_const value ]
    | N.Const (N.Float32_bits bits), N.Scalar N.F32 -> [ I32_const bits; Operation "f32.reinterpret_i32" ]
    | N.Binary (((N.Add | N.Sub) as operation), left, right), N.Rack ((N.U8 | N.I64) as element) ->
        emit_in_order [ left; right ] @ [ Operation (shape element ^ (if operation = N.Add then ".add" else ".sub")) ]
    | N.Binary (N.Mul, left, right), N.Rack ((N.I16 | N.I32 | N.U32 | N.I64) as element) ->
        emit_in_order [ left; right ] @ [ Operation (shape element ^ ".mul") ]
    | N.Binary (((N.Min | N.Max) as operation), left, right), N.Rack N.U8 ->
        emit_in_order [ left; right ] @ [ Operation (if operation = N.Min then "i8x16.min_u" else "i8x16.max_u") ]
    | N.Unary (((N.Neg | N.Abs) as operation), operand), N.Rack ((N.U8 | N.I16 | N.I32 | N.I64) as element) ->
        emit operand @ [ Operation (shape element ^ (if operation = N.Neg then ".neg" else ".abs")) ]
    | N.Unary (((N.Abs | N.Floor | N.Ceil | N.Trunc | N.Nearest) as operation), operand), N.Rack N.F32 ->
        emit operand @ [ Operation ("f32x4." ^ N.string_of_unary operation) ]
    | N.Reinterpret { operand; _ }, N.Rack _ -> emit operand
    | N.Relaxed { name; operands }, N.Rack N.F32 -> emit_in_order operands @ [ Operation ("f32x4." ^ name) ]
    | N.Compare (N.Ne, left, right), N.Scalar N.I1 when type_of left = N.Scalar N.F32 ->
        (* Rake's != is ordered, for uniforms as for racks: less or greater. *)
        let a = scratch_local F32 and b = scratch_local F32 in
        emit left @ [ Local_set a ] @ emit right @ [ Local_set b ]
        @ [ Local_get a; Local_get b; Operation "f32.lt"; Local_get a; Local_get b; Operation "f32.gt"; Operation "i32.or" ]
    | N.Compare (comparison, left, right), N.Scalar N.I1 ->
        (* A uniform condition: one scalar comparison. *)
        let prefix =
          match type_of left with
          | N.Scalar N.F32 -> "f32."
          | N.Scalar N.I64 -> "i64."
          | _ -> "i32."
        in
        let name =
          match (comparison, prefix) with
          | N.Eq, _ -> "eq" | N.Ne, _ -> "ne"
          | N.Lt, "f32." -> "lt" | N.Le, "f32." -> "le" | N.Gt, "f32." -> "gt" | N.Ge, "f32." -> "ge"
          | N.Lt, _ when type_of left = N.Scalar N.U32 -> "lt_u"
          | N.Le, _ when type_of left = N.Scalar N.U32 -> "le_u"
          | N.Gt, _ when type_of left = N.Scalar N.U32 -> "gt_u"
          | N.Ge, _ when type_of left = N.Scalar N.U32 -> "ge_u"
          | N.Lt, _ -> "lt_s" | N.Le, _ -> "le_s" | N.Gt, _ -> "gt_s" | N.Ge, _ -> "ge_s"
        in
        emit_in_order [ left; right ] @ [ Operation (prefix ^ name) ]
    | N.Select { condition; if_true; if_false }, N.Rack _ when type_of condition = N.Scalar N.I1 ->
        emit_in_order [ if_true; if_false; condition ] @ [ Operation "select" ]
    | N.Extract { rack; lane }, N.Scalar element -> (
        match IntMap.find_opt lane definitions with
        | Some (N.Const (N.Int32 index), _) ->
            let suffix = match element with N.I16 -> "extract_lane_s" | N.U8 -> "extract_lane_u" | _ -> "extract_lane" in
            emit rack @ [ Operation (Printf.sprintf "%s.%s %ld" (shape element) suffix index) ]
        | _ -> reject "a lane is chosen by a constant")
    | N.Insert { rack; inserted; lane }, N.Rack element -> (
        match IntMap.find_opt lane definitions with
        | Some (N.Const (N.Int32 index), _) ->
            emit_in_order [ rack; inserted ] @ [ Operation (Printf.sprintf "%s.replace_lane %ld" (shape element) index) ]
        | _ -> reject "a lane is chosen by a constant")
    | N.Reduce (((N.Reduce_and | N.Reduce_or) as operation), mask), N.Scalar N.I1 ->
        if operation = N.Reduce_or then emit mask @ [ Operation "v128.any_true" ]
        else
          let element = Option.value (mask_element mask) ~default:N.I32 in
          emit mask @ [ Operation (mask_shape element ^ ".all_true") ]
    | N.Reduce (((N.Reduce_add | N.Reduce_mul | N.Reduce_min | N.Reduce_max) as operation), rack), N.Scalar N.F32 ->
        (* Strict ascending-lane order: ((x0 op x1) op x2) op x3, one combine a step. *)
        let x = scratch_local V128 in
        let get = [ Local_get x ] in
        let lane_to_front lane =
          get @ get @ [ Operation ("i8x16.shuffle " ^ shuffle_bytes (List.init 4 (fun i -> if i = 0 then lane else i))) ]
        in
        let step = strict_step (reduction_name operation) in
        let combined =
          List.fold_left (fun acc lane -> step acc (lane_to_front lane)) get [ 1; 2; 3 ]
        in
        emit rack @ [ Local_set x ] @ combined @ [ Operation "f32x4.extract_lane 0" ]
    | N.Scan (operation, rack), N.Rack N.F32 ->
        (* Lane i is lane i-1's prefix combined with lane i, in ascending order. *)
        let x = scratch_local V128 and p = scratch_local V128 in
        let name = match operation with N.Scan_add -> "add" | N.Scan_mul -> "mul" | N.Scan_min -> "min" | N.Scan_max -> "max" in
        let step = strict_step name in
        let steps =
          List.concat_map
            (fun lane ->
              let previous =
                [ Local_get p; Local_get p ]
                @ [ Operation ("i8x16.shuffle " ^ shuffle_bytes (List.init 4 (fun i -> if i = lane then lane - 1 else i))) ]
              in
              let combined = step previous [ Local_get x ] in
              [ Local_get p ] @ combined
              @ [ Operation ("i8x16.shuffle " ^ shuffle_bytes (List.init 4 (fun i -> if i = lane then 4 + i else i)));
                  Local_set p ])
            [ 1; 2; 3 ]
        in
        emit rack @ [ Local_tee x; Local_set p ] @ steps @ [ Local_get p ]
    | op, typ ->
        reject "%s producing %s is not part of the wasm-simd128 slice" (N.instruction_name op)
          (N.string_of_typ typ)
  in
  let result =
    match func.body.terminators with
    | [ N.Return (Some result) ] -> result
    | _ -> reject "a wasm-simd128 function must end with one return of a value"
  in
  let instructions = emit result @ [ Local_set Result_local ] in
  {
    name = func.name;
    parameters =
      List.mapi
        (fun index (parameter : N.parameter) ->
          {
            parameter_name = Option.value parameter.name ~default:(Printf.sprintf "argument%d" index);
            parameter_class = class_of_type parameter.typ;
          })
        func.parameters;
    result_class = class_of_type (type_of result);
    scratch_classes = !scratch;
    instructions;
  }

let select ?mask_parameter (native_ir : N.t) =
  let rec select_all selected = function
    | [] -> Ok (List.rev selected)
    | (func : N.func) :: rest -> (
        match select_function ?mask_parameter func with
        | selected_function -> select_all (selected_function :: selected) rest
        | exception Selection_error message -> Error { function_name = func.name; message })
  in
  select_all [] native_ir
