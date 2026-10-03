(** No-spill physical vector allocation for AArch64 NEON under AAPCS64.

    Registers v8..v15 are deliberately unavailable because AAPCS64 makes
    their low halves callee-saved.  Excluding them preserves the leaf/no-stack
    contract without partial-register save and restore sequences. *)

module M = Aarch64_neon_mir
module I = Native_ir.IntMap
module S = Native_ir.IntSet

type vector_register = int

type operation =
  | Convert_i32_f32 of { dst : vector_register; source : vector_register; conversion : Native_ir.signed_word_conversion; scratch : vector_register list }
  | Integer_parameter of { dst : vector_register; argument : int }
  | Uniform_f32 of { dst : vector_register; bits : int32 }
  | Mask_const of { dst : vector_register; value : bool }
  | Broadcast_f32 of { dst : vector_register; source : vector_register; lane : M.f32_lane }
  | Broadcast_bool of { dst : vector_register; source : vector_register }
  | Insert_f32 of { dst : vector_register; inserted : vector_register; lane : M.f32_lane }
  | Reduce_mask of {
      dst : vector_register;
      source : vector_register;
      operation : Native_ir.mask_reduction;
      scratch : vector_register;
    }
  | Fadd of { dst : vector_register; left : vector_register; right : vector_register }
  | Fsub of { dst : vector_register; left : vector_register; right : vector_register }
  | Add_i32 of { dst : vector_register; left : vector_register; right : vector_register }
  | Sub_i32 of { dst : vector_register; left : vector_register; right : vector_register }
  | Mul_i32 of { dst : vector_register; left : vector_register; right : vector_register }
  | Min_i32 of { dst : vector_register; left : vector_register; right : vector_register; unsigned : bool }
  | Max_i32 of { dst : vector_register; left : vector_register; right : vector_register; unsigned : bool }
  | Neg_i32 of { dst : vector_register; source : vector_register }
  | Abs_i32 of { dst : vector_register; source : vector_register }
  | Shift_i32 of { dst : vector_register; source : vector_register; count : Native_ir.I32_shift_count.t; shift : Native_ir.shift }
  | Compare_i32 of { dst : vector_register; predicate : Native_ir.comparison; unsigned : bool; left : vector_register; right : vector_register }
  | Fmul of { dst : vector_register; left : vector_register; right : vector_register }
  | Fdiv of { dst : vector_register; left : vector_register; right : vector_register }
  | Fmin of { dst : vector_register; left : vector_register; right : vector_register }
  | Fmax of { dst : vector_register; left : vector_register; right : vector_register }
  | Fsqrt of { dst : vector_register; source : vector_register }
  | Round_f32 of { dst : vector_register; source : vector_register; mode : Native_ir.rounding_mode }
  | Fmla of {
      dst : vector_register;
      multiplicand : vector_register;
      multiplier : vector_register;
    }
  | Compare of {
      dst : vector_register;
      predicate : M.comparison;
      left : vector_register;
      right : vector_register;
    }
  | And of { dst : vector_register; left : vector_register; right : vector_register }
  | Bic of { dst : vector_register; left : vector_register; right : vector_register }
  | Orr of { dst : vector_register; left : vector_register; right : vector_register }
  | Eor of { dst : vector_register; left : vector_register; right : vector_register }
  | Mvn of { dst : vector_register; source : vector_register }
  | Bsl of {
      dst_mask : vector_register;
      if_true : vector_register;
      if_false : vector_register;
    }
  | Bit of {
      dst_false : vector_register;
      if_true : vector_register;
      mask : vector_register;
    }
  | Bif of {
      dst_true : vector_register;
      if_false : vector_register;
      mask : vector_register;
    }
  | Move of { dst : vector_register; source : vector_register }

type instruction = {
  operation : operation;
  loc : Native_ir.source_location;
  provenance : Native_ir.provenance;
}

type func = {
  name : string;
  loc : Native_ir.source_location;
  instructions : instruction list;
  result : vector_register option;
  result_type : Native_ir.typ option;
  maximum_live : int;
}

type error = {
  function_name : string;
  loc : Native_ir.source_location;
  required : int;
  available : int;
  fused : bool;
  message : string;
}

let format_error error =
  Printf.sprintf "%s: %s: %s" (Native_ir.format_source_location error.loc)
    error.function_name error.message

