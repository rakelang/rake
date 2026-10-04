(** Native stream traversals. The loop, addresses and partial-rack
    memory operations are selected here; rack expressions use the existing
    SSA selector and allocator. There is no C loop or scalar arithmetic tail.
    General runs remain rejected until their control/storage contracts have
    corresponding native implementations. *)

open Tier_ir

exception Unsupported of Ast.loc * string
let reject loc fmt = Printf.ksprintf (fun text -> raise (Unsupported (loc, text))) fmt

type compiled = { assembly : string; functions : string list }

type output = Stream | Column of string * string
type count_width = Count32 | Count64

(* Rebind checked names to immutable SSA aliases. An assignment changes the
   alias for subsequent expressions, leaving earlier snapshots intact. *)
let rec rename_bindings bindings (expression : Ast.expr) : Ast.expr =
  let walk = rename_bindings bindings in
  let rename name = Option.value (List.assoc_opt name bindings) ~default:name in
  let v = match expression.v with
    | EVar name -> Ast.EVar (rename name)
    | EScalarVar name -> Ast.EScalarVar (rename name)
    | EBroadcast e -> Ast.EBroadcast (walk e)
    | EBinop (a, op, b) -> EBinop (walk a, op, walk b)
    | EUnop (op, e) -> EUnop (op, walk e)
    | ECall (name, args) -> ECall (name, List.map walk args)
    | EIf (c, a, b) -> EIf (walk c, walk a, walk b)
    | EFma (a, b, c) -> EFma (walk a, walk b, walk c)
    | EConvert (kind, ty, e) -> EConvert (kind, ty, walk e)
    | EReduce (op, e) -> EReduce (op, walk e)
    | EScan (op, e) -> EScan (op, walk e)
    | EExtract (e, lane) -> EExtract (walk e, walk lane)
    | EInsert (e, lane, value) -> EInsert (walk e, walk lane, walk value)
    | EShuffle (e, indices) -> EShuffle (walk e, indices)
    | other -> other
  in
  { expression with v }

(* Uniform conditions are hoisted by the run checker. Restore the
   checked, direct comparison or Boolean so the common lowerer selects its vector
   mask, including the outer tail's participation. Other scalar work stays
   outside the supported native traversal subset. *)
let rec uniform_condition_expression uniforms bindings (value : expr) =
  let walk = uniform_condition_expression uniforms bindings in
  let operand (value : expr) : Ast.expr =
    let v = match value.ty, value.k with
      | Sc scalar, Var name when List.assoc_opt name uniforms = Some scalar -> Ast.EScalarVar name
      | Sc _, Var name when List.mem_assoc name bindings -> Ast.EScalarVar (List.assoc name bindings)
      | Sc Types.SFloat, Float number -> Ast.EFloat number
      | Sc (Types.SInt | Types.SUint), Int number -> Ast.EInt number
      | Sc Types.SBool, Bool boolean -> Ast.EBroadcast { Ast.v = Ast.EBool boolean; loc = value.loc }
      | _ -> reject value.loc
          "native stream uniform conditions take f32/i32/u32/bool parameters or literals; other scalar expressions are work in progress" in
    { Ast.v; loc = value.loc } in
  match value.ty, value.k with
  | Sc Types.SBool, Compare (comparison, left, right) ->
      let comparison = match comparison with
        | Lt -> Ast.Lt | Le -> Ast.Le | Gt -> Ast.Gt
        | Ge -> Ast.Ge | Eq -> Ast.Eq | Ne -> Ast.Ne in
      { Ast.v = Ast.EBinop (operand left, comparison, operand right); loc = value.loc }
  | Sc Types.SBool, (Var _ | Bool _) -> operand value
  | Sc Types.SBool, Logic (conjunction, left, right) ->
      { Ast.v = Ast.EBinop (walk left, (if conjunction then Ast.And else Ast.Or), walk right); loc = value.loc }
  | Sc Types.SBool, Unary (Not, inner) ->
      { Ast.v = Ast.EUnop (Ast.Not, walk inner); loc = value.loc }
  | _ -> reject value.loc
      "native stream uniform conditions support f32/i32/u32 comparisons, Booleans and and/or/not; other scalar expressions are work in progress"

