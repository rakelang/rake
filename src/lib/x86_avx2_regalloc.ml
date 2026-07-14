(** No-spill physical YMM allocation for the initial AVX2 backend. *)

module M = X86_avx2_mir
module I = Native_ir.IntMap
module S = Native_ir.IntSet

type ymm = int

type operation =
  | Uniform_f32 of { dst : ymm; bits : int32 }
  | Uniform_mask of { dst : ymm; value : bool }
  | Broadcastss of { dst : ymm; source : ymm }
  | Reduce_f32 of {
      dst : ymm;
      source : ymm;
      operation : Native_ir.reduction;
      scratch : ymm list;
    }
  | Scan_f32 of {
      dst : ymm;
      source : ymm;
      operation : Native_ir.scan;
      scratch : ymm list;
    }
  | Addps of { dst : ymm; left : ymm; right : ymm }
  | Subps of { dst : ymm; left : ymm; right : ymm }
  | Mulps of { dst : ymm; left : ymm; right : ymm }
  | Divps of { dst : ymm; left : ymm; right : ymm }
  | Sqrtps of { dst : ymm; source : ymm }
  | Negps of { dst : ymm; source : ymm }
  | Fma213ps of { dst : ymm; multiplier : ymm; addend : ymm }
  | Fma231ps of { dst : ymm; multiplicand : ymm; multiplier : ymm }
  | Cmpps of {
      dst : ymm;
      predicate : M.ordered_comparison;
      left : ymm;
      right : ymm;
    }
  | Blendvps of { dst : ymm; mask : ymm; if_true : ymm; if_false : ymm }
  | Mask_andps of { dst : ymm; left : ymm; right : ymm }
  | Mask_orps of { dst : ymm; left : ymm; right : ymm }
  | Mask_xorps of { dst : ymm; left : ymm; right : ymm }
  | Mask_notps of { dst : ymm; source : ymm }
  | Moveaps of { dst : ymm; source : ymm }

type instruction = {
  operation : operation;
  loc : Native_ir.source_location;
  provenance : Native_ir.provenance;
}

