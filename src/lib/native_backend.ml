(** Rake-owned production backend pipeline.

    The system assembler is deliberately the only external stage here: source
    lowering, legalization, instruction selection, physical register
    allocation, and textual assembly emission remain compiler-owned. *)

type stage =
  | Target
  | Native_ir
  | Optimization
  | Instruction_selection
  | Register_allocation
  | Assembly
  | Assemble
  | Verify

type error = { stage : stage; message : string }

let stage_name = function
  | Target -> "native target selection"
  | Native_ir -> "native SSA lowering"
  | Optimization -> "native graph optimization"
  | Instruction_selection -> "native instruction selection"
  | Register_allocation -> "native register allocation"
  | Assembly -> "native assembly emission"
  | Assemble -> "native object assembly"
  | Verify -> "native object verification"

let format_error error = Printf.sprintf "%s failed: %s" (stage_name error.stage) error.message

let ( let* ) = Result.bind

let require_backend (config : Target.config) =
  match (config.target, config.profile, config.width) with
  | Target.Cpu, Target.X86_sse2, 4 -> Ok ()
  | Target.Cpu, Target.X86_avx2, 8 -> Ok ()
  | Target.Cpu, Target.X86_avx512, 16 -> Ok ()
  | Target.Cpu, Target.Aarch64_neon, 4 -> Ok ()
  | Target.Cpu, (Target.Wasm_simd128 | Target.Wasm_simd128_relaxed), 4 -> Ok ()
  | _ ->
      Error
        {
          stage = Target;
          message =
            Printf.sprintf
              "profile '%s' has no production backend yet; select --target x86-sse2, x86-avx2, x86-avx512, aarch64-neon or wasm-simd128"
              (Target.profile_name config.profile);
        }

let lower ~config program =
  let* () = require_backend config in
  Native_lower.relaxed := config.Target.profile = Target.Wasm_simd128_relaxed;
  Native_ir.floating_point_exceptions := not (Target.is_wasm config.Target.profile);
  Wasm_simd128_c.relaxed := !Native_lower.relaxed;
  Wasm_simd128_toolchain.relaxed := !Native_lower.relaxed;
  match Native_lower.lower_program ~profile:config.profile program with
  | Ok native_ir -> (
      match Native_optimize.optimize ~profile:config.profile native_ir with
      | Ok optimized -> Ok optimized
      | Error errors ->
          Error
            {
              stage = Optimization;
              message = Native_optimize.format_error errors;
            })
  | Error error -> Error { stage = Native_ir; message = Native_lower.format_error error }

type allocated =
  | X86 of Target.profile * X86_simd_regalloc.func list
  | Neon of Aarch64_neon_regalloc.func list
  | Wasm of Wasm_simd128_isel.func list  (** WebAssembly locals need no register allocation *)

let allocate_x86 ~profile ?parameter_assignment native_ir =
  match X86_simd_isel.select ~profile native_ir with
  | Error error ->
      Error
        { stage = Instruction_selection; message = X86_simd_isel.format_error error }
  | Ok mir -> (
      match X86_simd_regalloc.allocate ~profile ?parameter_assignment mir with
      | Ok allocated -> Ok (X86 (profile, allocated))
      | Error error ->
          Error
            {
              stage = Register_allocation;
              message = X86_simd_regalloc.format_error error;
            })

let allocate_neon ?parameter_assignment native_ir =
  match Aarch64_neon_isel.select native_ir with
  | Error error ->
      Error
        {
          stage = Instruction_selection;
          message = Aarch64_neon_isel.format_error error;
        }
  | Ok mir -> (
      match Aarch64_neon_regalloc.allocate ?parameter_assignment mir with
      | Ok allocated -> Ok (Neon allocated)
      | Error error ->
          Error
            {
              stage = Register_allocation;
              message = Aarch64_neon_regalloc.format_error error;
            })

let allocate ~config native_ir =
  match config.Target.profile with
  | (Target.X86_sse2 | Target.X86_avx2 | Target.X86_avx512) as profile -> allocate_x86 ~profile native_ir
  | Target.Aarch64_neon -> allocate_neon native_ir
  | Target.Wasm_simd128 | Target.Wasm_simd128_relaxed -> (
      match Wasm_simd128_isel.select native_ir with
      | Ok selected -> Ok (Wasm selected)
      | Error error ->
          Error { stage = Instruction_selection; message = Wasm_simd128_isel.format_error error })
  | profile ->
      Error
        {
          stage = Target;
          message =
            Printf.sprintf "profile '%s' has no production backend yet"
              (Target.profile_name profile);
        }

let compile ~config program =
  let* native_ir = lower ~config program in
  allocate ~config native_ir

let emit_allocated ~source = function
  | Wasm selected -> (
      match Wasm_simd128_c.emit ~source selected with
      | source -> Ok source
      | exception Wasm_simd128_c.Emission_error message -> Error { stage = Assembly; message })
  | X86 (profile, allocated) -> (
      match X86_simd_asm.emit ~profile allocated with
      | Ok assembly -> Ok assembly
      | Error error ->
          Error { stage = Assembly; message = X86_simd_asm.format_error error })
  | Neon allocated -> (
      match Aarch64_neon_asm.emit allocated with
      | Ok assembly -> Ok assembly
      | Error error ->
          Error
            { stage = Assembly; message = Aarch64_neon_asm.format_error error })

