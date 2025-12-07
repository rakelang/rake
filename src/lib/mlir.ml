(** Rake 0.2.0 MLIR Emitter

    Generates MLIR for both CPU SIMD and GPU targets with width-parameterized
    vector emission for runtime SIMD multi-versioning.

    ==========================================================================
    ARCHITECTURE: Width-Parameterized Emission for Multi-Versioning
    ==========================================================================

    This emitter is designed to support runtime SIMD dispatch via function
    multi-versioning. The upper layer (MLIR/LLVM) will call this emitter
    multiple times with different widths to generate specialized versions:

      Width  | ISA Target       | Register Type  | Use Case
      -------|------------------|----------------|---------------------------
        1    | Scalar / GPU     | xmm (scalar)   | GPU backends, fallback
        4    | SSE / NEON       | xmm (128-bit)  | Baseline x86/ARM SIMD
        8    | AVX / AVX2       | ymm (256-bit)  | Modern x86 (default CPU)
       16    | AVX-512          | zmm (512-bit)  | High-end x86, datacenter
       16+   | AVX10 / SVE      | scalable       | Future: SVE, AVX10.2, etc.

    The emitter is structured so that:
    - All type helpers are parameterized by ctx.width
    - Loop constructs adapt: scf.for (vector) vs scf.parallel (scalar)
    - Memory ops adapt: vector.load/maskedstore vs memref.load/store
    - The same Rake source produces correct code for any width

    FUTURE: The compiler driver will:
    1. Query target CPU features (cpuid / /proc/cpuinfo)
    2. Emit multiple width variants into the same module
    3. Generate runtime dispatch based on feature detection
    4. Link with ifunc or similar mechanism for transparent dispatch

    ==========================================================================
    Current Implementation
    ==========================================================================

    CPU mode (width 8, AVX2):
    - scf.for loops with explicit vectorization
    - vector.load/store for memory operations
    - vector<8xT> types throughout
    - Tail masking via vector.create_mask + vector.maskedstore

    GPU mode (width 1, scalar):
    - scf.parallel loops declaring independent iterations
    - memref.load/store for memory (scalar)
    - Scalar types (f32, i32, etc.)
    - MLIR/SPIR-V passes handle GPU parallelization

    Key mappings (all widths):
    - Tine predicates → arith.cmpf/cmpi → vector<WxI1> or i1
    - Through blocks → arith.select (CPU) / scf.if (GPU)
    - Sweep → nested arith.select chain
    - Reductions → vector.reduction (vector) / identity (scalar)

    Target dialects: func, arith, vector, math, scf, memref
*)

open Ast
open Types

(** Target mode for emission.
    FUTURE: This will expand to include specific ISA targets:
    - SSE4 (width=4), AVX2 (width=8), AVX512 (width=16)
    - ARM NEON (width=4), SVE (scalable)
    - GPU variants (CUDA, Vulkan/SPIR-V, Metal)

    For now, CPU means "explicit vectorization" and GPU means "parallel scalar". *)
type target = CPU | GPU

(** Emission context.

    The key field for multi-versioning is [width]:
    - width=1: Scalar mode (GPU, or fallback)
    - width=4: SSE/NEON (128-bit vectors)
    - width=8: AVX/AVX2 (256-bit vectors) - current default
    - width=16: AVX-512 (512-bit vectors)

    All emission helpers read ctx.width to determine vector types,
    enabling the same code path to emit for any SIMD width. *)
type ctx = {
  mutable buf: Buffer.t;
  mutable indent: int;
  mutable ssa_counter: int;
  vars: (string, string) Hashtbl.t;  (* Rake var -> MLIR SSA name *)
  tines: (string, string) Hashtbl.t; (* Tine name -> mask SSA name *)
  types: (string, Types.t) Hashtbl.t; (* Type definitions *)
  type_env: Typecheck.env;
  pack_memrefs: (string, string) Hashtbl.t;  (* "pack.field" -> memref SSA name *)
  mutable current_over_offset: string option; (* Current over loop offset for loads *)
  mutable current_over_mask: string option;   (* Current tail mask for masked stores *)
  mutable current_over_iter: string option;   (* Current iteration index (GPU mode) *)
  mutable output_memref: string option;       (* Output memref for run function results *)
  target: target;                             (* CPU or GPU emission mode *)
  width: int;                                 (* Vector width: 1, 4, 8, 16, etc. *)
}

(** Create emission context with specified target and width.

    Width controls SIMD vector size:
      ~width:1  - Scalar (GPU, or fallback)
      ~width:4  - SSE/NEON (128-bit)
      ~width:8  - AVX/AVX2 (256-bit) - default for CPU
      ~width:16 - AVX-512 (512-bit)

    For multi-versioning, call this multiple times with different widths
    to generate ISA-specific function variants. *)
let create_ctx ?(target=CPU) ?width env =
  (* Use explicit width if provided, otherwise infer from target *)
  let width = match width with
    | Some w -> w
    | None -> match target with CPU -> 8 | GPU -> 1
  in
  {
    buf = Buffer.create 4096;
    indent = 0;
    ssa_counter = 0;
    vars = Hashtbl.create 64;
    tines = Hashtbl.create 16;
    types = env.Typecheck.types;
    type_env = env;
    pack_memrefs = Hashtbl.create 32;
    current_over_offset = None;
    current_over_mask = None;
    current_over_iter = None;
    output_memref = None;
    target;
    width;
  }

(** Generate fresh SSA name *)
let fresh ctx prefix =
  let n = ctx.ssa_counter in
  ctx.ssa_counter <- n + 1;
  Printf.sprintf "%%%s%d" prefix n

(** Emit with indentation *)
let emit ctx fmt =
  for _ = 1 to ctx.indent do
    Buffer.add_string ctx.buf "  "
  done;
  Printf.kbprintf (fun _ -> Buffer.add_char ctx.buf '\n') ctx.buf fmt

(** Emit without newline *)
let emit_inline ctx fmt =
  for _ = 1 to ctx.indent do
    Buffer.add_string ctx.buf "  "
  done;
  Printf.kbprintf (fun _ -> ()) ctx.buf fmt

(** Width-parameterized MLIR type for Rake type.

    This is the core function enabling multi-versioning:
    - width=1:  Rack Float → "f32"           (scalar)
    - width=4:  Rack Float → "vector<4xf32>" (SSE/NEON)
    - width=8:  Rack Float → "vector<8xf32>" (AVX/AVX2)
    - width=16: Rack Float → "vector<16xf32>" (AVX-512)

    Scalar types remain unchanged regardless of width.
    Mask types follow the same width (i1 vs vector<Wxi1>). *)