let uniform_type = function
  | Types.SFloat -> Native_ir.Scalar Native_ir.F32
  | Types.SInt -> Native_ir.Scalar Native_ir.I32
  | Types.SUint -> Native_ir.Scalar Native_ir.U32
  | Types.SBool -> Native_ir.Scalar Native_ir.I1
  | _ -> invalid_arg "unsupported native stream uniform type"

let column_type = function
  | Types.SFloat -> Native_ir.Rack Native_ir.F32
  | Types.SInt -> Native_ir.Rack Native_ir.I32
  | Types.SUint -> Native_ir.Rack Native_ir.U32
  | _ -> invalid_arg "unsupported native stream column type"

let column_supported = function Types.SFloat | Types.SInt | Types.SUint -> true | _ -> false

let column_load_supported element stored =
  column_supported element && (element = stored || match element, stored with
    | Types.SInt, (Types.SInt8 | Types.SInt16)
    | Types.SUint, (Types.SUint8 | Types.SUint16) -> true
    | _ -> false)

let output_pack program run owner =
  match List.find_opt (function Run_stack (name, _, true) -> name = owner | _ -> false) run.run_params with
  | Some (Run_stack (_, schema, _)) -> find_pack program schema
  | _ -> invalid_arg "native traversal output missing from its checked mutable stacks"

(* Stack descriptors, counts and the stream result consume integer slots.
   Floating-point arguments advance a separate ABI counter. *)
let uniform_arguments ~profile run uniforms output =
  let integer = ref (List.fold_left (fun count -> function
    | Run_stack _ -> count + 1 | _ -> count) 1 run.run_params) in
  let floating = ref 0 in
  let arguments = List.map (fun (name, scalar) ->
    let counter = if scalar = Types.SFloat then floating else integer in
    let slot = !counter in
    incr counter;
    name, scalar, slot) uniforms in
  let output_slot = if output = Stream then (let slot = !integer in incr integer; Some slot) else None in
  let capacity = if Target.is_x86 profile then 6 else 8 in
  if !integer > capacity then
    reject run.run_loc "native stream C boundary needs %d integer register slots but this profile provides %d; stack arguments are work in progress" !integer capacity;
  arguments, output_slot

let uniform_register profile index =
  let first = match profile with
    | Target.X86_sse2 -> 7
    | Target.X86_avx2 -> 8
    | Target.X86_avx512 -> 24
    | Target.Aarch64_neon -> 16
    | _ -> invalid_arg "native stream uniform profile"
  in
  first + index