let allocatable_registers =
  List.init 8 Fun.id @ List.init 16 (fun index -> index + 16)

let physical_register_count = List.length allocatable_registers
let argument_register_count = 8

let last_uses func =
  let uses =
    List.mapi (fun index instruction -> (index, M.operands instruction))
      func.M.instructions
    |> List.fold_left
         (fun uses (index, operands) ->
           List.fold_left (fun uses operand -> I.add operand index uses) uses operands)
         I.empty
  in
  match func.M.result with
  | None -> uses
  | Some result -> I.add result (List.length func.instructions) uses

let definition_provenance func =
  List.fold_left
    (fun provenances instruction ->
      I.add (M.def instruction) (M.provenance instruction) provenances)
    I.empty func.M.instructions

let last_use uses value = Option.value (I.find_opt value uses) ~default:(-1)
let expire uses index allocation = I.filter (fun value _ -> last_use uses value >= index) allocation
let occupied allocation = I.fold (fun _ physical set -> S.add physical set) allocation S.empty

let first_free allocation =
  let used = occupied allocation in
  List.find_opt (fun register -> not (S.mem register used)) allocatable_registers

let live_is_fused provenances allocation =
  I.exists
    (fun value _ ->
      match I.find_opt value provenances with
      | Some { Native_ir.fused = Some _; _ } -> true
      | _ -> false)
    allocation