let rec mlir_type_w width = function
  | Rack SFloat -> if width = 1 then "f32" else Printf.sprintf "vector<%dxf32>" width
  | Rack SDouble -> if width = 1 then "f64" else Printf.sprintf "vector<%dxf64>" width
  | Rack SInt -> if width = 1 then "i32" else Printf.sprintf "vector<%dxi32>" width
  | Rack SInt64 -> if width = 1 then "i64" else Printf.sprintf "vector<%dxi64>" width
  | Rack SBool -> if width = 1 then "i1" else Printf.sprintf "vector<%dxi1>" width
  | Scalar SFloat -> "f32"
  | Scalar SDouble -> "f64"
  | Scalar SInt -> "i32"
  | Scalar SInt64 -> "i64"
  | Scalar SBool -> "i1"
  | Mask -> if width = 1 then "i1" else Printf.sprintf "vector<%dxi1>" width
  | Stack (_name, fields) ->
      let field_types = List.map (fun (_, t) -> mlir_type_w width t) fields in
      "tuple<" ^ String.concat ", " field_types ^ ">"
  | Single (_name, fields) ->
      let field_types = List.map (fun (_, t) -> mlir_type_w width t) fields in
      "tuple<" ^ String.concat ", " field_types ^ ">"
  | Tuple ts ->
      "tuple<" ^ String.concat ", " (List.map (mlir_type_w width) ts) ^ ">"
  | Unit -> "()"
  | _ -> "!rake.unknown"

(** Context-aware type helpers.

    These read ctx.width to emit the correct type for the current target:
    - data_type: The primary data vector type (f32 or vector<Wxf32>)
    - mask_type: Comparison result type (i1 or vector<Wxi1>)
    - int_type:  Integer lane type (i32 or vector<Wxi32>)

    Using these consistently ensures width-agnostic code generation. *)
let mlir_type ctx t = mlir_type_w ctx.width t
let data_type ctx = if ctx.width = 1 then "f32" else Printf.sprintf "vector<%dxf32>" ctx.width
let mask_type ctx = if ctx.width = 1 then "i1" else Printf.sprintf "vector<%dxi1>" ctx.width
let int_type ctx = if ctx.width = 1 then "i32" else Printf.sprintf "vector<%dxi32>" ctx.width

(** Check if we're in scalar mode (width=1).
    Scalar mode uses different loop constructs and memory operations. *)
let is_scalar_mode ctx = ctx.width = 1

(** Emit a binary operation *)
let emit_binop ctx op t1 t2 lhs rhs =
  let result = fresh ctx "v" in
  let is_float = match t1 with
    | Rack SFloat | Rack SDouble | Scalar SFloat | Scalar SDouble -> true
    | _ -> false
  in
  let op_name = match op with
    | Add -> if is_float then "arith.addf" else "arith.addi"
    | Sub -> if is_float then "arith.subf" else "arith.subi"
    | Mul -> if is_float then "arith.mulf" else "arith.muli"
    | Div -> if is_float then "arith.divf" else "arith.divsi"
    | Mod -> "arith.remsi"
    | Lt -> if is_float then "arith.cmpf olt" else "arith.cmpi slt"
    | Le -> if is_float then "arith.cmpf ole" else "arith.cmpi sle"
    | Gt -> if is_float then "arith.cmpf ogt" else "arith.cmpi sgt"
    | Ge -> if is_float then "arith.cmpf oge" else "arith.cmpi sge"
    | Eq -> if is_float then "arith.cmpf oeq" else "arith.cmpi eq"
    | Ne -> if is_float then "arith.cmpf one" else "arith.cmpi ne"
    | And -> "arith.andi"
    | Or -> "arith.ori"
    | _ -> "arith.addf"  (* TODO: handle other ops *)
  in
  let result_type = match op with
    | Lt | Le | Gt | Ge | Eq | Ne -> mask_type ctx
    | _ -> mlir_type ctx (binop_result t1 t2)
  in
  emit ctx "%s = %s %s, %s : %s" result op_name lhs rhs result_type;
  result

(** Emit a unary operation *)
let emit_unop ctx op t arg =
  let result = fresh ctx "v" in
  let ty = mlir_type ctx t in
  (match op with
   | Neg | FNeg ->
       emit ctx "%s = arith.negf %s : %s" result arg ty
   | Not ->
       (* For masks, use xor with all-ones *)
       let ones = fresh ctx "ones" in
       let mask_t = mask_type ctx in
       if is_scalar_mode ctx then
         emit ctx "%s = arith.constant 1 : %s" ones mask_t
       else
         emit ctx "%s = arith.constant dense<true> : %s" ones mask_t;
       emit ctx "%s = arith.xori %s, %s : %s" result arg ones mask_t);
  result

(** Emit broadcast of scalar to vector (only if needed).
    In GPU mode (width=1), broadcast is a no-op. *)
let emit_broadcast ctx scalar_val scalar_type =
  match scalar_type with
  | Rack _ | Mask ->
      (* Already a vector/rack, no broadcast needed *)
      scalar_val
  | _ ->
      if is_scalar_mode ctx then
        (* GPU mode: no broadcast needed, everything is scalar *)
        scalar_val
      else begin
        let result = fresh ctx "bcast" in
        let vec_type = match scalar_type with
          | Scalar SFloat -> data_type ctx
          | Scalar SInt -> int_type ctx
          | _ -> data_type ctx
        in
        emit ctx "%s = vector.broadcast %s : %s to %s" result scalar_val
          (mlir_type_w 1 scalar_type) vec_type;
        result
      end

