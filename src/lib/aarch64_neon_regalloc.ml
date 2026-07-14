(** No-spill physical vector allocation for AArch64 NEON under AAPCS64.

    Registers v8..v15 are deliberately unavailable because AAPCS64 makes
    their low halves callee-saved.  Excluding them preserves the leaf/no-stack
    contract without partial-register save and restore sequences. *)

module M = Aarch64_neon_mir
module I = Native_ir.IntMap
module S = Native_ir.IntSet

type vector_register = int

type operation =
  | Uniform_f32 of { dst : vector_register; bits : int32 }
  | Mask_const of { dst : vector_register; value : bool }
  | Broadcast_f32 of { dst : vector_register; source : vector_register }
  | Fadd of { dst : vector_register; left : vector_register; right : vector_register }
  | Fsub of { dst : vector_register; left : vector_register; right : vector_register }
  | Fmul of { dst : vector_register; left : vector_register; right : vector_register }
  | Fdiv of { dst : vector_register; left : vector_register; right : vector_register }
  | Fsqrt of { dst : vector_register; source : vector_register }
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

let allocate_function func =
  let parameter_count = List.length func.M.parameters in
  if parameter_count > argument_register_count then
    Error
      {
        function_name = func.name;
        loc = func.loc;
        required = parameter_count;
        available = argument_register_count;
        fused = false;
        message =
          Printf.sprintf
            "AAPCS64 requires %d rack arguments but provides %d vector argument registers"
            parameter_count argument_register_count;
      }
  else
    let uses = last_uses func in
    let provenances = definition_provenance func in
    let initial_allocation =
      List.mapi (fun physical parameter -> (parameter.M.reg, physical)) func.parameters
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
    let fail_pressure instruction =
      let required = I.cardinal !allocation + 1 in
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
            | M.Broadcast_f32 { source; _ } -> [ source ]
            | M.Fma { addend; _ } -> [ addend ]
            | M.Select { mask; if_false; if_true; _ } -> [ mask; if_false; if_true ]
            | _ -> operands
          in
          (match choose_destination index candidates instruction with
          | Error _ as error -> error
          | Ok (dst, reused) ->
              let p = physical in
              (match instruction with
              | M.Uniform_f32 { bits; _ } -> emit loc provenance (Uniform_f32 { dst; bits })
              | M.Mask_const { value; _ } -> emit loc provenance (Mask_const { dst; value })
              | M.Broadcast_f32 { source; _ } ->
                  emit loc provenance (Broadcast_f32 { dst; source = p source })
              | M.Fadd { left; right; _ } -> emit loc provenance (Fadd { dst; left = p left; right = p right })
              | M.Fsub { left; right; _ } -> emit loc provenance (Fsub { dst; left = p left; right = p right })
              | M.Fmul { left; right; _ } -> emit loc provenance (Fmul { dst; left = p left; right = p right })
              | M.Fdiv { left; right; _ } -> emit loc provenance (Fdiv { dst; left = p left; right = p right })
              | M.Fsqrt { source; _ } -> emit loc provenance (Fsqrt { dst; source = p source })
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
              allocate (index + 1) rest)
    in
    allocate 0 func.instructions

let allocate module_ =
  let rec loop allocated = function
    | [] -> Ok (List.rev allocated)
    | func :: rest -> (
        match allocate_function func with
        | Ok allocated_function -> loop (allocated_function :: allocated) rest
        | Error _ as error -> error)
  in
  loop [] module_
