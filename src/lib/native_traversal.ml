(** Native AVX2 and AVX-512 stream traversals. The loop, addresses and partial-rack
    memory operations are selected here; rack expressions use the existing
    SSA selector and allocator. There is no C loop or scalar arithmetic tail.
    General runs remain rejected until their control/storage contracts have
    corresponding native implementations. *)

open Tier_ir

exception Unsupported of Ast.loc * string
let reject loc fmt = Printf.ksprintf (fun text -> raise (Unsupported (loc, text))) fmt

type compiled = { assembly : string; functions : string list }

(* Expand A-normal immutable bindings into the expression consumed by the
   common lowerer. This stage rejects other forms rather than dropping work. *)
let rec expand bindings (expression : Ast.expr) : Ast.expr =
  let walk = expand bindings in
  let v = match expression.v with
    | EVar name -> (match List.assoc_opt name bindings with Some e -> e.Ast.v | None -> expression.v)
    | EBroadcast e -> Ast.EBroadcast (walk e)
    | EBinop (a, op, b) -> EBinop (walk a, op, walk b)
    | EUnop (op, e) -> EUnop (op, walk e)
    | ECall (name, args) -> ECall (name, List.map walk args)
    | EIf (c, a, b) -> EIf (walk c, walk a, walk b)
    | EFma (a, b, c) -> EFma (walk a, walk b, walk c)
    | EConvert (kind, ty, e) -> EConvert (kind, ty, walk e)
    | other -> other
  in
  { expression with v }

let compile_body ~profile program run traverse ~tail =
  let bindings = ref [] and columns = ref [] and result = ref None in
  List.iter (fun statement ->
    if !result <> None then reject statement.rloc "native traversal must end with its yield";
    match statement.r with
    | R_chunk_load (name, Types.SFloat, field, Types.SFloat) ->
        columns := !columns @ [ name, field ]
    | R_pure (name, Rack Types.SFloat, expression, false)
    | R_pure (name, Mask _, expression, false) ->
        bindings := (name, expand !bindings expression) :: !bindings
    | R_yield name -> result := List.assoc_opt name !bindings
    | _ -> reject statement.rloc
        "native streams currently support f32 columns, immutable lane expressions and one yield; this run operation is work in progress") traverse.t_body;
  let expression = match !result with Some e -> e | None -> reject run.run_loc "native stream requires a yielded f32 expression" in
  if List.length !columns = 0 || List.length !columns > 4 then
    reject run.run_loc "native streams currently load one to four f32 columns";
  let parameters = List.map (fun (name, _) -> name, Native_ir.Rack Native_ir.F32) !columns in
  let mask = if tail then Some "$native_tail" else None in
  let parameters = match mask with None -> parameters | Some name -> parameters @ [ name, Native_ir.Mask ] in
  Native_ir.floating_point_exceptions := true;
  let func = match Native_lower.lower_expression ~definitions:program.vector_defs
    ~name:run.run_name ~parameters ?mask ~fused:false run.run_loc expression with
    | Ok f -> f | Error e -> reject run.run_loc "%s" (Native_lower.format_error e) in
  let ir = match Native_optimize.optimize ~profile [ func ] with
    | Ok ir -> ir | Error e -> reject run.run_loc "%s" (Native_optimize.format_error e) in
  let allocated = match Native_backend.allocate_x86 ~profile ir with
    | Ok (Native_backend.X86 (_, [ func ])) -> func
    | Error e -> reject run.run_loc "%s" (Native_backend.format_error e)
    | _ -> assert false in
  (match allocated.result_type with Some (Native_ir.Rack Native_ir.F32) -> ()
    | _ -> reject run.run_loc "native stream expression must produce f32s");
  (* Cross-lane operations need a separately defined participation contract
     for tails. Do not accept them through expression expansion. *)
  if Native_backend.cross_lane_function_names (Native_backend.X86 (profile, [ allocated ])) <> [] then
    reject run.run_loc "native stream reductions and scans are work in progress";
  allocated, !columns

