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
  | Target.Cpu, Target.X86_avx2, 8 -> Ok ()
  | Target.Cpu, Target.Aarch64_neon, 4 -> Ok ()
  | _ ->
      Error
        {
          stage = Target;
          message =
            Printf.sprintf
              "profile '%s' has no production backend yet; select --target x86-avx2 or --target aarch64-neon"
              (Target.profile_name config.profile);
        }

let lower ~config program =
  let* () = require_backend config in
  match Native_lower.lower_program program with
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
  | Avx2 of X86_avx2_regalloc.func list
  | Neon of Aarch64_neon_regalloc.func list

let allocate_avx2 native_ir =
  match X86_avx2_isel.select native_ir with
  | Error error ->
      Error
        { stage = Instruction_selection; message = X86_avx2_isel.format_error error }
  | Ok mir -> (
      match X86_avx2_regalloc.allocate mir with
      | Ok allocated -> Ok (Avx2 allocated)
      | Error error ->
          Error
            {
              stage = Register_allocation;
              message = X86_avx2_regalloc.format_error error;
            })

let allocate_neon native_ir =
  match Aarch64_neon_isel.select native_ir with
  | Error error ->
      Error
        {
          stage = Instruction_selection;
          message = Aarch64_neon_isel.format_error error;
        }
  | Ok mir -> (
      match Aarch64_neon_regalloc.allocate mir with
      | Ok allocated -> Ok (Neon allocated)
      | Error error ->
          Error
            {
              stage = Register_allocation;
              message = Aarch64_neon_regalloc.format_error error;
            })

let allocate ~config native_ir =
  match config.Target.profile with
  | Target.X86_avx2 -> allocate_avx2 native_ir
  | Target.Aarch64_neon -> allocate_neon native_ir
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

let emit_allocated = function
  | Avx2 allocated -> (
      match X86_avx2_asm.emit allocated with
      | Ok assembly -> Ok assembly
      | Error error ->
          Error { stage = Assembly; message = X86_avx2_asm.format_error error })
  | Neon allocated -> (
      match Aarch64_neon_asm.emit allocated with
      | Ok assembly -> Ok assembly
      | Error error ->
          Error
            { stage = Assembly; message = Aarch64_neon_asm.format_error error })

let emit_assembly ~config program =
  let* allocated = compile ~config program in
  emit_allocated allocated

let emit_object ~source ~config program =
  let* assembly = emit_assembly ~config program in
  match Native_toolchain.assemble ~profile:config.profile ~source assembly with
  | Ok object_bytes -> Ok object_bytes
  | Error error ->
      Error { stage = Assemble; message = Native_toolchain.format_error error }

let fma_count = function
  | Avx2 allocated ->
      List.fold_left
        (fun count (func : X86_avx2_regalloc.func) ->
          List.fold_left
            (fun count (instruction : X86_avx2_regalloc.instruction) ->
              match instruction.operation with
              | X86_avx2_regalloc.Fma213ps _ | X86_avx2_regalloc.Fma231ps _ ->
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

let function_names = function
  | Avx2 allocated ->
      List.map (fun (func : X86_avx2_regalloc.func) -> func.name) allocated
  | Neon allocated ->
      List.map (fun (func : Aarch64_neon_regalloc.func) -> func.name) allocated

let cross_lane_function_names = function
  | Avx2 allocated ->
      List.filter_map
        (fun (func : X86_avx2_regalloc.func) ->
          if
            List.exists
              (fun (instruction : X86_avx2_regalloc.instruction) ->
                match instruction.operation with
                | X86_avx2_regalloc.Reduce_f32 _
                | X86_avx2_regalloc.Scan_f32 _ -> true
                | _ -> false)
              func.instructions
          then Some func.name
          else None)
        allocated
  | Neon _ -> []

let emit_verified_object ~source ~config program =
  let* allocated = compile ~config program in
  let* assembly = emit_allocated allocated in
  let* object_bytes =
    match Native_toolchain.assemble ~profile:config.profile ~source assembly with
    | Ok object_bytes -> Ok object_bytes
    | Error error ->
        Error { stage = Assemble; message = Native_toolchain.format_error error }
  in
  let functions = function_names allocated in
  let cross_lane_functions = cross_lane_function_names allocated in
  match
    Native_verify.verify ~profile:config.profile ~source ~functions
      ~cross_lane_functions
      ~expected_fma_count:(fma_count allocated) object_bytes
  with
  | Ok () -> Ok object_bytes
  | Error error ->
      Error { stage = Verify; message = Native_verify.format_error error }
