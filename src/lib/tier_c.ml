(** One C translation unit for WebAssembly and native programs.

    Native scratches and rakes are opaque Rake-selected assembly, checked in
    the final object. Slow callers use scalar f32/i32/u32/bool C boundaries. Native
    stream traversals embed complete selected loops. WebAssembly kernels
    keep their verified emission ({!Wasm_simd128_c}).
    A WebAssembly run becomes an external, never-inlined C function whose body is Rake's
    loops, loads and stores; its pure rack expressions become always-inline
    functions lowered through the scratch pipeline, so each rack operation is
    one selected instruction wherever it is written. Slow code becomes plain
    C: records, arrays and views as structs, module state and embedded data
    as statics, and integer arithmetic, conversions and indexing checked by
    small inline helpers that trap.

    Address formation inside a run is Rake's: an access whose element index
    is affine in its loop's index shares one strength-reduced pointer per
    view, stride and invariant base, and its constant term becomes the
    load's or store's offset immediate. Clang 20 folds such an offset only
    when it can see that the address doesn't wrap, which loop strength
    reduction hides; in the default [Barrier] addressing an empty [asm]
    statement with one i32 operand at the top of each iteration keeps each
    pointer opaque to it, so the offsets fold. [Plain] addressing emits
    intrinsics alone. *)

open Tier_ir

type addressing = Barrier | Plain

type execution_target = WebAssembly | Native_program of Target.profile

type native_selection = {
  registers : Native_backend.allocated option;
  traversals : Native_traversal.compiled option;
}

exception Emission_error of Ast.loc * string

let fail loc fmt = Printf.ksprintf (fun m -> raise (Emission_error (loc, m))) fmt

(* ─── Names ─────────────────────────────────────────────────────────── *)

(** A Rake local in C: user names gain a trailing underscore, and the
    compiler's own names (which contain [$]) map [$] to [_rk], so the two
    never collide. *)
let local name =
  if String.contains name '$' then String.concat "_rk" (String.split_on_char '$' name) else name ^ "_"

let is_aggregate = function Array _ | Record _ -> true | _ -> false

let function_name name = if List.mem name Typecheck.c_reserved_words then name ^ "_" else name

let scalar_c = function
  | Types.SBool -> "bool"
  | SInt8 -> "int8_t" | SUint8 -> "uint8_t"
  | SInt16 -> "int16_t" | SUint16 -> "uint16_t"
  | SInt -> "int32_t" | SUint -> "uint32_t"
  | SInt64 -> "int64_t" | SUint64 -> "uint64_t"
  | SFloat -> "float" | SDouble -> "double"

let scalar_tag = function
  | Types.SBool -> "bool"
  | SInt8 -> "i8" | SUint8 -> "u8" | SInt16 -> "i16" | SUint16 -> "u16"
  | SInt -> "i32" | SUint -> "u32" | SInt64 -> "i64" | SUint64 -> "u64"
  | SFloat -> "f32" | SDouble -> "f64"

let unsigned_of = function
  | Types.SInt8 | SUint8 -> "uint8_t" | SInt16 | SUint16 -> "uint16_t"
  | SInt | SUint -> "uint32_t" | SInt64 | SUint64 -> "uint64_t"
  | s -> scalar_c s

let signed_of = function
  | Types.SInt8 | SUint8 -> "int8_t" | SInt16 | SUint16 -> "int16_t"
  | SInt | SUint -> "int32_t" | SInt64 | SUint64 -> "int64_t"
  | s -> scalar_c s

(* ─── The unit being built ──────────────────────────────────────────── *)