let emit_run ~profile program buffer (run : run) =
  let avx512 = profile = Target.X86_avx512 in
  let lanes = (Target.info profile).f32_lanes in
  let alignment = if avx512 then 6 else 5 in
  let register = X86_simd_asm.vector_register profile in
  let memory = if avx512 then "ZMMWORD" else "YMMWORD" in
  let traverse = match run.run_body, run.run_params, run.run_stream with
    | [ { r = R_traverse t; _ } ], [ Run_stack (input, schema, false); Run_uniform (count, Types.SInt64) ], Some Types.SFloat
      when t.t_stack = input && t.t_pack = schema && t.t_domain = Types.SFloat
        && (match t.t_count.k with Var n -> n = count | _ -> false) -> t
    | _ -> reject run.run_loc "native streams currently support one f32 stream traversal with a read-only stack and an i64 count; general native runs are work in progress" in
  let full, columns = compile_body ~profile program run traverse ~tail:false in
  let tail, tail_columns = compile_body ~profile program run traverse ~tail:true in
  if columns <> tail_columns then assert false;
  let schema = find_pack program traverse.t_pack in
  let pool = X86_simd_asm.create_pool () in
  (* Labels are local to this function; unlike separate register kernels the
     literals are in its own text extent, requiring no ELF relocations. *)
  pool.next_label <- 0;
  let emit format = Printf.bprintf buffer ("    " ^^ format ^^ "\n") in
  let label suffix = ".Lrake_stream_" ^ run.run_name ^ "_" ^ suffix in
  let pointers = [| "r8"; "r9"; "r10"; "r11" |] in
  let body allocated =
    let block = Buffer.create 512 in
    List.iter (X86_simd_asm.emit_instruction profile pool block) allocated.X86_simd_regalloc.instructions;
    Buffer.add_string buffer (Buffer.contents block) in
  (* Match the literal-pool alignment at the function entry. Its relative
     offsets then stay identical in isolated and mixed-program objects. *)
  Printf.bprintf buffer ".intel_syntax noprefix\n.text\n.p2align %d\n.globl %s\n.type %s, @function\n%s:\n"
    alignment run.run_name run.run_name run.run_name;
  emit "test rsi, rsi";
  emit "jle %s" (label "return");
  List.iteri (fun index (_, field) ->
    let rec offset n = function
      | (f, _) :: _ when f = field -> n * 8
      | _ :: rest -> offset (n + 1) rest
      | [] -> assert false in
    emit "mov %s, QWORD PTR [rdi + %d]" pointers.(index) (offset 0 schema.pack_fields)) columns;
  emit "xor eax, eax";
  emit "cmp rsi, %d" lanes;
  emit "jl %s" (label "tail");
  Printf.bprintf buffer "%s:\n" (label "loop");
  List.iteri (fun index _ -> emit "vmovups %s, %s PTR [%s + rax*4]" (register index) memory pointers.(index)) columns;
  body full;
  emit "vmovups %s PTR [rdx + rax*4], %s" memory (register 0);
  emit "add rax, %d" lanes;
  emit "sub rsi, %d" lanes;
  emit "cmp rsi, %d" lanes;
  emit "jge %s" (label "loop");
  Printf.bprintf buffer "%s:\n" (label "tail");
  emit "test rsi, rsi";
  emit "je %s" (label "return");
  let mask_register = List.length columns in
  if avx512 then (
    (* k1 belongs to the register selector. k2 preserves the memory
       participation mask through comparisons and blends in the body. *)
    emit "mov ecx, esi";
    emit "mov edi, 1";
    emit "shl edi, cl";
    emit "dec edi";
    emit "kmovw k2, edi";
    emit "vpxord %s, %s, %s" (register mask_register) (register mask_register) (register mask_register);
    emit "vpternlogd %s{k2}, %s, %s, 0xff" (register mask_register) (register mask_register) (register mask_register);
    List.iteri (fun index _ ->
      emit "vmovups %s{k2}{z}, %s PTR [%s + rax*4]" (register index) memory pointers.(index)) columns)
  else (
    emit "lea rcx, [rip + %s]" (label "masks");
    emit "shl rsi, %d" alignment;
    emit "add rcx, rsi";
    emit "vmovups %s, %s PTR [rcx]" (register mask_register) memory;
    List.iteri (fun index _ ->
      emit "vmaskmovps %s, %s, %s PTR [%s + rax*4]" (register index) (register mask_register) memory pointers.(index)) columns);
  body tail;
  (* AVX2 allocation may reuse the input mask register; reload it only after
     the result has reached its ABI register. ymm1 is dead at this point. *)
  if avx512 then emit "vmovups %s PTR [rdx + rax*4]{k2}, %s" memory (register 0)
  else (
    emit "vmovups ymm1, YMMWORD PTR [rcx]";
    emit "vmaskmovps YMMWORD PTR [rdx + rax*4], ymm1, ymm0");
  Printf.bprintf buffer "%s:\n" (label "return");
  emit "vzeroupper";
  emit "ret";
  (* Constant labels emitted by the register selector need per-run scopes.
     Rewrite its private label prefix once, including their references. *)
  List.iter (fun (constant, constant_label) ->
    Printf.bprintf buffer ".p2align %d\n%s:\n" alignment constant_label;
    let bits = match constant with X86_simd_asm.Splat_f32 b -> [ b ] | Vector_f32 bs -> bs in
    List.iter (fun bits -> Printf.bprintf buffer "    .long 0x%08lx\n" bits) bits) pool.entries;
  if not avx512 then (
    Printf.bprintf buffer ".p2align %d\n%s:\n" alignment (label "masks");
    for active = 0 to lanes - 1 do
      for lane = 0 to lanes - 1 do
        Printf.bprintf buffer "    .long 0x%08lx\n" (if lane < active then -1l else 0l)
      done
    done);
  Printf.bprintf buffer ".size %s, .-%s\n.att_syntax prefix\n" run.run_name run.run_name

let compile ~profile program =
  if not (List.mem profile [ Target.X86_avx2; Target.X86_avx512 ]) then (
    match program.runs with
    | run :: _ -> reject run.run_loc "native streams currently require x86-avx2 or x86-avx512; other native run profiles are work in progress"
    | [] -> ());
  let parts = List.map (fun run ->
    let buffer = Buffer.create 2048 in
    emit_run ~profile program buffer run;
    Str.global_replace (Str.regexp_string ".Lrake_const_")
      (".Lrake_stream_" ^ run.run_name ^ "_const_") (Buffer.contents buffer)) program.runs in
  { assembly = String.concat "\n" parts ^ ".section .note.GNU-stack,\"\",@progbits\n";
    functions = List.map (fun run -> run.run_name) program.runs }