let allocate_function ?parameter_assignment func =
  let parameter_count = List.length func.M.parameters in
  match Native_register_assignment.resolve ~available:allocatable_registers
    ~argument_count:argument_register_count ~integer_argument_count:8
    ~classes:(List.map (fun parameter -> parameter.M.argument_class) func.parameters) parameter_assignment with
  | Error message ->
    Error
      {
        function_name = func.name;
        loc = func.loc;
        required = parameter_count;
        available = argument_register_count;
        fused = false;
        message;
      }
  | Ok (parameter_assignment, integer_transfers) ->
    let uses = Native_register_assignment.preserve_uses
      ~instruction_count:(List.length func.instructions) parameter_assignment
      (List.map (fun parameter -> parameter.M.reg) func.parameters) (last_uses func) in
    let provenances = definition_provenance func in
    let initial_allocation =
      List.map2 (fun (assignment : Native_register_assignment.parameter) parameter ->
        (parameter.M.reg, assignment.Native_register_assignment.register)) parameter_assignment func.parameters
      |> List.fold_left
           (fun allocation (value, physical) -> I.add value physical allocation)
           I.empty
    in
    let maximum_live = ref (I.cardinal initial_allocation) in
    let emitted_rev = ref [] in
    let allocation = ref initial_allocation in
    let physical value =
      match I.find_opt value !allocation with
      | Some register -> register
      | None -> invalid_arg (Printf.sprintf "unallocated NEON value %%%d" value)
    in
    let emit loc provenance operation =
      emitted_rev := { operation; loc; provenance } :: !emitted_rev
    in
    List.iter (fun (transfer : Native_register_assignment.integer_transfer) ->
      emit func.loc Native_ir.source (Integer_parameter { dst = transfer.register; argument = transfer.argument })) integer_transfers;
    (* Keep the Boolean's value bit, independently of unspecified upper C ABI
       bits. All argument transfers stay together at the verified entry. *)
    List.iter2 (fun (assigned : Native_register_assignment.parameter) parameter ->
      if parameter.M.argument_class = Native_register_assignment.Boolean then (
        let count = Option.get (Native_ir.I32_shift_count.of_int32 31l) in
        let dst = assigned.register in
        emit func.loc Native_ir.source (Shift_i32 { dst; source = dst; count; shift = Native_ir.Shift_left });
        emit func.loc Native_ir.source (Shift_i32 { dst; source = dst; count; shift = Native_ir.Shift_right })))
      parameter_assignment func.parameters;
    let fail_pressure ?(additional = 1) instruction =
      let required = I.cardinal !allocation + additional in
      let provenance = M.provenance instruction in
      let fused = provenance.fused <> None || live_is_fused provenances !allocation in
      let loc = M.value_location func (M.def instruction) in
      Error
        {
          function_name = func.name;
          loc;
          required;
          available = physical_register_count;
          fused;
          message =
            Printf.sprintf
              "%s requires %d simultaneously live full NEON registers; AAPCS64 leaf profile provides %d (v0..v7 and v16..v31); no spill fallback is permitted"
              (if fused then "fused region" else "native rack expression") required
              physical_register_count;
        }
    in
    let choose_destination index candidates instruction =
      match
        List.find_opt
          (fun value -> last_use uses value = index && I.mem value !allocation)
          candidates
      with
      | Some value -> Ok (physical value, Some value)
      | None -> (
          match first_free !allocation with
          | Some register -> Ok (register, None)
          | None -> fail_pressure instruction)
    in
    let finish_instruction index instruction dst reused =
      Option.iter (fun value -> allocation := I.remove value !allocation) reused;
      allocation := I.add (M.def instruction) dst !allocation;
      maximum_live := max !maximum_live (I.cardinal !allocation);
      List.iter
        (fun operand ->
          if last_use uses operand = index then allocation := I.remove operand !allocation)
        (M.operands instruction)
    in
    let rec allocate index = function
      | [] ->
          allocation := expire uses (List.length func.instructions) !allocation;
          let result, emitted_rev =
            match func.result with
            | None -> (None, !emitted_rev)
            | Some value ->
                let source = physical value in
                if source = 0 then (Some 0, !emitted_rev)
                else
                  let instruction =
                    {
                      operation = Move { dst = 0; source };
                      loc = M.value_location func value;
                      provenance = Native_ir.source;
                    }
                  in
                  (Some 0, instruction :: !emitted_rev)
          in
          Ok
            {
              name = func.name;
              loc = func.loc;
              instructions = List.rev emitted_rev;
              result;
              result_type = func.result_type;
              maximum_live = !maximum_live;
            }
      | instruction :: rest ->
          allocation := expire uses index !allocation;
          let loc = M.value_location func (M.def instruction) in
          let provenance = M.provenance instruction in
          let operands = M.operands instruction in
          let candidates =
            match instruction with
            | M.Uniform_f32 _ | M.Mask_const _ -> []
            | M.Convert_i32_f32 { conversion = Native_ir.F32_to_i32; _ } -> []
            | M.Broadcast_f32 { source; _ } -> [ source ]
            | M.Broadcast_bool { source; _ } -> [ source ]
            | M.Insert_f32 { previous; _ } -> [ previous ]
            | M.Fma { addend; _ } -> [ addend ]
            | M.Select { mask; if_false; if_true; _ } -> [ mask; if_false; if_true ]
            | _ -> operands
          in
          (match choose_destination index candidates instruction with
          | Error _ as error -> error
          | Ok (dst, reused) ->
              let p = physical in
              let scratch_count = match instruction with
                | M.Convert_i32_f32 { conversion = Native_ir.F32_to_i32; _ } -> 4
                | M.Reduce_mask _ -> 1 | _ -> 0 in
              let occupied = occupied !allocation in
              let scratch = List.filter (fun register ->
                register <> dst && not (S.mem register occupied)) allocatable_registers
                |> List.filteri (fun index _ -> index < scratch_count) in
              if List.length scratch <> scratch_count then
                fail_pressure ~additional:(scratch_count + if reused = None then 1 else 0) instruction
              else (
              maximum_live := max !maximum_live
                (I.cardinal !allocation + (if reused = None then 1 else 0) + scratch_count);
              (match instruction with
              | M.Convert_i32_f32 { source; conversion; _ } ->
                  emit loc provenance (Convert_i32_f32 { dst; source = p source; conversion; scratch })
              | M.Copy_word { source; _ } ->
                  if reused <> Some source then
                    emit loc provenance (Move { dst; source = p source })
              | M.Uniform_f32 { bits; _ } -> emit loc provenance (Uniform_f32 { dst; bits })
              | M.Mask_const { value; _ } -> emit loc provenance (Mask_const { dst; value })
              | M.Broadcast_f32 { source; lane; _ } ->
                  emit loc provenance (Broadcast_f32 { dst; source = p source; lane })
              | M.Broadcast_bool { source; _ } ->
                  emit loc provenance (Broadcast_bool { dst; source = p source })
              | M.Insert_f32 { previous; inserted; lane; _ } ->
                  if reused <> Some previous then
                    emit loc provenance (Move { dst; source = p previous });
                  emit loc provenance (Insert_f32 { dst; inserted = p inserted; lane })
              | M.Reduce_mask { source; operation; _ } ->
                  emit loc provenance (Reduce_mask { dst; source = p source; operation; scratch = List.hd scratch })
              | M.Fadd { left; right; _ } -> emit loc provenance (Fadd { dst; left = p left; right = p right })
              | M.Fsub { left; right; _ } -> emit loc provenance (Fsub { dst; left = p left; right = p right })
              | M.Add_i32 { left; right; _ } -> emit loc provenance (Add_i32 { dst; left = p left; right = p right })
              | M.Sub_i32 { left; right; _ } -> emit loc provenance (Sub_i32 { dst; left = p left; right = p right })
              | M.Mul_i32 { left; right; _ } -> emit loc provenance (Mul_i32 { dst; left = p left; right = p right })
              | M.Min_i32 { left; right; unsigned; _ } -> emit loc provenance (Min_i32 { dst; left = p left; right = p right; unsigned })
              | M.Max_i32 { left; right; unsigned; _ } -> emit loc provenance (Max_i32 { dst; left = p left; right = p right; unsigned })
              | M.Neg_i32 { source; _ } -> emit loc provenance (Neg_i32 { dst; source = p source })
              | M.Abs_i32 { source; _ } -> emit loc provenance (Abs_i32 { dst; source = p source })
              | M.Shift_i32 { source; count; shift; _ } ->
                  emit loc provenance (Shift_i32 { dst; source = p source; count; shift })
              | M.Compare_i32 { predicate; unsigned; left; right; _ } ->
                  emit loc provenance (Compare_i32 { dst; predicate; unsigned; left = p left; right = p right })
              | M.Fmul { left; right; _ } -> emit loc provenance (Fmul { dst; left = p left; right = p right })
              | M.Fdiv { left; right; _ } -> emit loc provenance (Fdiv { dst; left = p left; right = p right })
              | M.Fmin { left; right; _ } -> emit loc provenance (Fmin { dst; left = p left; right = p right })
              | M.Fmax { left; right; _ } -> emit loc provenance (Fmax { dst; left = p left; right = p right })
              | M.Fsqrt { source; _ } -> emit loc provenance (Fsqrt { dst; source = p source })
              | M.Round_f32 { source; mode; _ } -> emit loc provenance (Round_f32 { dst; source = p source; mode })
              | M.Fma { multiplicand; multiplier; addend; _ } ->
                  let addend_register = p addend in
                  if reused <> Some addend then
                    emit loc provenance (Move { dst; source = addend_register });
                  emit loc provenance
                    (Fmla { dst; multiplicand = p multiplicand; multiplier = p multiplier })
              | M.Compare { predicate; left; right; _ } ->
                  emit loc provenance
                    (Compare { dst; predicate; left = p left; right = p right })
              | M.And { left; right; _ } -> emit loc provenance (And { dst; left = p left; right = p right })
              | M.Bic { left; right; _ } -> emit loc provenance (Bic { dst; left = p left; right = p right })
              | M.Orr { left; right; _ } -> emit loc provenance (Orr { dst; left = p left; right = p right })
              | M.Eor { left; right; _ } -> emit loc provenance (Eor { dst; left = p left; right = p right })
              | M.Mvn { source; _ } -> emit loc provenance (Mvn { dst; source = p source })
              | M.Select { mask; if_true; if_false; _ } ->
                  if reused = Some mask then
                    emit loc provenance
                      (Bsl { dst_mask = dst; if_true = p if_true; if_false = p if_false })
                  else if reused = Some if_false then
                    emit loc provenance
                      (Bit { dst_false = dst; if_true = p if_true; mask = p mask })
                  else if reused = Some if_true then
                    emit loc provenance
                      (Bif { dst_true = dst; if_false = p if_false; mask = p mask })
                  else (
                    emit loc provenance (Move { dst; source = p if_false });
                    emit loc provenance
                      (Bit { dst_false = dst; if_true = p if_true; mask = p mask })));
              finish_instruction index instruction dst reused;
              allocate (index + 1) rest))
    in
    allocate 0 func.instructions

let allocate ?parameter_assignment module_ =
  let rec loop allocated = function
    | [] -> Ok (List.rev allocated)
    | func :: rest -> (
        match allocate_function ?parameter_assignment func with
        | Ok allocated_function -> loop (allocated_function :: allocated) rest
        | Error _ as error -> error)
  in
  loop [] module_