let compile_body ~profile program run traverse uniforms output ~tail =
  let bindings = ref [] and conditions = ref [] and columns = ref [] and result = ref None in
  let expressions = ref [] and locations = ref [] and next_binding = ref 0 in
  let fresh () =
    incr next_binding;
    Printf.sprintf "$native_binding_%d" !next_binding in
  let bind name alias = bindings := (name, alias) :: List.remove_assoc name !bindings in
  let alias loc name = match List.assoc_opt name !bindings with
    | Some alias -> alias
    | None -> reject loc "native traversal value '%s' is not bound" name in
  let rec statements body = List.iter (fun statement ->
    if !result <> None then reject statement.rloc "native traversal must end with its yield or column update";
    match statement.r with
    | R_chunk_load (name, element, field, stored) when column_load_supported element stored ->
        let existing = List.find_opt (fun (_, e, f, s) ->
          e = element && f = field && s = stored) !columns in
        (match existing with
         | Some (parameter, _, _, _) -> bind name parameter
         | None ->
             columns := !columns @ [ name, element, field, stored ];
             bind name name)
    | R_pure (name, Rack (Types.SFloat | Types.SInt | Types.SUint), expression, false)
    | R_pure (name, Mask _, expression, false) ->
        let expression = rename_bindings !bindings expression in
        let value = fresh () in
        expressions := (value, expression) :: !expressions;
        bind name value
    | R_uniform (name, value) ->
        if value.ty <> Sc Types.SBool then reject value.loc
          "native stream local uniform bindings currently require bool; other scalar bindings are work in progress";
        let expression = uniform_condition_expression uniforms !bindings value in
        let condition = fresh () in
        conditions := !conditions @ [ condition, expression ];
        bind name condition
    | R_location (name, (Rack (Types.SFloat | Types.SInt | Types.SUint) | Mask _), first) ->
        bind name (alias statement.rloc first);
        locations := name :: !locations
    | R_set (name, value) when List.mem name !locations ->
        bind name (alias statement.rloc value)
    | R_block body ->
        let outer_bindings = !bindings and outer_locations = !locations in
        statements body;
        bindings := List.map (fun (name, previous) ->
          name, if List.mem name outer_locations then alias statement.rloc name else previous)
          outer_bindings;
        locations := outer_locations
    | R_yield name when output = Stream ->
        result := Some { Ast.v = Ast.EVar (alias statement.rloc name); loc = statement.rloc }
    | R_output (owner, field, name) when output = Column (owner, field) ->
        result := Some { Ast.v = Ast.EVar (alias statement.rloc name); loc = statement.rloc }
    | _ -> reject statement.rloc
        "native traversals currently support f32/i32/u32 columns, explicit byte/16-bit widening, local rack assignments, unrolled repeat and one final yield or column update; this run operation is work in progress") body in
  statements traverse.t_body;
  let expression = match !result with Some e -> e | None -> reject run.run_loc "native traversal requires a 32-bit rack output expression" in
  if List.length !columns = 0 || List.length !columns > 4 then
    reject run.run_loc "native streams currently load one to four columns into f32/i32/u32 racks";
  let parameters = List.map (fun (name, element, _, _) -> name, column_type element) !columns
    @ List.map (fun (name, scalar) -> name, uniform_type scalar) uniforms in
  let mask = if tail then Some "$native_tail" else None in
  let parameters = match mask with None -> parameters | Some name -> parameters @ [ name, Native_ir.Mask ] in
  let parameter_assignment =
    List.mapi (fun register _ -> { Native_register_assignment.register; persistent = false }) !columns
    @ List.mapi (fun index _ ->
        { Native_register_assignment.register = uniform_register profile index; persistent = true }) uniforms
    @ (if tail then [ { Native_register_assignment.register = List.length !columns; persistent = false } ] else []) in
  Native_ir.floating_point_exceptions := true;
  let func = match Native_lower.lower_expression ~profile ~definitions:program.vector_defs
    ~condition_bindings:!conditions ~expression_bindings:(List.rev !expressions)
    ~name:run.run_name ~parameters ?mask ~fused:false run.run_loc expression with
    | Ok f -> f | Error e -> reject run.run_loc "%s" (Native_lower.format_error e) in
  let output_element = match output with
    | Stream -> Option.get run.run_stream
    | Column (owner, field) -> List.assoc field (output_pack program run owner).pack_fields in
  if not (column_supported output_element) || func.result <> Some (column_type output_element) then
    reject run.run_loc "native traversal expression must match its f32/i32/u32 output column or stream";
  let ir = match Native_optimize.optimize ~profile [ func ] with
    | Ok ir -> ir | Error e -> reject run.run_loc "%s" (Native_optimize.format_error e) in
  let allocation =
    if Target.is_x86 profile then Native_backend.allocate_x86 ~profile ~parameter_assignment ir
    else Native_backend.allocate_neon ~parameter_assignment ir in
  let allocated = match allocation with
    | Ok allocated -> allocated
    | Error e -> reject run.run_loc "%s" (Native_backend.format_error e)
  in
  (* Tail participation follows the source operation, not its instruction
     sequence: SSE2 multiplication permutes partial products back to their
     original lanes. Actual cross-lane expressions remain unsupported. *)
  if List.exists (fun (instruction : Native_ir.instruction) ->
      match instruction.op with
      | Native_ir.Reduce _ | Native_ir.Scan _ | Native_ir.Extract _
      | Native_ir.Insert _ | Native_ir.Shuffle _ -> true
      | _ -> false) func.body.instructions then
    reject run.run_loc "native stream reductions, scans, extractions, insertions and shuffles are work in progress";
  allocated, !columns