type unit_ = {
  program : program;
  execution_target : execution_target;
  addressing : addressing;
  types : Buffer.t;
  defined : (string, unit) Hashtbl.t;
  helpers : Buffer.t;
  helper_names : (string, unit) Hashtbl.t;
  expressions : Buffer.t;  (** a run's pure rack expressions, always inline *)
  mutable selected : string list;  (** wasm instructions selected for the current run *)
  mutable lane_operations : int;  (** lane extractions and replacements Rake emitted in the current run *)
  mutable loops : int;  (** loops Rake emitted in the current run *)
  mutable slow_calls : string list;
  run_facts : (string, int * int * string list * string list) Hashtbl.t;
      (** per run: loops, lane operations and selected instructions, for verification *)
}

(* The process wrapper has C's char ** ABI. Its Rake body receives a separately
   typed pointer array, avoiding an incompatible uint8_t ** alias of argv. *)
let slow_symbol u name =
  if name <> "main" then function_name name
  else match List.find_opt (fun f -> f.fname = name) u.program.slows with
    | Some f when entry_parameters f.fparams = Some Process_arguments ->
        let occupied = List.map (fun f -> function_name f.fname) u.program.slows
          @ List.map (fun e -> function_name e.ename) u.program.externs
          @ List.map (fun r -> function_name r.run_name) u.program.runs
          @ List.filter_map (fun (d : Ast.def) -> match d.v with
              | DScratch (n, _, _, _) | DRake (n, _, _, _, _, _, _) -> Some (function_name n)
              | _ -> None) u.program.vector_defs in
        let rec choose candidate =
          if List.mem candidate occupied then choose (candidate ^ "_") else candidate in
        choose "rake_process_main"
    | _ -> "main"

let helper u name text =
  if not (Hashtbl.mem u.helper_names name) then (
    Hashtbl.replace u.helper_names name ();
    Buffer.add_string u.helpers text)

let record_c u name =
  match List.find_opt (fun r -> r.rname = name) u.program.records with
  | Some { rlayout = (C_struct _ | C_union _); _ } -> name
  | _ -> "rake_" ^ name

let rec tag = function
  | Sc s -> scalar_tag s
  | Array (n, t) -> Printf.sprintf "a%d_%s" n (tag t)
  | View (t, writable) -> (if writable then "v_" else "cv_") ^ tag t
  | Ptr (t, access) -> (if access = Read_only then "cp_" else "p_") ^ tag t
  | Function_pointer (args, result) ->
      let part ty = let text = tag ty in Printf.sprintf "%d_%s" (String.length text) text in
      "fn_" ^ String.concat "_" (List.map part args) ^ "_ret_" ^ part result
  | Record name -> "r" ^ name
  | Void -> "void"
  | ty -> invalid_arg ("tag " ^ string_of_ty ty)

let rec ctype u ty =
  match ty with
  | Sc s -> scalar_c s
  | Array (n, t) ->
      let name = "rake_arr_" ^ tag ty in
      if not (Hashtbl.mem u.defined name) then (
        let element = ctype u t in
        complete u t;
        Hashtbl.replace u.defined name ();
        Buffer.add_string u.types (Printf.sprintf "typedef struct { %s e[%d]; } %s;\n" element n name));
      name
  | View (t, writable) ->
      let name = "rake_" ^ tag ty in
      if not (Hashtbl.mem u.defined name) then (
        let pointer = ctype u (Ptr (t, if writable then Read_write else Read_only)) in
        Hashtbl.replace u.defined name ();
        Buffer.add_string u.types (Printf.sprintf "typedef struct { %s data; int32_t count; } %s;\n" pointer name));
      name
  | Ptr (t, access) -> ctype u t ^ (if access = Read_only then " const *" else " *")
  | Function_pointer (args, result) ->
      let name = "rake_" ^ tag ty in
      if not (Hashtbl.mem u.defined name) then (
        let result = ctype u result and args = List.map (ctype u) args in
        Hashtbl.replace u.defined name ();
        Buffer.add_string u.types (Printf.sprintf "typedef %s (*%s)(%s);\n" result name
          (if args = [] then "void" else String.concat ", " args)));
      name
  | Record name -> record_c u name
  | Stack (stack, false) -> stack_type u stack false
  | Stack (stack, true) -> stack_type u stack true
  | Rack _ | Mask _ -> "v128_t"
  | Str -> "const char *"
  | Void -> "void"
  | Rack_array _ -> invalid_arg "a rack array has no C type"

(** Make a record's struct complete before a value of it is held. *)
and complete u ty =
  match ty with
  | Record name -> (
      match List.find_opt (fun r -> r.rname = name) u.program.records with
      | Some ({ rlayout = Rake_struct; _ } as r) ->
          let cname = record_c u name in
          if not (Hashtbl.mem u.defined cname) then (
            let fields = List.map (fun (f, t) -> Printf.sprintf "    %s %s;\n" (ctype u t) f) r.rfields in
            List.iter (fun (_, t) -> complete u t) r.rfields;
            Hashtbl.replace u.defined cname ();
            Buffer.add_string u.types (Printf.sprintf "struct %s {\n%s};\n" cname (String.concat "" fields)))
      | _ -> ())
  | Array (_, t) -> ignore (ctype u ty); complete u t
  | _ -> ()

and stack_type u stack writable =
  let name = Printf.sprintf "struct rake_%sstack_%s_v1" (if writable then "mut_" else "") stack in
  if not (Hashtbl.mem u.defined name) then (
    Hashtbl.replace u.defined name ();
    let s = find_pack u.program stack in
    let fields =
      List.map (fun (f, e) -> Printf.sprintf "    %s%s *%s;\n" (if writable then "" else "const ") (scalar_c e) f) s.pack_fields
    in
    Buffer.add_string u.types (Printf.sprintf "%s {\n%s};\n" name (String.concat "" fields)));
  name

(* ─── Runtime helpers ───────────────────────────────────────────────── *)

let checked u op s =
  let t = scalar_c s and k = scalar_tag s in
  let name = Printf.sprintf "rake_%s_%s" op k in
  let body =
    match op with
    | "add" | "sub" | "mul" ->
        Printf.sprintf "    %s r;\n    if (__builtin_%s_overflow(a, b, &r)) __builtin_trap();\n    return r;\n" t op
    | "div" | "rem" ->
        let overflow = if is_signed s then Printf.sprintf " || (b == -1 && a == (%s)((%s)1 << %d))" t (unsigned_of s) (bits s - 1) else "" in
        Printf.sprintf "    if (b == 0%s) __builtin_trap();\n    return (%s)(a %s b);\n" overflow t (if op = "div" then "/" else "%")
    | _ -> invalid_arg op
  in
  helper u name (Printf.sprintf "static inline %s %s(%s a, %s b)\n{\n%s}\n" t name t t body);
  name

let index_helper u =
  helper u "rake_index"
    "static inline int32_t rake_index(int64_t i, int64_t n)\n{\n    if (i < 0 || i >= n) __builtin_trap();\n    return (int32_t)i;\n}\n";
  "rake_index"

let span_helper u =
  helper u "rake_span"
    "static inline int32_t rake_span(int64_t i, int64_t lanes, int64_t n)\n{\n    if (i < 0 || i > n || lanes > n - i) __builtin_trap();\n    return (int32_t)i;\n}\n"

let float_extreme u op s =
  let t = scalar_c s and k = scalar_tag s in
  let name = Printf.sprintf "rake_%s_%s" op k in
  let nan = if s = SDouble then "__builtin_nan(\"\")" else "__builtin_nanf(\"\")" in
  let signbit = "__builtin_signbit" in
  let equal = if op = "min" then "return " ^ signbit ^ "(a) ? a : b;" else "return " ^ signbit ^ "(a) ? b : a;" in
  let pick = if op = "min" then "a < b ? a : b" else "a > b ? a : b" in
  helper u name
    (Printf.sprintf "static inline %s %s(%s a, %s b)\n{\n    if (a != a || b != b) return %s;\n    if (a == b) %s\n    return %s;\n}\n"
       t name t t nan equal pick);
  name

let bitcast_helper u target source =
  let name = Printf.sprintf "rake_bitcast_%s_from_%s" (scalar_tag target) (scalar_tag source) in
  let target_type = scalar_c target in
  helper u name
    (Printf.sprintf "static inline %s %s(%s x)\n{\n    %s result;\n    __builtin_memcpy(&result, &x, sizeof result);\n    return result;\n}\n"
       target_type name (scalar_c source) target_type);
  name

let math_helpers u =
  let float_from_bits = bitcast_helper u SFloat SUint in
  let bits_from_float = bitcast_helper u SUint SFloat in
  helper u "rake_math" (Rake_math.c_source ~float_from_bits ~bits_from_float ())

(* ─── Uniform scalar expressions ────────────────────────────────────── *)

(** How a name is reached in the code being emitted. *)
type place_kind = Value | Borrowed  (** a pointer parameter, read through * *)

(** A table keyed by the identity of an IR node, not its structure: two
    accesses that look alike in different unrolled copies are different. *)
module Node_table = Hashtbl.Make (struct
  type t = Obj.t
  let equal = ( == )
  let hash = Hashtbl.hash
end)

type scope = {
  places : (string, place_kind) Hashtbl.t;
  accesses : string Node_table.t;  (** a run's planned accesses: index or element node to address *)
  dropped : unit Node_table.t;  (** uniform definitions whose every use is a planned, checked access *)
  mutable framed : bool;  (** this slow function keeps large aggregates in Rake's frame stack *)
  frame_slots : string Node_table.t;  (** declaration identity -> field in this function's frame *)
}

let new_scope () =
  { places = Hashtbl.create 16; accesses = Node_table.create 8; dropped = Node_table.create 8; framed = false; frame_slots = Node_table.create 4 }

let int_literal s value =
  match s with
  | Types.SInt64 -> Printf.sprintf "INT64_C(%Ld)" value
  | SUint64 -> Printf.sprintf "UINT64_C(0x%Lx)" value
  | SUint -> Printf.sprintf "%LdU" value
  | SInt when value = -2147483648L -> "(-2147483647 - 1)"
  | _ -> Printf.sprintf "%Ld" value

let rec is_zero u (e : expr) =
  match e.k with
  | Int 0L | Bool false -> true
  | Float f -> f = 0.0 && not (Float.sign_bit f)
  | Array_lit items -> List.for_all (is_zero u) items
  | Record_lit (name, fields) ->
      let record = List.find (fun r -> r.rname = name) u.program.records in
      (match record.rlayout with C_union _ -> false | Rake_struct | C_struct _ ->
        List.for_all (fun (_, value) -> is_zero u value) fields)
  | _ -> false

let condition text =
  let n = String.length text in
  let rec closes_at depth i =
    if i >= n then -1
    else
      match text.[i] with
      | '(' -> closes_at (depth + 1) (i + 1)
      | ')' -> if depth = 1 then i else closes_at (depth - 1) (i + 1)
      | _ -> closes_at depth (i + 1)
  in
  if n >= 2 && text.[0] = '(' && closes_at 0 0 = n - 1 then text else "(" ^ text ^ ")"

let rec expr u scope (e : expr) : string =
  let go = expr u scope in
  match e.k with
  | Int value -> (
      match e.ty with
      | Sc s when is_float s -> Rake_math.c_float (Int64.to_float value)
      | Sc s -> Printf.sprintf "((%s)%s)" (scalar_c s) (int_literal s value)
      | _ -> Int64.to_string value)
  | Float value -> if e.ty = Sc SDouble then Printf.sprintf "%h" value else Rake_math.c_float value
  | Bool value -> if value then "true" else "false"
  | Str_lit text -> "\"" ^ text ^ "\""
  | Var name -> (
      match Hashtbl.find_opt scope.places name with
      | Some Borrowed -> "(*" ^ local name ^ ")"
      | _ -> local name)
  | Global name -> global_ref u name e.ty
  | Unary (Neg, a) -> (
      match a.ty with
      | Sc s when is_integer s -> Printf.sprintf "%s(0, %s)" (checked u "sub" s) (go a)
      | _ -> "(-" ^ go a ^ ")")
  | Unary (Not, a) -> "(!" ^ go a ^ ")"
  | Unary (Bit_not, a) -> Printf.sprintf "((%s)~%s)" (ctype u a.ty) (go a)
  | Binary (op, a, b) -> binary u scope e op a b
  | Compare (Ne, a, b) when (match a.ty with Sc s -> is_float s | _ -> false) ->
      (* Rake's != is ordered: false where either operand is NaN, as for racks. *)
      let t = ctype u a.ty in
      let name = "rake_ne_" ^ tag a.ty in
      helper u name (Printf.sprintf "static inline bool %s(%s a, %s b) { return a < b || a > b; }\n" name t t);
      Printf.sprintf "%s(%s, %s)" name (go a) (go b)
  | Compare (op, a, b) ->
      let o = match op with Eq -> "==" | Ne -> "!=" | Lt -> "<" | Le -> "<=" | Gt -> ">" | Ge -> ">=" in
      Printf.sprintf "(%s %s %s)" (go a) o (go b)
  | Logic (conj, a, b) -> Printf.sprintf "(%s %s %s)" (go a) (if conj then "&&" else "||") (go b)
  | Math (name, [ a ]) -> (
      let s = match a.ty with Sc s -> s | _ -> Types.SFloat in
      let f = if s = SDouble then "" else "f" in
      match name with
      | "sqrt" -> Printf.sprintf "__builtin_sqrt%s(%s)" f (go a)
      | "floor" -> Printf.sprintf "__builtin_floor%s(%s)" f (go a)
      | "ceil" -> Printf.sprintf "__builtin_ceil%s(%s)" f (go a)
      | "abs" when is_float s -> Printf.sprintf "__builtin_fabs%s(%s)" f (go a)
      | "abs" ->
          let neg = checked u "sub" s in
          helper u ("rake_abs_" ^ scalar_tag s)
            (Printf.sprintf "static inline %s rake_abs_%s(%s a) { return a < 0 ? %s(0, a) : a; }\n" (scalar_c s) (scalar_tag s) (scalar_c s) neg);
          Printf.sprintf "rake_abs_%s(%s)" (scalar_tag s) (go a)
      | "exp" | "log" | "log2" | "tanh" ->
          if s <> SFloat then fail e.loc "%s is defined on f32" name;
          math_helpers u;
          Printf.sprintf "rake_%s_f32(%s)" name (go a)
      | _ -> fail e.loc "no C for %s" name)
  | Math (name, _) -> fail e.loc "no C for %s" name
  | Count_bits (kind, a) ->
      let s = match a.ty with Sc s -> s | _ -> SInt in
      let w = bits s in
      let wide = if w = 64 then "ll" else "" in
      let x = Printf.sprintf "(%s)%s" (if w = 64 then "uint64_t" else "uint32_t") (go a) in
      let r =
        match kind with
        | Clz -> Printf.sprintf "(%s == 0 ? %d : __builtin_clz%s(%s) - %d)" x w wide x (if w = 64 then 0 else 32 - w)
        | Ctz -> Printf.sprintf "(%s == 0 ? %d : __builtin_ctz%s(%s))" x w wide x
        | Popcnt -> Printf.sprintf "__builtin_popcount%s(%s)" wide x
      in
      Printf.sprintf "((%s)%s)" (scalar_c s) r
  | Call (name, args) ->
      let f = List.find (fun f -> f.fname = name) u.program.slows in
      if f.fblock then u.slow_calls <- slow_symbol u name :: u.slow_calls;
      let params = f.fparams in
      let args =
        List.concat (List.mapi
          (fun i a ->
            match (List.nth_opt params i) with
            | Some { pty = View _; _ } when f.fblock ->
                [ Printf.sprintf "(%s).data" (go a); Printf.sprintf "(%s).count" (go a) ]
            | Some { pass = Borrow | Borrow_mut; _ } -> [ "&" ^ addressable u scope a ]
            | _ -> [ go a ])
          args)
      in
      Printf.sprintf "%s(%s)" (slow_symbol u name) (String.concat ", " args)
  | Extern_call (name, args) ->
      let args =
        List.map
          (fun (a : expr) ->
            match a.ty with
            | Ptr (_, access) -> (if access = Read_only then "(const void *)(" else "(void *)(") ^ go a ^ ")"
            | Str -> "(const void *)" ^ go a
            | _ -> go a)
          args
      in
      Printf.sprintf "%s(%s)" name (String.concat ", " args)
  | Function_ref name ->
      if List.exists (fun f -> f.fname = name) u.program.slows then "(&" ^ slow_symbol u name ^ ")"
      else "(&" ^ name ^ ")"
  | Pointer_cast value -> Printf.sprintf "((%s)(%s))" (ctype u e.ty) (go value)
  | Indirect_call (callee, args) ->
      let result, params = match callee.ty with Function_pointer (params, result) -> result, params | _ -> assert false in
      let name = "rake_invoke_" ^ tag callee.ty in
      let callback_type = ctype u callee.ty and result_type = ctype u result in
      complete u result;
      List.iter (complete u) params;
      let declarations = List.mapi (fun i ty -> Printf.sprintf "%s a%d" (ctype u ty) i) params in
      let arguments = List.mapi (fun i _ -> Printf.sprintf "a%d" i) params in
      helper u name (Printf.sprintf
        "static inline %s %s(%s callback%s)\n{\n    if (!callback) __builtin_trap();\n    %scallback(%s);\n}\n"
        result_type name callback_type (if declarations = [] then "" else ", " ^ String.concat ", " declarations)
        (if result = Void then "" else "return ") (String.concat ", " arguments));
      Printf.sprintf "%s(%s)" name (String.concat ", " (go callee :: List.map go args))
  | Vector_call (name, args) ->
      (* A scratch with uniform parameters, reached through its boundary. *)
      let args = List.map (function Arg_uniform a -> go a | Arg_memory a -> go a) args in
      Printf.sprintf "rake_boundary_%s(%s)" name (String.concat ", " args)
  | Field (base, field) -> (
      match base.ty with
      | Ptr _ -> Printf.sprintf "(%s)->%s" (go base) field
      | _ -> Printf.sprintf "(%s).%s" (go base) field)
  | Elem (base, index, checked) -> element u scope e base index checked
  | Convert (kind, target, value) -> convert u scope e kind target value
  | Cond (c, a, b) -> Printf.sprintf "(%s ? %s : %s)" (go c) (go a) (go b)
  | Record_lit (name, fields) ->
      complete u e.ty;
      let record = List.find (fun r -> r.rname = name) u.program.records in
      if record.rlayout <> Rake_struct && List.exists (fun (_, v) -> match v.ty with Array _ -> true | _ -> false) fields then (
        (* Header-backed arrays use C's raw storage, not Rake's array wrapper.
           Evaluate each initializer once, then copy its array bytes. *)
        let destination = "rake_aggregate_value" in
        let assignments = List.map (fun (field, value) ->
          match value.ty with
          | Array _ ->
              if raw_array u value then
                Printf.sprintf "    __builtin_memcpy(%s.%s, %s, sizeof(%s.%s));\n" destination field (go value) destination field
              else
                let source = "rake_field_value_" ^ field in
                Printf.sprintf "    const %s %s = %s;\n    __builtin_memcpy(%s.%s, %s.e, sizeof(%s.%s));\n"
                  (ctype u value.ty) source (go value) destination field source destination field
          | _ -> Printf.sprintf "    %s.%s = %s;\n" destination field (go value)) fields in
        Printf.sprintf "({ %s %s = {0};\n%s    %s; })" (record_c u name) destination (String.concat "" assignments) destination
      ) else
        Printf.sprintf "((%s){ %s })" (record_c u name)
          (String.concat ", " (List.map (fun (f, v) -> Printf.sprintf ".%s = %s" f (go v)) fields))
  | Array_lit items when List.for_all (is_zero u) items -> Printf.sprintf "((%s){0})" (ctype u e.ty)
  | Array_lit items ->
      Printf.sprintf "((%s){ { %s } })" (ctype u e.ty) (String.concat ", " (List.map go items))
  | Stack_lit _ -> fail e.loc "a pack is built at the run call it is passed to"
  | Addr place -> "(&" ^ addressable u scope place ^ ")"
  | Length a -> (
      match a.ty with
      | Array (n, _) -> string_of_int n
      | _ -> Printf.sprintf "(%s).count" (go a))
  | Slice (base, start, count) ->
      let element, writable = match e.ty with View (t, writable) -> t, writable | _ -> assert false in
      let view = ctype u e.ty in
      let pointer = ctype u (Ptr (element, if writable then Read_write else Read_only)) in
      let data, n =
        match base.ty with
        | Array (n, _) when raw_array u base -> (Printf.sprintf "(%s)" (go base), string_of_int n)
        | Array (n, _) -> (Printf.sprintf "(%s).e" (addressable u scope base), string_of_int n)
        | _ -> let v = go base in (Printf.sprintf "(%s).data" v, Printf.sprintf "(%s).count" v)
      in
      let name = "rake_slice_" ^ tag e.ty in
      helper u name
        (Printf.sprintf
           "static inline %s %s(%s data, int32_t n, int32_t start, int32_t count)\n{\n    if (start < 0 || count < 0 || start > n - count) __builtin_trap();\n    return (%s){ data + start, count };\n}\n"
           view name pointer view);
      Printf.sprintf "%s((%s)%s, %s, %s, %s)" name pointer data n (go start) (go count)
  | Ptr_view (p, count) -> Printf.sprintf "((%s){ %s, %s })" (ctype u e.ty) (go p) (go count)
  | Read_only_view value ->
      let name = "rake_read_only_" ^ tag value.ty in
      let target = ctype u e.ty and source = ctype u value.ty in
      helper u name (Printf.sprintf
        "static inline %s %s(%s value) { return (%s){ value.data, value.count }; }\n"
        target name source target);
      Printf.sprintf "%s(%s)" name (go value)
  | Is_null p -> Printf.sprintf "(%s == 0)" (go p)
  | Block (body, value) ->
      let inner = { scope with places = Hashtbl.copy scope.places } in
      let body = block u inner 4 body in
      let tail = match value with Some value -> expr u inner value ^ ";\n" | None -> "(void)0;\n" in
      Printf.sprintf "({\n%s%s})" body tail

(** Whether an array place is a C array inside a C struct (an extern record's field). *)
and raw_array u (e : expr) =
  match e.k with
  | Field (base, _) -> (
      match base.ty with
      | Record name | Ptr (Record name, _) -> (
          match List.find_opt (fun r -> r.rname = name) u.program.records with Some { rlayout = (C_struct _ | C_union _); _ } -> true | _ -> false)
      | _ -> false)
  | _ -> false

(** An lvalue for a place, for & and assignment. *)
and addressable u scope (e : expr) =
  match e.k with
  | Var _ | Global _ | Field _ | Elem _ -> expr u scope e
  | _ ->
      (* A borrowed rvalue: a compound literal is an lvalue in C. *)
      Printf.sprintf "((%s[1]){ %s })[0]" (ctype u e.ty) (expr u scope e)

and global_ref u name ty =
  match List.assoc_opt name u.program.embeds with
  | Some contents ->
      Printf.sprintf "((%s){ (uint8_t *)rake_embed_%s, %d })" (ctype u ty) name (String.length contents)
  | None ->
      if List.exists (fun (n, _, _) -> n = name) u.program.consts then "rake_const_" ^ name else "rake_state_" ^ name

and element u scope (e : expr) base index checked =
  match Node_table.find_opt scope.accesses (Obj.repr e) with
  | Some address -> Printf.sprintf "(*(%s *)(%s))" (ctype u e.ty) address
  | None -> (
      let i = expr u scope index in
      match base.ty with
      | Array (n, _) ->
          let idx = if checked then Printf.sprintf "%s(%s, %d)" (index_helper u) i n else i in
          if raw_array u base then Printf.sprintf "(%s)[%s]" (expr u scope base) idx
          else Printf.sprintf "(%s).e[%s]" (expr u scope base) idx
      | View (_, writable) ->
          let v = expr u scope base in
          if checked then (
            ignore (index_helper u);
            let name = "rake_at_" ^ tag base.ty in
            let pointer = ctype u (Ptr (e.ty, if writable then Read_write else Read_only)) in
            helper u name
              (Printf.sprintf "static inline %s %s(%s view, int64_t i)\n{\n    return view.data + rake_index(i, view.count);\n}\n"
                 pointer name (ctype u base.ty));
            Printf.sprintf "(*%s(%s, %s))" name v i)
          else Printf.sprintf "(%s).data[%s]" v i
      | Ptr _ -> Printf.sprintf "(%s)[%s]" (expr u scope base) i
      | _ -> fail e.loc "can't index %s" (string_of_ty base.ty))

and binary u scope (e : expr) op a b =
  let go = expr u scope in
  let s = match e.ty with Sc s -> s | _ -> SInt in
  let t = scalar_c s and ut = unsigned_of s in
  let width = bits s in
  match op with
  | Add | Sub | Mul | Div | Rem when is_integer s ->
      let name = match op with Add -> "add" | Sub -> "sub" | Mul -> "mul" | Div -> "div" | _ -> "rem" in
      Printf.sprintf "%s(%s, %s)" (checked u name s) (go a) (go b)
  | Add | Sub | Mul | Div ->
      let name, operator = match op with Add -> ("add", "+") | Sub -> ("sub", "-") | Mul -> ("mul", "*") | _ -> ("div", "/") in
      (* Recorded for run verification: clang may compute it in a vector lane. *)
      u.selected <- Printf.sprintf "%s.%s" (if s = SDouble then "f64" else "f32") name :: u.selected;
      Printf.sprintf "(%s %s %s)" (go a) operator (go b)
  | Rem -> fail e.loc "floats have no remainder"
  | Wrap_add -> Printf.sprintf "((%s)(%s)((%s)%s + (%s)%s))" t ut ut (go a) ut (go b)
  | Wrap_sub -> Printf.sprintf "((%s)(%s)((%s)%s - (%s)%s))" t ut ut (go a) ut (go b)
  | Wrap_mul ->
      (* Small types promote to int; multiply in a wide unsigned type. *)
      let wide = if width = 64 then "uint64_t" else "uint32_t" in
      Printf.sprintf "((%s)(%s)((%s)%s * (%s)%s))" t ut wide (go a) wide (go b)
  | Bit_and -> Printf.sprintf "((%s)(%s & %s))" t (go a) (go b)
  | Bit_or -> Printf.sprintf "((%s)(%s | %s))" t (go a) (go b)
  | Bit_xor -> Printf.sprintf "((%s)(%s ^ %s))" t (go a) (go b)
  | Bit_andnot -> Printf.sprintf "((%s)(%s & ~%s))" t (go a) (go b)
  | Shl -> Printf.sprintf "((%s)((%s)%s << ((uint32_t)%s & %du)))" t ut (go a) (go b) (width - 1)
  | Shr -> Printf.sprintf "((%s)((%s)%s >> ((uint32_t)%s & %du)))" t ut (go a) (go b) (width - 1)
  | Shr_signed -> Printf.sprintf "((%s)((%s)%s >> ((uint32_t)%s & %du)))" t (signed_of s) (go a) (go b) (width - 1)
  | Rotl | Rotr ->
      let name = Printf.sprintf "rake_%s_%s" (if op = Rotl then "rotl" else "rotr") (scalar_tag s) in
      let left, right = if op = Rotl then ("<<", ">>") else (">>", "<<") in
      helper u name
        (Printf.sprintf "static inline %s %s(%s a, uint32_t c)\n{\n    const %s x = (%s)a;\n    c &= %du;\n    return (%s)(c == 0 ? x : (%s)((x %s c) | (x %s (%du - c))));\n}\n"
           t name t ut ut (width - 1) t ut left right width);
      Printf.sprintf "%s(%s, (uint32_t)%s)" name (go a) (go b)
  | Min | Max when is_float s -> Printf.sprintf "%s(%s, %s)" (float_extreme u (if op = Min then "min" else "max") s) (go a) (go b)
  | Min | Max ->
      let name = Printf.sprintf "rake_%s_%s" (if op = Min then "min" else "max") (scalar_tag s) in
      helper u name
        (Printf.sprintf "static inline %s %s(%s a, %s b) { return a %s b ? a : b; }\n" t name t t (if op = Min then "<" else ">"));
      Printf.sprintf "%s(%s, %s)" name (go a) (go b)

and convert u scope (e : expr) kind target value =
  let source = match value.ty with Sc s -> s | _ -> fail e.loc "conversion of a non-scalar" in
  let v = expr u scope value in
  let t = scalar_c target in
  match kind with
  | Ast.Convert_bitcast ->
      let name = bitcast_helper u target source in
      Printf.sprintf "%s(%s)" name v
  | Convert_wrap -> Printf.sprintf "((%s)(%s)%s)" t (unsigned_of target) v
  | Convert_checked when source = target -> v
  | Convert_checked when is_float target -> Printf.sprintf "((%s)%s)" t v
  | Convert_checked when source = SBool || target = SBool -> Printf.sprintf "((%s)%s)" t v
  | Convert_checked when is_float source ->
      let name = Printf.sprintf "rake_%s_from_%s" (scalar_tag target) (scalar_tag source) in
      let low, high =
        (* The open interval of floats that truncate into the target. *)
        match target with
        | SInt8 -> ("-129.0", "128.0") | SUint8 -> ("-1.0", "256.0")
        | SInt16 -> ("-32769.0", "32768.0") | SUint16 -> ("-1.0", "65536.0")
        | SInt -> ("-2147483904.0", "2147483648.0") | SUint -> ("-1.0", "4294967296.0")
        | SInt64 -> ("-9223373136366403584.0", "9223372036854775808.0") | SUint64 -> ("-1.0", "18446744073709551616.0")
        | _ -> ("0", "0")
      in
      let st = scalar_c source in
      helper u name
        (Printf.sprintf "static inline %s %s(%s x)\n{\n    if (!(x > (%s)%s && x < (%s)%s)) __builtin_trap();\n    return (%s)x;\n}\n"
           t name st st low st high t);
      Printf.sprintf "%s(%s)" name v
  | Convert_checked ->
      let name = Printf.sprintf "rake_%s_from_%s" (scalar_tag target) (scalar_tag source) in
      let check =
        if is_signed source = is_signed target && bits target >= bits source then "0"
        else if (not (is_signed source)) && bits target > bits source then "0"
        else
          (* Compare in 128-bit range terms: both as int64 or uint64 as appropriate. *)
          let lo = if is_signed target then Printf.sprintf "-(__int128)((__int128)1 << %d)" (bits target - 1) else "0" in
          let hi =
            if is_signed target then Printf.sprintf "((__int128)1 << %d) - 1" (bits target - 1)
            else Printf.sprintf "((__int128)1 << %d) - 1" (bits target)
          in
          Printf.sprintf "(__int128)x < %s || (__int128)x > (%s)" lo hi
      in
      helper u name
        (Printf.sprintf "static inline %s %s(%s x)\n{\n    if (%s) __builtin_trap();\n    return (%s)x;\n}\n"
           t name (scalar_c source) check t);
      Printf.sprintf "%s(%s)" name v

(* ─── Slow statements ───────────────────────────────────────────────── *)
and stmt u scope indent (s : stmt) =
  let pad = String.make indent ' ' in
  let go = expr u scope in
  match s.s with
  | Decl (name, ty, value, _) when Node_table.mem scope.frame_slots (Obj.repr s) ->
      (* Declare the pointer in its lexical scope. Sibling blocks may reuse a
         source name, but their declarations have distinct frame slots. *)
      let field = Node_table.find scope.frame_slots (Obj.repr s) in
      let initial = Option.map go value in
      Hashtbl.replace scope.places name Borrowed;
      let setup = Printf.sprintf "%s%s *const %s = &rake_locals->%s;\n" pad (ctype u ty) (local name) field in
      let initialise = match value, initial with
        | Some v, Some text when not (is_zero u v) -> Printf.sprintf "%s*%s = %s;\n" pad (local name) text
        | _ -> Printf.sprintf "%s__builtin_memset(%s, 0, sizeof *%s);\n" pad (local name) (local name)
      in
      setup ^ initialise
  | Decl (name, (Ptr _ as ty), Some v, mutable_) ->
      (* An immutable pointer binding is a const pointer, not a pointer to const. *)
      Printf.sprintf "%s%s%s %s = %s;\n" pad (ctype u ty) (if mutable_ then "" else "const") (local name) (go v)
  | Decl (name, ty, Some v, mutable_) ->
      Printf.sprintf "%s%s%s %s = %s;\n" pad (if mutable_ || is_aggregate ty then "" else "const ") (ctype u ty) (local name) (go v)
  | Decl (name, ty, None, _) -> Printf.sprintf "%s%s %s = {0};\n" pad (ctype u ty) (local name)
  | Assign (place, v) -> (
      match place.ty with
      | Array _ when raw_array u place ->
          Printf.sprintf "%s{ const %s rake_tmp = %s; __builtin_memcpy(%s, rake_tmp.e, sizeof rake_tmp.e); }\n" pad (ctype u place.ty) (go v) (go place)
      | _ -> Printf.sprintf "%s%s = %s;\n" pad (addressable u scope place) (go v))
  | Eval { k = Vector_call (name, args); loc; _ } -> run_call u scope pad loc name args
  | Eval e -> Printf.sprintf "%s(void)%s;\n" pad (go e)
  | If (c, a, b) ->
      let else_part = if b = [] then "" else Printf.sprintf " else {\n%s%s}" (block u scope (indent + 4) b) pad in
      Printf.sprintf "%sif %s {\n%s%s}%s\n" pad (condition (go c)) (block u scope (indent + 4) a) pad else_part
  | While (c, body) ->
      Printf.sprintf "%s#pragma clang loop vectorize(disable)\n%swhile %s {\n%s%s}\n" pad pad (condition (go c)) (block u scope (indent + 4) body) pad
  | For (name, s, from, upto, by, body) ->
      let t = scalar_c s and i = local name in
      let step, next =
        match by with
        | None -> ("", Printf.sprintf "%s = (%s)(%s + 1)" i t i)
        | Some step ->
            let helper_name = "rake_next_" ^ scalar_tag s in
            helper u helper_name
              (Printf.sprintf "static inline %s %s(%s i, %s step, %s end)\n{\n    if (step <= 0) __builtin_trap();\n    return end - i <= step ? end : (%s)(i + step);\n}\n"
                 t helper_name t t t t);
            (Printf.sprintf " const %s %s_step = %s;" t i (go step), Printf.sprintf "%s = %s(%s, %s_step, %s_end)" i helper_name i i i)
      in
      Printf.sprintf "%s{\n%s    const %s %s_end = %s;%s\n%s    #pragma clang loop vectorize(disable)\n%s    for (%s %s = %s; %s < %s_end; %s) {\n%s%s    }\n%s}\n"
        pad pad t i (go upto) step pad pad t i (go from) i i next (block u scope (indent + 8) body) pad pad
  | Break -> pad ^ "break;\n"
  | Continue -> pad ^ "continue;\n"
  | Return None when scope.framed -> pad ^ "if (rake_arena_frame) rake_frame_leave(rake_frame_mark);\n" ^ pad ^ "return;\n"
  | Return None -> pad ^ "return;\n"
  | Return (Some v) when scope.framed ->
      (* The value may read the frame: take it before leaving. *)
      Printf.sprintf "%s{\n%s    const %s rake_result = %s;\n%s    if (rake_arena_frame) rake_frame_leave(rake_frame_mark);\n%s    return rake_result;\n%s}\n"
        pad pad (ctype u v.ty) (go v) pad pad pad
  | Return (Some v) -> Printf.sprintf "%sreturn %s;\n" pad (go v)

and block u scope indent stmts = String.concat "" (List.map (stmt u scope indent) stmts)

(** A slow call into a run: views become a pointer and a count, packs a
    descriptor, and each column and the output must hold the traversed count. *)
and run_call u scope pad loc name args =
  let run = match List.find_opt (fun r -> r.run_name = name) u.program.runs with Some r -> r | None -> fail loc "unknown run %s" name in
  let go = expr u scope in
  let temps = Buffer.create 128 and passed = ref [] and checks = ref [] in
  let fresh = let n = ref 0 in fun () -> incr n; Printf.sprintf "rake_arg%d" !n in
  let params = run.run_params in
  let counts =
    (* Stack parameters and the uniform parameter their traversal counts. *)
    let rec outputs stmts =
      List.concat_map (fun s -> match s.r with R_output (o, _, _) -> [ o ] | R_for (_, _, _, _, b) | R_block b -> outputs b | R_if (_, a, b) -> outputs a @ outputs b | _ -> []) stmts
    in
    let rec traversals stmts =
      List.concat_map
        (fun s ->
          match s.r with
          | R_traverse t -> (
              (* The traversed pack, and every pack it stores columns of, hold the count. *)
              match t.t_count.k with
              | Var count -> ((t.t_stack, count) :: List.map (fun o -> (o, count)) (outputs t.t_body)) @ traversals t.t_body
              | _ -> traversals t.t_body)
          | R_for (_, _, _, _, b) | R_block b -> traversals b
          | R_if (_, a, b) -> traversals a @ traversals b
          | _ -> [])
        stmts
    in
    traversals run.run_body
  in
  let uniform_value = Hashtbl.create 4 in
  List.iteri
    (fun index arg ->
      match (List.nth_opt params index, arg) with
      | Some (Run_uniform (pname, s)), Arg_uniform v ->
          let t = fresh () in
          Buffer.add_string temps (Printf.sprintf "%s    const %s %s = %s;\n" pad (scalar_c s) t (go v));
          Hashtbl.replace uniform_value pname t;
          passed := t :: !passed
      | Some (Run_view (_, _, _)), Arg_memory v ->
          let t = fresh () in
          Buffer.add_string temps (Printf.sprintf "%s    const %s %s = %s;\n" pad (ctype u v.ty) t (go v));
          passed := Printf.sprintf "%s.count" t :: Printf.sprintf "%s.data" t :: !passed
      | Some (Run_stack (pname, stack, w)), Arg_memory { k = Stack_lit (_, columns); _ } ->
          let t = fresh () in
          let s = find_pack u.program stack in
          let column_temps =
            List.map
              (fun (field, _) ->
                let v = List.assoc field columns in
                let c = fresh () in
                Buffer.add_string temps (Printf.sprintf "%s    const %s %s = %s;\n" pad (ctype u v.ty) c (go v));
                (field, c))
              s.pack_fields
          in
          Buffer.add_string temps
            (Printf.sprintf "%s    const %s %s = { %s };\n" pad (stack_type u stack w) t
               (String.concat ", " (List.map (fun (_, c) -> c ^ ".data") column_temps)));
          List.iter
            (fun (pack, count) -> if pack = pname then checks := (count, List.map snd column_temps) :: !checks)
            counts;
          passed := ("&" ^ t) :: !passed
      | None, Arg_memory v when run.run_stream <> None ->
          (* The stream's output view. *)
          let t = fresh () in
          Buffer.add_string temps (Printf.sprintf "%s    const %s %s = %s;\n" pad (ctype u v.ty) t (go v));
          List.iter (fun (_, count) -> checks := (count, [ t ]) :: !checks) counts;
          passed := (t ^ ".data") :: !passed
      | _ -> fail loc "argument %d of %s doesn't match its parameter" (index + 1) name)
    args;
  let checks =
    List.concat_map
      (fun (count, views) ->
        match Hashtbl.find_opt uniform_value count with
        | Some value -> List.map (fun v -> Printf.sprintf "%s    if ((int64_t)%s > (int64_t)%s.count) __builtin_trap();\n" pad value v) views
        | None -> [])
      !checks
  in
  Printf.sprintf "%s{\n%s%s%s    %s(%s);\n%s}\n" pad (Buffer.contents temps) (String.concat "" checks) pad name
    (String.concat ", " (List.rev !passed)) pad

(* ─── Runs ──────────────────────────────────────────────────────────── *)

let rec initializer_ ?(raw_array_field = false) u (e : expr) =
  match e.k with
  | Record_lit (name, fields) ->
      let record = List.find (fun r -> r.rname = name) u.program.records in
      "{ " ^ String.concat ", " (List.map (fun (f, v) ->
        Printf.sprintf ".%s = %s" f (initializer_ ~raw_array_field:(record.rlayout <> Rake_struct) u v)) fields) ^ " }"
  | Array_lit items when List.for_all (is_zero u) items -> "{0}"
  | Array_lit items ->
      let values = String.concat ", " (List.map (initializer_ ~raw_array_field u) items) in
      if raw_array_field then "{ " ^ values ^ " }" else "{ { " ^ values ^ " } }"
  | _ -> expr u (new_scope ()) e

let ir_element = function
  | Types.SFloat -> Native_ir.F32
  | SInt -> Native_ir.I32
  | SUint -> Native_ir.U32
  | SInt16 | SUint16 -> Native_ir.I16
  | SInt8 | SUint8 -> Native_ir.U8
  | SInt64 | SUint64 -> Native_ir.I64
  | SDouble -> Native_ir.F64
  | SBool -> Native_ir.I1

let ir_type = function
  | Rack s -> Native_ir.Rack (ir_element s)
  | Mask _ -> Native_ir.Mask
  | Sc s -> Native_ir.Scalar (ir_element s)
  | ty -> invalid_arg ("ir_type " ^ string_of_ty ty)

(** Free names of a pure rack expression, in first-use order. *)
let free_names (e : Ast.expr) =
  let seen = Hashtbl.create 8 and order = ref [] in
  let add name = if not (Hashtbl.mem seen name) then (Hashtbl.replace seen name (); order := name :: !order) in
  let rec walk (e : Ast.expr) =
    match e.v with
    | EVar name | EScalarVar name -> add name
    | EBroadcast inner -> walk inner
    | EBinop (a, _, b) -> walk a; walk b
    | EUnop (_, a) | EConvert (_, _, a) | EReduce (_, a) | EScan (_, a) | EShift (a, _, _) | ERotate (a, _, _) -> walk a
    | ECall (_, args) | EArray args -> List.iter walk args
    | EIf (a, b, c) | EFma (a, b, c) | EInsert (a, b, c) -> walk a; walk b; walk c
    | EExtract (a, b) -> walk a; walk b
    | EShuffle (a, _) -> walk a
    | ETuple items -> List.iter walk items
    | _ -> ()
  in
  walk e;
  List.rev !order

let rec rename (map : string -> string) (e : Ast.expr) : Ast.expr =
  let r = rename map in
  let v =
    match e.v with
    | EVar name -> Ast.EVar (map name)
    | EScalarVar name -> EScalarVar (map name)
    | EBroadcast inner -> EBroadcast (r inner)
    | EBinop (a, op, b) -> EBinop (r a, op, r b)
    | EUnop (op, a) -> EUnop (op, r a)
    | EConvert (k, t, a) -> EConvert (k, t, r a)
    | EReduce (op, a) -> EReduce (op, r a)
    | EScan (op, a) -> EScan (op, r a)
    | ECall (name, args) -> ECall (name, List.map r args)
    | EIf (a, b, c) -> EIf (r a, r b, r c)
    | EFma (a, b, c) -> EFma (r a, r b, r c)
    | EInsert (a, b, c) -> EInsert (r a, r b, r c)
    | EExtract (a, b) -> EExtract (r a, r b)
    | EShuffle (a, idx) -> EShuffle (r a, idx)
    | ETuple items -> ETuple (List.map r items)
    | other -> other
  in
  { e with v }

type run_state = {
  run : run;
  types : (string, ty) Hashtbl.t;
  counter : int ref;
  tail : bool;  (** emitting a traversal's tail: rack values are under its mask *)
  assigned_in_traversal : (string, unit) Hashtbl.t;
}

(** A pure rack expression as an always-inline function of its free names,
    lowered by the scratch pipeline; returns the call. *)
let pure_call u rs loc name ty (pure : Ast.expr) fused =
  let free = free_names pure in
  let cname n = local n in
  let parameters =
    List.map
      (fun n ->
        match Hashtbl.find_opt rs.types n with
        | Some t -> (cname n, ir_type t)
        | None -> fail loc "internal: %s has no type in run %s" n rs.run.run_name)
      free
  in
  let mask_name = "rake_tail" in
  let parameters, mask = if rs.tail then (parameters @ [ (mask_name, Native_ir.Mask) ], Some mask_name) else (parameters, None) in
  incr rs.counter;
  let fname = Printf.sprintf "rake__%s__%d" rs.run.run_name !(rs.counter) in
  let renamed = rename cname pure in
  match
    Native_lower.lower_expression ~definitions:u.program.vector_defs ~name:fname ~parameters ?mask ~fused loc renamed
  with
  | Error error -> fail loc "%s" (Native_lower.format_error error)
  | Ok func -> (
      (match (ty, func.Native_ir.result) with
       | (Rack _ | Mask _ | Sc _), Some result when result <> ir_type ty ->
           fail loc "%s is %s here but the expression lowers to %s" name (string_of_ty ty) (Native_ir.string_of_typ result)
       | _ -> ());
      let mask_parameter _ index =
        match List.nth_opt parameters index with
        | Some (_, Native_ir.Mask) -> (
            if index = List.length parameters - 1 && rs.tail then Some Native_ir.I32
            else
              match Hashtbl.find_opt rs.types (List.nth free index) with
              | Some (Mask s) -> Some (ir_element s)
              | _ -> None)
        | _ -> None
      in
      match Wasm_simd128_isel.select ~mask_parameter [ func ] with
      | Error error -> fail loc "%s" (Wasm_simd128_isel.format_error error)
      | Ok [ selected ] ->
          List.iter
            (function
              | Wasm_simd128_isel.Operation text ->
                  let mnemonic = match String.index_opt text ' ' with Some i -> String.sub text 0 i | None -> text in
                  if String.ends_with ~suffix:"_lane" mnemonic || String.ends_with ~suffix:"_lane_s" mnemonic
                     || String.ends_with ~suffix:"_lane_u" mnemonic
                  then u.lane_operations <- u.lane_operations + 1;
                  u.selected <- mnemonic :: u.selected
              | _ -> ())
            selected.instructions;
          let text = Wasm_simd128_c.emit_function selected in
          let text =
            (* Always inline: a run calls nothing. *)
            "static inline __attribute__((always_inline)) "
            ^ String.sub text (String.length "RAKE_WASM_LINKAGE ") (String.length text - String.length "RAKE_WASM_LINKAGE ")
          in
          Buffer.add_string u.expressions text;
          Buffer.add_char u.expressions '\n';
          let args = List.map cname free @ (if rs.tail then [ "rake_tail" ] else []) in
          Printf.sprintf "%s(%s)" fname (String.concat ", " args)
      | Ok _ -> fail loc "internal: one function expected")

(* Address planning: the accesses of a loop body that are affine in its index. *)

(** An element index as a constant plus terms, each a uniform expression with a coefficient. *)
type linear = { constant : int64; terms : (expr * int64) list }

let rec same_expr (a : expr) (b : expr) =
  match (a.k, b.k) with
  | Int x, Int y -> x = y
  | Var x, Var y -> x = y
  | Binary (o, a1, a2), Binary (p, b1, b2) -> o = p && same_expr a1 b1 && same_expr a2 b2
  | Convert (k, s, x), Convert (l, t, y) -> k = l && s = t && same_expr x y
  | _ -> false

let rec mentions name (e : expr) =
  match e.k with
  | Var n -> n = name
  | Int _ | Float _ | Bool _ | Str_lit _ | Global _ | Function_ref _ -> false
  | Unary (_, a) | Convert (_, _, a) | Pointer_cast a | Read_only_view a | Math (_, [ a ]) | Count_bits (_, a) | Field (a, _) | Length a | Addr a | Is_null a -> mentions name a
  | Binary (_, a, b) | Compare (_, a, b) | Logic (_, a, b) | Elem (a, b, _) -> mentions name a || mentions name b
  | Cond (a, b, c) | Slice (a, b, c) -> mentions name a || mentions name b || mentions name c
  | _ -> true

let add_linear a b =
  let terms =
    List.fold_left
      (fun acc (t, c) ->
        match List.partition (fun (u, _) -> same_expr u t) acc with
        | [ (u, d) ], rest -> (u, Int64.add c d) :: rest
        | _ -> (t, c) :: acc)
      a.terms b.terms
  in
  { constant = Int64.add a.constant b.constant; terms = List.filter (fun (_, c) -> c <> 0L) terms }

let scale k l = { constant = Int64.mul k l.constant; terms = List.map (fun (t, c) -> (t, Int64.mul k c)) l.terms }

let rec linear (defs : (string * expr) list) (e : expr) =
  match e.k with
  | Int n -> { constant = n; terms = [] }
  | Var name when List.mem_assoc name defs -> linear defs (List.assoc name defs)
  | Binary (Add, a, b) -> add_linear (linear defs a) (linear defs b)
  | Binary (Sub, a, b) -> add_linear (linear defs a) (scale (-1L) (linear defs b))
  | Unary (Neg, a) -> scale (-1L) (linear defs a)
  | Binary (((Div | Rem) as op), a, b) -> (
      (* A quotient or remainder of constants, such as an unrolled index's row and column. *)
      match (linear defs a, linear defs b) with
      | { terms = []; constant = x }, { terms = []; constant = y } when y <> 0L && y <> -1L ->
          { constant = (if op = Div then Int64.div x y else Int64.rem x y); terms = [] }
      | _ -> { constant = 0L; terms = [ (e, 1L) ] })
  | Binary (Mul, a, b) -> (
      match (linear defs a, linear defs b) with
      | { terms = []; constant }, l | l, { terms = []; constant } -> scale constant l
      | { constant = 0L; terms = [ (u, 1L) ] }, l | l, { constant = 0L; terms = [ (u, 1L) ] } ->
          (* A product by one opaque term distributes: (p + 1) * g = p * g + g. *)
          let product t = { k = Binary (Mul, t, u); ty = e.ty; loc = e.loc } in
          List.fold_left (fun acc (t, c) -> add_linear acc { constant = 0L; terms = [ (product t, c) ] })
            { constant = 0L; terms = (if l.constant = 0L then [] else [ (u, l.constant) ]) } l.terms
      | _ -> { constant = 0L; terms = [ (e, 1L) ] })
  | _ -> { constant = 0L; terms = [ (e, 1L) ] }

(** For loop index [var]: the invariant base, the stride per unit of [var],
    and the constant, if the index is affine in [var]. *)
let affine defs var index =
  let l = linear defs index in
  let stride_parts, base_parts =
    List.partition (fun (t, _) -> mentions var t) l.terms
  in
  let stride_of (t : expr) =
    match t.k with
    | Var v when v = var -> Some None
    | Binary (Mul, a, b) when (match a.k with Var v -> v = var | _ -> false) && not (mentions var b) -> Some (Some b)
    | Binary (Mul, a, b) when (match b.k with Var v -> v = var | _ -> false) && not (mentions var a) -> Some (Some a)
    | _ -> None
  in
  let strides = List.map (fun (t, c) -> (stride_of t, c)) stride_parts in
  if List.exists (fun (s, _) -> s = None) strides then None
  else Some (base_parts, List.map (fun (s, c) -> (Option.get s, c)) strides, l.constant)

let rec run_stmts u rs scope indent (stmts : rstmt list) =
  String.concat "" (List.map (run_stmt u rs scope indent) stmts)

and view_c (view : expr) = match view.k with Var name -> local name | _ -> "/* view */"

and record_type rs name ty = Hashtbl.replace rs.types name ty

and run_stmt u rs scope indent (s : rstmt) =
  let pad = String.make indent ' ' in
  let uniform e = expr u scope e in
  match s.r with
  | R_uniform (name, e) ->
      record_type rs name e.ty;
      if Node_table.mem scope.dropped (Obj.repr s) then ""
      else Printf.sprintf "%sconst %s %s = %s;\n" pad (ctype u e.ty) (local name) (uniform e)
  | R_slow e -> Printf.sprintf "%s(void)%s;\n" pad (uniform e)
  | R_pure (name, ty, pure, fused) ->
      record_type rs name ty;
      let c = match ty with Sc st -> scalar_c st | _ -> "v128_t" in
      Printf.sprintf "%sconst %s %s = %s;\n" pad c (local name) (pure_call u rs s.rloc name ty pure fused)
  | R_load (name, element, view, index, checked) ->
      record_type rs name (Rack element);
      u.selected <- "v128.load" :: u.selected;
      Printf.sprintf "%sconst v128_t %s = wasm_v128_load(%s);\n" pad (local name) (address u rs scope view index element (lanes element) checked)
  | R_gather (name, element, view, indices, checked) ->
      record_type rs name (Rack element);
      u.lane_operations <- u.lane_operations + 8;
      u.selected <- "v128.load32_lane" :: "i32x4.extract_lane" :: "i32x4.splat" :: u.selected;
      let v = view_c view and g = local indices in
      let check =
        if checked then (
          u.selected <- "i32x4.all_true" :: "i32x4.ge_s" :: "i32x4.lt_s" :: "v128.and" :: "i32x4.splat" :: u.selected;
          Printf.sprintf "%s    if (!wasm_i32x4_all_true(wasm_v128_and(wasm_i32x4_ge(%s, wasm_i32x4_splat(0)), wasm_i32x4_lt(%s, wasm_i32x4_splat(%s.count))))) __builtin_trap();\n" pad g g v)
        else ""
      in
      let lane k = Printf.sprintf "%s = wasm_v128_load32_lane(%s.data + wasm_i32x4_extract_lane(%s, %d), %s, %d);" (local name) v g k (local name) k in
      if rs.tail then (
        (* In a traversal's tail only the active lanes are checked and read,
           chosen by the uniform remainder as the tail's loads are. *)
        let check =
          if checked then (
            u.selected <- "v128.or" :: "v128.not" :: u.selected;
            Printf.sprintf "%s    if (!wasm_i32x4_all_true(wasm_v128_or(wasm_v128_and(wasm_i32x4_ge(%s, wasm_i32x4_splat(0)), wasm_i32x4_lt(%s, wasm_i32x4_splat(%s.count))), wasm_v128_not(rake_tail)))) __builtin_trap();\n" pad g g v)
          else ""
        in
        Printf.sprintf "%sv128_t %s = wasm_i32x4_splat(0);\n%s{\n%s%s    switch (rake_r) {\n%s    case 3: %s __attribute__((fallthrough));\n%s    case 2: %s __attribute__((fallthrough));\n%s    case 1: %s break;\n%s    default: __builtin_trap();\n%s    }\n%s}\n"
          pad (local name) pad check pad pad (lane 2) pad (lane 1) pad (lane 0) pad pad pad)
      else
        let lanes = List.init 4 (fun k -> Printf.sprintf "%s    %s\n" pad (lane k)) in
        Printf.sprintf "%sv128_t %s = wasm_i32x4_splat(0);\n%s{\n%s%s%s}\n" pad (local name) pad check (String.concat "" lanes) pad
  | R_location (name, ty, first) ->
      record_type rs name ty;
      Printf.sprintf "%sv128_t %s = %s;\n" pad (local name) (local first)
  | R_set (name, value) ->
      if rs.tail && Hashtbl.mem rs.assigned_in_traversal name then (
        (* A tail updates only its active lanes. *)
        u.selected <- "v128.bitselect" :: u.selected;
        Printf.sprintf "%s%s = wasm_v128_bitselect(%s, %s, rake_tail);\n" pad (local name) (local value) (local name))
      else Printf.sprintf "%s%s = %s;\n" pad (local name) (local value)
  | R_store (view, index, value, checked) ->
      let element = match view.ty with View (Sc e, _) -> e | _ -> SInt in
      u.selected <- "v128.store" :: u.selected;
      Printf.sprintf "%swasm_v128_store(%s, %s);\n" pad (address u rs scope view index element (lanes element) checked) (local value)
  | R_for (var, from, upto, by, body) -> loop u rs scope indent var from upto by body
  | R_if (c, a, b) ->
      let else_part = if b = [] then "" else Printf.sprintf " else {\n%s%s}" (run_stmts u rs scope (indent + 4) b) pad in
      Printf.sprintf "%sif %s {\n%s%s}%s\n" pad (condition (uniform c)) (run_stmts u rs scope (indent + 4) a) pad else_part
  | R_block body -> Printf.sprintf "%s{\n%s%s}\n" pad (run_stmts u rs scope (indent + 4) body) pad
  | R_traverse t -> traverse u rs scope indent t
  | R_chunk_load _ | R_output _ | R_yield _ -> fail s.rloc "internal: traversal statement outside its traversal"

(** The byte address of a rack or element access. Planned accesses use their
    loop's pointer and a constant offset; the rest form their address here. *)
and address u rs scope view index element lane_count checked =
  ignore rs;
  match Node_table.find_opt scope.accesses (Obj.repr index) with
  | Some planned -> planned
  | None ->
      let v = view_c view in
      let i = expr u scope index in
      if checked then (
        span_helper u;
        Printf.sprintf "(uint8_t *)%s.data + (int32_t)%d * rake_span(%s, %d, %s.count)" v (bytes element) i lane_count v)
      else Printf.sprintf "(uint8_t *)%s.data + (int32_t)%d * (int32_t)(%s)" v (bytes element) i

(** Replace names in a uniform expression: the body's arithmetic definitions
    by their values, and the loop index by [replacement]. *)
and substitute defs var replacement (e : expr) =
  let go = substitute defs var replacement in
  let k =
    match e.k with
    | Var name when name = var -> Var replacement
    | Var name when List.mem_assoc name defs -> (go (List.assoc name defs)).k
    | Unary (o, a) -> Unary (o, go a)
    | Binary (o, a, b) -> Binary (o, go a, go b)
    | Compare (o, a, b) -> Compare (o, go a, go b)
    | Logic (o, a, b) -> Logic (o, go a, go b)
    | Convert (c, s, a) -> Convert (c, s, go a)
    | Cond (a, b, c) -> Cond (go a, go b, go c)
    | Math (f, args) -> Math (f, List.map go args)
    | other -> other
  in
  { e with k }

(** The integer leaves of an index expression in tree order, and whether two
    expressions are the same tree apart from those leaves. *)
and leaves (e : expr) =
  match e.k with
  | Int n -> [ n ]
  | Var _ -> []
  | Unary (_, a) | Convert (_, _, a) -> leaves a
  | Binary (_, a, b) -> leaves a @ leaves b
  | _ -> []

and same_shape (a : expr) (b : expr) =
  match (a.k, b.k) with
  | Int _, Int _ -> true
  | Var x, Var y -> x = y
  | Unary (o, x), Unary (p, y) -> o = p && same_shape x y
  | Convert (k, s, x), Convert (l, t, y) -> k = l && s = t && same_shape x y
  | Binary (o, x1, x2), Binary (p, y1, y2) -> o = p && same_shape x1 y1 && same_shape x2 y2
  | _ -> false

(** The members of an access group whose checks bound every member's: when
    members are one tree differing in a single integer leaf, every
    intermediate is affine in that leaf, so its least and greatest copies
    bound the rest; otherwise each member is checked. *)
and checked_representatives members =
  let rec partition = function
    | [] -> []
    | ((index, _, _) as m) :: rest ->
        let same, other = List.partition (fun (i, _, _) -> same_shape i index) rest in
        (m :: same) :: partition other
  in
  List.concat_map
    (fun shape ->
      match shape with
      | [] | [ _ ] -> shape
      | (first, _, _) :: _ ->
          let vectors = List.map (fun (i, _, _) -> Array.of_list (leaves i)) shape in
          let base = Array.of_list (leaves first) in
          let varying =
            List.filter
              (fun position -> List.exists (fun v -> v.(position) <> base.(position)) vectors)
              (List.init (Array.length base) Fun.id)
          in
          (match varying with
           | [] -> [ List.hd shape ]
           | [ position ] ->
               let key (i, _, _) = (Array.of_list (leaves i)).(position) in
               let low = List.fold_left (fun a m -> if key m < key a then m else a) (List.hd shape) shape in
               let high = List.fold_left (fun a m -> if key m > key a then m else a) (List.hd shape) shape in
               if low == high then [ low ] else [ low; high ]
           | _ -> shape))
    (partition members)

(** A counted loop with its accesses' pointers formed once, checked once at
    its first and last iterations, and advanced each iteration. *)
and loop u rs scope indent var from upto by body =
  let pad = String.make indent ' ' in
  u.loops <- u.loops + 1;
  let s = match from.ty with Sc s -> s | _ -> SInt in
  let t = scalar_c s and i = local var in
  let uniform e = expr u scope e in
  (* Accesses directly in this body (and its unrolled blocks); the body's
     uniform definitions that are pure arithmetic; and every name the body
     binds, which an invariant base must not mention. *)
  let accesses = ref [] and bound = ref [] in
  let rec has_memory (e : expr) =
    match e.k with
    | Elem _ | Call _ | Extern_call _ | Indirect_call _ | Vector_call _ -> true
    | Binary (_, a, b) | Compare (_, a, b) | Logic (_, a, b) -> has_memory a || has_memory b
    | Unary (_, a) | Convert (_, _, a) -> has_memory a
    | Cond (a, b, c) -> has_memory a || has_memory b || has_memory c
    | _ -> false
  in
  let rec reads defs (e : expr) =
    match e.k with
    | Elem ({ k = Var _; ty = View (Sc el, _); _ } as base, index, checked) ->
        accesses := (Obj.repr e, base, substitute defs var var index, el, 1, checked) :: !accesses
    | Binary (_, a, b) | Compare (_, a, b) | Logic (_, a, b) -> reads defs a; reads defs b
    | Unary (_, a) | Convert (_, _, a) -> reads defs a
    | Cond (a, b, c) -> reads defs a; reads defs b; reads defs c
    | _ -> ()
  in
  (* Each access is resolved with the definitions visible where it is: an
     unrolled copy's names are its own. *)
  let rec collect defs stmts =
    ignore
      (List.fold_left
         (fun defs st ->
           match st.r with
           | R_uniform (name, e) ->
               bound := name :: !bound;
               reads defs e;
               if has_memory e then defs else (name, substitute defs var var e) :: defs
           | R_pure (name, _, _, _) ->
               bound := name :: !bound;
               defs
           | R_load (_, el, ({ k = Var _; _ } as base), index, checked) ->
               accesses := (Obj.repr index, base, substitute defs var var index, el, lanes el, checked) :: !accesses;
               defs
           | R_store (({ k = Var _; ty = View (Sc el, _); _ } as base), index, _, checked) ->
               accesses := (Obj.repr index, base, substitute defs var var index, el, lanes el, checked) :: !accesses;
               defs
           | R_block b ->
               collect defs b;
               defs
           | _ -> defs)
         defs stmts)
  in
  collect [] body;
  let opaque = !bound in
  let groups = ref [] in
  let same_terms a b =
    List.length a = List.length b && List.for_all2 (fun (x, c) (y, d) -> c = d && same_expr x y) a b
  in
  let same_strides a b =
    List.length a = List.length b
    && List.for_all2
         (fun (x, c) (y, d) -> c = d && (match (x, y) with None, None -> true | Some x, Some y -> same_expr x y | _ -> false))
         a b
  in
  List.iter
    (fun (key, base, index, el, lane_count, checked) ->
      let view = view_c base in
      let inlined = index in
      if List.exists (fun n -> mentions n inlined) opaque then ()
      else
        match affine [] var inlined with
        | Some (base_terms, strides, constant) ->
            let name =
              match List.find_opt (fun (v, b, st, e, _, _) -> v = view && e = el && same_terms b base_terms && same_strides st strides) !groups with
              | Some (_, _, _, _, name, members) ->
                  members := (inlined, lane_count, checked) :: !members;
                  name
              | None ->
                  incr rs.counter;
                  let name = Printf.sprintf "rake_p%d" !(rs.counter) in
                  groups := !groups @ [ (view, base_terms, strides, el, name, ref [ (inlined, lane_count, checked) ]) ];
                  name
            in
            Node_table.replace scope.accesses key (Printf.sprintf "%s + %Ld" name (Int64.mul constant (Int64.of_int (bytes el))))
        | None -> ())
    !accesses;
  (* A uniform definition of pure arithmetic whose every use is a planned,
     checked access needs no evaluation of its own: the access's checks at
     the first and last iterations evaluate the same tree, every
     intermediate of which is affine in the loop index, so they bound its
     overflow at every iteration, and the address is the planned pointer. *)
  let exempt = Node_table.create 8 in
  List.iter
    (fun (key, _, _, _, _, checked) -> if checked && Node_table.mem scope.accesses key then Node_table.replace exempt key ())
    !accesses;
  let rec expr_uses name (e : expr) =
    match e.k with
    | Elem _ when Node_table.mem exempt (Obj.repr e) -> false
    | Var n -> n = name
    | Int _ | Float _ | Bool _ | Str_lit _ | Global _ | Function_ref _ -> false
    | Unary (_, a) | Convert (_, _, a) | Pointer_cast a | Read_only_view a | Math (_, [ a ]) | Count_bits (_, a) | Field (a, _) | Length a | Addr a | Is_null a -> expr_uses name a
    | Binary (_, a, b) | Compare (_, a, b) | Logic (_, a, b) | Elem (a, b, _) -> expr_uses name a || expr_uses name b
    | Cond (a, b, c) | Slice (a, b, c) -> expr_uses name a || expr_uses name b || expr_uses name c
    | _ -> true
  in
  let index_uses name (index : expr) = (not (Node_table.mem exempt (Obj.repr index))) && expr_uses name index in
  let rec uses name stmts =
    List.exists
      (fun st ->
        match st.r with
        | R_uniform (_, e) -> (not (Node_table.mem scope.dropped (Obj.repr st))) && expr_uses name e
        | R_slow e -> expr_uses name e
        | R_pure (_, _, pure, _) -> List.mem name (free_names pure)
        | R_load (_, _, view, index, _) | R_store (view, index, _, _) -> expr_uses name view || index_uses name index
        | R_gather (_, _, view, _, _) -> expr_uses name view
        | R_location _ | R_set _ | R_chunk_load _ | R_output _ | R_yield _ -> false
        | R_for (_, a, b, c, body) -> expr_uses name a || expr_uses name b || Option.fold ~none:false ~some:(expr_uses name) c || uses name body
        | R_if (c, a, b) -> expr_uses name c || uses name a || uses name b
        | R_block b -> uses name b
        | R_traverse t -> expr_uses name t.t_count || uses name t.t_body)
      stmts
  in
  let rec drop stmts =
    let changed = ref false in
    let rec after = function
      | [] -> ()
      | st :: rest ->
          (match st.r with
           | R_uniform (name, e) when (not (has_memory e)) && not (Node_table.mem scope.dropped (Obj.repr st)) ->
               if not (uses name rest) then (Node_table.replace scope.dropped (Obj.repr st) (); changed := true)
           | R_block b -> if drop b then changed := true
           | _ -> ());
          after rest
    in
    after stmts;
    if !changed then (ignore (drop stmts); true) else false
  in
  ignore (drop body);
  let term_c (e, c) = Printf.sprintf "(int64_t)%Ld * (int64_t)(%s)" c (uniform e) in
  let stride_c strides =
    if strides = [] then "(int64_t)0"
    else String.concat " + " (List.map (fun (st, c) -> match st with None -> Printf.sprintf "(int64_t)%Ld" c | Some e -> term_c (e, c)) strides)
  in
  let base_c terms = if terms = [] then "(int64_t)0" else String.concat " + " (List.map term_c terms) in
  let lines = Buffer.create 512 in
  let line indent text = Buffer.add_string lines (String.make indent ' ' ^ text ^ "\n") in
  let first = var ^ "$first" and last = var ^ "$last" in
  line indent "{";
  line (indent + 4) (Printf.sprintf "const %s %s = %s;" t (local first) (uniform from));
  line (indent + 4) (Printf.sprintf "const %s %s_end = %s;" t i (uniform upto));
  line (indent + 4) (Printf.sprintf "const %s %s_step = %s;" t i (match by with Some b -> uniform b | None -> "1"));
  if by <> None then line (indent + 4) (Printf.sprintf "if (%s_step <= 0) __builtin_trap();" i);
  line (indent + 4)
    (Printf.sprintf "const %s %s = %s < %s_end ? (%s)(%s + ((%s_end - %s - 1) / %s_step) * %s_step) : %s;"
       t (local last) (local first) i t (local first) i (local first) i i (local first));
  List.iter
    (fun (view, base_terms, strides, el, name, members) ->
      line (indent + 4)
        (Printf.sprintf "uint8_t *%s = (uint8_t *)%s.data + (int32_t)((%s + (%s) * (int64_t)%s) * %d);"
           name view (base_c base_terms) (stride_c strides) (local first) (bytes el));
      line (indent + 4) (Printf.sprintf "const int32_t %s_step = (int32_t)((%s) * (int64_t)%s_step * %d);" name (stride_c strides) i (bytes el));
      (* Each checked access, evaluated as written at the first and last
         iterations: its index is affine in the loop index, so these bound
         every iteration's index and every intermediate's overflow. *)
      List.iter
        (fun (index, lane_count, checked) ->
          if checked then (
            span_helper u;
            let at name = uniform (substitute [] var name index) in
            line (indent + 4)
              (Printf.sprintf "if (%s < %s_end) { (void)rake_span(%s, %d, %s.count); (void)rake_span(%s, %d, %s.count); }"
                 (local first) i (at first) lane_count view (at last) lane_count view)))
        (checked_representatives (List.filter (fun (_, _, checked) -> checked) (List.rev !members))))
    !groups;
  let next =
    match by with
    | None -> Printf.sprintf "%s = (%s)(%s + 1)" i t i
    | Some _ ->
        let helper_name = "rake_next_" ^ scalar_tag s in
        helper u helper_name
          (Printf.sprintf "static inline %s %s(%s i, %s step, %s end)\n{\n    return end - i <= step ? end : (%s)(i + step);\n}\n"
             t helper_name t t t t);
        Printf.sprintf "%s = %s(%s, %s_step, %s_end)" i helper_name i i i
  in
  let pragma () = line (indent + 4) "#pragma clang loop unroll(disable) vectorize(disable)" in
  (match by with
   | None ->
       pragma ();
       line (indent + 4) (Printf.sprintf "for (%s %s = %s; %s < %s_end; %s) {" t i (local first) i i next)
   | Some _ ->
       (* A stepped loop counts its trips: the index then advances by a plain
          add, which can't overflow before the count ends the loop. *)
       ignore next;
       line (indent + 4)
         (Printf.sprintf "const uint32_t %s_trips = %s < %s_end ? (uint32_t)(((int64_t)%s_end - (int64_t)%s - 1) / (int64_t)%s_step) + 1u : 0u;" i (local first) i i (local first) i);
       line (indent + 4)
         (Printf.sprintf "%s %s = %s;" t i (local first));
       pragma ();
       line (indent + 4)
         (Printf.sprintf "for (uint32_t %s_trip = 0; %s_trip < %s_trips; %s_trip++, %s = (%s)((%s)%s + (%s)%s_step)) {" i i i i i t (Tier_ir.(if is_signed s then "uint64_t" else "uint64_t")) i "uint64_t" i));
  if u.addressing = Barrier then
    List.iter (fun (_, _, _, _, name, _) -> line (indent + 8) (Printf.sprintf "__asm__(\"\" : \"+r\"(%s));" name)) !groups;
  Buffer.add_string lines (run_stmts u rs scope (indent + 8) body);
  List.iter (fun (_, _, _, _, name, _) -> line (indent + 8) (Printf.sprintf "%s += %s_step;" name name)) !groups;
  line (indent + 4) "}";
  line indent "}";
  ignore pad;
  Buffer.contents lines

(** A traversal: full racks, then a tail of the remaining lanes loaded and
    stored with lane-sized memory instructions chosen by the uniform
    remainder, never past the count, and computed under the tail's mask. *)
and traverse u rs scope indent t =
  let pad = String.make indent ' ' in
  u.loops <- u.loops + 1;
  let stack = find_pack u.program t.t_pack in
  let l = lanes t.t_domain in
  let count = expr u scope t.t_count in
  let rec assigned stmts =
    List.iter
      (fun s -> match s.r with R_set (name, _) -> Hashtbl.replace rs.assigned_in_traversal name () | R_for (_, _, _, _, b) | R_block b -> assigned b | R_if (_, a, b) -> assigned a; assigned b | _ -> ())
      stmts
  in
  assigned t.t_body;
  let loads, rest = List.partition (fun s -> match s.r with R_chunk_load _ -> true | _ -> false) t.t_body in
  (* Each column a traversal reads or writes, loaded from its descriptor once:
     inside the loop clang can't prove a store leaves the descriptor alone. *)
  let columns = Buffer.create 128 and column_names = Hashtbl.create 8 in
  let column_pointer ?(writable = false) owner field =
    let key = (owner, field, writable) in
    match Hashtbl.find_opt column_names key with
    | Some name -> name
    | None ->
        let name = Printf.sprintf "rake_column_%s_%s%s" (local owner) field (if writable then "_out" else "") in
        Hashtbl.replace column_names key name;
        Buffer.add_string columns
          (Printf.sprintf "%s        %suint8_t *const %s = (%suint8_t *)%s->%s;\n" pad (if writable then "" else "const ")
             name (if writable then "" else "const ") (local owner) field);
        name
  in
  let body tail =
    let rs = { rs with tail } in
    let load s =
      match s.r with
      | R_chunk_load (name, element, field, stored) ->
          record_type rs name (Rack element);
          let column = Printf.sprintf "%s + (uint32_t)%d * rake_i" (column_pointer t.t_stack field) (bytes stored) in
          let widen raw =
            if stored = element then raw
            else
              let steps =
                match (bytes stored, bytes element) with
                | 1, 4 -> if is_signed stored then [ "wasm_i16x8_extend_low_i8x16"; "wasm_i32x4_extend_low_i16x8" ] else [ "wasm_u16x8_extend_low_u8x16"; "wasm_u32x4_extend_low_u16x8" ]
                | 2, 4 -> if is_signed stored then [ "wasm_i32x4_extend_low_i16x8" ] else [ "wasm_u32x4_extend_low_u16x8" ]
                | 1, 2 -> if is_signed stored then [ "wasm_i16x8_extend_low_i8x16" ] else [ "wasm_u16x8_extend_low_u8x16" ]
                | 4, 8 -> if stored = SFloat then [ "wasm_f64x2_promote_low_f32x4" ] else if is_signed stored then [ "wasm_i64x2_extend_low_i32x4" ] else [ "wasm_u64x2_extend_low_u32x4" ]
                | _ -> fail Ast.dummy_loc "no widening from %d to %d bytes" (bytes stored) (bytes element)
              in
              u.selected <- List.map (fun s -> s) [ "i16x8.extend_low_i8x16_u"; "i32x4.extend_low_i16x8_u"; "i16x8.extend_low_i8x16_s"; "i32x4.extend_low_i16x8_s" ] @ u.selected;
              List.fold_left (fun acc f -> Printf.sprintf "%s(%s)" f acc) raw steps
          in
          let raw =
            if tail then Printf.sprintf "rake_tail_load_%d_%d(%s, rake_r)" (bytes stored * l) (bytes stored) column
            else if bytes stored * l = 16 then "wasm_v128_load(" ^ column ^ ")"
            else Printf.sprintf "wasm_v128_load%d_zero(%s)" (bytes stored * l * 8) column
          in
          if tail then tail_helpers u (bytes stored * l) (bytes stored);
          u.selected <- "v128.load" :: "v128.load32_zero" :: "v128.load64_zero" :: u.selected;
          Printf.sprintf "%s        const v128_t %s = %s;\n" pad (local name) (widen raw)
      | _ -> ""
    in
    u.selected <- "v128.store" :: u.selected;
    let rec stmt s =
      match s.r with
      | R_yield value ->
          let out = Printf.sprintf "(uint8_t *)p_result + (uint32_t)%d * rake_i" (bytes t.t_domain) in
          if tail then (tail_helpers u (bytes t.t_domain * l) (bytes t.t_domain); Printf.sprintf "%s        rake_tail_store_%d_%d(%s, %s, rake_r);\n" pad (bytes t.t_domain * l) (bytes t.t_domain) out (local value))
          else Printf.sprintf "%s        wasm_v128_store(%s, %s);\n" pad out (local value)
      | R_output (output, field, value) ->
          let element = List.assoc field (find_pack u.program (match Hashtbl.find_opt rs.types output with Some (Stack (s, _)) -> s | _ -> t.t_pack)).pack_fields in
          let out = Printf.sprintf "%s + (uint32_t)%d * rake_i" (column_pointer ~writable:true output field) (bytes element) in
          if tail then (tail_helpers u (bytes element * l) (bytes element); Printf.sprintf "%s        rake_tail_store_%d_%d(%s, %s, rake_r);\n" pad (bytes element * l) (bytes element) out (local value))
          else Printf.sprintf "%s        wasm_v128_store(%s, %s);\n" pad out (local value)
      | R_block b -> Printf.sprintf "%s        {\n%s%s        }\n" pad (String.concat "" (List.map stmt b)) pad
      | _ -> run_stmt u rs scope (indent + 8) s
    in
    let loaded = String.concat "" (List.map load loads) in
    let computed = String.concat "" (List.map stmt rest) in
    loaded ^ computed
  in
  ignore stack;
  (* Inside an outer traversal's tail, every lane outside it stays inactive:
     the full chunks run under the outer mask, and the tail's remainder is
     the smaller of the two, its mask their common prefix. *)
  let outer_tail = rs.tail in
  let full = body outer_tail in
  let tail = body true in
  let mask_bits = 128 / l in
  u.selected <- Printf.sprintf "i%dx%d.lt_s" (128 / l) l :: Printf.sprintf "i%dx%d.splat" (128 / l) l :: u.selected;
  let mask =
    Printf.sprintf "wasm_i%dx%d_lt(%s, wasm_i%dx%d_splat(rake_r))" mask_bits l
      (match l with
       | 4 -> "wasm_i32x4_make(0, 1, 2, 3)"
       | 2 -> "wasm_i64x2_make(0, 1)"
       | 8 -> "wasm_i16x8_make(0, 1, 2, 3, 4, 5, 6, 7)"
       | _ -> "wasm_i8x16_make(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)")
      mask_bits l
  in
  Printf.sprintf
    "%s{\n%s    const int64_t rake_count = (int64_t)(%s);\n%s    if (rake_count > 0) {\n%s        if (rake_count > (int64_t)UINT32_MAX) __builtin_trap();\n%s        const uint32_t rake_n = (uint32_t)rake_count;\n%s        const uint32_t rake_full = rake_n & ~(uint32_t)%d;\n%s%s        uint32_t rake_i = 0;\n%s        #pragma clang loop unroll(disable) vectorize(disable)\n%s        for (; rake_i < rake_full; rake_i += %d) {\n%s%s        }\n%s        if (rake_i < rake_n) {\n%s            const int32_t rake_r = %s;\n%s            const v128_t rake_tail = %s;\n%s%s        }\n%s    }\n%s}\n"
    pad pad count pad pad pad pad (l - 1)
    (Buffer.contents columns ^ (if outer_tail then Printf.sprintf "%s        const int32_t rake_outer_r = rake_r;\n" pad else ""))
    pad pad pad l (indent_lines 4 full) pad pad pad
    (if outer_tail then "(int32_t)(rake_n - rake_i) < rake_outer_r ? (int32_t)(rake_n - rake_i) : rake_outer_r" else "(int32_t)(rake_n - rake_i)")
    pad mask (indent_lines 4 tail) pad pad pad

and indent_lines n text =
  let pad = String.make n ' ' in
  String.concat "\n" (List.map (fun line -> if line = "" then line else pad ^ line) (String.split_on_char '\n' text))

(** Partial loads and stores of [r] lanes for a [width]-byte rack of
    [element]-byte lanes: one lane-sized memory instruction per set bit of
    the remaining bytes, chosen by a switch on the uniform remainder. *)
and tail_helpers u width element =
  (* Keep the store's remainder opaque to Clang. A known one-lane store
     otherwise lets it move integer arithmetic out of the rack and past a
     lane extraction. The empty scalar asm preserves the runtime remainder. *)
  let name = Printf.sprintf "rake_tail_load_%d_%d" width element in
  if not (Hashtbl.mem u.helper_names name) then (
    let cases store =
      String.concat ""
        (List.init ((width / element) - 1) (fun k ->
             let r = k + 1 in
             let total = r * element in
             let ops = ref [] and offset = ref 0 in
             List.iter
               (fun chunk ->
                 if total land chunk <> 0 then (
                   let lane = !offset / chunk in
                   ops :=
                     (if store then Printf.sprintf "wasm_v128_store%d_lane(p + %d, v, %d); " (chunk * 8) !offset lane
                      else Printf.sprintf "v = wasm_v128_load%d_lane(p + %d, v, %d); " (chunk * 8) !offset lane)
                     :: !ops;
                   offset := !offset + chunk))
               [ 8; 4; 2; 1 ];
             Printf.sprintf "    case %d: %sbreak;\n" r (String.concat "" (List.rev !ops))))
    in
    helper u name
      (Printf.sprintf
         "static inline v128_t %s(const uint8_t *p, int32_t r)\n{\n    v128_t v = wasm_i32x4_splat(0);\n    switch (r) {\n%s    default: __builtin_trap();\n    }\n    return v;\n}\n\
          static inline void rake_tail_store_%d_%d(uint8_t *p, v128_t v, int32_t r)\n{\n    __asm__(\"\" : \"+r\"(r));\n    switch (r) {\n%s    default: __builtin_trap();\n    }\n}\n"
         name (cases false) width element (cases true)));
  u.selected <- "v128.load8_lane" :: "v128.load16_lane" :: "v128.load32_lane" :: "v128.load64_lane"
                :: "v128.store8_lane" :: "v128.store16_lane" :: "v128.store32_lane" :: "v128.store64_lane" :: u.selected

let run_function u (run : run) =
  u.selected <- [];
  u.lane_operations <- 0;
  u.loops <- 0;
  u.slow_calls <- [];
  let rs = { run; types = Hashtbl.create 32; counter = ref 0; tail = false; assigned_in_traversal = Hashtbl.create 4 } in
  let scope = new_scope () in
  let params = ref [] and entry = Buffer.create 128 in
  List.iter
    (function
      | Run_stack (name, stack, w) ->
          record_type rs name (Stack (stack, w));
          params := Printf.sprintf "const %s *%s" (stack_type u stack w) (local name) :: !params
      | Run_view (name, s, w) ->
          record_type rs name (View (Sc s, w));
          let view = ctype u (View (Sc s, w)) in
          params := Printf.sprintf "int32_t p_%s_count" name :: Printf.sprintf "%s%s *p_%s" (if w then "" else "const ") (scalar_c s) name :: !params;
          Buffer.add_string entry (Printf.sprintf "    const %s %s = { (%s *)p_%s, p_%s_count };\n" view (local name) (scalar_c s) name name)
      | Run_uniform (name, s) ->
          record_type rs name (Sc s);
          params := Printf.sprintf "%s %s" (scalar_c s) (local name) :: !params
      | Run_rack (name, s) ->
          record_type rs name (Rack s);
          params := Printf.sprintf "v128_t %s" (local name) :: !params)
    run.run_params;
  (match run.run_stream with
   | Some s -> params := Printf.sprintf "%s *p_result" (scalar_c s) :: !params
   | None -> ());
  let body = run_stmts u rs scope 4 run.run_body in
  Hashtbl.replace u.run_facts run.run_name
    (u.loops, u.lane_operations, List.sort_uniq compare u.selected, List.sort_uniq compare u.slow_calls);
  Printf.sprintf "__attribute__((noinline)) void %s(%s)\n{\n%s%s}\n" run.run_name
    (if !params = [] then "void" else String.concat ", " (List.rev !params)) (Buffer.contents entry) body

(* ─── The unit ──────────────────────────────────────────────────────── *)

let frame_threshold = 256

(** Large slow aggregates use a bounded arena. WebAssembly reserves it in
    linear memory; native threads allocate it while a framed call is active.
    Keeping only the native pointer and cursor in TLS avoids inflating the
    minimum host-thread stack. Nested calls and C callbacks share the arena. *)
let frame_helpers u =
  let storage, allocate, release = match u.execution_target with
    | WebAssembly ->
        ("static uint8_t rake_frames[RAKE_FRAME_BYTES] __attribute__((aligned(16)));\nstatic size_t rake_frame_top;\n", "", "")
    | Native_program _ ->
        ("#include <stdlib.h>\nstatic _Thread_local uint8_t *rake_frames;\nstatic _Thread_local size_t rake_frame_top;\n",
         "    if (!rake_frames) {\n        rake_frames = malloc(RAKE_FRAME_BYTES);\n        if (!rake_frames) __builtin_trap();\n    }\n",
         "    if (rake_frame_top == 0) {\n        free(rake_frames);\n        rake_frames = NULL;\n    }\n")
  in
  helper u "rake_frame"
    (Printf.sprintf {|#include <stddef.h>
#ifndef RAKE_FRAME_BYTES
#define RAKE_FRAME_BYTES (4u << 20)
#endif
%sstatic inline void *rake_frame_enter(size_t size, size_t alignment, size_t *mark)
{
    const size_t available = (size_t)RAKE_FRAME_BYTES - rake_frame_top;
    if (size > available || alignment == 0 || (alignment & (alignment - 1)) != 0) __builtin_trap();
%s    const uintptr_t address = (uintptr_t)(rake_frames + rake_frame_top);
    const size_t padding = (alignment - address %% alignment) %% alignment;
    if (padding > available - size) __builtin_trap();
    *mark = rake_frame_top;
    void *const frame = rake_frames + rake_frame_top + padding;
    rake_frame_top += padding + size;
    return frame;
}
static inline void rake_frame_leave(size_t mark)
{
    rake_frame_top = mark;
%s}
|} storage allocate release)

let slow_function u (f : slow_func) =
  let scope = new_scope () in
  let entry = Buffer.create 128 in
  let params =
    List.concat_map
      (fun p ->
        match (p.pty, p.pass) with
        | View (Sc s, w), By_value when f.fblock ->
            Buffer.add_string entry
              (Printf.sprintf "    const %s %s = { (%s *)p_%s, p_%s_count };\n"
                 (ctype u p.pty) (local p.pname) (scalar_c s) p.pname p.pname);
            [ Printf.sprintf "%s%s *p_%s" (if w then "" else "const ") (scalar_c s) p.pname;
              Printf.sprintf "int32_t p_%s_count" p.pname ]
        | _, By_value -> [ Printf.sprintf "%s %s" (ctype u p.pty) (local p.pname) ]
        | _, Borrow ->
            Hashtbl.replace scope.places p.pname Borrowed;
            complete u p.pty;
            [ Printf.sprintf "const %s *%s" (ctype u p.pty) (local p.pname) ]
        | _, Borrow_mut ->
            Hashtbl.replace scope.places p.pname Borrowed;
            complete u p.pty;
            [ Printf.sprintf "%s *%s" (ctype u p.pty) (local p.pname) ])
      f.fparams
  in
  let signature =
    if f.fname = "main" && entry_parameters f.fparams = Some No_arguments then "int main(void)"
    else
      let linkage = if f.fblock || f.fname = "main" then "static " else "" in
      Printf.sprintf "%s%s%s %s(%s)" linkage (if f.fblock then "__attribute__((noinline)) " else "")
        (ctype u f.fresult) (slow_symbol u f.fname)
        (if params = [] then "void" else String.concat ", " params)
  in
  (* C determines the aggregate frame's size and alignment, including foreign
     layouts and padding. Small frames stay on the host stack; large ones use
     the bounded arena. This avoids guessing foreign sizes in the emitter. *)
  let rec framed_expr (e : expr) =
    match e.k with
    | Block (body, value) -> framed_decls body @ Option.fold ~none:[] ~some:framed_expr value
    | Unary (_, a) | Convert (_, _, a) | Pointer_cast a | Read_only_view a | Field (a, _) | Length a | Addr a | Is_null a | Count_bits (_, a) -> framed_expr a
    | Binary (_, a, b) | Compare (_, a, b) | Logic (_, a, b) | Elem (a, b, _) | Ptr_view (a, b) -> framed_expr a @ framed_expr b
    | Cond (a, b, c) | Slice (a, b, c) -> framed_expr a @ framed_expr b @ framed_expr c
    | Call (_, args) | Extern_call (_, args) | Math (_, args) | Array_lit args -> List.concat_map framed_expr args
    | Indirect_call (callee, args) -> List.concat_map framed_expr (callee :: args)
    | Vector_call (_, args) -> List.concat_map (function Arg_uniform e | Arg_memory e -> framed_expr e) args
    | Record_lit (_, fields) | Stack_lit (_, fields) -> List.concat_map (fun (_, e) -> framed_expr e) fields
    | _ -> []
  and framed_decls stmts =
    List.concat_map (fun s ->
      match s.s with
      | Decl (_, ty, value, _) ->
          (if is_aggregate ty then [ (s, ty) ] else [])
          @ Option.fold ~none:[] ~some:framed_expr value
      | Eval e | Return (Some e) -> framed_expr e
      | Assign (a, b) -> framed_expr a @ framed_expr b
      | If (c, a, b) -> framed_expr c @ framed_decls a @ framed_decls b
      | While (c, b) -> framed_expr c @ framed_decls b
      | For (_, _, a, b, c, body) -> framed_expr a @ framed_expr b @ Option.fold ~none:[] ~some:framed_expr c @ framed_decls body
      | _ -> []) stmts
  in
  match framed_decls f.fbody with
  | [] -> (signature, Printf.sprintf "%s\n{\n%s%s}\n" signature (Buffer.contents entry) (block u scope 4 f.fbody))
  | locals ->
      scope.framed <- true;
      frame_helpers u;
      let frame_type = Printf.sprintf "struct rake_frame_%s" (local f.fname) in
      List.iter (fun (_, ty) -> complete u ty) locals;
      let fields = List.mapi (fun index (declaration, ty) ->
        let field = Printf.sprintf "slot_%d" index in
        Node_table.replace scope.frame_slots (Obj.repr declaration) field;
        Printf.sprintf "    %s %s;\n" (ctype u ty) field) locals in
      Buffer.add_string u.types
        (Printf.sprintf "%s {\n%s};\n" frame_type
           (String.concat "" fields));
      let body = block u scope 4 f.fbody in
      let ends_in_return = match List.rev f.fbody with { s = Return _; _ } :: _ -> true | _ -> false in
      ( signature,
        Printf.sprintf {|%s
{
    size_t rake_frame_mark = 0;
    enum { rake_arena_frame = sizeof(%s) > %d };
    %s *const rake_locals = rake_arena_frame
        ? rake_frame_enter(sizeof(%s), _Alignof(%s), &rake_frame_mark)
        : __builtin_alloca_with_align(rake_arena_frame ? 1 : sizeof(%s),
              rake_arena_frame ? __CHAR_BIT__ : _Alignof(%s) * __CHAR_BIT__);
%s%s%s}
|} signature frame_type frame_threshold frame_type frame_type frame_type frame_type frame_type
          (Buffer.contents entry) body
          (if ends_in_return then "" else "    if (rake_arena_frame) rake_frame_leave(rake_frame_mark);\n") )

let escape_bytes contents =
  let b = Buffer.create (String.length contents * 3) in
  let column = ref 0 in
  String.iter
    (fun c ->
      let code = Char.code c in
      if !column > 120 then (Buffer.add_string b "\"\n\""; column := 0);
      (match c with
       | '"' -> Buffer.add_string b "\\\""
       | '\\' -> Buffer.add_string b "\\\\"
       | '?' -> Buffer.add_string b "\\?"
       | _ when code >= 32 && code < 127 -> Buffer.add_char b c
       | _ -> Buffer.add_string b (Printf.sprintf "\\%03o" code));
      incr column)
    contents;
  Buffer.contents b

let process_entry u =
  match List.find_opt (fun f -> f.fname = "main") u.program.slows with
  | Some f when entry_parameters f.fparams = Some Process_arguments ->
      Printf.sprintf
        {|
int main(int argc, char **argv)
{
    if (argc < 0 || (size_t)argc > SIZE_MAX / sizeof(uint8_t *) - 1) __builtin_trap();
    uint8_t **arguments = malloc(((size_t)argc + 1) * sizeof(*arguments));
    if (!arguments) __builtin_trap();
    for (int i = 0; i < argc; ++i) arguments[i] = (uint8_t *)argv[i];
    arguments[argc] = NULL;
    int result = %s((int32_t)argc, arguments);
    free(arguments);
    return result;
}
|} (slow_symbol u f.fname)
  | _ -> ""

let native_assembly_literal ~profile assembly =
  let assembly = assembly
    ^ (if Target.is_x86 profile then ".att_syntax prefix\n" else "") ^ ".text\n" in
  "__asm__(\"" ^ escape_bytes assembly ^ "\");\n"

(** The scratches and rakes, through their verified emission; and for each
    scratch slow code calls, a never-inlined boundary function. *)
let vector_definitions ~source u =
  match u.program.vector_defs with
  | [] -> ("", None)
  | defs -> (
      let program = [ { Ast.mod_name = "main"; mod_defs = defs } ] in
      match u.execution_target with
      | Native_program profile ->
          let config = Target.make_exn ~selection:(Explicit profile) Target.Cpu in
          let allocated = match Native_backend.compile ~config program with
            | Ok allocated -> allocated
            | Error error -> fail Ast.dummy_loc "%s" (Native_backend.format_error error) in
          let assembly = match Native_backend.emit_allocated ~source allocated with
            | Ok assembly -> assembly
            | Error error -> fail Ast.dummy_loc "%s" (Native_backend.format_error error) in
          (native_assembly_literal ~profile assembly, Some allocated)
      | WebAssembly ->
      match Native_lower.lower_program program with
      | Error error -> raise (Emission_error (error.loc, Native_lower.format_error error))
      | Ok native -> (
          match Wasm_simd128_isel.select native with
          | Error error -> raise (Emission_error (Ast.dummy_loc, Wasm_simd128_isel.format_error error))
          | Ok selected ->
              (String.concat "\n" (List.map Wasm_simd128_c.emit_function selected), None)))

let boundaries u =
  let called = Hashtbl.create 4 in
  let rec walk_expr (e : expr) =
    match e.k with
    | Vector_call (name, args) ->
        if not (List.exists (fun r -> r.run_name = name) u.program.runs) then Hashtbl.replace called name ();
        List.iter (function Arg_uniform a | Arg_memory a -> walk_expr a) args
    | Unary (_, a) | Convert (_, _, a) | Pointer_cast a | Read_only_view a | Field (a, _) | Length a | Addr a | Is_null a | Count_bits (_, a) -> walk_expr a
    | Binary (_, a, b) | Compare (_, a, b) | Logic (_, a, b) | Elem (a, b, _) | Ptr_view (a, b) -> walk_expr a; walk_expr b
    | Cond (a, b, c) | Slice (a, b, c) -> walk_expr a; walk_expr b; walk_expr c
    | Call (_, args) | Extern_call (_, args) | Math (_, args) | Array_lit args -> List.iter walk_expr args
    | Indirect_call (callee, args) -> List.iter walk_expr (callee :: args)
    | Record_lit (_, fields) | Stack_lit (_, fields) -> List.iter (fun (_, v) -> walk_expr v) fields
    | Block (body, value) -> List.iter walk body; Option.iter walk_expr value
    | _ -> ()
  and walk (s : stmt) =
    match s.s with
    | Decl (_, _, Some e, _) | Eval e | Return (Some e) -> walk_expr e
    | Assign (a, b) -> walk_expr a; walk_expr b
    | If (c, a, b) -> walk_expr c; List.iter walk a; List.iter walk b
    | While (c, b) -> walk_expr c; List.iter walk b
    | For (_, _, a, b, c, body) -> walk_expr a; walk_expr b; Option.iter walk_expr c; List.iter walk body
    | _ -> ()
  in
  List.iter (fun f -> List.iter walk f.fbody) u.program.slows;
  Hashtbl.fold
    (fun name () acc ->
      let def = List.find (fun (d : Ast.def) -> match d.v with DScratch (n, _, _, _) | DRake (n, _, _, _, _, _, _) -> n = name | _ -> false) u.program.vector_defs in
      let params, result =
        match def.v with
        | DScratch (_, params, result, _) | DRake (_, params, result, _, _, _, _) -> (params, result)
        | _ -> assert false
      in
      let c_of (t : Ast.typ) =
        match t.v with
        | TScalar PFloat -> "float"
        | TScalar PInt -> "int32_t"
        | TScalar PBool when u.execution_target <> WebAssembly -> "bool"
        | TScalar (PInt64 | PUint64) -> "uint64_t"
        | _ -> "uint32_t"
      in
      let ps = List.mapi (fun i p -> match p with Ast.PScalar (_, Some t) -> Printf.sprintf "%s a%d" (c_of t) i | _ -> "") params in
      let r = match result.result_type with Some t -> c_of t | None -> "float" in
      let prototype = match u.execution_target with
        | WebAssembly -> ""
        | Native_program _ ->
            if not (List.for_all (function Ast.PScalar (_, Some { v = TScalar (PFloat | PBool | PInt | PUint); _ }) -> true | _ -> false) params
              && (match result.result_type with Some { v = TScalar (PFloat | PBool | PInt | PUint); _ } -> true | _ -> false)) then
              fail def.loc "a native kernel called from slow code takes uniform f32/i32/u32/bool parameters and returns f32, bool, i32 or u32; other scalar C boundaries are work in progress";
            Printf.sprintf "extern %s %s(%s);\n" r name (if ps = [] then "void" else String.concat ", " ps)
      in
      acc
      ^ prototype
      ^ Printf.sprintf "static __attribute__((noinline)) %s rake_boundary_%s(%s)\n{\n    return %s(%s);\n}\n" r name
          (if ps = [] then "void" else String.concat ", " ps) name (String.concat ", " (List.mapi (fun i _ -> Printf.sprintf "a%d" i) params)))
    called ""

let emit ?(addressing = Barrier) ?(execution_target = WebAssembly) ~source (program : program) =
  (match execution_target with
   | WebAssembly -> ()
   | Native_program profile ->
       if not (Target.is_x86 profile || profile = Target.Aarch64_neon) then
         fail Ast.dummy_loc "native programs require an x86 or AArch64 profile");
  let u =
    {
      program; execution_target; addressing; types = Buffer.create 1024; defined = Hashtbl.create 32; helpers = Buffer.create 1024;
      helper_names = Hashtbl.create 32; expressions = Buffer.create 4096; selected = []; lane_operations = 0; loops = 0; slow_calls = [];
      run_facts = Hashtbl.create 8;
    }
  in
  let headers =
    List.sort_uniq compare
      (List.map (fun e -> e.eheader) program.externs
      @ List.filter_map (fun r -> match r.rlayout with Rake_struct -> None | C_struct path | C_union path -> Some path) program.records)
  in
  let forward =
    List.filter_map (fun r -> match r.rlayout with Rake_struct -> Some (Printf.sprintf "typedef struct rake_%s rake_%s;\n" r.rname r.rname) | C_struct _ | C_union _ -> None) program.records
  in
  List.iter (fun r -> complete u (Record r.rname)) program.records;
  (* Extern records: C owns their layout; the declared fields must have the declared sizes. *)
  let layout_checks =
    List.concat_map
      (fun r ->
        match r.rlayout with
        | C_struct _ | C_union _ ->
            let overlap_checks = match r.rlayout with
              | C_union _ ->
                  Printf.sprintf "_Static_assert(__builtin_classify_type(*(%s *)0) == 13, \"%s must be a C union\");\n" r.rname r.rname
                  :: List.map (fun (field, _) ->
                    Printf.sprintf "_Static_assert(__builtin_offsetof(%s, %s) == 0, \"%s.%s must overlap union storage\");\n" r.rname field r.rname field) r.rfields
              | Rake_struct | C_struct _ -> []
            in
            overlap_checks @ List.filter_map
              (fun (field, ty) ->
                match ty with
                | Sc _ | Ptr _ | Function_pointer _ ->
                    let size = match ty with Sc s -> string_of_int (bytes s) | _ -> "sizeof(" ^ ctype u ty ^ ")" in
                    Some (Printf.sprintf "_Static_assert(sizeof(((%s *)0)->%s) == %s, \"%s.%s is declared %s in Rake\");\n" r.rname field size r.rname field (string_of_ty ty))
                | Array (n, Sc s) ->
                    Some (Printf.sprintf "_Static_assert(sizeof(((%s *)0)->%s) == %d, \"%s.%s is declared %s in Rake\");\n" r.rname field (n * bytes s) r.rname field (string_of_ty ty))
                | _ -> None)
              r.rfields
        | Rake_struct -> [])
      program.records
  in
  let globals = Buffer.create 256 in
  List.iter
    (fun (name, ty, value) ->
      complete u ty;
      Buffer.add_string globals (Printf.sprintf "static const %s rake_const_%s = %s;\n" (ctype u ty) name (initializer_ u value)))
    (List.filter (fun (_, ty, _) -> is_aggregate ty) program.consts);
  List.iter
    (fun (name, ty, init) ->
      complete u ty;
      Buffer.add_string globals
        (Printf.sprintf "static %s rake_state_%s%s;\n" (ctype u ty) name
           (match init with Some v -> " = " ^ initializer_ u v | None -> "")))
    program.states;
  List.iter
    (fun (name, contents) ->
      Buffer.add_string globals
        (Printf.sprintf "static const uint8_t rake_embed_%s[%d] __attribute__((aligned(16))) =\n\"%s\";\n" name
           (max 1 (String.length contents)) (escape_bytes contents)))
    program.embeds;
  let vectors, registers = vector_definitions ~source u in
  let runs, traversals = match execution_target, program.runs with
    | WebAssembly, _ -> List.map (run_function u) program.runs, None
    | Native_program _, [] -> [], None
    | Native_program profile, _ ->
        let selected = try Native_traversal.compile ~profile program with
          Native_traversal.Unsupported (loc, message) -> fail loc "%s" message in
        let prototypes = List.map (fun run ->
          let parameters = List.map (function
            | Run_stack (name, schema, writable) ->
                Printf.sprintf "const %s *%s" (stack_type u schema writable) (local name)
            | Run_uniform (name, scalar) -> Printf.sprintf "%s %s" (scalar_c scalar) (local name)
            | _ -> assert false) run.run_params in
          let parameters = parameters @ (match run.run_stream with
            | None -> [] | Some element -> [ scalar_c element ^ " *rake_out" ]) in
          Printf.sprintf "extern void %s(%s);\n" run.run_name (String.concat ", " parameters)) program.runs in
        prototypes @ [ native_assembly_literal ~profile selected.assembly ], Some selected in
  let native_kernels = if registers = None && traversals = None then None
    else Some { registers; traversals } in
  let slows = List.map (slow_function u) program.slows in
  let prototypes = List.filter_map (fun (signature, _) -> if String.starts_with ~prefix:"int main" signature then None else Some (signature ^ ";\n")) slows in
  let entry = process_entry u in
  let entry_headers = if entry = "" then "" else
    "#include <stdlib.h>\n#include <stddef.h>\n_Static_assert(sizeof(int) == sizeof(int32_t), \"Rake main requires a 32-bit C int\");\n" in
  let prologue, vector_prologue, vector_epilogue =
    match execution_target with
    | WebAssembly ->
        ( Printf.sprintf
            "/* Generated by rakec --target wasm-simd128 from %s. Runs are Rake's loops, loads and\n   stores; every intrinsic is one Rake-selected WebAssembly SIMD instruction. */\n"
            (Filename.basename source)
          ^ "#pragma STDC FP_CONTRACT OFF\n#include <stdint.h>\n#include <stdbool.h>\n#include <wasm_simd128.h>\n",
          "\n#ifndef RAKE_WASM_LINKAGE\n#define RAKE_WASM_LINKAGE static inline __attribute__((always_inline))\n#endif\n\n"
          ^ Wasm_simd128_c.relaxed_prologue (),
          Wasm_simd128_c.relaxed_epilogue () )
    | Native_program profile ->
        ( Printf.sprintf
            "/* Generated by rakec --target %s from %s. Rake-selected kernels are opaque\n   assembly. The platform C compiler owns only slow lowering and the C ABI. */\n"
            (Target.profile_name profile) (Filename.basename source)
          ^ "#include <stdint.h>\n#include <stdbool.h>\n_Static_assert(sizeof(void *) == 8, \"native Rake slow code requires a 64-bit C ABI\");\n",
          "", "" )
  in
  let unit_text =
    String.concat ""
      ([ prologue; entry_headers ]
      @ List.map (fun h -> Printf.sprintf "#include \"%s\"\n" h) headers
      @ [ vector_prologue ]
      @ forward @ [ Buffer.contents u.types ] @ layout_checks
      @ [ "\n"; Buffer.contents u.helpers; "\n"; Buffer.contents globals; "\n"; vectors; "\n"; boundaries u; "\n";
          Buffer.contents u.expressions ]
      @ prototypes @ [ "\n" ] @ runs @ [ "\n" ] @ List.map snd slows @ [ entry; vector_epilogue ])
  in
  (unit_text, u.run_facts, native_kernels)