let emit_assembly ~source ~config program =
  let* allocated = compile ~config program in
  emit_allocated ~source allocated

let assemble ~source ~(config : Target.config) assembly =
  match config.profile with
  | Target.Wasm_simd128 | Target.Wasm_simd128_relaxed -> (
      match Wasm_simd128_toolchain.assemble assembly with
      | Ok object_bytes -> Ok object_bytes
      | Error error -> Error { stage = Assemble; message = Wasm_simd128_toolchain.format_error error })
  | profile -> (
      match Native_toolchain.assemble ~profile ~source assembly with
      | Ok object_bytes -> Ok object_bytes
      | Error error -> Error { stage = Assemble; message = Native_toolchain.format_error error })

let emit_object ~source ~config program =
  let* assembly = emit_assembly ~source ~config program in
  assemble ~source ~config assembly

let fma_count = function
  | X86 (_, allocated) ->
      List.fold_left
        (fun count (func : X86_simd_regalloc.func) ->
          List.fold_left
            (fun count (instruction : X86_simd_regalloc.instruction) ->
              match instruction.operation with
              | X86_simd_regalloc.Fma213ps _ | X86_simd_regalloc.Fma231ps _ ->
                  count + 1
              | _ -> count)
            count func.instructions)
        0 allocated
  | Neon allocated ->
      List.fold_left
        (fun count (func : Aarch64_neon_regalloc.func) ->
          List.fold_left
            (fun count (instruction : Aarch64_neon_regalloc.instruction) ->
              match instruction.operation with
              | Aarch64_neon_regalloc.Fmla _ -> count + 1
              | _ -> count)
            count func.instructions)
        0 allocated
  | Wasm _ -> 0

let function_names = function
  | Wasm selected -> List.map (fun (func : Wasm_simd128_isel.func) -> func.name) selected
  | X86 (_, allocated) ->
      List.map (fun (func : X86_simd_regalloc.func) -> func.name) allocated
  | Neon allocated ->
      List.map (fun (func : Aarch64_neon_regalloc.func) -> func.name) allocated

let cross_lane_function_names = function
  | X86 (profile, allocated) ->
      List.filter_map
        (fun (func : X86_simd_regalloc.func) ->
          if
            List.exists
              (fun (instruction : X86_simd_regalloc.instruction) ->
                match instruction.operation with
                | X86_simd_regalloc.Reduce_f32 _
                | X86_simd_regalloc.Reduce_mask _
                | X86_simd_regalloc.Scan_f32 _
                | X86_simd_regalloc.Extract_f32 _
                | X86_simd_regalloc.Insert_f32 _
                | X86_simd_regalloc.Shuffle_f32 _ -> true
                (* SSE2's packed low-word multiplication permutes two sets
                   of products back into their original lane order. *)
                | X86_simd_regalloc.Mul_i32 _ -> profile = Target.X86_sse2
                | _ -> false)
              func.instructions
          then Some func.name
          else None)
        allocated
  | Neon allocated ->
      List.filter_map (fun (func : Aarch64_neon_regalloc.func) ->
        if List.exists (fun (instruction : Aarch64_neon_regalloc.instruction) ->
          match instruction.operation with
          | Aarch64_neon_regalloc.Broadcast_f32 { lane; _ } -> lane <> Aarch64_neon_mir.Lane0
          | Aarch64_neon_regalloc.Insert_f32 _ | Aarch64_neon_regalloc.Reduce_mask _ -> true
          | _ -> false) func.instructions
        then Some func.name else None) allocated
  | Wasm _ -> []

let integer_result_function_names =
  let is_integer = function
    | Some (Native_ir.Scalar (Native_ir.I1 | Native_ir.I32)) -> true
    | _ -> false in
  function
  | X86 (_, allocated) -> List.filter_map (fun (func : X86_simd_regalloc.func) ->
      if is_integer func.result_type then Some func.name else None) allocated
  | Neon allocated -> List.filter_map (fun (func : Aarch64_neon_regalloc.func) ->
      if is_integer func.result_type then Some func.name else None) allocated
  | Wasm _ -> []

let verify_allocated_object ~source ~(config : Target.config) allocated object_bytes =
  let functions = function_names allocated in
  match allocated with
  | Wasm _ -> (
      match Wasm_simd128_toolchain.verify ~functions object_bytes with
      | Ok () -> Ok object_bytes
      | Error error -> Error { stage = Verify; message = Wasm_simd128_toolchain.format_error error })
  | X86 _ | Neon _ ->
    let cross_lane_functions = cross_lane_function_names allocated in
    match
      Native_verify.verify ~profile:config.profile ~source ~functions
        ~cross_lane_functions
        ~integer_result_functions:(integer_result_function_names allocated)
        ~expected_fma_count:(fma_count allocated) object_bytes
    with
    | Ok () -> Ok object_bytes
    | Error error ->
      Error { stage = Verify; message = Native_verify.format_error error }

let emit_verified_object ~source ~config program =
  let* allocated = compile ~config program in
  let* assembly = emit_allocated ~source allocated in
  let* object_bytes = assemble ~source ~config assembly in
  verify_allocated_object ~source ~config allocated object_bytes
