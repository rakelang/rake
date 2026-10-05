(** Native stack runs. One kernel computes every output of a rack. This
    module selects the loop, the addresses, the partial-rack memory operations
    and compaction. Rack expressions use the shared SSA selector and allocator.
    There is no C loop or scalar arithmetic tail. *)

open Tier_ir

exception Unsupported of Ast.loc * string
let reject loc fmt = Printf.ksprintf (fun text -> raise (Unsupported (loc, text))) fmt

type compiled = { assembly : string; functions : string list; facts : (string * string list) list }

(** One column a run reads or writes: its stack, field and stored element, the
    element of its rack, and its pointer's offset in the stack descriptor. *)
type column = { owner : string; field : string; stored : Types.scalar; element : Types.scalar; offset : int }

(** What a kernel output becomes: a replaced column, the compaction's
    selection, or a compacted column. *)
type output = Replace of column | Selection | Compacted of column

type argument = Stack_argument of string * int | Uniform_argument of string * Types.scalar * int

let column_type = function
  | Types.SFloat -> Native_ir.Rack Native_ir.F32
  | Types.SInt -> Native_ir.Rack Native_ir.I32
  | Types.SUint -> Native_ir.Rack Native_ir.U32
  | _ -> invalid_arg "unsupported native column type"

let uniform_type = function
  | Types.SFloat -> Native_ir.Scalar Native_ir.F32
  | Types.SInt -> Native_ir.Scalar Native_ir.I32
  | Types.SUint -> Native_ir.Scalar Native_ir.U32
  | Types.SBool -> Native_ir.Scalar Native_ir.I1
  | _ -> invalid_arg "unsupported native uniform type"

(** The 32-bit rack a stored element is computed in. *)
let working_element loc = function
  | (Types.SFloat | SInt | SUint) as element -> element
  | SInt8 | SInt16 -> SInt
  | SUint8 | SUint16 -> SUint
  | element -> reject loc "native stack runs compute 32-bit lanes; a %s column is work in progress" (string_of_ty (Sc element))

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

(* Uniform conditions are hoisted by the run checker. Restore the checked,
   direct comparison or Boolean so the common lowerer selects its vector mask,
   including the tail's participation. Other scalar work stays outside the
   supported native subset. *)
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
          "native uniform conditions take f32/i32/u32/bool parameters or literals; other scalar expressions are work in progress" in
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
      "native uniform conditions support f32/i32/u32 comparisons, Booleans and and/or/not; other scalar expressions are work in progress"

(** Argument slots in source order: stack descriptors and integer uniforms
    take integer registers, f32 uniforms the vector argument registers. *)
let arguments ~profile (run : run) =
  let integer = ref 0 and floating = ref 0 in
  let take counter = let slot = !counter in incr counter; slot in
  let arguments = List.map (function
    | Run_stack (name, _) -> Stack_argument (name, take integer)
    | Run_uniform (name, (Types.SFloat as scalar)) -> Uniform_argument (name, scalar, take floating)
    | Run_uniform (name, ((Types.SInt | Types.SUint | Types.SBool) as scalar)) -> Uniform_argument (name, scalar, take integer)
    | Run_uniform (name, scalar) ->
        reject run.run_loc "native uniform %s is %s; native runs take f32, i32, u32 and bool uniforms" name (string_of_ty (Sc scalar))
    | Run_view (name, _, _) -> reject run.run_loc "view %s: views in native stack runs are work in progress" name
    | Run_rack (name, _) -> reject run.run_loc "rack parameter %s: native stack runs take stacks and uniforms" name) run.run_params in
  let capacity = if Target.is_x86 profile then 6 else 8 in
  if !integer > capacity then
    reject run.run_loc "this run needs %d integer argument registers and the profile provides %d; stack arguments are forbidden" !integer capacity;
  let uniforms = List.filter_map (function Uniform_argument (name, scalar, _) -> Some (name, scalar) | _ -> None) arguments in
  if List.length uniforms > 8 then reject run.run_loc "native runs take at most eight uniform arguments";
  if !floating > 8 then reject run.run_loc "native runs take at most eight f32 uniforms";
  arguments, uniforms

(** The first register of the persistent uniforms, past the column and mask
    registers. *)
let uniform_base = function
  | Target.X86_sse2 -> 7
  | Target.X86_avx2 -> 8
  | Target.X86_avx512 -> 24
  | Target.Aarch64_neon -> 16
  | _ -> invalid_arg "native uniform profile"

let uniform_register profile index = uniform_base profile + index

(* C leaves bits above a Boolean's value unspecified. The register allocator
   leaves persistent uniforms to the traversal, which keeps only bit zero once,
   before its loop, with the same packed shifts as a kernel entry. *)
let boolean_normalisation profile uniforms =
  let count = Option.get (Native_ir.I32_shift_count.of_int32 31l) in
  List.concat (List.mapi (fun index (_, scalar) ->
    if scalar <> Types.SBool then []
    else
      let dst = uniform_register profile index in
      [ dst, count, Native_ir.Shift_left; dst, count, Native_ir.Shift_right ]) uniforms)

let descriptor_offset program stack field =
  let pack = find_pack program stack in
  let rec offset n = function
    | (f, _) :: _ when f = field -> 8 + n * 8
    | _ :: rest -> offset (n + 1) rest
    | [] -> invalid_arg "native column missing from its checked pack"
  in
  offset 0 pack.pack_fields

type kernel = {
  allocated : Native_backend.allocated;
  loaded : column list;  (** in their rack registers 0, 1, ... *)
  outputs : (output * int) list;  (** each output and the register holding it *)
}

let compile_kernel ~profile program (run : run) traverse uniforms ~tail =
  let bindings = ref [] and conditions = ref [] and loaded = ref [] and outputs = ref [] in
  let expressions = ref [] and locations = ref [] and next_binding = ref 0 in
  let fresh () = incr next_binding; Printf.sprintf "$native_binding_%d" !next_binding in
  let bind name alias = bindings := (name, alias) :: List.remove_assoc name !bindings in
  let alias loc name = match List.assoc_opt name !bindings with
    | Some alias -> alias
    | None -> reject loc "native value '%s' is not bound" name in
  let column loc owner field =
    let stored = List.assoc field (find_pack program (match List.find (function Run_stack (n, _) -> n = owner | _ -> false) run.run_params with
      | Run_stack (_, pack) -> pack | _ -> assert false)).pack_fields in
    { owner; field; stored; element = working_element loc stored; offset = descriptor_offset program
        (match List.find (function Run_stack (n, _) -> n = owner | _ -> false) run.run_params with Run_stack (_, pack) -> pack | _ -> assert false) field } in
  let output loc kind name = outputs := !outputs @ [ kind, { Ast.v = Ast.EVar (alias loc name); loc } ] in
  let rec statements body = List.iter (fun statement ->
    match statement.r with
    | R_chunk_load (name, element, owner, field, stored) ->
        let c = column statement.rloc owner field in
        if c.element <> element || c.stored <> stored then
          reject statement.rloc "native column %s.%s is loaded as %s" owner field (string_of_ty (Rack element));
        if not (List.exists (fun l -> l.owner = owner && l.field = field) !loaded) then loaded := !loaded @ [ c ];
        let index = let rec find i = function l :: _ when l.owner = owner && l.field = field -> i | _ :: rest -> find (i + 1) rest | [] -> assert false in find 0 !loaded in
        bind name (Printf.sprintf "$column_%d" index)
    | R_pure (name, (Rack (Types.SFloat | Types.SInt | Types.SUint) | Mask _), expression, false) ->
        let expression = rename_bindings !bindings expression in
        let value = fresh () in
        expressions := (value, expression) :: !expressions;
        bind name value
    | R_uniform (name, value) ->
        if value.ty <> Sc Types.SBool then reject value.loc
          "native local uniform bindings currently require bool; other scalar bindings are work in progress";
        let expression = uniform_condition_expression uniforms !bindings value in
        let condition = fresh () in
        conditions := !conditions @ [ condition, expression ];
        bind name condition
    | R_location (name, (Rack (Types.SFloat | Types.SInt | Types.SUint) | Mask _), first) ->
        bind name (alias statement.rloc first);
        locations := name :: !locations
    | R_set (name, value) when List.mem name !locations -> bind name (alias statement.rloc value)
    | R_block body ->
        let outer_bindings = !bindings and outer_locations = !locations in
        statements body;
        bindings := List.map (fun (name, previous) ->
          name, if List.mem name outer_locations then alias statement.rloc name else previous) outer_bindings;
        locations := outer_locations
    | R_output (owner, field, name) -> output statement.rloc (Replace (column statement.rloc owner field)) name
    | R_compact (mask, racks) ->
        output statement.rloc Selection mask;
        List.iter (fun (field, rack) -> output statement.rloc (Compacted (column statement.rloc traverse.t_stack field)) rack) racks
    | _ -> reject statement.rloc
        "native stack runs support 32-bit and widened compact columns, rack bindings, local rack assignments, unrolled repeat, Boolean uniform bindings and their result; this operation is work in progress") body in
  statements traverse.t_body;
  let columns = List.length !loaded in
  let column_limit = match profile with
    | Target.X86_sse2 -> 6 | Target.X86_avx2 -> 7 | Target.Aarch64_neon -> 7 | _ -> 20 in
  if columns > column_limit then
    reject run.run_loc "this run reads %d columns and %s keeps at most %d in registers" columns (Target.profile_name profile) column_limit;
  let parameters =
    List.mapi (fun index c -> Printf.sprintf "$column_%d" index, column_type c.element) !loaded
    @ List.map (fun (name, scalar) -> name, uniform_type scalar) uniforms in
  let mask = if tail then Some "$native_tail" else None in
  let parameters = match mask with None -> parameters | Some name -> parameters @ [ name, Native_ir.Mask ] in
  let parameter_assignment =
    List.mapi (fun register _ -> { Native_register_assignment.register; persistent = false }) !loaded
    @ List.mapi (fun index _ ->
        { Native_register_assignment.register = uniform_register profile index; persistent = true }) uniforms
    @ (if tail then [ { Native_register_assignment.register = columns; persistent = false } ] else []) in
  let func, types = match Native_lower.lower_kernel ~profile ~definitions:program.vector_defs
    ~condition_bindings:!conditions ~expression_bindings:(List.rev !expressions)
    ~name:run.run_name ~parameters ?mask ~fused:false run.run_loc (List.map snd !outputs) with
    | Ok lowered -> lowered | Error e -> reject run.run_loc "%s" (Native_lower.format_error e) in
  List.iter2 (fun (kind, _) typ ->
    let expected = match kind with
      | Replace c | Compacted c -> column_type c.element
      | Selection -> Native_ir.Mask in
    if typ <> expected then
      reject run.run_loc "native result has %s where %s is expected" (Native_ir.string_of_typ typ) (Native_ir.string_of_typ expected))
    !outputs types;
  if List.exists (fun (instruction : Native_ir.instruction) ->
      match instruction.op with
      | Native_ir.Reduce _ | Native_ir.Scan _ | Native_ir.Extract _
      | Native_ir.Insert _ | Native_ir.Shuffle _ -> true
      | _ -> false) func.body.instructions then
    reject run.run_loc "native stack run reductions, scans, extractions, insertions and shuffles are work in progress";
  let ir = match Native_optimize.optimize ~profile [ func ] with
    | Ok ir -> ir | Error e -> reject run.run_loc "%s" (Native_optimize.format_error e) in
  let allocated =
    match (if Target.is_x86 profile then Native_backend.allocate_x86 ~profile ~parameter_assignment ir
           else Native_backend.allocate_neon ~parameter_assignment ir) with
    | Ok allocated -> allocated
    | Error e -> reject run.run_loc "%s" (Native_backend.format_error e) in
  let registers = match allocated with
    | Native_backend.X86 (_, [ f ]) -> f.X86_simd_regalloc.outputs
    | Native_backend.Neon [ f ] -> f.Aarch64_neon_regalloc.outputs
    | _ -> assert false in
  { allocated; loaded = !loaded; outputs = List.map2 (fun (kind, _) register -> kind, register) !outputs registers }

let run_traversal (run : run) =
  match run.run_body, run.run_result with
  | [ { r = R_traverse t; _ } ], Some (result, _) when t.t_stack = result -> t
  | _ -> reject run.run_loc "native code compiles stack runs; general runs over views are work in progress on physical targets"

(* ─── x86 ───────────────────────────────────────────────────────────── *)

let x86_argument_registers = [| "rdi"; "rsi"; "rdx"; "rcx"; "r8"; "r9" |]
let x86_dword = function
  | "rax" -> "eax" | "rbx" -> "ebx" | "rcx" -> "ecx" | "rdx" -> "edx" | "rsi" -> "esi" | "rdi" -> "edi"
  | "rbp" -> "ebp" | r -> r ^ "d"
let x86_callee_saved = [ "rbx"; "rbp"; "r12"; "r13"; "r14"; "r15" ]

let x86_kernel_registers = function
  | Native_backend.X86 (_, [ f ]) -> List.concat_map (fun i -> X86_simd_asm.registers i.X86_simd_regalloc.operation) f.instructions
  | _ -> assert false

let emit_x86_run ~profile program buffer (run : run) =
  let sse2 = profile = Target.X86_sse2 in
  let avx512 = profile = Target.X86_avx512 in
  let lanes = (Target.info profile).f32_lanes in
  let alignment = if sse2 then 4 else if avx512 then 6 else 5 in
  let register = X86_simd_asm.vector_register profile in
  let memory = if sse2 then "XMMWORD" else if avx512 then "ZMMWORD" else "YMMWORD" in
  let move = if sse2 then "movups" else "vmovups" in
  let traverse = run_traversal run in
  let arguments, uniforms = arguments ~profile run in
  let full = compile_kernel ~profile program run traverse uniforms ~tail:false in
  let tail = compile_kernel ~profile program run traverse uniforms ~tail:true in
  let loaded = full.loaded in
  let compacting = List.exists (fun (o, _) -> o = Selection) full.outputs in
  let x86_function = function Native_backend.X86 (_, [ func ]) -> func | _ -> assert false in
  let pool = X86_simd_asm.create_pool () in
  pool.next_label <- 0;
  let emit format = Printf.bprintf buffer ("    " ^^ format ^^ "\n") in
  let label suffix = ".Lrake_stream_" ^ run.run_name ^ "_" ^ suffix in
  let descriptor name = List.find_map (function Stack_argument (n, slot) when n = name -> Some x86_argument_registers.(slot) | _ -> None) arguments |> Option.get in
  let descriptors = List.filter_map (function Stack_argument (_, slot) -> Some x86_argument_registers.(slot) | _ -> None) arguments in
  let result_descriptor = descriptor traverse.t_stack in
  (* Column pointers come from registers that hold no descriptor, so every
     descriptor stays readable until the pointers are loaded. rax indexes
     records, and rcx and one more register are scratch. *)
  let pointer_columns =
    List.fold_left (fun columns (o, f) -> if List.mem (o, f) columns then columns else columns @ [ o, f ])
      (List.map (fun c -> c.owner, c.field) loaded)
      (List.filter_map (function (Replace c | Compacted c), _ -> Some (c.owner, c.field) | Selection, _ -> None) full.outputs) in
  let pool_registers = [ "r11"; "r10"; "r9"; "r8"; "rdx"; "rsi"; "rdi"; "rbx"; "rbp"; "r12"; "r13"; "r14"; "r15" ] in
  let roles = if compacting then 5 else 2 in
  let role_registers =
    List.filteri (fun i _ -> i < roles)
      (List.filter (fun r -> not (List.mem r descriptors)) pool_registers) in
  if List.length role_registers < roles then reject run.run_loc "this run needs more x86 general registers than remain";
  let scratch = List.nth role_registers 0 and count = List.nth role_registers 1 in
  let bits, popcount, cursor =
    if compacting then List.nth role_registers 2, List.nth role_registers 3, List.nth role_registers 4 else "", "", "" in
  let free_pointers = List.filter (fun r -> not (List.mem r descriptors) && not (List.mem r role_registers)) pool_registers in
  if List.length pointer_columns > List.length free_pointers then
    reject run.run_loc "this run touches %d columns and x86 has %d free pointer registers" (List.length pointer_columns) (List.length free_pointers);
  let pointers = List.mapi (fun index column -> column, List.nth free_pointers index) pointer_columns in
  let pointer c = List.assoc (c.owner, c.field) pointers in
  let used = role_registers @ List.map snd pointers in
  let saved = List.filter (fun r -> List.mem r used) x86_callee_saved in
  (* Vector temporaries: registers no kernel instruction, output, column or
     uniform uses. *)
  let occupied =
    List.init (List.length loaded + 1) Fun.id
    @ List.mapi (fun index _ -> uniform_register profile index) uniforms
    @ List.map snd full.outputs @ List.map snd tail.outputs
    @ x86_kernel_registers full.allocated @ x86_kernel_registers tail.allocated in
  let vector_count = if sse2 then 15 else Target.x86_register_count profile in
  let free_vectors = List.filter (fun r -> not (List.mem r occupied)) (List.init vector_count Fun.id) in
  let temporary n =
    match List.nth_opt free_vectors n with
    | Some r -> r
    | None -> reject run.run_loc "this run's compaction needs vector temporaries that %s doesn't have free" (Target.profile_name profile) in
  let widening_instruction stored =
    "vpmov" ^ (if is_signed stored then "sx" else "zx") ^ (if bytes stored = 1 then "bd" else "wd") in
  let widen_register index stored =
    if bytes stored < 4 then
      if sse2 then (
        if bytes stored = 1 then emit "punpcklbw xmm%d, xmm%d" index index;
        emit "punpcklwd xmm%d, xmm%d" index index;
        emit "%s xmm%d, %d" (if is_signed stored then "psrad" else "psrld") index (32 - Tier_ir.bits stored))
      else emit "%s %s, xmm%d" (widening_instruction stored) (register index) index in
  let load_column ~masked index c =
    let width = bytes c.stored in
    let address = Printf.sprintf "[%s + rax*%d]" (pointer c) width in
    if width = 4 then
      emit "%s %s%s, %s PTR %s" move (register index) (if masked then "{k2}{z}" else "") memory address
    else if sse2 then (
      emit "%s xmm%d, %s PTR %s" (if width = 1 then "movd" else "movq") index (if width = 1 then "DWORD" else "QWORD") address;
      widen_register index c.stored)
    else
      let source_memory = match lanes * width with
        | 8 -> "QWORD" | 16 -> "XMMWORD" | 32 -> "YMMWORD" | _ -> invalid_arg "native widening load width" in
      emit "%s %s%s, %s PTR %s" (widening_instruction c.stored) (register index) (if masked then "{k2}{z}" else "") source_memory address in
  let body kernel =
    let block = Buffer.create 512 in
    List.iter (X86_simd_asm.emit_instruction profile pool block) (x86_function kernel.allocated).X86_simd_regalloc.instructions;
    Buffer.add_string buffer (Buffer.contents block) in
  (* Truncate a widened rack in [source] to its stored bytes, low lanes first,
     in [t]. Its values came from that storage, so truncation is exact. SSE2
     sign-extends each element's low bits so its saturating packs keep them. *)
  let narrow c source t =
    let stored_bytes = bytes c.stored in
    if sse2 then (
      emit "movaps xmm%d, xmm%d" t source;
      emit "pslld xmm%d, %d" t (32 - Tier_ir.bits c.stored);
      emit "psrad xmm%d, %d" t (32 - Tier_ir.bits c.stored);
      emit "packssdw xmm%d, xmm%d" t t;
      if stored_bytes = 1 then emit "packsswb xmm%d, xmm%d" t t)
    else (
      (* vpshufb gathers each 128-bit lane's low element bytes, and vpermd
         joins the two lanes' results. *)
      let control = List.init 4 (fun dword ->
        List.fold_left (fun acc b ->
          let k = dword * 4 + b in
          let index = if stored_bytes = 1 then (if k < 4 then k * 4 else 0x80) else (if k < 8 then (k / 2) * 4 + k mod 2 else 0x80) in
          Int32.logor acc (Int32.shift_left (Int32.of_int index) (8 * b))) 0l [ 0; 1; 2; 3 ]) in
      let shuffle = X86_simd_asm.intern pool (X86_simd_asm.Vector_bits (control @ control)) in
      emit "vpshufb ymm%d, ymm%d, YMMWORD PTR [rip + %s]" t source shuffle;
      let join = X86_simd_asm.intern pool (X86_simd_asm.Vector_bits
        (List.map Int32.of_int (if stored_bytes = 1 then [ 0; 4; 0; 0; 0; 0; 0; 0 ] else [ 0; 1; 4; 5; 0; 0; 0; 0 ]))) in
      let index = temporary 2 in
      emit "vmovdqu ymm%d, YMMWORD PTR [rip + %s]" index join;
      emit "vpermd ymm%d, ymm%d, ymm%d" t index t) in
  (* Guarded stores of the first [active] lanes of xmm [t] at [base], where
     [active] holds 1 .. lanes - 1. SSE2 has no lane extraction to memory, so
     it moves each lane through xmm15 or ecx. *)
  let guarded_stores ~active ~width ~base t done_label =
    if sse2 && width = 1 then emit "movd ecx, xmm%d" t;
    for lane = 0 to lanes - 2 do
      if lane > 0 then (emit "cmp %s, %d" active (lane + 1); emit "jl %s" done_label);
      (match width, sse2 with
       | 4, true ->
           if lane = 0 then emit "movss DWORD PTR [%s], xmm%d" base t
           else (
             emit "movaps xmm15, xmm%d" t;
             emit "shufps xmm15, xmm15, 0x%02x" (lane * 0x55);
             emit "movss DWORD PTR [%s + %d], xmm15" base (lane * 4))
       | 2, true ->
           emit "pextrw ecx, xmm%d, %d" t lane;
           emit "mov WORD PTR [%s + %d], cx" base (lane * 2)
       | _, true ->
           emit "mov BYTE PTR [%s + %d], cl" base lane;
           emit "shr ecx, 8"
       | 4, false ->
           if lane < 4 then emit "vextractps DWORD PTR [%s + %d], xmm%d, %d" base (lane * 4) t lane
           else (
             let upper = temporary 3 in
             emit "vextractf128 xmm%d, ymm%d, 1" upper t;
             emit "vextractps DWORD PTR [%s + %d], xmm%d, %d" base (lane * 4) upper (lane mod 4))
       | 2, false -> emit "vpextrw WORD PTR [%s + %d], xmm%d, %d" base (lane * 2) t lane
       | _, false -> emit "vpextrb BYTE PTR [%s + %d], xmm%d, %d" base lane t lane)
    done in
  Printf.bprintf buffer ".intel_syntax noprefix\n.text\n.p2align %d\n.globl %s\n.type %s, @function\n%s:\n"
    alignment run.run_name run.run_name run.run_name;
  List.iter (fun r -> emit "push %s" r) saved;
  (* Uniforms leave their argument registers first. SSE2's last vector
     argument register is also its first uniform register, so floats copy
     backwards. *)
  let uniform_slots = List.filter_map (function Uniform_argument (name, scalar, slot) -> Some (name, scalar, slot) | _ -> None) arguments in
  List.mapi (fun index argument -> index, argument) uniform_slots |> List.rev |> List.iter (fun (index, (_, scalar, slot)) ->
    if scalar = Types.SFloat then (
      let destination = uniform_register profile index in
      if avx512 then emit "vbroadcastss zmm%d, xmm%d" destination slot
      else emit "%s xmm%d, xmm%d" (if sse2 then "movaps" else "vmovaps") destination slot));
  List.iteri (fun index (_, scalar, slot) ->
    if scalar <> Types.SFloat then
      emit "%smovd xmm%d, %s" (if sse2 then "" else "v") (uniform_register profile index) (x86_dword x86_argument_registers.(slot))) uniform_slots;
  List.iter (fun (dst, count, shift) ->
    X86_simd_asm.emit_instruction profile pool buffer
      { X86_simd_regalloc.operation = Shift_i32 { dst; source = dst; count; shift };
        loc = Native_ir.unknown_location; provenance = Native_ir.source })
    (boolean_normalisation profile uniforms);
  List.iter (fun ((owner, field), r) ->
    emit "mov %s, QWORD PTR [%s + %d]" r (descriptor owner) (descriptor_offset program
      (match List.find (function Run_stack (n, _) -> n = owner | _ -> false) run.run_params with Run_stack (_, p) -> p | _ -> assert false) field)) pointers;
  emit "mov %s, QWORD PTR [%s]" count result_descriptor;
  emit "test %s, %s" count count;
  emit "jle %s" (label "return");
  emit "xor eax, eax";
  if compacting then emit "xor %s, %s" (x86_dword cursor) (x86_dword cursor);
  emit "cmp %s, %d" count lanes;
  emit "jl %s" (label "tail");
  Printf.bprintf buffer "%s:\n" (label "loop");
  List.iteri (load_column ~masked:false) loaded;
  body full;
  let compact ~tail_rack kernel =
    let mask_register = List.assoc Selection kernel.outputs in
    let compacted = List.filter_map (function Compacted c, r -> Some (c, r) | _ -> None) kernel.outputs in
    if avx512 then (
      emit "vptestmd k3, zmm%d, zmm%d" mask_register mask_register;
      if tail_rack then emit "kandw k3, k3, k2";
      emit "kmovw %s, k3" (x86_dword bits);
      emit "popcnt %s, %s" (x86_dword popcount) (x86_dword bits);
      if List.exists (fun (c, _) -> bytes c.stored < 4) compacted then (
        emit "mov ecx, %s" (x86_dword popcount);
        emit "mov %s, 1" (x86_dword bits);
        emit "shl %s, cl" (x86_dword bits);
        emit "dec %s" (x86_dword bits);
        emit "kmovw k4, %s" (x86_dword bits));
      List.iter (fun (c, r) ->
        if bytes c.stored = 4 then emit "vcompressps ZMMWORD PTR [%s + %s*4]{k3}, zmm%d" (pointer c) cursor r
        else (
          let t = temporary 0 in
          emit "vcompressps zmm%d{k3}{z}, zmm%d" t r;
          if bytes c.stored = 1 then emit "vpmovdb XMMWORD PTR [%s + %s]{k4}, zmm%d" (pointer c) cursor t
          else emit "vpmovdw YMMWORD PTR [%s + %s*2]{k4}, zmm%d" (pointer c) cursor t)) compacted)
    else (
      let selection = temporary 0 in
      if tail_rack then (
        emit "%s %s, %s PTR [rcx]" (if sse2 then "movaps" else "vmovups") (register selection) memory;
        if sse2 then emit "andps xmm%d, xmm%d" selection mask_register
        else emit "vandps %s, %s, %s" (register selection) (register selection) (register mask_register);
        emit "%s %s, %s" (if sse2 then "movmskps" else "vmovmskps") (x86_dword bits) (register selection))
      else emit "%s %s, %s" (if sse2 then "movmskps" else "vmovmskps") (x86_dword bits) (register mask_register);
      if sse2 then (
        emit "lea rcx, [rip + %s]" (label "popcounts");
        emit "movzx %s, BYTE PTR [rcx + %s]" (x86_dword popcount) bits;
        (* SSE2 has no variable shuffle: jump to one of 16 fixed permutations
           of the distinct output registers. *)
        let registers = List.sort_uniq compare (List.map snd compacted) in
        let suffix = if tail_rack then "tail_" else "" in
        emit "lea rcx, [rip + %s]" (label (suffix ^ "permutations"));
        emit "movsxd %s, DWORD PTR [rcx + %s*4]" bits bits;
        emit "add %s, rcx" bits;
        emit "jmp %s" bits;
        for selected = 0 to 15 do
          Printf.bprintf buffer "%s:\n" (label (Printf.sprintf "%spermute_%d" suffix selected));
          let order = List.filter (fun lane -> selected land (1 lsl lane) <> 0) [ 0; 1; 2; 3 ] in
          let order = order @ List.init (4 - List.length order) (fun _ -> 0) in
          let immediate = List.fold_left (fun acc (k, lane) -> acc lor (lane lsl (2 * k))) 0 (List.mapi (fun k lane -> k, lane) order) in
          List.iter (fun r -> emit "pshufd xmm%d, xmm%d, 0x%02x" r r immediate) registers;
          emit "jmp %s" (label (suffix ^ "permuted"))
        done;
        Printf.bprintf buffer ".p2align 2\n%s:\n" (label (suffix ^ "permutations"));
        for selected = 0 to 15 do
          Printf.bprintf buffer "    .long %s - %s\n" (label (Printf.sprintf "%spermute_%d" suffix selected)) (label (suffix ^ "permutations"))
        done;
        Printf.bprintf buffer "%s:\n" (label (suffix ^ "permuted"));
        ignore registers)
      else (
        emit "popcnt %s, %s" (x86_dword popcount) (x86_dword bits);
        emit "lea rcx, [rip + %s]" (label "permutations");
        emit "shl %s, 5" bits;
        let permutation = temporary 1 in
        emit "vmovdqu %s, YMMWORD PTR [rcx + %s]" (register permutation) bits;
        List.iter (fun (_, r) -> emit "vpermps %s, %s, %s" (register r) (register permutation) (register r))
          (List.sort_uniq (fun (_, a) (_, b) -> compare a b) compacted));
      (* A full rack's stores stay below its own end: the cursor never passes
         the records already read. A tail stores only the selected lanes. *)
      List.iter (fun (c, r) ->
        let width = bytes c.stored in
        let source = if width = 4 then r else (let t = temporary (if sse2 then 1 else 3) in narrow c r t; t) in
        let base = Printf.sprintf "%s + %s*%d" (pointer c) cursor width in
        if not tail_rack then (
          if width = 4 then emit "%s %s PTR [%s], %s" move memory base (register source)
          else if sse2 then emit "%s %s PTR [%s], xmm%d" (if width = 1 then "movd" else "movq") (if width = 1 then "DWORD" else "QWORD") base source
          else if width * lanes = 8 then emit "vmovq QWORD PTR [%s], xmm%d" base source
          else emit "vmovdqu XMMWORD PTR [%s], xmm%d" base source)
        else (
          emit "test %s, %s" (x86_dword popcount) (x86_dword popcount);
          let skip = label (Printf.sprintf "kept_%s_%s" c.field (if tail_rack then "tail" else "full")) in
          emit "je %s" skip;
          emit "lea %s, [%s]" scratch base;
          if width = 4 && not sse2 && lanes = 8 then (
            emit "lea rcx, [rip + %s]" (label "masks");
            emit "mov %s, %s" (x86_dword bits) (x86_dword popcount);
            emit "shl %s, %d" (x86_dword bits) alignment;
            let prefix = temporary 2 in
            emit "vmovups ymm%d, YMMWORD PTR [rcx + %s]" prefix bits;
            emit "vmaskmovps YMMWORD PTR [%s], ymm%d, ymm%d" scratch prefix source)
          else guarded_stores ~active:(x86_dword popcount) ~width ~base:scratch source skip;
          Printf.bprintf buffer "%s:\n" skip)) compacted);
    emit "add %s, %s" cursor popcount in
  let store_outputs ~tail_rack kernel =
    if compacting then compact ~tail_rack kernel
    else
      List.iter (function
        | Replace c, r ->
            let address = Printf.sprintf "[%s + rax*4]" (pointer c) in
            if not tail_rack then emit "%s %s PTR %s, %s" move memory address (register r)
            else if avx512 then emit "vmovups %s PTR %s{k2}, %s" memory address (register r)
            else if sse2 then (
              let done_label = label ("stored_" ^ c.field) in
              emit "lea %s, %s" scratch address;
              guarded_stores ~active:count ~width:4 ~base:scratch r done_label;
              Printf.bprintf buffer "%s:\n" done_label)
            else (
              let prefix = temporary 0 in
              emit "vmovups ymm%d, YMMWORD PTR [rcx]" prefix;
              emit "vmaskmovps YMMWORD PTR %s, ymm%d, ymm%d" address prefix r)
        | _ -> ()) kernel.outputs in
  store_outputs ~tail_rack:false full;
  emit "add rax, %d" lanes;
  emit "sub %s, %d" count lanes;
  emit "cmp %s, %d" count lanes;
  emit "jge %s" (label "loop");
  Printf.bprintf buffer "%s:\n" (label "tail");
  emit "test %s, %s" count count;
  emit "je %s" (label "finish");
  let mask_register = List.length loaded in
  if sse2 then (
    emit "lea rcx, [rip + %s]" (label "masks");
    emit "mov %s, %s" (x86_dword scratch) (x86_dword count);
    emit "shl %s, %d" (x86_dword scratch) alignment;
    emit "add rcx, %s" scratch;
    emit "movaps %s, %s PTR [rcx]" (register mask_register) memory;
    List.iteri (fun index c -> if bytes c.stored < 4 then emit "pxor xmm%d, xmm%d" index index) loaded;
    for lane = 0 to lanes - 2 do
      if lane > 0 then (emit "cmp %s, %d" count (lane + 1); emit "jl %s" (label "tail_loaded"));
      List.iteri (fun index c ->
        let p = pointer c in
        if bytes c.stored = 1 then (
          emit "movzx %s, BYTE PTR [%s + rax + %d]" (x86_dword scratch) p lane;
          emit "movd xmm15, %s" (x86_dword scratch);
          if lane > 0 then emit "pslldq xmm15, %d" lane;
          emit "por xmm%d, xmm15" index)
        else if bytes c.stored = 2 then emit "pinsrw xmm%d, WORD PTR [%s + rax*2 + %d], %d" index p (lane * 2) lane
        else if lane = 0 then emit "movss %s, DWORD PTR [%s + rax*4]" (register index) p
        else (
          emit "movss xmm15, DWORD PTR [%s + rax*4 + %d]" p (lane * 4);
          emit "%s %s, xmm15" (if lane = 1 then "unpcklps" else "movlhps") (register index))) loaded
    done;
    Printf.bprintf buffer "%s:\n" (label "tail_loaded");
    List.iteri (fun index c -> widen_register index c.stored) loaded)
  else if avx512 then (
    emit "mov ecx, %s" (x86_dword count);
    emit "mov %s, 1" (x86_dword scratch);
    emit "shl %s, cl" (x86_dword scratch);
    emit "dec %s" (x86_dword scratch);
    emit "kmovw k2, %s" (x86_dword scratch);
    emit "vpxord %s, %s, %s" (register mask_register) (register mask_register) (register mask_register);
    emit "vpternlogd %s{k2}, %s, %s, 0xff" (register mask_register) (register mask_register) (register mask_register);
    List.iteri (load_column ~masked:true) loaded)
  else (
    emit "lea rcx, [rip + %s]" (label "masks");
    emit "mov %s, %s" (x86_dword scratch) (x86_dword count);
    emit "shl %s, %d" (x86_dword scratch) alignment;
    emit "add rcx, %s" scratch;
    emit "vmovups %s, %s PTR [rcx]" (register mask_register) memory;
    List.iteri (fun index c ->
      if bytes c.stored = 4 then
        emit "vmaskmovps %s, %s, %s PTR [%s + rax*4]" (register index) (register mask_register) memory (pointer c)
      else emit "vpxor xmm%d, xmm%d, xmm%d" index index index) loaded;
    if List.exists (fun c -> bytes c.stored < 4) loaded then (
      for lane = 0 to lanes - 2 do
        if lane > 0 then (emit "cmp %s, %d" count (lane + 1); emit "jl %s" (label "tail_narrow_loaded"));
        List.iteri (fun index c ->
          if bytes c.stored < 4 then
            emit "%s xmm%d, xmm%d, %s PTR [%s + rax*%d + %d], %d"
              (if bytes c.stored = 1 then "vpinsrb" else "vpinsrw") index index
              (if bytes c.stored = 1 then "BYTE" else "WORD") (pointer c) (bytes c.stored) (lane * bytes c.stored) lane) loaded
      done;
      Printf.bprintf buffer "%s:\n" (label "tail_narrow_loaded");
      List.iteri (fun index c -> widen_register index c.stored) loaded));
  body tail;
  store_outputs ~tail_rack:true tail;
  Printf.bprintf buffer "%s:\n" (label "finish");
  if compacting then emit "mov QWORD PTR [%s], %s" result_descriptor cursor;
  Printf.bprintf buffer "%s:\n" (label "return");
  List.iter (fun r -> emit "pop %s" r) (List.rev saved);
  if not sse2 then emit "vzeroupper";
  emit "ret";
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
  if compacting && sse2 then (
    Printf.bprintf buffer "%s:\n" (label "popcounts");
    Printf.bprintf buffer "    .byte %s\n" (String.concat ", " (List.init 16 (fun b ->
      string_of_int (List.length (List.filter (fun lane -> b land (1 lsl lane) <> 0) [ 0; 1; 2; 3 ]))))));
  if compacting && not sse2 && not avx512 then (
    (* For each 8-bit selection, the lanes it keeps in order, then zeros. *)
    Printf.bprintf buffer ".p2align 5\n%s:\n" (label "permutations");
    for selected = 0 to 255 do
      let order = List.filter (fun lane -> selected land (1 lsl lane) <> 0) (List.init 8 Fun.id) in
      let order = order @ List.init (8 - List.length order) (fun _ -> 0) in
      Printf.bprintf buffer "    .long %s\n" (String.concat ", " (List.map string_of_int order))
    done);
  Printf.bprintf buffer ".size %s, .-%s\n.att_syntax prefix\n" run.run_name run.run_name;
  let method_ =
    if not compacting then []
    else [ (if avx512 then "compaction: vcompressps under the selection mask"
            else if sse2 then "compaction: a jump to one of 16 fixed pshufd permutations"
            else "compaction: vpermps by a 256-entry permutation table") ] in
  let tail_fact =
    if avx512 then "tail: k2-masked vector transfers"
    else if sse2 then "tail: count-guarded lane transfers"
    else if List.exists (fun c -> bytes c.stored < 4) loaded then "tail: vmaskmovps for 32-bit columns, guarded lane transfers for compact columns"
    else "tail: vmaskmovps" in
  method_ @ [ tail_fact ]

(* ─── AArch64 ───────────────────────────────────────────────────────── *)

let neon_kernel_registers = function
  | Native_backend.Neon [ f ] -> List.concat_map (fun i -> Aarch64_neon_asm.registers i.Aarch64_neon_regalloc.operation) f.instructions
  | _ -> assert false

let emit_neon_run program buffer (run : run) =
  let profile = Target.Aarch64_neon in
  let traverse = run_traversal run in
  let arguments, uniforms = arguments ~profile run in
  let full = compile_kernel ~profile program run traverse uniforms ~tail:false in
  let tail = compile_kernel ~profile program run traverse uniforms ~tail:true in
  let loaded = full.loaded in
  let compacting = List.exists (fun (o, _) -> o = Selection) full.outputs in
  let pool = Aarch64_neon_asm.create_pool () in
  let emit format = Printf.bprintf buffer ("    " ^^ format ^^ "\n") in
  let label suffix = ".Lrake_stream_" ^ run.run_name ^ "_" ^ suffix in
  let descriptor name = List.find_map (function Stack_argument (n, slot) when n = name -> Some (Printf.sprintf "x%d" slot) | _ -> None) arguments |> Option.get in
  let descriptors = List.filter_map (function Stack_argument (_, slot) -> Some (Printf.sprintf "x%d" slot) | _ -> None) arguments in
  let result_descriptor = descriptor traverse.t_stack in
  let pointer_columns =
    List.fold_left (fun columns (o, f) -> if List.mem (o, f) columns then columns else columns @ [ o, f ])
      (List.map (fun c -> c.owner, c.field) loaded)
      (List.filter_map (function (Replace c | Compacted c), _ -> Some (c.owner, c.field) | Selection, _ -> None) full.outputs) in
  let pool_registers = List.map (Printf.sprintf "x%d") ([ 9; 10; 11; 12; 13; 14; 15; 16; 17 ] @ [ 0; 1; 2; 3; 4; 5; 6; 7; 8 ]) in
  let free_of_descriptors = List.filter (fun r -> not (List.mem r descriptors)) pool_registers in
  if List.length pointer_columns + 6 > List.length free_of_descriptors then
    reject run.run_loc "this run touches %d columns, more than AArch64's free pointer registers" (List.length pointer_columns);
  let pointers = List.mapi (fun index column -> column, List.nth free_of_descriptors index) pointer_columns in
  let pointer c = List.assoc (c.owner, c.field) pointers in
  let rest = List.filter (fun r -> not (List.mem r (List.map snd pointers)) && not (List.mem r descriptors)) pool_registers in
  let count = List.nth rest 0 and index = List.nth rest 1 and address = List.nth rest 2 and table = List.nth rest 3 in
  let bits = List.nth rest 4 and popcount = List.nth rest 5 in
  let cursor = if compacting then List.nth (List.filter (fun r -> not (List.mem r [ count; index; address; table; bits; popcount ])) rest) 0 else "" in
  let w register = "w" ^ String.sub register 1 (String.length register - 1) in
  let occupied =
    List.init (List.length loaded + 1) Fun.id
    @ List.mapi (fun i _ -> uniform_register profile i) uniforms
    @ List.map snd full.outputs @ List.map snd tail.outputs
    @ neon_kernel_registers full.allocated @ neon_kernel_registers tail.allocated in
  let free_vectors = List.filter (fun r -> not (List.mem r occupied)) Aarch64_neon_regalloc.allocatable_registers in
  let temporary n =
    match List.nth_opt free_vectors n with
    | Some r -> r
    | None -> reject run.run_loc "this run's compaction needs vector temporaries that aarch64-neon doesn't have free" in
  let body kernel = match kernel.allocated with
    | Native_backend.Neon [ func ] -> List.iter (Aarch64_neon_asm.emit_instruction pool buffer) func.instructions
    | _ -> assert false in
  let shift_of width = match width with 1 -> "" | 2 -> ", lsl #1" | _ -> ", lsl #2" in
  let widen_register index stored =
    if bytes stored < 4 then (
      let instruction = if is_signed stored then "sshll" else "ushll" in
      if bytes stored = 1 then emit "%s v%d.8h, v%d.8b, #0" instruction index index;
      emit "%s v%d.4s, v%d.4h, #0" instruction index index) in
  Printf.bprintf buffer ".arch armv8-a+simd\n.text\n.p2align 4\n.globl %s\n.type %s, %%function\n%s:\n"
    run.run_name run.run_name run.run_name;
  let uniform_slots = List.filter_map (function Uniform_argument (name, scalar, slot) -> Some (name, scalar, slot) | _ -> None) arguments in
  List.iteri (fun i (_, scalar, slot) ->
    if scalar = Types.SFloat then emit "dup v%d.4s, v%d.s[0]" (uniform_register profile i) slot
    else emit "fmov s%d, w%d" (uniform_register profile i) slot) uniform_slots;
  List.iter (fun (dst, count, shift) ->
    Aarch64_neon_asm.emit_instruction pool buffer
      { Aarch64_neon_regalloc.operation = Shift_i32 { dst; source = dst; count; shift };
        loc = Native_ir.unknown_location; provenance = Native_ir.source })
    (boolean_normalisation profile uniforms);
  List.iter (fun ((owner, field), r) ->
    let offset = descriptor_offset program
      (match List.find (function Run_stack (n, _) -> n = owner | _ -> false) run.run_params with Run_stack (_, p) -> p | _ -> assert false) field in
    if offset > 32760 then reject run.run_loc "native NEON column exceeds the supported descriptor offset";
    emit "ldr %s, [%s, #%d]" r (descriptor owner) offset) pointers;
  emit "ldr %s, [%s]" count result_descriptor;
  emit "cmp %s, #0" count;
  emit "b.le %s" (label "return");
  emit "mov %s, #0" index;
  if compacting then emit "mov %s, #0" cursor;
  emit "cmp %s, #4" count;
  emit "b.lt %s" (label "tail");
  Printf.bprintf buffer "%s:\n" (label "loop");
  List.iteri (fun i c ->
    emit "add %s, %s, %s%s" table (pointer c) index (shift_of (bytes c.stored));
    emit "ldr %s%d, [%s]" (match bytes c.stored with 1 -> "s" | 2 -> "d" | _ -> "q") i table;
    widen_register i c.stored) loaded;
  body full;
  let narrow c source t =
    emit "xtn v%d.4h, v%d.4s" t source;
    if bytes c.stored = 1 then emit "xtn v%d.8b, v%d.8h" t t in
  let guarded_lanes ~active ~width ~base t done_label =
    emit "mov %s, %s" address base;
    for lane = 0 to 2 do
      if lane > 0 then (emit "cmp %s, #%d" (w active) (lane + 1); emit "b.lt %s" done_label);
      emit "st1 {v%d.%s}[%d], [%s], #%d" t (match width with 1 -> "b" | 2 -> "h" | _ -> "s") lane address width
    done in
  let compact ~tail_rack kernel =
    let mask_register = List.assoc Selection kernel.outputs in
    let compacted = List.filter_map (function Compacted c, r -> Some (c, r) | _ -> None) kernel.outputs in
    let selected = temporary 0 and weights = temporary 1 and permutation = temporary 2 and moved = temporary 3 in
    emit "adr %s, %s" table (label "lane_bits");
    emit "ldr q%d, [%s]" weights table;
    emit "and v%d.16b, v%d.16b, v%d.16b" selected mask_register weights;
    if tail_rack then (
      emit "ldr q%d, [%s]" weights address;
      emit "and v%d.16b, v%d.16b, v%d.16b" selected selected weights);
    emit "addv s%d, v%d.4s" selected selected;
    emit "fmov %s, s%d" (w bits) selected;
    emit "adr %s, %s" table (label "popcounts");
    emit "ldrb %s, [%s, %s]" (w popcount) table bits;
    emit "adr %s, %s" table (label "permutations");
    emit "add %s, %s, %s, lsl #4" table table bits;
    emit "ldr q%d, [%s]" permutation table;
    List.iter (fun (c, r) ->
      let width = bytes c.stored in
      emit "tbl v%d.16b, {v%d.16b}, v%d.16b" moved r permutation;
      if width < 4 then narrow c moved moved;
      if not tail_rack then
        (emit "add %s, %s, %s%s" table (pointer c) cursor (shift_of width);
         emit "str %s%d, [%s]" (match width with 1 -> "s" | 2 -> "d" | _ -> "q") moved table)
      else (
        let skip = label ("kept_" ^ c.field) in
        emit "cbz %s, %s" (w popcount) skip;
        emit "add %s, %s, %s%s" table (pointer c) cursor (shift_of width);
        guarded_lanes ~active:popcount ~width ~base:table moved skip;
        Printf.bprintf buffer "%s:\n" skip)) compacted;
    emit "add %s, %s, %s" cursor cursor popcount in
  let store_outputs ~tail_rack kernel =
    if compacting then compact ~tail_rack kernel
    else
      List.iter (function
        | Replace c, r ->
            if not tail_rack then (
              emit "add %s, %s, %s, lsl #2" table (pointer c) index;
              emit "str q%d, [%s]" r table)
            else (
              let done_label = label ("stored_" ^ c.field) in
              emit "add %s, %s, %s, lsl #2" table (pointer c) index;
              guarded_lanes ~active:count ~width:4 ~base:table r done_label;
              Printf.bprintf buffer "%s:\n" done_label)
        | _ -> ()) kernel.outputs in
  store_outputs ~tail_rack:false full;
  emit "add %s, %s, #4" index index;
  emit "sub %s, %s, #4" count count;
  emit "cmp %s, #4" count;
  emit "b.ge %s" (label "loop");
  Printf.bprintf buffer "%s:\n" (label "tail");
  emit "cbz %s, %s" count (label "finish");
  (* Count-guarded lane transfers cover the one-to-three-element tail. Only
     the transfers are lane-sized: its arithmetic is one masked rack. *)
  emit "adr %s, %s" address (label "masks");
  emit "add %s, %s, %s, lsl #4" address address count;
  emit "ldr q%d, [%s]" (List.length loaded) address;
  List.iteri (fun i _ -> emit "movi v%d.4s, #0" i) loaded;
  for lane = 0 to 2 do
    if lane > 0 then (emit "cmp %s, #%d" count (lane + 1); emit "b.lt %s" (label "tail_loaded"));
    List.iteri (fun i c ->
      emit "add %s, %s, %s%s" table (pointer c) index (shift_of (bytes c.stored));
      emit "ld1 {v%d.%s}[%d], [%s]" i (match bytes c.stored with 1 -> "b" | 2 -> "h" | _ -> "s")
        lane (if lane = 0 then table else (emit "add %s, %s, #%d" table table (lane * bytes c.stored); table))) loaded
  done;
  Printf.bprintf buffer "%s:\n" (label "tail_loaded");
  List.iteri (fun i c -> widen_register i c.stored) loaded;
  body tail;
  store_outputs ~tail_rack:true tail;
  Printf.bprintf buffer "%s:\n" (label "finish");
  if compacting then emit "str %s, [%s]" cursor result_descriptor;
  Printf.bprintf buffer "%s:\n" (label "return");
  emit "ret";
  List.iter (fun (bits, constant_label) ->
    Printf.bprintf buffer ".p2align 4\n%s:\n" constant_label;
    List.iter (fun bits -> Printf.bprintf buffer "    .long 0x%08lx\n" bits) bits) pool.entries;
  Printf.bprintf buffer ".p2align 4\n%s:\n" (label "masks");
  for active = 0 to 3 do
    for lane = 0 to 3 do
      Printf.bprintf buffer "    .long 0x%08lx\n" (if lane < active then -1l else 0l)
    done
  done;
  if compacting then (
    Printf.bprintf buffer ".p2align 4\n%s:\n    .long 1, 2, 4, 8\n" (label "lane_bits");
    Printf.bprintf buffer ".p2align 4\n%s:\n" (label "permutations");
    for selected = 0 to 15 do
      let order = List.filter (fun lane -> selected land (1 lsl lane) <> 0) [ 0; 1; 2; 3 ] in
      let bytes = List.concat_map (fun lane -> List.init 4 (fun b -> lane * 4 + b)) order in
      let bytes = bytes @ List.init (16 - List.length bytes) (fun _ -> 0xff) in
      Printf.bprintf buffer "    .byte %s\n" (String.concat ", " (List.map string_of_int bytes))
    done;
    Printf.bprintf buffer "%s:\n    .byte %s\n" (label "popcounts") (String.concat ", " (List.init 16 (fun b ->
      string_of_int (List.length (List.filter (fun lane -> b land (1 lsl lane) <> 0) [ 0; 1; 2; 3 ]))))));
  Printf.bprintf buffer ".size %s, .-%s\n" run.run_name run.run_name;
  (if compacting then [ "compaction: tbl by a 16-entry byte table" ] else []) @ [ "tail: count-guarded lane transfers" ]

let compile ~profile program =
  if not (Target.is_x86 profile || profile = Target.Aarch64_neon) then (
    match program.runs with
    | run :: _ -> reject run.run_loc "native runs require a physical x86 or NEON SIMD profile"
    | [] -> ());
  let parts = List.map (fun run ->
    let buffer = Buffer.create 2048 in
    let facts, constant_prefix = if profile = Target.Aarch64_neon then (
      let facts = emit_neon_run program buffer run in
      (facts, ".Lrake_neon_const_"))
    else (
      let facts = emit_x86_run ~profile program buffer run in
      (facts, ".Lrake_const_")) in
    (run.run_name, facts),
    Str.global_replace (Str.regexp_string constant_prefix)
      (".Lrake_stream_" ^ run.run_name ^ "_const_") (Buffer.contents buffer)) program.runs in
  let progbits = if profile = Target.Aarch64_neon then "%progbits" else "@progbits" in
  { assembly = String.concat "\n" (List.map snd parts) ^ ".section .note.GNU-stack,\"\"," ^ progbits ^ "\n";
    functions = List.map (fun run -> run.run_name) program.runs;
    facts = List.map fst parts }