type func = {
  name : string;
  loc : Native_ir.source_location;
  instructions : instruction list;
  result : ymm option;
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

let physical_register_count = 16
let argument_register_count = 8

let last_uses func =
  let uses =
    List.mapi (fun index instruction -> (index, M.operands instruction)) func.M.instructions
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

let expire uses index allocation =
  I.filter (fun value _ -> last_use uses value >= index) allocation

let occupied allocation = I.fold (fun _ physical set -> S.add physical set) allocation S.empty

let first_free allocation =
  let occupied = occupied allocation in
  let rec find register =
    if register = physical_register_count then None
    else if S.mem register occupied then find (register + 1)
    else Some register
  in
  find 0

let free_registers allocation excluded =
  let occupied = occupied allocation in
  List.init physical_register_count Fun.id
  |> List.filter (fun register ->
         not (S.mem register occupied) && not (List.mem register excluded))

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
            "native AVX2 SysV calling convention requires %d SSE-class arguments but provides %d register argument slots; stack arguments are forbidden"
            parameter_count argument_register_count;
      }
  else
    let uses = last_uses func in
    let provenances = definition_provenance func in
    let initial_allocation =
      List.mapi (fun physical parameter -> (parameter.M.reg, physical)) func.parameters
      |> List.fold_left (fun allocation (value, physical) -> I.add value physical allocation) I.empty
    in
    let maximum_live = ref (I.cardinal initial_allocation) in
    let emitted_rev = ref [] in
    let allocation = ref initial_allocation in
    let physical value =
      match I.find_opt value !allocation with
      | Some register -> register
      | None -> invalid_arg (Printf.sprintf "unallocated AVX2 value %%%d" value)
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
            Printf.sprintf "%s requires %d simultaneously live YMM registers; profile provides %d; no spill fallback is permitted"
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
                      operation = Moveaps { dst = 0; source };
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
            | M.Uniform_f32 _ | M.Uniform_mask _ -> []
            | M.Broadcastss { source; _ } -> [ source ]
            | M.Reduce_f32 _ | M.Scan_f32 _ -> []
            | M.Fma_ps { addend; multiplicand; multiplier; _ } ->
                [ addend; multiplicand; multiplier ]
            | M.Blendvps { if_false; if_true; _ } -> [ if_false; if_true ]
            | _ -> operands
          in
          (match choose_destination index candidates instruction with
          | Error _ as error -> error
          | Ok (dst, reused) ->
              let p = physical in
              let scratch_count =
                match instruction with
                | M.Reduce_f32 { operation = (Native_ir.Reduce_add | Native_ir.Reduce_mul); _ } -> 1
                | M.Scan_f32 { operation = (Native_ir.Scan_add | Native_ir.Scan_mul); _ } -> 2
                | M.Reduce_f32 _ -> 6
                | M.Scan_f32 _ -> 7
                | _ -> 0
              in
              let scratch =
                free_registers !allocation [ dst ]
                |> List.filteri (fun index _ -> index < scratch_count)
              in
              if List.length scratch <> scratch_count then
                let required = I.cardinal !allocation + 1 + scratch_count in
                Error
                  {
                    function_name = func.name;
                    loc;
                    required;
                    available = physical_register_count;
                    fused = false;
                    message =
                      Printf.sprintf
                        "strict cross-lane operation requires %d simultaneous YMM registers; profile provides %d; no spill fallback is permitted"
                        required physical_register_count;
                  }
              else (
              let destination_growth = if reused = None then 1 else 0 in
              maximum_live :=
                max !maximum_live
                  (I.cardinal !allocation + destination_growth + scratch_count);
              (match instruction with
              | M.Uniform_f32 { bits; _ } -> emit loc provenance (Uniform_f32 { dst; bits })
              | M.Uniform_mask { value; _ } -> emit loc provenance (Uniform_mask { dst; value })
              | M.Broadcastss { source; _ } ->
                  emit loc provenance (Broadcastss { dst; source = p source })
              | M.Reduce_f32 { source; operation; _ } ->
                  emit loc provenance
                    (Reduce_f32 { dst; source = p source; operation; scratch })
              | M.Scan_f32 { source; operation; _ } ->
                  emit loc provenance
                    (Scan_f32 { dst; source = p source; operation; scratch })
              | M.Addps { left; right; _ } -> emit loc provenance (Addps { dst; left = p left; right = p right })
              | M.Subps { left; right; _ } -> emit loc provenance (Subps { dst; left = p left; right = p right })
              | M.Mulps { left; right; _ } -> emit loc provenance (Mulps { dst; left = p left; right = p right })
              | M.Divps { left; right; _ } -> emit loc provenance (Divps { dst; left = p left; right = p right })
              | M.Sqrtps { source; _ } -> emit loc provenance (Sqrtps { dst; source = p source })
              | M.Negps { source; _ } -> emit loc provenance (Negps { dst; source = p source })
              | M.Cmpps { predicate; left; right; _ } ->
                  emit loc provenance (Cmpps { dst; predicate; left = p left; right = p right })
              | M.Blendvps { mask; if_true; if_false; _ } ->
                  emit loc provenance
                    (Blendvps { dst; mask = p mask; if_true = p if_true; if_false = p if_false })
              | M.Mask_andps { left; right; _ } ->
                  emit loc provenance (Mask_andps { dst; left = p left; right = p right })
              | M.Mask_orps { left; right; _ } ->
                  emit loc provenance (Mask_orps { dst; left = p left; right = p right })
              | M.Mask_xorps { left; right; _ } ->
                  emit loc provenance (Mask_xorps { dst; left = p left; right = p right })
              | M.Mask_notps { source; _ } -> emit loc provenance (Mask_notps { dst; source = p source })
              | M.Fma_ps { multiplicand; multiplier; addend; _ } ->
                  let multiplicand_reg = p multiplicand in
                  let multiplier_reg = p multiplier in
                  let addend_reg = p addend in
                  if reused = Some addend then
                    emit loc provenance
                      (Fma231ps { dst; multiplicand = multiplicand_reg; multiplier = multiplier_reg })
                  else if reused = Some multiplicand then
                    emit loc provenance
                      (Fma213ps { dst; multiplier = multiplier_reg; addend = addend_reg })
                  else if reused = Some multiplier then
                    emit loc provenance
                      (Fma213ps { dst; multiplier = multiplicand_reg; addend = addend_reg })
                  else (
                    emit loc provenance (Moveaps { dst; source = multiplicand_reg });
                    emit loc provenance
                      (Fma213ps { dst; multiplier = multiplier_reg; addend = addend_reg })));
              finish_instruction index instruction dst reused;
              allocate (index + 1) rest))
    in
    allocate 0 func.instructions

let allocate module_ =
  let rec loop allocated = function
    | [] -> Ok (List.rev allocated)
    | func :: rest -> (
        match allocate_function func with
        | Ok func -> loop (func :: allocated) rest
        | Error _ as error -> error)
  in
  loop [] module_
