(** No-spill physical vector-register allocation for x86-64 SIMD profiles. *)

module M = X86_simd_mir
module I = Native_ir.IntMap
module S = Native_ir.IntSet

type vector_register = int

type operation =
  | Uniform_f32 of { dst : vector_register; bits : int32 }
  | Uniform_mask of { dst : vector_register; value : bool }
  | Broadcastss of { dst : vector_register; source : vector_register }
  | Extract_f32 of { dst : vector_register; source : vector_register; lane : M.f32_lane }
  | Insert_f32 of {
      dst : vector_register;
      previous : vector_register;
      inserted : vector_register;
      lane : M.f32_lane;
      broadcast : vector_register;
    }
  | Shuffle_word of {
      dst : vector_register;
      racks : vector_register list;
      indices : int list;
      scratch : vector_register list;
    }
  | Reduce_mask of {
      dst : vector_register;
      source : vector_register;
      operation : Native_ir.mask_reduction;
      scratch : vector_register;
    }
  | Reduce_f32 of {
      dst : vector_register;
      source : vector_register;
      operation : Native_ir.reduction;
      scratch : vector_register list;
    }
  | Scan_f32 of {
      dst : vector_register;
      source : vector_register;
      operation : Native_ir.scan;
      scratch : vector_register list;
    }
  | Addps of { dst : vector_register; left : vector_register; right : vector_register }
  | Subps of { dst : vector_register; left : vector_register; right : vector_register }
  | Add_i32 of { dst : vector_register; left : vector_register; right : vector_register }
  | Sub_i32 of { dst : vector_register; left : vector_register; right : vector_register }
  | Mul_i32 of {
      dst : vector_register;
      left : vector_register;
      right : vector_register;
      scratch : vector_register list;
    }
  | Neg_i32 of { dst : vector_register; source : vector_register }
  | Abs_i32 of { dst : vector_register; source : vector_register; sign : vector_register option }
  | Shift_i32 of { dst : vector_register; source : vector_register; count : Native_ir.I32_shift_count.t; shift : Native_ir.shift }
  | Extreme_i32 of {
      dst : vector_register;
      left : vector_register;
      right : vector_register;
      operation : M.extremum;
      scratch : vector_register list;
    }
  | Compare_i32 of { dst : vector_register; predicate : Native_ir.comparison; unsigned : bool; left : vector_register; right : vector_register; scratch : vector_register list }
  | Mulps of { dst : vector_register; left : vector_register; right : vector_register }
  | Divps of { dst : vector_register; left : vector_register; right : vector_register }
  | Extreme_f32 of {
      dst : vector_register;
      left : vector_register;
      right : vector_register;
      operation : M.extremum;
      scratch : vector_register list;
    }
  | Sqrtps of { dst : vector_register; source : vector_register }
  | Negps of { dst : vector_register; source : vector_register }
  | Absps of { dst : vector_register; source : vector_register }
  | Round_f32 of {
      dst : vector_register;
      source : vector_register;
      mode : Native_ir.rounding_mode;
      scratch : vector_register list;
    }
  | Fma213ps of { dst : vector_register; multiplier : vector_register; addend : vector_register }
  | Fma231ps of { dst : vector_register; multiplicand : vector_register; multiplier : vector_register }
  | Cmpps of {
      dst : vector_register;
      predicate : M.ordered_comparison;
      left : vector_register;
      right : vector_register;
      ordered_mask : vector_register option;
    }
  | Blendvps of { dst : vector_register; mask : vector_register; if_true : vector_register; if_false : vector_register }
  | Mask_andps of { dst : vector_register; left : vector_register; right : vector_register }
  | Mask_andnotps of { dst : vector_register; left : vector_register; right : vector_register }
  | Mask_orps of { dst : vector_register; left : vector_register; right : vector_register }
  | Mask_xorps of { dst : vector_register; left : vector_register; right : vector_register }
  | Mask_notps of { dst : vector_register; source : vector_register }
  | Moveaps of { dst : vector_register; source : vector_register }

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

let first_free register_count allocation =
  let occupied = occupied allocation in
  let rec find register =
    if register = register_count then None
    else if S.mem register occupied then find (register + 1)
    else Some register
  in
  find 0

let free_registers register_count allocation excluded =
  let occupied = occupied allocation in
  List.init register_count Fun.id
  |> List.filter (fun register ->
         not (S.mem register occupied) && not (List.mem register excluded))

