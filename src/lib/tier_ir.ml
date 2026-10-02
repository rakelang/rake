(** Typed intermediate representation of the slow tier and of general runs.

    The checker ({!Tier_check}) produces this form; the interpreter
    ({!Tier_interp}) and the C emitter ({!Tier_c}) consume it. Scratches and
    rakes keep their own pipeline (typed native SSA); a run's pure rack
    expressions stay Rake AST here and are lowered through that same pipeline,
    so a rack operation has one implementation wherever it is written. *)

type scalar = Types.scalar
type pointer_access = Ast.pointer_access = Read_write | Read_only

type ty =
  | Sc of scalar
  | Rack of scalar
  | Mask of scalar  (** a lane mask from comparing racks of this element *)
  | Rack_array of int * scalar  (** registers: N racks, indexed by constants *)
  | Array of int * ty  (** memory: N elements *)
  | View of ty * bool  (** element, writable *)
  | Ptr of ty * pointer_access
  | Function_pointer of ty list * ty
  | Record of string
  | Stack of string * bool  (** a pack's columns, writable *)
  | Str
  | Void

let rec string_of_ty = function
  | Sc s -> Types.show_concise (Types.Scalar s)
  | Rack s -> Types.show_concise (Types.Rack s)
  | Mask s -> "mask of " ^ Types.show_concise (Types.Rack s)
  | Rack_array (n, s) -> Printf.sprintf "[%d]%s" n (Types.show_concise (Types.Rack s))
  | Array (n, t) -> Printf.sprintf "[%d]%s" n (string_of_ty t)
  | View (t, false) -> "[]" ^ string_of_ty t
  | View (t, true) -> "mut []" ^ string_of_ty t
  | Ptr (t, access) -> "ptr " ^ (if access = Read_only then "const " else "") ^ string_of_ty t
  | Function_pointer (args, result) ->
      "slow(" ^ String.concat ", " (List.map string_of_ty args) ^ ") -> " ^ string_of_ty result
  | Record name -> name
  | Stack (name, false) -> "stack " ^ name
  | Stack (name, true) -> "mut stack " ^ name
  | Str -> "string"
  | Void -> "()"

let is_integer = function
  | Types.SInt | SInt8 | SInt16 | SInt64 | SUint | SUint8 | SUint16 | SUint64 -> true
  | SFloat | SDouble | SBool -> false

let is_signed = function
  | Types.SInt | SInt8 | SInt16 | SInt64 -> true
  | _ -> false

let is_float = function Types.SFloat | SDouble -> true | _ -> false

let bits = function
  | Types.SBool -> 8
  | SInt8 | SUint8 -> 8
  | SInt16 | SUint16 -> 16
  | SFloat | SInt | SUint -> 32
  | SDouble | SInt64 | SUint64 -> 64

let bytes s = bits s / 8

(** Lanes of a rack of [s] in one 128-bit register. *)
let lanes s = 128 / bits s

let scalar_of_prim = Types.of_prim

(* Uniform scalar expressions: everything the slow tier computes, and the
   uniform scalars of a run (indices, bounds, conditions). *)

type unary = Neg | Not | Bit_not

type binary =
  | Add | Sub | Mul | Div | Rem  (** checked on integers *)
  | Wrap_add | Wrap_sub | Wrap_mul
  | Bit_and | Bit_or | Bit_xor | Bit_andnot
  | Shl | Shr | Shr_signed | Rotl | Rotr  (** counts taken modulo the bits *)
  | Min | Max

type comparison = Eq | Ne | Lt | Le | Gt | Ge

type count_kind = Clz | Ctz | Popcnt

type expr = { k : kind; ty : ty; loc : Ast.loc }

and kind =
  | Int of int64
  | Float of float
  | Bool of bool
  | Str_lit of string
  | Var of string  (** a local, parameter, loop index or uniform *)
  | Global of string  (** module state or an embedded file *)
  | Unary of unary * expr
  | Binary of binary * expr * expr
  | Compare of comparison * expr * expr
  | Logic of bool * expr * expr  (** true for and; short-circuit *)
  | Math of string * expr list  (** sqrt, exp, log, log2, tanh, abs, floor, ceil *)
  | Count_bits of count_kind * expr
  | Call of string * expr list  (** a slow function; aggregates are borrowed *)
  | Extern_call of string * expr list
  | Function_ref of string
  | Indirect_call of expr * expr list
  | Pointer_cast of expr  (** erase or restore a data pointer through ptr () *)
  | Vector_call of string * vector_arg list  (** a run, or a scratch with uniform parameters *)
  | Field of expr * string
  | Elem of expr * expr * bool  (** element of an array, view or pointer; checked *)
  | Convert of Ast.convert * scalar * expr
  | Cond of expr * expr * expr
  | Record_lit of string * (string * expr) list
  | Stack_lit of string * (string * expr) list  (** a pack's columns, each a view *)
  | Array_lit of expr list
  | Addr of expr
  | Length of expr  (** elements in a view or array *)
  | Slice of expr * expr * expr  (** view of [count] elements from [start]; checked *)
  | Ptr_view of expr * expr  (** unchecked view of [count] elements at a pointer *)
  | Read_only_view of expr  (** borrow a writable view without write access *)
  | Is_null of expr
  | Block of stmt list * expr option  (** lexical scalar scope; tail expression is its value *)

and vector_arg = Arg_memory of expr | Arg_uniform of expr

and stmt = { s : skind; sloc : Ast.loc }

and skind =
  | Decl of string * ty * expr option * bool  (** name, type, initial value, mutable *)
  | Assign of expr * expr
  | Eval of expr
  | If of expr * stmt list * stmt list
  | While of expr * stmt list
  | For of string * scalar * expr * expr * expr option * stmt list
  | Break
  | Continue
  | Return of expr option

type pass = By_value | Borrow | Borrow_mut

type param = { pname : string; pty : ty; pass : pass }

type entry_parameters = No_arguments | Process_arguments

let entry_parameters = function
  | [] -> Some No_arguments
  | [ { pty = Sc SInt; pass = By_value; _ };
      { pty = Ptr (Ptr (Sc SUint8, Read_write), Read_write); pass = By_value; _ } ] -> Some Process_arguments
  | _ -> None

type slow_func = {
  fname : string; fparams : param list; fresult : ty; fbody : stmt list;
  floc : Ast.loc;
  fblock : bool;  (** extracted run block: never inline; view captures use pointer/count ABI *)
}

type record_layout = Rake_struct | C_struct of string | C_union of string

type record = { rname : string; rlayout : record_layout; rfields : (string * ty) list; rloc : Ast.loc }

type extern_func = { ename : string; eheader : string; eparams : param list; eresult : ty }

(* Runs: vector code over memory. A run's statements are in A-normal form:
   every load, gather and pure rack computation binds a name. *)

type run_param =
  | Run_stack of string * string * bool  (** name, pack, writable *)
  | Run_view of string * scalar * bool
  | Run_uniform of string * scalar
  | Run_rack of string * scalar

type rstmt = { r : rkind; rloc : Ast.loc }

and rkind =
  | R_uniform of string * expr  (** let <x: T> = e, a uniform scalar *)
  | R_slow of expr  (** a discarded slow block result *)
  | R_pure of string * ty * Ast.expr * bool
      (** a pure rack, mask or uniform-scalar result of rack operations; its
          free names are racks, masks and uniform scalars bound earlier *)
  | R_load of string * scalar * expr * expr * bool  (** name, element, view, element index, checked *)
  | R_gather of string * scalar * expr * string * bool  (** name, element, view, index rack, checked *)
  | R_location of string * ty * string  (** a mutable rack location and its first value *)
  | R_set of string * string
  | R_store of expr * expr * string * bool  (** view, element index, rack, checked *)
  | R_for of string * expr * expr * expr option * rstmt list
  | R_if of expr * rstmt list * rstmt list
  | R_traverse of traverse
  | R_chunk_load of string * scalar * string * scalar
      (** name, rack element, field, stored element: a chunk's column, widened when narrower *)
  | R_output of string * string * string  (** output stack, field, rack *)
  | R_yield of string
  | R_block of rstmt list  (** one unrolled repeat iteration: its names are its own *)

and traverse = {
  t_stack : string;
  t_pack : string;
  t_domain : scalar;
  t_count : expr;
  t_body : rstmt list;
}

type run = {
  run_name : string;
  run_params : run_param list;
  run_stream : scalar option;  (** the output element of the spec-02 stream form *)
  run_body : rstmt list;
  run_loc : Ast.loc;
}

type pack = { pack_name : string; pack_fields : (string * scalar) list }

type program = {
  source : Ast.program;
  packs : pack list;
  records : record list;  (** declaration order; fields only name earlier records *)
  externs : extern_func list;
  states : (string * ty * expr option) list;
  embeds : (string * string) list;  (** name, file contents *)
  consts : (string * ty * expr) list;
  slows : slow_func list;
  runs : run list;
  vector_defs : Ast.def list;  (** scratches and rakes, lowered by the native pipeline *)
}

let find_pack program name = List.find (fun s -> s.pack_name = name) program.packs
let find_record program name = List.find (fun r -> r.rname = name) program.records

(* ─── Text ──────────────────────────────────────────────────────────── *)

let rec string_of_ast (e : Ast.expr) =
  let s = string_of_ast in
  match e.v with
  | EInt n -> Int64.to_string n
  | EFloat f -> Printf.sprintf "%g" f
  | EBool b -> string_of_bool b
  | EVar n -> n
  | EScalarVar n -> "<" ^ n ^ ">"
  | EBroadcast inner -> "<" ^ s inner ^ ">"
  | EBinop (a, op, b) -> Printf.sprintf "(%s %s %s)" (s a) (Ast.show_binop op) (s b)
  | EUnop (op, a) -> Printf.sprintf "%s(%s)" (Ast.show_unop op) (s a)
  | ECall (name, args) -> Printf.sprintf "%s(%s)" name (String.concat ", " (List.map s args))
  | EIf (c, a, b) -> Printf.sprintf "if %s then %s else %s" (s c) (s a) (s b)
  | EExtract (a, l) -> Printf.sprintf "extract(%s, %s)" (s a) (s l)
  | EInsert (a, l, x) -> Printf.sprintf "insert(%s, %s, %s)" (s a) (s l) (s x)
  | EConvert (_, _, a) -> Printf.sprintf "bitcast(%s)" (s a)
  | EFma (a, b, c) -> Printf.sprintf "fma(%s, %s, %s)" (s a) (s b) (s c)
  | EReduce (_, a) -> Printf.sprintf "reduce(%s)" (s a)
  | EScan (_, a) -> Printf.sprintf "scan(%s)" (s a)
  | EShuffle (a, idx) -> Printf.sprintf "shuffle(%s, [%s])" (s a) (String.concat ", " (List.map string_of_int idx))
  | ETuple items -> String.concat ", " (List.map s items)
  | _ -> "..."

let rec string_of_expr (e : expr) =
  let s = string_of_expr in
  match e.k with
  | Int n -> Int64.to_string n
  | Float f -> Printf.sprintf "%g" f
  | Bool b -> string_of_bool b
  | Str_lit t -> Printf.sprintf "%S" t
  | Var n -> n
  | Global n -> "@" ^ n
  | Unary (Neg, a) -> "-" ^ s a
  | Unary (Not, a) -> "not " ^ s a
  | Unary (Bit_not, a) -> "bit_not(" ^ s a ^ ")"
  | Binary (_, a, b) -> Printf.sprintf "(%s op %s)" (s a) (s b)
  | Compare (_, a, b) -> Printf.sprintf "(%s cmp %s)" (s a) (s b)
  | Logic (c, a, b) -> Printf.sprintf "(%s %s %s)" (s a) (if c then "and" else "or") (s b)
  | Math (f, args) | Call (f, args) | Extern_call (f, args) -> Printf.sprintf "%s(%s)" f (String.concat ", " (List.map s args))
  | Function_ref f -> "addr(" ^ f ^ ")"
  | Indirect_call (f, args) -> Printf.sprintf "%s(%s)" (s f) (String.concat ", " (List.map s args))
  | Pointer_cast a -> Printf.sprintf "bitcast(%s, %s)" (string_of_ty e.ty) (s a)
  | Count_bits (_, a) -> "count_bits(" ^ s a ^ ")"
  | Vector_call (f, _) -> f ^ "(...)"
  | Field (a, f) -> s a ^ "." ^ f
  | Elem (a, i, checked) -> Printf.sprintf "%s[%s%s]" (s a) (if checked then "" else "unchecked ") (s i)
  | Convert (_, t, a) -> Printf.sprintf "%s(%s)" (string_of_ty (Sc t)) (s a)
  | Cond (c, a, b) -> Printf.sprintf "if %s then %s else %s" (s c) (s a) (s b)
  | Record_lit (n, _) | Stack_lit (n, _) -> n ^ " {...}"
  | Array_lit items -> Printf.sprintf "[%d items]" (List.length items)
  | Addr a -> "addr(" ^ s a ^ ")"
  | Length a -> "count(" ^ s a ^ ")"
  | Slice (a, b, c) -> Printf.sprintf "slice(%s, %s, %s)" (s a) (s b) (s c)
  | Ptr_view (a, b) -> Printf.sprintf "unchecked_view(%s, %s)" (s a) (s b)
  | Read_only_view a -> "read_only(" ^ s a ^ ")"
  | Is_null a -> "is_null(" ^ s a ^ ")"
  | Block (_, value) -> "slow { ..." ^ (match value with None -> " }" | Some v -> "; " ^ s v ^ " }")

let rec string_of_rstmts indent stmts = String.concat "" (List.map (string_of_rstmt indent) stmts)

and string_of_rstmt indent (st : rstmt) =
  let pad = String.make indent ' ' in
  match st.r with
  | R_uniform (n, e) -> Printf.sprintf "%suniform %s : %s = %s\n" pad n (string_of_ty e.ty) (string_of_expr e)
  | R_slow e -> Printf.sprintf "%sslow %s\n" pad (string_of_expr e)
  | R_pure (n, ty, e, fused) -> Printf.sprintf "%s%s %s : %s = %s\n" pad (if fused then "fused" else "pure") n (string_of_ty ty) (string_of_ast e)
  | R_load (n, el, v, i, c) -> Printf.sprintf "%sload %s : %s = %s[%s%s]\n" pad n (string_of_ty (Rack el)) (string_of_expr v) (if c then "" else "unchecked ") (string_of_expr i)
  | R_gather (n, el, v, i, c) -> Printf.sprintf "%sgather %s : %s = %s[%s%s]\n" pad n (string_of_ty (Rack el)) (string_of_expr v) (if c then "" else "unchecked ") i
  | R_location (n, ty, v) -> Printf.sprintf "%slocation %s : %s := %s\n" pad n (string_of_ty ty) v
  | R_set (n, v) -> Printf.sprintf "%s%s <- %s\n" pad n v
  | R_store (v, i, x, c) -> Printf.sprintf "%sstore %s[%s%s] <- %s\n" pad (string_of_expr v) (if c then "" else "unchecked ") (string_of_expr i) x
  | R_for (n, a, b, by, body) ->
      Printf.sprintf "%sfor <%s> from %s up to %s%s:\n%s" pad n (string_of_expr a) (string_of_expr b)
        (match by with Some e -> " by " ^ string_of_expr e | None -> "") (string_of_rstmts (indent + 2) body)
  | R_if (c, a, b) -> Printf.sprintf "%sif %s:\n%s%selse:\n%s" pad (string_of_expr c) (string_of_rstmts (indent + 2) a) pad (string_of_rstmts (indent + 2) b)
  | R_traverse t ->
      Printf.sprintf "%straverse %s (%s) using %s up to %s:\n%s" pad t.t_stack t.t_pack (string_of_ty (Rack t.t_domain)) (string_of_expr t.t_count)
        (string_of_rstmts (indent + 2) t.t_body)
  | R_chunk_load (n, el, f, stored) -> Printf.sprintf "%scolumn %s : %s = %s (stored %s)\n" pad n (string_of_ty (Rack el)) f (string_of_ty (Sc stored))
  | R_output (p, f, v) -> Printf.sprintf "%soutput %s.%s <- %s\n" pad p f v
  | R_yield v -> Printf.sprintf "%syield %s\n" pad v
  | R_block body -> Printf.sprintf "%sunrolled:\n%s" pad (string_of_rstmts (indent + 2) body)

let dump program =
  String.concat ""
    (List.map
       (fun r -> Printf.sprintf "\nrun @%s:\n%s" r.run_name (string_of_rstmts 2 r.run_body))
       program.runs
    @ List.map (fun f -> Printf.sprintf "\nslow @%s: %d statements\n" f.fname (List.length f.fbody)) program.slows)