let run_traversal (run : run) =
  match run.run_body, run.run_params, run.run_stream with
    | [ { r = R_traverse t; _ } ], Run_stack (input, schema, writable) :: Run_uniform (count, ((Types.SInt | Types.SInt64) as count_type)) :: arguments, stream
      when t.t_stack = input && t.t_pack = schema && column_supported t.t_domain
        && (match t.t_count.k with Var n -> n = count | _ -> false) ->
        let destination, uniforms = match arguments with
          | Run_stack (owner, _, true) :: rest -> Some owner, rest
          | _ -> None, arguments in
        let output = match stream, destination, List.rev t.t_body with
          | Some element, None, { r = R_yield _; _ } :: _ when not writable && element = t.t_domain -> Stream
          | None, None, { r = R_output (owner, field, _); _ } :: _ when owner = input && writable -> Column (owner, field)
          | None, Some destination, { r = R_output (owner, field, _); _ } :: _ when owner = destination -> Column (owner, field)
          | _ -> reject run.run_loc "native traversals end with one stream yield matching the f32/i32/u32 domain or one 32-bit column update in a mutable stack; other outputs are work in progress" in
        if List.length uniforms > 8 then
          reject run.run_loc "native streams accept at most eight uniform arguments; stack arguments are work in progress";
        let uniforms = List.map (function
          | Run_uniform (name, ((Types.SFloat | Types.SInt | Types.SUint | Types.SBool) as scalar)) -> name, scalar
          | _ -> reject run.run_loc "native stream arguments after the count must be uniform f32/i32/u32/bool values; other arguments are work in progress") uniforms in
        let count_width = if count_type = Types.SInt then Count32 else Count64 in
        t, count_width, uniforms, output
    | _ -> reject run.run_loc "native traversals currently support one f32/i32/u32 traversal with an input stack, an i32 or i64 count, an optional mutable destination stack and uniform f32/i32/u32/bool arguments; general native runs are work in progress"

let column_offset schema field =
  let rec offset n = function
    | (f, _) :: _ when f = field -> n * 8
    | _ :: rest -> offset (n + 1) rest
    | [] -> invalid_arg "native traversal column missing from its checked pack"
  in
  offset 0 schema.pack_fields