let live_is_fused provenances allocation =
  I.exists
    (fun value _ ->
      match I.find_opt value provenances with
      | Some { Native_ir.fused = Some _; _ } -> true
      | _ -> false)
    allocation

let allocate_function ?(profile = Target.X86_avx2) ?parameter_assignment func =
  (* SSE2's two-address expansion reserves xmm15 for instruction-local work.
     It never holds a source value or a spill. *)
  let physical_register_count =
    if profile = Target.X86_sse2 then 15 else Target.x86_register_count profile
  in
  let register_class = Option.get (Target.info profile).mir_register_class in
  let parameter_count = List.length func.M.parameters in
  match Native_register_assignment.resolve
    ~available:(List.init physical_register_count Fun.id)
    ~argument_count:argument_register_count ~parameter_count parameter_assignment with
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
  | Ok parameter_assignment ->
    let uses = Native_register_assignment.preserve_uses
      ~instruction_count:(List.length func.instructions) parameter_assignment
      (List.map (fun parameter -> parameter.M.reg) func.parameters) (last_uses func) in
    let provenances = definition_provenance func in
    let initial_allocation =
      List.map2 (fun assignment parameter ->
        (parameter.M.reg, assignment.Native_register_assignment.register)) parameter_assignment func.parameters
      |> List.fold_left (fun allocation (value, physical) -> I.add value physical allocation) I.empty
    in
    let maximum_live = ref (I.cardinal initial_allocation) in
    let emitted_rev = ref [] in
    let allocation = ref initial_allocation in
    let physical value =
      match I.find_opt value !allocation with
      | Some register -> register
      | None -> invalid_arg (Printf.sprintf "unallocated x86 SIMD value %%%d" value)
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
            Printf.sprintf "%s requires %d simultaneously live %s registers; profile provides %d allocation slots; no spill fallback is permitted"
              (if fused then "fused region" else "native rack expression") required
              register_class physical_register_count;
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
          match first_free physical_register_count !allocation with
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
            (* The zero-minus sequence must retain its source until subtraction. *)
            | M.Neg_i32 _ -> []
            | M.Broadcastss { source; _ } -> [ source ]
            | M.Insert_f32 { previous; _ } -> [ previous ]
            (* Two permutations still need both original racks. *)
            | M.Shuffle_word { racks = [ source ]; _ } -> [ source ]
            | M.Shuffle_word _ -> []
            | M.Reduce_f32 _ | M.Scan_f32 _ -> []
            (* SSE2's final merge still needs the original input. *)
            | M.Round_f32 _ when profile = Target.X86_sse2 -> []
            (* The strict combine starts by copying left, retaining right
               until its final blend. Only left may alias the destination. *)
            | M.Extreme_f32 { left; _ } -> [ left ]
            | M.Fma_ps { addend; multiplicand; multiplier; _ } ->
                [ addend; multiplicand; multiplier ]
            | M.Blendvps { if_false; if_true; _ } -> [ if_false; if_true ]
            | M.Cmpps { left; _ } when profile = Target.X86_sse2 -> [ left ]
            | _ -> operands
          in
          (match choose_destination index candidates instruction with
          | Error _ as error -> error
          | Ok (dst, reused) ->
              let p = physical in
              let scratch_count =
                match instruction with
                | M.Compare_i32 { unsigned = true; predicate = (Native_ir.Lt | Native_ir.Le | Native_ir.Gt | Native_ir.Ge); _ }
                    when profile <> Target.X86_avx512 -> 2
                | M.Insert_f32 _ -> 1
                | M.Reduce_mask _ -> 1
                | M.Mul_i32 _ when profile = Target.X86_sse2 -> 2
                | M.Extreme_i32 _ when profile = Target.X86_sse2 -> 1
                | M.Abs_i32 _ when profile = Target.X86_sse2 -> 1
                | M.Shuffle_word { racks; _ } ->
                    (if profile = Target.X86_sse2 then 0 else 1)
                    + (if List.length racks = 2 then 1 else 0)
                | M.Cmpps { predicate = M.Ole; _ } when profile = Target.X86_sse2 -> 1
                | M.Extreme_f32 _ -> 5
                | M.Round_f32 _ when profile = Target.X86_sse2 -> 5
                | M.Reduce_f32 { operation = (Native_ir.Reduce_add | Native_ir.Reduce_mul); _ } -> 1
                | M.Scan_f32 { operation = (Native_ir.Scan_add | Native_ir.Scan_mul); _ } -> 2
                | M.Reduce_f32 _ -> 6
                | M.Scan_f32 _ -> 7
                | _ -> 0
              in
              let scratch =
                free_registers physical_register_count !allocation [ dst ]
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
                        "strict native operation requires %d simultaneous %s registers; profile provides %d; no spill fallback is permitted"
                        required register_class physical_register_count;
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
              | M.Extract_f32 { source; lane; _ } ->
                  emit loc provenance (Extract_f32 { dst; source = p source; lane })
              | M.Insert_f32 { previous; inserted; lane; _ } ->
                  emit loc provenance (Insert_f32 { dst; previous = p previous; inserted = p inserted; lane; broadcast = List.hd scratch })
              | M.Shuffle_word { racks; indices; _ } ->
                  emit loc provenance (Shuffle_word { dst; racks = List.map p racks; indices; scratch })
              | M.Reduce_mask { source; operation; _ } ->
                  emit loc provenance (Reduce_mask { dst; source = p source; operation; scratch = List.hd scratch })
              | M.Reduce_f32 { source; operation; _ } ->
                  emit loc provenance
                    (Reduce_f32 { dst; source = p source; operation; scratch })
              | M.Scan_f32 { source; operation; _ } ->
                  emit loc provenance
                    (Scan_f32 { dst; source = p source; operation; scratch })
              | M.Addps { left; right; _ } -> emit loc provenance (Addps { dst; left = p left; right = p right })
              | M.Subps { left; right; _ } -> emit loc provenance (Subps { dst; left = p left; right = p right })
              | M.Add_i32 { left; right; _ } -> emit loc provenance (Add_i32 { dst; left = p left; right = p right })
              | M.Sub_i32 { left; right; _ } -> emit loc provenance (Sub_i32 { dst; left = p left; right = p right })
              | M.Mul_i32 { left; right; _ } -> emit loc provenance (Mul_i32 { dst; left = p left; right = p right; scratch })
              | M.Extreme_i32 { left; right; operation; _ } ->
                  emit loc provenance (Extreme_i32 { dst; left = p left; right = p right; operation; scratch })
              | M.Neg_i32 { source; _ } -> emit loc provenance (Neg_i32 { dst; source = p source })
              | M.Abs_i32 { source; _ } ->
                  emit loc provenance (Abs_i32 { dst; source = p source; sign = List.nth_opt scratch 0 })
              | M.Shift_i32 { source; count; shift; _ } ->
                  emit loc provenance (Shift_i32 { dst; source = p source; count; shift })
              | M.Compare_i32 { predicate; unsigned; left; right; _ } ->
                  emit loc provenance (Compare_i32 { dst; predicate; unsigned; left = p left; right = p right; scratch })
              | M.Mulps { left; right; _ } -> emit loc provenance (Mulps { dst; left = p left; right = p right })
              | M.Divps { left; right; _ } -> emit loc provenance (Divps { dst; left = p left; right = p right })
              | M.Extreme_f32 { left; right; operation; _ } ->
                  emit loc provenance
                    (Extreme_f32 { dst; left = p left; right = p right; operation; scratch })
              | M.Sqrtps { source; _ } -> emit loc provenance (Sqrtps { dst; source = p source })
              | M.Negps { source; _ } -> emit loc provenance (Negps { dst; source = p source })
              | M.Absps { source; _ } -> emit loc provenance (Absps { dst; source = p source })
              | M.Round_f32 { source; mode; _ } ->
                  emit loc provenance (Round_f32 { dst; source = p source; mode; scratch })
              | M.Cmpps { predicate; left; right; _ } ->
                  let ordered_mask = match scratch with [] -> None | register :: _ -> Some register in
                  emit loc provenance (Cmpps { dst; predicate; left = p left; right = p right; ordered_mask })
              | M.Blendvps { mask; if_true; if_false; _ } ->
                  emit loc provenance
                    (Blendvps { dst; mask = p mask; if_true = p if_true; if_false = p if_false })
              | M.Mask_andps { left; right; _ } ->
                  emit loc provenance (Mask_andps { dst; left = p left; right = p right })
              | M.Mask_andnotps { left; right; _ } ->
                  emit loc provenance (Mask_andnotps { dst; left = p left; right = p right })
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

let allocate ?(profile = Target.X86_avx2) ?parameter_assignment module_ =
  let rec loop allocated = function
    | [] -> Ok (List.rev allocated)
    | func :: rest -> (
        match allocate_function ~profile ?parameter_assignment func with
        | Ok func -> loop (func :: allocated) rest
        | Error _ as error -> error)
  in
  loop [] module_