(** Emit expression, return SSA name and type *)
let rec emit_expr ctx (expr: Ast.expr) : string * Types.t =
  match expr.v with
  | EInt n ->
      let result = fresh ctx "c" in
      (* In vector context, treat integers as floats for arithmetic *)
      let dt = data_type ctx in
      if is_scalar_mode ctx then
        emit ctx "%s = arith.constant %Ld.0 : %s" result n dt
      else
        emit ctx "%s = arith.constant dense<%Ld.0> : %s" result n dt;
      (result, Rack SFloat)

  | EFloat f ->
      let result = fresh ctx "c" in
      (* Use proper float formatting to ensure decimal point *)
      let f_str = if Float.is_integer f then Printf.sprintf "%.1f" f else Printf.sprintf "%g" f in
      let dt = data_type ctx in
      if is_scalar_mode ctx then
        emit ctx "%s = arith.constant %s : %s" result f_str dt
      else
        emit ctx "%s = arith.constant dense<%s> : %s" result f_str dt;
      (result, Rack SFloat)

  | EBool b ->
      let result = fresh ctx "c" in
      let mt = mask_type ctx in
      if is_scalar_mode ctx then
        emit ctx "%s = arith.constant %b : %s" result b mt
      else
        emit ctx "%s = arith.constant dense<%b> : %s" result b mt;
      (result, Mask)

  | EVar name -> (
      match Hashtbl.find_opt ctx.vars name with
      | Some ssa_name ->
          let t = match Hashtbl.find_opt ctx.type_env.vars name with
            | Some t -> t
            | None -> Rack SFloat
          in
          (ssa_name, t)
      | None ->
          (* Undefined variable - shouldn't happen after type checking *)
          let result = fresh ctx "undef" in
          let dt = data_type ctx in
          if is_scalar_mode ctx then
            emit ctx "%s = arith.constant 0.0 : %s" result dt
          else
            emit ctx "%s = arith.constant dense<0.0> : %s" result dt;
          (result, Rack SFloat))

  | EScalarVar name -> (
      match Hashtbl.find_opt ctx.vars name with
      | Some ssa_name ->
          let t = match Hashtbl.find_opt ctx.type_env.vars name with
            | Some t -> t
            | None -> Scalar SFloat
          in
          (ssa_name, t)
      | None ->
          let result = fresh ctx "undef" in
          emit ctx "%s = arith.constant 0.0 : f32" result;
          (result, Scalar SFloat))

  | EBinop (l, op, r) ->
      let (lhs, lt) = emit_expr ctx l in
      let (rhs, rt) = emit_expr ctx r in
      (* Handle broadcast if mixing scalar and rack *)
      let (lhs', lt') = match (lt, rt) with
        | (Scalar _, Rack _) -> (emit_broadcast ctx lhs lt, broadcast lt)
        | _ -> (lhs, lt)
      in
      let (rhs', _rt') = match (lt, rt) with
        | (Rack _, Scalar _) -> (emit_broadcast ctx rhs rt, broadcast rt)
        | _ -> (rhs, rt)
      in
      let result = emit_binop ctx op lt' rt lhs' rhs' in
      let result_t = match op with
        | Lt | Le | Gt | Ge | Eq | Ne -> Mask
        | _ -> binop_result lt' rt
      in
      (result, result_t)

  | EUnop (op, e) ->
      let (arg, t) = emit_expr ctx e in
      let result = emit_unop ctx op t arg in
      (result, t)

  | ECall (name, args) ->
      (* Handle built-in math functions *)
      let emit_math_unary fname arg =
        let result = fresh ctx "r" in
        let dt = data_type ctx in
        emit ctx "%s = math.%s %s : %s" result fname arg dt;
        (result, Rack SFloat)
      in
      let emit_math_binary fname arg1 arg2 =
        let result = fresh ctx "r" in
        let dt = data_type ctx in
        emit ctx "%s = math.%s %s, %s : %s" result fname arg1 arg2 dt;
        (result, Rack SFloat)
      in
      (match (name, args) with
       (* Unary math functions *)
       | ("sqrt", [e]) ->
           let (arg, _) = emit_expr ctx e in
           emit_math_unary "sqrt" arg
       | ("sin", [e]) ->
           let (arg, _) = emit_expr ctx e in
           emit_math_unary "sin" arg
       | ("cos", [e]) ->
           let (arg, _) = emit_expr ctx e in
           emit_math_unary "cos" arg
       | ("tan", [e]) ->
           let (arg, _) = emit_expr ctx e in
           emit_math_unary "tan" arg
       | ("exp", [e]) ->
           let (arg, _) = emit_expr ctx e in
           emit_math_unary "exp" arg
       | ("log", [e]) ->
           let (arg, _) = emit_expr ctx e in
           emit_math_unary "log" arg
       | ("abs", [e]) ->
           let (arg, _) = emit_expr ctx e in
           emit_math_unary "absf" arg
       | ("floor", [e]) ->
           let (arg, _) = emit_expr ctx e in
           emit_math_unary "floor" arg
       | ("ceil", [e]) ->
           let (arg, _) = emit_expr ctx e in
           emit_math_unary "ceil" arg
       (* Binary math functions *)
       | ("min", [e1; e2]) ->
           let (arg1, _) = emit_expr ctx e1 in
           let (arg2, _) = emit_expr ctx e2 in
           (* Use arith.minimumf for min - math dialect doesn't have min *)
           let result = fresh ctx "r" in
           let dt = data_type ctx in
           emit ctx "%s = arith.minimumf %s, %s : %s" result arg1 arg2 dt;
           (result, Rack SFloat)
       | ("max", [e1; e2]) ->
           let (arg1, _) = emit_expr ctx e1 in
           let (arg2, _) = emit_expr ctx e2 in
           (* Use arith.maximumf for max - math dialect doesn't have max *)
           let result = fresh ctx "r" in
           let dt = data_type ctx in
           emit ctx "%s = arith.maximumf %s, %s : %s" result arg1 arg2 dt;
           (result, Rack SFloat)
       | ("pow", [e1; e2]) ->
           let (arg1, _) = emit_expr ctx e1 in
           let (arg2, _) = emit_expr ctx e2 in
           emit_math_binary "powf" arg1 arg2
       | ("atan2", [e1; e2]) ->
           let (arg1, _) = emit_expr ctx e1 in
           let (arg2, _) = emit_expr ctx e2 in
           emit_math_binary "atan2" arg1 arg2
       | _ ->
           (* User-defined function call *)
           let arg_results = List.map (emit_expr ctx) args in
           let arg_vals = List.map fst arg_results in
           let arg_types = List.map (fun (_, t) -> mlir_type ctx t) arg_results in
           let result = fresh ctx "call" in
           let dt = data_type ctx in
           emit ctx "%s = func.call @%s(%s) : (%s) -> %s"
             result name
             (String.concat ", " arg_vals)
             (String.concat ", " arg_types)
             dt;
           (result, Rack SFloat))

  | EField (e, field) ->
      (* First check if this is a direct variable field access (e.g., chunk.ox) *)
      (match e.v with
       | EVar var_name ->
           (* Try chunk.field format first (for over loop bindings) *)
           let chunk_field_key = var_name ^ "." ^ field in
           (match Hashtbl.find_opt ctx.vars chunk_field_key with
            | Some ssa ->
                (* Look up base type to get proper field type *)
                let base_t = match Hashtbl.find_opt ctx.type_env.vars var_name with
                  | Some t -> t
                  | None -> Rack SFloat  (* fallback for untyped vars *)
                in
                (ssa, get_field_type base_t field)
            | None ->
                (* Fall back to base_field format *)
                let (base, t) = emit_expr ctx e in
                let field_var = base ^ "_" ^ field in
                (match Hashtbl.find_opt ctx.vars field_var with
                 | Some ssa -> (ssa, get_field_type t field)
                 | None ->
                     failwith (Printf.sprintf "Field %s.%s not bound in context" var_name field)))
       | _ ->
           let (base, t) = emit_expr ctx e in
           let field_var = base ^ "_" ^ field in
           (match Hashtbl.find_opt ctx.vars field_var with
            | Some ssa -> (ssa, get_field_type t field)
            | None ->
                failwith (Printf.sprintf "Field access %s.%s not bound in context" base field)))

  | EBroadcast e ->
      let (val_, t) = emit_expr ctx e in
      let result = emit_broadcast ctx val_ t in
      (result, broadcast t)

  | EReduce (op, e) ->
      let (arg, _) = emit_expr ctx e in
      let result = fresh ctx "red" in
      let op_name = match op with
        | RAdd -> "add"
        | RMul -> "mul"
        | RMin -> "minimumf"
        | RMax -> "maximumf"
        | _ -> "add"
      in
      if is_scalar_mode ctx then
        (* GPU mode: no reduction needed, value is already scalar *)
        (arg, Scalar SFloat)
      else begin
        let dt = data_type ctx in
        emit ctx "%s = vector.reduction <%s>, %s : %s into f32"
          result op_name arg dt;
        (result, Scalar SFloat)
      end

  | ELaneIndex ->
      let result = fresh ctx "idx" in
      if is_scalar_mode ctx then begin
        (* GPU mode: lane index comes from current iteration *)
        match ctx.current_over_iter with
        | Some iter ->
            (* Cast index to i32 *)
            emit ctx "%s = arith.index_cast %s : index to i32" result iter;
            (result, Scalar SInt)
        | None ->
            emit ctx "%s = arith.constant 0 : i32" result;
            (result, Scalar SInt)
      end else begin
        emit ctx "%s = vector.step : vector<%dxi32>" result ctx.width;
        (result, Rack SInt)
      end

  | ELanes ->
      let result = fresh ctx "w" in
      emit ctx "%s = arith.constant %d : i32" result ctx.width;
      (result, Scalar SInt)

  | ERecord (name, inits) ->
      (* Emit each field value and track them for later field access.
         We decompose records to individual field SSA values rather than
         using MLIR tuples, since field access is the primary use case. *)
      let result = fresh ctx "rec" in
      let field_results = List.map (fun init ->
        let (v, t) = emit_expr ctx init.init_value in
        (init.init_field, v, t)
      ) inits in

      (* Store field values keyed by "result_field" for EField access *)
      List.iter (fun (field_name, v, _) ->
        Hashtbl.add ctx.vars (result ^ "_" ^ field_name) v
      ) field_results;

      (* Emit as MLIR tuple if we have the type info, otherwise just track fields *)
      let record_type = match Hashtbl.find_opt ctx.types name with
        | Some t -> t
        | None -> Unknown
      in
      (match record_type with
       | Stack (_, fields) | Single (_, fields) when List.length fields > 0 ->
           (* Emit as tuple.from_elements for MLIR compatibility *)
           let field_vals = List.map (fun (_, v, _) -> v) field_results in
           let field_types = List.map (fun (_, _, t) -> mlir_type ctx t) field_results in
           let tuple_type = "tuple<" ^ String.concat ", " field_types ^ ">" in
           emit ctx "%s = tuple.from_elements %s : %s"
             result (String.concat ", " field_vals) tuple_type
       | _ ->
           (* No type info - just emit a comment tracking the fields *)
           let field_vals = List.map (fun (_, v, _) -> v) field_results in
           emit ctx "// Record %s: %s" name (String.concat ", " field_vals));

      (result, record_type)

  | ETuple es ->
      let vals = List.map (fun e -> emit_expr ctx e) es in
      let result = fresh ctx "tup" in
      emit ctx "// Tuple: %s" (String.concat ", " (List.map fst vals));
      (result, Tuple (List.map snd vals))

  | EUnit -> ("%unit", Unit)

  | ELet (binding, body) ->
      let (v, t) = emit_expr ctx binding.bind_expr in
      Hashtbl.add ctx.vars binding.bind_name v;
      Hashtbl.add ctx.type_env.vars binding.bind_name t;
      emit_expr ctx body

  | EFusedPipe (l, r) ->
      (* Fused pipe: evaluate right-to-left, fusion guaranteed by type checker *)
      let (lhs, _) = emit_expr ctx l in
      (* If r is a function call, apply lhs as first argument *)
      (match r.v with
       | ECall (name, args) ->
           let arg_results = List.map (emit_expr ctx) args in
           let all_args = lhs :: List.map fst arg_results in
           let all_types = List.map (fun (_, t) -> mlir_type ctx t) arg_results in
           let result = fresh ctx "fused" in
           let dt = data_type ctx in
           emit ctx "%s = func.call @%s(%s) : (%s, %s) -> %s"
             result name
             (String.concat ", " all_args)
             dt (String.concat ", " all_types)
             dt;
           (result, Rack SFloat)
       | EVar fname ->
           (* Simple function application *)
           let result = fresh ctx "fused" in
           let dt = data_type ctx in
           emit ctx "%s = func.call @%s(%s) : (%s) -> %s" result fname lhs dt dt;
           (result, Rack SFloat)
       | _ ->
           (* Fall back to evaluating r and treating as pipe *)
           emit_expr ctx r)

  (* Explicitly fail on unhandled expressions - no silent fallback *)
  | ELambda _ ->
      failwith "Unhandled expression: ELambda (closures not yet implemented)"
  | EPipe _ ->
      failwith "Unhandled expression: EPipe (should be desugared before emission)"
  | EWith _ ->
      failwith "Unhandled expression: EWith (record update not yet implemented)"
  | EExtract _ ->
      failwith "Unhandled expression: EExtract (lane extraction not yet implemented)"
  | EInsert _ ->
      failwith "Unhandled expression: EInsert (lane insertion not yet implemented)"
  | EScan _ ->
      failwith "Unhandled expression: EScan (prefix scan not yet implemented)"
  | EShuffle _ ->
      failwith "Unhandled expression: EShuffle (shuffle not yet implemented)"
  | EShift _ ->
      failwith "Unhandled expression: EShift (vector shift not yet implemented)"
  | ERotate _ ->
      failwith "Unhandled expression: ERotate (vector rotate not yet implemented)"
  | EGather _ ->
      failwith "Unhandled expression: EGather (gather not yet implemented)"
  | EScatter _ ->
      failwith "Unhandled expression: EScatter (scatter not yet implemented)"
  | ECompress _ ->
      failwith "Unhandled expression: ECompress (compress not yet implemented)"
  | EExpand _ ->
      failwith "Unhandled expression: EExpand (expand not yet implemented)"
  | ETines _ ->
      failwith "Unhandled expression: ETines (should be handled via emit_sweep)"
  | EFma _ ->
      failwith "Unhandled expression: EFma (fused multiply-add not yet implemented)"
  | EOuter _ ->
      failwith "Unhandled expression: EOuter (outer product not yet implemented)"

and get_field_type t field =
  match t with
  | Stack (_, fields) | Single (_, fields) -> (
      match List.assoc_opt field fields with
      | Some ft -> ft
      | None -> Rack SFloat)
  | _ -> Rack SFloat

(** Emit a statement *)
let rec emit_stmt ctx (stmt: Ast.stmt) =
  match stmt.v with
  | SLet binding ->
      (* SSA binding: immutable, no storage *)
      let (v, t) = emit_expr ctx binding.bind_expr in
      Hashtbl.add ctx.vars binding.bind_name v;
      Hashtbl.add ctx.type_env.vars binding.bind_name t

  | SLocBind lb ->
      (* Location binding: introduces mutable storage *)
      let (v, t) = emit_expr ctx lb.loc_expr in
      Hashtbl.add ctx.vars lb.loc_name v;
      Hashtbl.add ctx.type_env.vars lb.loc_name t;
      emit ctx "// Location %s := %s" lb.loc_name v

  | SAssign (name, e) ->
      (* Assignment: mutates existing location (must exist) *)
      if not (Hashtbl.mem ctx.vars name) then
        failwith (Printf.sprintf "Cannot assign to undefined location: %s" name);
      let (v, _) = emit_expr ctx e in
      Hashtbl.replace ctx.vars name v

  | SFused fb ->
      (* Fused binding: must fuse, no intermediate storage *)
      (* Type checker guarantees this is fusible - just emit as SSA *)
      let (v, t) = emit_expr ctx fb.fused_expr in
      Hashtbl.add ctx.vars fb.fused_name v;
      Hashtbl.add ctx.type_env.vars fb.fused_name t
      (* No comment - these are invisible in the output by design *)

  | SExpr e ->
      ignore (emit_expr ctx e)

  | SOver over ->
      (* Emit scf.for loop over pack in stack-sized chunks *)
      emit_over_loop ctx over

(** Emit over loop with width-appropriate constructs.

    This is where multi-versioning manifests in loop structure:
    - width=1 (scalar/GPU): scf.parallel with memref.load/store
    - width>1 (vector/CPU): scf.for with vector.load/maskedstore

    For CPU multi-versioning (SSE/AVX/AVX-512), only the width changes;
    the loop structure remains scf.for with vector operations.
    The vector width (4, 8, 16) determines register utilization. *)
and emit_over_loop ctx (over: Ast.over_loop) =
  (* Get count expression and its type - handle scalar variable specially *)
  let (count_val, count_type) = match over.over_count.v with
    | EScalarVar name ->
        let v = match Hashtbl.find_opt ctx.vars name with
         | Some v -> v
         | None -> failwith ("Undefined count variable: " ^ name)
        in
        let t = match Hashtbl.find_opt ctx.type_env.vars name with
         | Some t -> t
         | None -> Scalar SFloat
        in
        (v, t)
    | _ -> emit_expr ctx over.over_count
  in

  (* Cast count to index - handle both integer and float types *)
  let count_idx = fresh ctx "count_idx" in
  (match count_type with
   | Scalar SInt64 ->
       emit ctx "%s = arith.index_cast %s : i64 to index" count_idx count_val
   | Scalar SInt ->
       emit ctx "%s = arith.index_cast %s : i32 to index" count_idx count_val
   | Scalar SFloat ->
       let count_i64 = fresh ctx "count_i64" in
       emit ctx "%s = arith.fptosi %s : f32 to i64" count_i64 count_val;
       emit ctx "%s = arith.index_cast %s : i64 to index" count_idx count_i64
   | _ ->
       emit ctx "%s = arith.index_cast %s : i64 to index" count_idx count_val);

  if is_scalar_mode ctx then
    emit_over_loop_gpu ctx over count_idx
  else
    emit_over_loop_cpu ctx over count_idx

(** GPU mode: scf.parallel with scalar operations, one element per iteration *)
and emit_over_loop_gpu ctx (over: Ast.over_loop) count_idx =
  let zero = fresh ctx "zero" in
  let one = fresh ctx "one" in

  emit ctx "%s = arith.constant 0 : index" zero;
  emit ctx "%s = arith.constant 1 : index" one;

  (* scf.parallel declares iterations are independent *)
  let iter_var = fresh ctx "i" in
  emit ctx "scf.parallel (%s) = (%s) to (%s) step (%s) {" iter_var zero count_idx one;
  ctx.indent <- ctx.indent + 1;

  (* Store iteration index for ELaneIndex *)
  ctx.current_over_iter <- Some iter_var;
  ctx.current_over_offset <- Some iter_var;  (* offset = iter in scalar mode *)

  (* Load fields from pack memrefs using memref.load (scalar) *)
  (match Hashtbl.find_opt ctx.type_env.vars over.over_pack with
   | Some (Pack (_, fields)) ->
       List.iter (fun (field_name, _field_type) ->
         let memref_key = over.over_pack ^ "." ^ field_name in
         match Hashtbl.find_opt ctx.pack_memrefs memref_key with
         | Some memref ->
             let loaded = fresh ctx field_name in
             emit ctx "%s = memref.load %s[%s] : memref<?xf32>" loaded memref iter_var;
             Hashtbl.add ctx.vars (over.over_chunk ^ "." ^ field_name) loaded
         | None ->
             emit ctx "// Warning: no memref for %s" memref_key
       ) fields
   | _ ->
       emit ctx "// Warning: pack type not found for %s" over.over_pack);

  (* Emit body statements, capture result of last expression *)
  let result_val = ref None in
  List.iter (fun stmt ->
    match stmt.Ast.v with
    | Ast.SExpr e ->
        let (v, _) = emit_expr ctx e in
        result_val := Some v
    | _ ->
        emit_stmt ctx stmt
  ) over.over_body;

  (* Store result to output memref if available *)
  (match (!result_val, ctx.output_memref) with
   | (Some result, Some out_memref) ->
       emit ctx "memref.store %s, %s[%s] : memref<?xf32>" result out_memref iter_var
   | (Some result, None) ->
       emit ctx "// Result %s computed but no output memref" result
   | _ ->
       emit ctx "// No result expression in over loop body");

  emit ctx "scf.reduce";
  ctx.current_over_iter <- None;
  ctx.current_over_offset <- None;
  ctx.indent <- ctx.indent - 1;
  emit ctx "}"

(** CPU mode: scf.for with vector operations, lanes elements per iteration *)
and emit_over_loop_cpu ctx (over: Ast.over_loop) count_idx =
  let dt = data_type ctx in
  let mt = mask_type ctx in
  let width = ctx.width in

  let zero = fresh ctx "zero" in
  let one = fresh ctx "one" in
  let lanes_val = fresh ctx "lanes" in
  let num_iters = fresh ctx "niters" in

  emit ctx "%s = arith.constant 0 : index" zero;
  emit ctx "%s = arith.constant 1 : index" one;
  emit ctx "%s = arith.constant %d : index" lanes_val width;

  (* Compute number of full iterations: ceil(count / lanes) *)
  let count_plus = fresh ctx "count_plus" in
  let lanes_minus_one = fresh ctx "lanes_m1" in
  emit ctx "%s = arith.constant %d : index" lanes_minus_one (width - 1);
  emit ctx "%s = arith.addi %s, %s : index" count_plus count_idx lanes_minus_one;
  emit ctx "%s = arith.divui %s, %s : index" num_iters count_plus lanes_val;

  (* Emit scf.for loop *)
  let iter_var = fresh ctx "i" in
  emit ctx "scf.for %s = %s to %s step %s {" iter_var zero num_iters one;
  ctx.indent <- ctx.indent + 1;

  (* Compute offset for this iteration *)
  let offset = fresh ctx "offset" in
  emit ctx "%s = arith.muli %s, %s : index" offset iter_var lanes_val;

  (* Store offset for field access *)
  ctx.current_over_offset <- Some offset;

  (* Compute tail mask for last iteration *)
  let remaining = fresh ctx "remaining" in
  let mask = fresh ctx "mask" in

  emit ctx "%s = arith.subi %s, %s : index" remaining count_idx offset;
  emit ctx "%s = vector.create_mask %s : %s" mask remaining mt;

  (* Store mask in context for masked operations *)
  ctx.current_over_mask <- Some mask;

  (* Load chunk fields from pack memrefs using vector.load *)
  (match Hashtbl.find_opt ctx.type_env.vars over.over_pack with
   | Some (Pack (_, fields)) ->
       List.iter (fun (field_name, _field_type) ->
         let memref_key = over.over_pack ^ "." ^ field_name in
         match Hashtbl.find_opt ctx.pack_memrefs memref_key with
         | Some memref ->
             let loaded = fresh ctx field_name in
             emit ctx "%s = vector.load %s[%s] : memref<?xf32>, %s" loaded memref offset dt;
             Hashtbl.add ctx.vars (over.over_chunk ^ "." ^ field_name) loaded
         | None ->
             emit ctx "// Warning: no memref for %s" memref_key
       ) fields
   | _ ->
       emit ctx "// Warning: pack type not found for %s" over.over_pack);

  (* Emit body statements, capture result of last expression *)
  let result_val = ref None in
  List.iter (fun stmt ->
    match stmt.Ast.v with
    | Ast.SExpr e ->
        let (v, _) = emit_expr ctx e in
        result_val := Some v
    | _ ->
        emit_stmt ctx stmt
  ) over.over_body;

  (* Store result to output memref if available *)
  (match (!result_val, ctx.output_memref) with
   | (Some result, Some out_memref) ->
       emit ctx "vector.maskedstore %s[%s], %s, %s : memref<?xf32>, %s, %s"
         out_memref offset mask result mt dt
   | (Some result, None) ->
       emit ctx "// Result %s computed but no output memref" result
   | _ ->
       emit ctx "// No result expression in over loop body");

  ctx.current_over_offset <- None;
  ctx.current_over_mask <- None;
  ctx.indent <- ctx.indent - 1;
  emit ctx "}"

(** Emit predicate, return SSA name of mask *)
let rec emit_predicate ctx (pred: Ast.predicate) : string =
  match pred.v with
  | PExpr e ->
      fst (emit_expr ctx e)

  | PCmp (l, op, r) ->
      let (lhs, lt) = emit_expr ctx l in
      let (rhs, rt) = emit_expr ctx r in
      (* Handle broadcast if needed *)
      let (lhs', rhs') = match (lt, rt) with
        | (Scalar _, Rack _) -> (emit_broadcast ctx lhs lt, rhs)
        | (Rack _, Scalar _) -> (lhs, emit_broadcast ctx rhs rt)
        | _ -> (lhs, rhs)
      in
      let result = fresh ctx "cmp" in
      let op_str = match op with
        | CLt -> "olt" | CLe -> "ole" | CGt -> "ogt"
        | CGe -> "oge" | CEq -> "oeq" | CNe -> "one"
      in
      let dt = data_type ctx in
      emit ctx "%s = arith.cmpf %s, %s, %s : %s" result op_str lhs' rhs' dt;
      result

  | PIs (l, r) | PIsNot (l, r) ->
      let (lhs, _) = emit_expr ctx l in
      let (rhs, _) = emit_expr ctx r in
      let result = fresh ctx "is" in
      let cmp = match pred.v with PIs _ -> "oeq" | _ -> "one" in
      let dt = data_type ctx in
      emit ctx "%s = arith.cmpf %s, %s, %s : %s" result cmp lhs rhs dt;
      result

  | PAnd (l, r) ->
      let lm = emit_predicate ctx l in
      let rm = emit_predicate ctx r in
      let result = fresh ctx "and" in
      let mt = mask_type ctx in
      emit ctx "%s = arith.andi %s, %s : %s" result lm rm mt;
      result

  | POr (l, r) ->
      let lm = emit_predicate ctx l in
      let rm = emit_predicate ctx r in
      let result = fresh ctx "or" in
      let mt = mask_type ctx in
      emit ctx "%s = arith.ori %s, %s : %s" result lm rm mt;
      result

  | PNot p ->
      let m = emit_predicate ctx p in
      let ones = fresh ctx "ones" in
      let result = fresh ctx "not" in
      let mt = mask_type ctx in
      if is_scalar_mode ctx then
        emit ctx "%s = arith.constant 1 : %s" ones mt
      else
        emit ctx "%s = arith.constant dense<true> : %s" ones mt;
      emit ctx "%s = arith.xori %s, %s : %s" result m ones mt;
      result

  | PTineRef name -> (
      match Hashtbl.find_opt ctx.tines name with
      | Some ssa -> ssa
      | None -> failwith ("Reference to undefined tine: " ^ name))

(** Emit tine declaration *)
let emit_tine ctx (tine: Ast.tine) =
  let mask = emit_predicate ctx tine.tine_pred in
  Hashtbl.add ctx.tines tine.tine_name mask;
  emit ctx "// Tine #%s = %s" tine.tine_name mask

(** Emit through block *)
let emit_through ctx (th: Ast.through) =
  (* Get the mask for this through block *)
  let mask = match th.through_tine with
    | TRSingle name -> (
        match Hashtbl.find_opt ctx.tines name with
        | Some m -> m
        | None -> failwith ("Through references undefined tine: " ^ name))
    | TRComposed pred -> emit_predicate ctx pred
  in

  (* Emit passthru value if present, otherwise use zero *)
  let passthru = match th.through_passthru with
    | Some e -> fst (emit_expr ctx e)
    | None ->
        let z = fresh ctx "zero" in
        let dt = data_type ctx in
        if is_scalar_mode ctx then
          emit ctx "%s = arith.constant 0.0 : %s" z dt
        else
          emit ctx "%s = arith.constant dense<0.0> : %s" z dt;
        z
  in

  (* In GPU mode, use scf.if for conditional execution *)
  if is_scalar_mode ctx then begin
    let result_var = fresh ctx "through_result" in
    emit ctx "%s = scf.if %s -> (%s) {" result_var mask (data_type ctx);
    ctx.indent <- ctx.indent + 1;
    (* Emit body statements *)
    List.iter (emit_stmt ctx) th.through_body;
    (* Emit result expression *)
    let (result_val, result_t) = emit_expr ctx th.through_result in
    emit ctx "scf.yield %s : %s" result_val (mlir_type ctx result_t);
    ctx.indent <- ctx.indent - 1;
    emit ctx "} else {";
    ctx.indent <- ctx.indent + 1;
    emit ctx "scf.yield %s : %s" passthru (data_type ctx);
    ctx.indent <- ctx.indent - 1;
    emit ctx "}";
    (* Store the result binding *)
    Hashtbl.add ctx.vars th.through_binding result_var;
    Hashtbl.add ctx.type_env.vars th.through_binding (Rack SFloat);
    emit ctx "// Through -> %s = %s" th.through_binding result_var
  end else begin
    (* CPU mode: use arith.select *)
    (* Emit body statements *)
    List.iter (emit_stmt ctx) th.through_body;
    (* Emit result expression *)
    let (result_val, result_t) = emit_expr ctx th.through_result in
    (* Use arith.select to apply the mask *)
    let masked = fresh ctx "masked" in
    let result_type = mlir_type ctx result_t in
    let mt = mask_type ctx in
    emit ctx "%s = arith.select %s, %s, %s : %s, %s"
      masked mask result_val passthru mt result_type;
    (* Store the result binding *)
    Hashtbl.add ctx.vars th.through_binding masked;
    Hashtbl.add ctx.type_env.vars th.through_binding result_t;
    emit ctx "// Through -> %s = %s" th.through_binding masked
  end

(** Emit sweep block *)
let emit_sweep ctx (sw: Ast.sweep) =
  let dt = data_type ctx in
  let mt = mask_type ctx in
  (* Build nested select chain from last to first *)
  let rec build_select arms acc =
    match arms with
    | [] -> acc
    | arm :: rest ->
        let (val_, _) = emit_expr ctx arm.arm_value in
        let result = fresh ctx "sel" in
        (match arm.arm_tine with
         | Some name -> (
             match Hashtbl.find_opt ctx.tines name with
             | Some mask ->
                 emit ctx "%s = arith.select %s, %s, %s : %s, %s"
                   result mask val_ acc mt dt;
                 build_select rest result
             | None ->
                 build_select rest val_)
         | None ->
             (* Catch-all: use this value as default *)
             build_select rest val_)
  in
  (* Start with undefined/zero and build up *)
  let init = fresh ctx "undef" in
  if is_scalar_mode ctx then
    emit ctx "%s = arith.constant 0.0 : %s" init dt
  else
    emit ctx "%s = arith.constant dense<0.0> : %s" init dt;
  let result = build_select (List.rev sw.sweep_arms) init in
  Hashtbl.add ctx.vars sw.sweep_binding result;
  emit ctx "// Sweep -> %s = %s" sw.sweep_binding result;
  result

(** Flatten params, expanding spreads to individual names *)
let flatten_params ctx params =
  List.concat_map (fun p ->
    match p with
    | PRack (n, _) -> [(n, false)]  (* name, is_scalar *)
    | PScalar (n, _) -> [(n, true)]
    | PSpread (names, type_name) ->
        (* Look up type to get field types *)
        (match Hashtbl.find_opt ctx.types type_name with
         | Some (Stack (_, fields)) | Some (Single (_, fields)) ->
             List.map2 (fun n (_, _) -> (n, false)) names fields
         | _ ->
             (* Fallback: treat as rack params *)
             List.map (fun n -> (n, false)) names)
  ) params

(** Emit crunch function *)
let emit_crunch ctx name params _result body =
  let dt = data_type ctx in
  (* Compute result type from annotation, or infer from result name, or default *)
  let result_type = match _result.result_type with
    | Some ty -> mlir_type ctx (Typecheck.typ_to_t ctx.type_env ty)
    | None ->
        (* Try to look up the result name as a type *)
        (match Typecheck.find_type ctx.type_env _result.result_name with
         | Some t -> mlir_type ctx t
         | None -> dt)  (* default to data_type *)
  in

  (* Flatten params, expanding spreads *)
  let flat_params = flatten_params ctx params in
  (* Function signature *)
  let param_strs = List.mapi (fun i (pname, _is_scalar) ->
    Hashtbl.add ctx.vars pname (Printf.sprintf "%%arg%d" i);
    Printf.sprintf "%%arg%d: %s" i dt
  ) flat_params in

  emit ctx "func.func @%s(%s) -> %s attributes {llvm.alwaysinline} {" name (String.concat ", " param_strs) result_type;
  ctx.indent <- ctx.indent + 1;

  (* Emit body *)
  List.iter (emit_stmt ctx) body;

  (* Find result variable and return it *)
  let ret_val = match Hashtbl.find_opt ctx.vars _result.result_name with
    | Some v -> v
    | None -> "%arg0"
  in
  emit ctx "func.return %s : %s" ret_val result_type;

  ctx.indent <- ctx.indent - 1;
  emit ctx "}"

(** Emit rake function *)
let emit_rake ctx name params _result setup tines throughs sweep =
  let dt = data_type ctx in
  (* Compute result type *)
  let result_type = match Typecheck.find_type ctx.type_env _result.result_name with
    | Some t -> mlir_type ctx t
    | None -> dt
  in

  (* Flatten params, expanding spreads *)
  let flat_params = flatten_params ctx params in
  (* Function signature *)
  let param_strs = List.mapi (fun i (pname, is_scalar) ->
    let pty = if is_scalar then "f32" else dt in
    let arg = Printf.sprintf "%%arg%d" i in
    Hashtbl.add ctx.vars pname arg;
    Hashtbl.add ctx.type_env.vars pname
      (if is_scalar then Scalar SFloat else Rack SFloat);
    Printf.sprintf "%s: %s" arg pty
  ) flat_params in

  emit ctx "func.func @%s(%s) -> %s attributes {llvm.alwaysinline} {" name (String.concat ", " param_strs) result_type;
  ctx.indent <- ctx.indent + 1;

  (* Emit setup statements *)
  List.iter (emit_stmt ctx) setup;

  (* Emit tine declarations *)
  List.iter (emit_tine ctx) tines;

  (* Emit through blocks *)
  List.iter (emit_through ctx) throughs;

  (* Emit sweep *)
  let result = emit_sweep ctx sweep in

  emit ctx "func.return %s : %s" result result_type;

  ctx.indent <- ctx.indent - 1;
  emit ctx "}"

(** Emit a definition *)
let rec emit_def ctx (def: Ast.def) =
  match def.v with
  | DStack (name, fields) ->
      emit ctx "// Stack type: %s" name;
      List.iter (fun f ->
        emit ctx "//   %s: %s" f.field_name (show_typ_kind f.field_type.v)
      ) fields

  | DSingle (name, fields) ->
      emit ctx "// Single type: %s" name;
      List.iter (fun f ->
        emit ctx "//   %s: %s" f.field_name (show_typ_kind f.field_type.v)
      ) fields

  | DType (name, ty) ->
      emit ctx "// Type alias: %s = %s" name (show_typ_kind ty.v)

  | DCrunch (name, params, result, body) ->
      emit_crunch ctx name params result body

  | DRake (name, params, result, setup, tines, throughs, sweep) ->
      emit_rake ctx name params result setup tines throughs sweep

  | DRun (name, params, result, body) ->
      emit_run ctx name params result body

(** Emit run function with pack parameter expansion *)
and emit_run ctx name params _result body =
  let dt = data_type ctx in
  (* Expand pack parameters to memrefs, keep scalars as-is *)
  let param_counter = ref 0 in
  let param_strs = List.concat_map (fun p ->
    match p with
    | PSpread (names, _type_name) ->
        (* Spreads in run expand to individual rack params *)
        List.map (fun pname ->
          let arg_idx = !param_counter in
          incr param_counter;
          let arg = Printf.sprintf "%%arg%d" arg_idx in
          Hashtbl.add ctx.vars pname arg;
          Hashtbl.add ctx.type_env.vars pname (Rack SFloat);
          Printf.sprintf "%s: %s" arg dt
        ) names
    | _ ->
        let (pname, pty_opt, is_scalar) = match p with
          | PRack (n, t) -> (n, t, false)
          | PScalar (n, t) -> (n, t, true)
          | PSpread _ -> failwith "unreachable"
        in
        (* Check if this is a pack parameter *)
        let is_pack = match pty_opt with
          | Some ty -> (match ty.v with TPack _ -> true | _ -> false)
          | None -> false
        in

        if is_pack then begin
      (* Look up pack type and expand to memrefs for each field *)
      let pack_type_name = match pty_opt with
        | Some ty -> (match ty.v with TPack n -> n | _ -> pname)
        | None -> pname
      in
      match Hashtbl.find_opt ctx.types pack_type_name with
      | Some (Stack (_, fields)) | Some (Pack (_, fields)) ->
          List.map (fun (field_name, _) ->
            let arg_idx = !param_counter in
            incr param_counter;
            let arg = Printf.sprintf "%%arg%d" arg_idx in
            let memref_key = pname ^ "." ^ field_name in
            Hashtbl.add ctx.pack_memrefs memref_key arg;
            (* Also register the pack in vars for type lookup in over loop *)
            Hashtbl.add ctx.type_env.vars pname (Pack (pack_type_name, fields));
            Printf.sprintf "%s: memref<?xf32>" arg
          ) fields
      | _ ->
          let arg_idx = !param_counter in
          incr param_counter;
          let arg = Printf.sprintf "%%arg%d" arg_idx in
          Hashtbl.add ctx.vars pname arg;
          [Printf.sprintf "%s: memref<?xf32>" arg]
    end else if is_scalar then begin
      let arg_idx = !param_counter in
      incr param_counter;
      let arg = Printf.sprintf "%%arg%d" arg_idx in
      Hashtbl.add ctx.vars pname arg;
      (* Determine scalar type from annotation *)
      let scalar_type = match pty_opt with
        | Some ty -> (match ty.v with
            | TScalar PInt64 -> Scalar SInt64
            | TScalar PInt -> Scalar SInt
            | TScalar PDouble -> Scalar SDouble
            | TScalar PBool -> Scalar SBool
            | _ -> Scalar SFloat)
        | None -> Scalar SFloat
      in
      Hashtbl.add ctx.type_env.vars pname scalar_type;
      let mlir_ty = mlir_type_w 1 scalar_type in  (* Scalars are always width 1 *)
      [Printf.sprintf "%s: %s" arg mlir_ty]
    end else begin
      let arg_idx = !param_counter in
      incr param_counter;
      let arg = Printf.sprintf "%%arg%d" arg_idx in
      Hashtbl.add ctx.vars pname arg;
      Hashtbl.add ctx.type_env.vars pname (Rack SFloat);
      [Printf.sprintf "%s: %s" arg dt]
    end
  ) params in

  (* Add output memref for result *)
  let output_arg = Printf.sprintf "%%arg%d" !param_counter in
  let param_strs = param_strs @ [Printf.sprintf "%s: memref<?xf32>" output_arg] in
  ctx.output_memref <- Some output_arg;

  emit ctx "func.func @%s(%s) {" name (String.concat ", " param_strs);
  ctx.indent <- ctx.indent + 1;

  (* Emit body *)
  List.iter (emit_stmt ctx) body;

  ctx.output_memref <- None;
  emit ctx "func.return";
  ctx.indent <- ctx.indent - 1;
  emit ctx "}"

(** Emit a module *)
let emit_module ctx (m: Ast.module_) =
  emit ctx "// Module: %s" m.mod_name;
  List.iter (emit_def ctx) m.mod_defs

(** Emit a program with specified target *)
let emit_program ?(target=CPU) ?width env (prog: Ast.program) =
  let ctx = create_ctx ~target ?width env in
  let target_comment = match target with
    | CPU -> Printf.sprintf "CPU SIMD (width %d)" ctx.width
    | GPU -> "GPU scalar (scf.parallel)"
  in
  emit ctx "// Target: %s" target_comment;
  emit ctx "module {";
  ctx.indent <- 1;
  List.iter (emit_module ctx) prog;
  ctx.indent <- 0;
  emit ctx "}";
  Buffer.contents ctx.buf

(** Main entry point - CPU mode with configurable width
    ~width: Vector width (default 8 for AVX2)
      1  = scalar fallback
      4  = SSE (128-bit)
      8  = AVX/AVX2 (256-bit) - default
      16 = AVX-512 (512-bit) *)
let emit ?(width=8) env prog =
  emit_program ~target:CPU ~width env prog

(** GPU mode entry point (always width=1, scalar parallel) *)
let emit_gpu env prog =
  emit_program ~target:GPU ~width:1 env prog