let emit_x86_run ~profile program buffer (run : run) =
  let sse2 = profile = Target.X86_sse2 in
  let avx512 = profile = Target.X86_avx512 in
  let lanes = (Target.info profile).f32_lanes in
  let alignment = if sse2 then 4 else if avx512 then 6 else 5 in
  let register = X86_simd_asm.vector_register profile in
  let memory = if sse2 then "XMMWORD" else if avx512 then "ZMMWORD" else "YMMWORD" in
  let move = if sse2 then "movups" else "vmovups" in
  let traverse, count_width, uniforms, output = run_traversal run in
  let arguments, output_slot = uniform_arguments ~profile run uniforms output in
  let full, columns = compile_body ~profile program run traverse uniforms output ~tail:false in
  let tail, tail_columns = compile_body ~profile program run traverse uniforms output ~tail:true in
  let x86_function = function
    | Native_backend.X86 (_, [ func ]) -> func
    | _ -> assert false in
  let full = x86_function full and tail = x86_function tail in
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
  let widening_instruction stored =
    "vpmov" ^ (if is_signed stored then "sx" else "zx")
    ^ (if bytes stored = 1 then "bd" else "wd") in
  let widen_register index stored =
    if bytes stored < 4 then
      if sse2 then (
        (* Duplicate each stored element through its dword, then use one
           packed shift to retain either its sign or its unsigned value. *)
        if bytes stored = 1 then emit "punpcklbw xmm%d, xmm%d" index index;
        emit "punpcklwd xmm%d, xmm%d" index index;
        emit "%s xmm%d, %d" (if is_signed stored then "psrad" else "psrld")
          index (32 - bits stored))
      else emit "%s %s, xmm%d" (widening_instruction stored) (register index) index in
  let load_column ~masked index (_, _, _, stored) =
    let width = bytes stored in
    let address = Printf.sprintf "[%s + rax*%d]" pointers.(index) width in
    if width = 4 then
      emit "%s %s%s, %s PTR %s" move (register index)
        (if masked then "{k2}{z}" else "") memory address
    else if sse2 then (
      emit "%s xmm%d, %s PTR %s" (if width = 1 then "movd" else "movq") index
        (if width = 1 then "DWORD" else "QWORD") address;
      widen_register index stored)
    else
      let source_memory = match lanes * width with
        | 8 -> "QWORD" | 16 -> "XMMWORD" | 32 -> "YMMWORD"
        | _ -> invalid_arg "native widening load width" in
      emit "%s %s%s, %s PTR %s" (widening_instruction stored) (register index)
        (if masked then "{k2}{z}" else "") source_memory address in
  (* Match the literal-pool alignment at the function entry. Its relative
     offsets then stay identical in isolated and mixed-program objects. *)
  Printf.bprintf buffer ".intel_syntax noprefix\n.text\n.p2align %d\n.globl %s\n.type %s, @function\n%s:\n"
    alignment run.run_name run.run_name run.run_name;
  (* The C ABI does not define the upper half of an incoming i32 argument.
     Normalise it before signed count guards or 64-bit pointer arithmetic. *)
  (match count_width with Count32 -> emit "movsxd rsi, esi" | Count64 -> ());
  emit "test rsi, rsi";
  emit "jle %s" (label "return");
  (* Copy backwards because SSE2's final ABI input, xmm7, is also its first
     preserved slot. These arguments stay live in the allocator across racks. *)
  List.mapi (fun index argument -> index, argument) arguments |> List.rev |> List.iter (fun (index, (_, scalar, slot)) ->
    let destination = uniform_register profile index in
    if scalar = Types.SFloat then (
      if avx512 then emit "vbroadcastss zmm%d, xmm%d" destination slot
      else emit "%s xmm%d, xmm%d" (if sse2 then "movaps" else "vmovaps") destination slot));
  List.iteri (fun index (_, scalar, slot) ->
    if scalar <> Types.SFloat then
      emit "%smovd xmm%d, %s" (if sse2 then "" else "v") (uniform_register profile index)
        (List.nth [ "edi"; "esi"; "edx"; "ecx"; "r8d"; "r9d" ] slot)) arguments;
  Option.iter (fun slot ->
    let source = List.nth [ "rdi"; "rsi"; "rdx"; "rcx"; "r8"; "r9" ] slot in
    if source <> "rdx" then emit "mov rdx, %s" source) output_slot;
  List.iteri (fun index (_, _, field, _) ->
    emit "mov %s, QWORD PTR [rdi + %d]" pointers.(index) (column_offset schema field)) columns;
  (match output with
   | Stream -> ()
   | Column (owner, field) ->
       let descriptor = if owner = traverse.t_stack then "rdi" else "rdx" in
       emit "mov rdx, QWORD PTR [%s + %d]" descriptor (column_offset (output_pack program run owner) field));
  emit "xor eax, eax";
  emit "cmp rsi, %d" lanes;
  emit "jl %s" (label "tail");
  Printf.bprintf buffer "%s:\n" (label "loop");
  List.iteri (load_column ~masked:false) columns;
  body full;
  emit "%s %s PTR [rdx + rax*4], %s" move memory (register 0);
  emit "add rax, %d" lanes;
  emit "sub rsi, %d" lanes;
  emit "cmp rsi, %d" lanes;
  emit "jge %s" (label "loop");
  Printf.bprintf buffer "%s:\n" (label "tail");
  emit "test rsi, rsi";
  emit "je %s" (label "return");
  let mask_register = List.length columns in
  if sse2 then (
    (* SSE2 has no fault-suppressing f32 vector load. Guard the three possible
       lane transfers by the uniform count, then evaluate one masked rack.
       xmm15 is the SSE selector's reserved instruction-local temporary. *)
    emit "lea rcx, [rip + %s]" (label "masks");
    emit "mov edi, esi";
    emit "shl edi, %d" alignment;
    emit "add rcx, rdi";
    emit "movaps %s, %s PTR [rcx]" (register mask_register) memory;
    List.iteri (fun index (_, _, _, stored) ->
      if bytes stored < 4 then emit "pxor xmm%d, xmm%d" index index) columns;
    for lane = 0 to lanes - 2 do
      if lane > 0 then (
        emit "cmp rsi, %d" (lane + 1);
        emit "jl %s" (label "tail_loaded"));
      List.iteri (fun index (_, _, _, stored) ->
        if bytes stored = 1 then (
          (* SSE2 has no byte lane load. This transfers one guarded byte
             into compact storage; widening remains a packed operation. *)
          emit "movzx edi, BYTE PTR [%s + rax + %d]" pointers.(index) lane;
          emit "movd xmm15, edi";
          if lane > 0 then emit "pslldq xmm15, %d" lane;
          emit "por xmm%d, xmm15" index)
        else if bytes stored = 2 then
          emit "pinsrw xmm%d, WORD PTR [%s + rax*2 + %d], %d" index pointers.(index) (lane * 2) lane
        else if lane = 0 then
          emit "movss %s, DWORD PTR [%s + rax*4]" (register index) pointers.(index)
        else (
          emit "movss xmm15, DWORD PTR [%s + rax*4 + %d]" pointers.(index) (lane * 4);
          emit "%s %s, xmm15" (if lane = 1 then "unpcklps" else "movlhps") (register index))) columns
    done;
    Printf.bprintf buffer "%s:\n" (label "tail_loaded");
    List.iteri (fun index (_, _, _, stored) -> widen_register index stored) columns)
  else if avx512 then (
    (* k1 belongs to the register selector. k2 preserves the memory
       participation mask through comparisons and blends in the body. *)
    emit "mov ecx, esi";
    emit "mov edi, 1";
    emit "shl edi, cl";
    emit "dec edi";
    emit "kmovw k2, edi";
    emit "vpxord %s, %s, %s" (register mask_register) (register mask_register) (register mask_register);
    emit "vpternlogd %s{k2}, %s, %s, 0xff" (register mask_register) (register mask_register) (register mask_register);
    List.iteri (load_column ~masked:true) columns)
  else (
    emit "lea rcx, [rip + %s]" (label "masks");
    emit "mov edi, esi";
    emit "shl edi, %d" alignment;
    emit "add rcx, rdi";
    emit "vmovups %s, %s PTR [rcx]" (register mask_register) memory;
    List.iteri (fun index (_, _, _, stored) ->
      if bytes stored = 4 then
        emit "vmaskmovps %s, %s, %s PTR [%s + rax*4]" (register index) (register mask_register) memory pointers.(index)
      else emit "vpxor xmm%d, xmm%d, xmm%d" index index index) columns;
    if List.exists (fun (_, _, _, stored) -> bytes stored < 4) columns then (
      (* AVX2 lacks fault-suppressing byte/word extension loads. Assemble
         only participating storage elements, then widen the whole rack. *)
      for lane = 0 to lanes - 2 do
        if lane > 0 then (
          emit "cmp rsi, %d" (lane + 1);
          emit "jl %s" (label "tail_narrow_loaded"));
        List.iteri (fun index (_, _, _, stored) ->
          if bytes stored < 4 then
            emit "%s xmm%d, xmm%d, %s PTR [%s + rax*%d + %d], %d"
              (if bytes stored = 1 then "vpinsrb" else "vpinsrw") index index
              (if bytes stored = 1 then "BYTE" else "WORD") pointers.(index)
              (bytes stored) (lane * bytes stored) lane) columns
      done;
      Printf.bprintf buffer "%s:\n" (label "tail_narrow_loaded");
      List.iteri (fun index (_, _, _, stored) -> widen_register index stored) columns));
  body tail;
  (* AVX2 allocation may reuse the input mask register; reload it only after
     the result has reached its ABI register. ymm1 is dead at this point. *)
  if sse2 then (
    for lane = 0 to lanes - 2 do
      if lane = 0 then emit "movss DWORD PTR [rdx + rax*4], xmm0"
      else (
        emit "cmp rsi, %d" (lane + 1);
        emit "jl %s" (label "return");
        emit "movaps xmm15, xmm0";
        emit "shufps xmm15, xmm15, 0x%02x" (lane * 0x55);
        emit "movss DWORD PTR [rdx + rax*4 + %d], xmm15" (lane * 4))
    done)
  else if avx512 then emit "vmovups %s PTR [rdx + rax*4]{k2}, %s" memory (register 0)
  else (
    emit "vmovups ymm1, YMMWORD PTR [rcx]";
    emit "vmaskmovps YMMWORD PTR [rdx + rax*4], ymm1, ymm0");
  Printf.bprintf buffer "%s:\n" (label "return");
  if not sse2 then emit "vzeroupper";
  emit "ret";
  (* Constant labels emitted by the register selector need per-run scopes.
     Rewrite its private label prefix once, including their references. *)
  List.iter (fun (constant, constant_label) ->
    Printf.bprintf buffer ".p2align %d\n%s:\n" alignment constant_label;
    let bits = match constant with X86_simd_asm.Splat_f32 b -> [ b ] | Vector_bits bs -> bs in
    List.iter (fun bits -> Printf.bprintf buffer "    .long 0x%08lx\n" bits) bits) pool.entries;
  if not avx512 then (
    Printf.bprintf buffer ".p2align %d\n%s:\n" alignment (label "masks");
    for active = 0 to lanes - 1 do
      for lane = 0 to lanes - 1 do
        Printf.bprintf buffer "    .long 0x%08lx\n" (if lane < active then -1l else 0l)
      done
    done);
  Printf.bprintf buffer ".size %s, .-%s\n.att_syntax prefix\n" run.run_name run.run_name

let emit_neon_run program buffer (run : run) =
  let profile = Target.Aarch64_neon in
  let traverse, count_width, uniforms, output = run_traversal run in
  let arguments, output_slot = uniform_arguments ~profile run uniforms output in
  let full, columns = compile_body ~profile program run traverse uniforms output ~tail:false in
  let tail, tail_columns = compile_body ~profile program run traverse uniforms output ~tail:true in
  if columns <> tail_columns then assert false;
  let schema = find_pack program traverse.t_pack in
  let pool = Aarch64_neon_asm.create_pool () in
  let emit format = Printf.bprintf buffer ("    " ^^ format ^^ "\n") in
  let label suffix = ".Lrake_stream_" ^ run.run_name ^ "_" ^ suffix in
  let pointer index = Printf.sprintf "x%d" (index + 3) in
  let body = function
    | Native_backend.Neon [ func ] ->
        List.iter (Aarch64_neon_asm.emit_instruction pool buffer) func.instructions
    | _ -> assert false in
  let widen_register index stored =
    if bytes stored < 4 then (
      let instruction = if is_signed stored then "sshll" else "ushll" in
      if bytes stored = 1 then emit "%s v%d.8h, v%d.8b, #0" instruction index index;
      emit "%s v%d.4s, v%d.4h, #0" instruction index index) in
  Printf.bprintf buffer ".arch armv8-a+simd\n.text\n.p2align 4\n.globl %s\n.type %s, %%function\n%s:\n"
    run.run_name run.run_name run.run_name;
  (match count_width with Count32 -> emit "sxtw x1, w1" | Count64 -> ());
  emit "cmp x1, #0";
  emit "b.le %s" (label "return");
  List.iteri (fun index (_, scalar, slot) ->
    if scalar = Types.SFloat then
      emit "dup v%d.4s, v%d.s[0]" (uniform_register profile index) slot
    else emit "fmov s%d, w%d" (uniform_register profile index) slot) arguments;
  Option.iter (fun slot -> if slot <> 2 then emit "mov x2, x%d" slot) output_slot;
  List.iteri (fun index (_, _, field, _) ->
    let displacement = column_offset schema field in
    if displacement > 32760 then
      reject run.run_loc "native NEON stream column exceeds the supported descriptor offset";
    emit "ldr %s, [x0, #%d]" (pointer index) displacement) columns;
  (match output with
   | Stream -> ()
   | Column (owner, field) ->
       let descriptor = if owner = traverse.t_stack then "x0" else "x2" in
       let displacement = column_offset (output_pack program run owner) field in
       if displacement > 32760 then
         reject run.run_loc "native NEON traversal output exceeds the supported descriptor offset";
       emit "ldr x2, [%s, #%d]" descriptor displacement);
  emit "cmp x1, #4";
  emit "b.lt %s" (label "tail");
  Printf.bprintf buffer "%s:\n" (label "loop");
  List.iteri (fun index (_, _, _, stored) ->
    emit "ldr %s%d, [%s], #%d" (match bytes stored with 1 -> "s" | 2 -> "d" | _ -> "q")
      index (pointer index) (4 * bytes stored);
    widen_register index stored) columns;
  body full;
  emit "str q0, [x2], #16";
  emit "sub x1, x1, #4";
  emit "cmp x1, #4";
  emit "b.ge %s" (label "loop");
  Printf.bprintf buffer "%s:\n" (label "tail");
  emit "cbz x1, %s" (label "return");
  (* Count-guarded lane transfers cover the one-to-three-element tail.
     Only the transfers are lane-sized: its arithmetic is one masked rack. *)
  emit "adr x7, %s" (label "masks");
  emit "add x7, x7, x1, lsl #4";
  emit "ldr q%d, [x7]" (List.length columns);
  List.iteri (fun index _ -> emit "movi v%d.4s, #0" index) columns;
  for lane = 0 to 2 do
    if lane > 0 then (
      emit "cmp x1, #%d" (lane + 1);
      emit "b.lt %s" (label "tail_loaded"));
    List.iteri (fun index (_, _, _, stored) ->
      emit "ld1 {v%d.%s}[%d], [%s], #%d" index
        (match bytes stored with 1 -> "b" | 2 -> "h" | _ -> "s")
        lane (pointer index) (bytes stored)) columns
  done;
  Printf.bprintf buffer "%s:\n" (label "tail_loaded");
  List.iteri (fun index (_, _, _, stored) -> widen_register index stored) columns;
  body tail;
  for lane = 0 to 2 do
    if lane > 0 then (
      emit "cmp x1, #%d" (lane + 1);
      emit "b.lt %s" (label "return"));
    emit "st1 {v0.s}[%d], [x2], #4" lane
  done;
  Printf.bprintf buffer "%s:\n" (label "return");
  emit "ret";
  (* PC-relative literals stay in the function's checked, relocation-free
     extent, with identical alignment in isolated and mixed objects. *)
  List.iter (fun (bits, constant_label) ->
    Printf.bprintf buffer ".p2align 4\n%s:\n" constant_label;
    List.iter (fun bits -> Printf.bprintf buffer "    .long 0x%08lx\n" bits) bits) pool.entries;
  Printf.bprintf buffer ".p2align 4\n%s:\n" (label "masks");
  for active = 0 to 3 do
    for lane = 0 to 3 do
      Printf.bprintf buffer "    .long 0x%08lx\n" (if lane < active then -1l else 0l)
    done
  done;
  Printf.bprintf buffer ".size %s, .-%s\n" run.run_name run.run_name

let compile ~profile program =
  if not (Target.is_x86 profile || profile = Target.Aarch64_neon) then (
    match program.runs with
    | run :: _ -> reject run.run_loc "native streams require a physical x86 or NEON SIMD profile"
    | [] -> ());
  let parts = List.map (fun run ->
    let buffer = Buffer.create 2048 in
    let constant_prefix = if profile = Target.Aarch64_neon then (
      emit_neon_run program buffer run;
      ".Lrake_neon_const_")
    else (
      emit_x86_run ~profile program buffer run;
      ".Lrake_const_") in
    Str.global_replace (Str.regexp_string constant_prefix)
      (".Lrake_stream_" ^ run.run_name ^ "_const_") (Buffer.contents buffer)) program.runs in
  let progbits = if profile = Target.Aarch64_neon then "%progbits" else "@progbits" in
  { assembly = String.concat "\n" parts ^ ".section .note.GNU-stack,\"\"," ^ progbits ^ "\n";
    functions = List.map (fun run -> run.run_name) program.runs }
