(** Executable semantics of whole programs: slow code and runs.

    This interpreter defines what a program means independently of the C
    Rake emits. Slow values follow C's layout rules only where C owns them
    (extern records); otherwise records and arrays are values, copied when
    bound or assigned, and views and pointers alias the storage they name.
    Integer [+ - *], [/] and [%], checked conversions and checked indexing
    trap exactly where the emitted C traps. A run's rack expressions are
    evaluated by {!Native_reference}, the semantics of crunches, so a rack
    operation means one thing in both. *)

open Tier_ir
module R = Native_reference

exception Trap of Ast.loc * string

let trap loc fmt = Printf.ksprintf (fun m -> raise (Trap (loc, m))) fmt

type value =
  | VInt of scalar * int64  (** normalised to its type; u64 as raw bits *)
  | VFloat of scalar * float  (** binary32 values are rounded *)
  | VBool of bool
  | VStr of string
  | VArr of value array
  | VRec of string * value array  (** fields in declaration order *)
  | VView of view
  | VPtr of pointer
  | VNull
  | VPack of (string * value) list
  | VRack of R.value
  | VUnit

and view = { store : value array; start : int; count : int }
and pointer = { store : value array; index : int }

type externs = (string, value list -> value) Hashtbl.t

type trace = {
  trace_name : string;
  trace_loc : Ast.loc;
  trace_value : R.value;
  trace_active : int option;
}

type machine = {
  program : program;
  globals : (string, value ref) Hashtbl.t;
  externs : externs;
  trace : trace -> unit;
}

let rec copy = function
  | VArr a -> VArr (Array.map copy a)
  | VRec (n, f) -> VRec (n, Array.map copy f)
  | v -> v

(* ─── Integers ──────────────────────────────────────────────────────── *)

let width s = bits s

let normalise s v =
  let open Int64 in
  match s with
  | Types.SBool -> if v <> 0L then 1L else 0L
  | SInt64 | SUint64 -> v
  | _ ->
      let w = width s in
      let m = sub (shift_left 1L w) 1L in
      let low = logand v m in
      if is_signed s && logand low (shift_left 1L (w - 1)) <> 0L then sub low (shift_left 1L w) else low

let range s =
  match s with
  | Types.SInt8 -> (-128L, 127L) | SUint8 -> (0L, 255L)
  | SInt16 -> (-32768L, 32767L) | SUint16 -> (0L, 65535L)
  | SInt -> (-2147483648L, 2147483647L) | SUint -> (0L, 4294967295L)
  | _ -> (Int64.min_int, Int64.max_int)

let fits s v = let lo, hi = range s in v >= lo && v <= hi

let checked_arith loc op s a b =
  let open Int64 in
  match s with
  | Types.SInt64 -> (
      match op with
      | Add -> let r = add a b in if (a >= 0L) = (b >= 0L) && (r >= 0L) <> (a >= 0L) then trap loc "i64 overflow" else r
      | Sub -> let r = sub a b in if (a >= 0L) <> (b >= 0L) && (r >= 0L) <> (a >= 0L) then trap loc "i64 overflow" else r
      | Mul ->
          let r = mul a b in
          if a <> 0L && (div r a <> b || (a = -1L && b = min_int) || (b = -1L && a = min_int)) then trap loc "i64 overflow" else r
      | Div | Rem ->
          if b = 0L then trap loc "division by zero"
          else if a = min_int && b = -1L then trap loc "i64 overflow"
          else if op = Div then div a b else rem a b
      | _ -> assert false)
  | SUint64 -> (
      match op with
      | Add -> let r = add a b in if unsigned_compare r a < 0 then trap loc "u64 overflow" else r
      | Sub -> if unsigned_compare a b < 0 then trap loc "u64 overflow" else sub a b
      | Mul -> let r = mul a b in if a <> 0L && unsigned_div r a <> b then trap loc "u64 overflow" else r
      | Div | Rem -> if b = 0L then trap loc "division by zero" else if op = Div then unsigned_div a b else unsigned_rem a b
      | _ -> assert false)
  | _ ->
      let r =
        match op with
        | Add -> add a b | Sub -> sub a b | Mul -> mul a b
        | Div -> if b = 0L then trap loc "division by zero" else div a b
        | Rem -> if b = 0L then trap loc "division by zero" else rem a b
        | _ -> assert false
      in
      if fits s r then r else trap loc "%s overflow" (string_of_ty (Sc s))

let unsigned s v = if is_signed s then Int64.logand v (if width s = 64 then -1L else Int64.sub (Int64.shift_left 1L (width s)) 1L) else v

let bit_op op s a b =
  let open Int64 in
  let w = width s in
  let c = to_int (logand b (of_int (w - 1))) in
  let ua = unsigned s a in
  let r =
    match op with
    | Bit_and -> logand a b | Bit_or -> logor a b | Bit_xor -> logxor a b | Bit_andnot -> logand a (lognot b)
    | Shl -> shift_left a c
    | Shr -> shift_right_logical ua c
    | Shr_signed -> shift_right (normalise (match s with Types.SUint8 -> SInt8 | SUint16 -> SInt16 | SUint -> SInt | SUint64 -> SInt64 | s -> s) a) c
    | Rotl -> if c = 0 then a else logor (shift_left ua c) (shift_right_logical ua (w - c))
    | Rotr -> if c = 0 then a else logor (shift_right_logical ua c) (shift_left ua (w - c))
    | Wrap_add -> add a b | Wrap_sub -> sub a b | Wrap_mul -> mul a b
    | _ -> assert false
  in
  normalise s r

(** Correctly rounded integer to binary32 or binary64. *)
let to_float target s v =
  let open Int64 in
  let exact = if s = Types.SUint64 && v < 0L then (to_float (shift_right_logical v 1) *. 2.0) +. to_float (logand v 1L) else to_float v in
  if target = Types.SDouble then exact
  else
    (* Round once to binary32: magnitudes below 2^53 are exact as doubles. *)
    let magnitude = if s = Types.SUint64 then v else abs v in
    if (s <> Types.SUint64 && magnitude < 0x20000000000000L && magnitude >= 0L) || (s = Types.SUint64 && unsigned_compare v 0x20000000000000L < 0)
    then R.f32 exact
    else
      (* Keep 25 significant bits plus a sticky bit, then round to binary32. *)
      let negative = s <> Types.SUint64 && v < 0L in
      let m = if negative then neg v else v in
      let rec top b = if b < 0 then 0 else if logand (shift_right_logical m b) 1L = 1L then b else top (b - 1) in
      let high = top 63 in
      let shift = high - 25 in
      let kept = shift_right_logical m shift in
      let sticky = if logand m (sub (shift_left 1L shift) 1L) <> 0L then 1L else 0L in
      let approx = Float.ldexp (Int64.to_float (logor kept sticky)) shift in
      R.f32 (if negative then -.approx else approx)

(* ─── Expressions ───────────────────────────────────────────────────── *)

type env = { machine : machine; vars : (string, value ref) Hashtbl.t }

exception Return_value of value
exception Break_loop
exception Continue_loop

let as_int loc = function VInt (_, v) -> v | VBool b -> if b then 1L else 0L | _ -> trap loc "expected an integer"
let as_bool loc = function VBool b -> b | VInt (_, v) -> v <> 0L | _ -> trap loc "expected a bool"
let as_float loc = function VFloat (_, f) -> f | _ -> trap loc "expected a float"

let scalar_of loc = function Sc s -> s | ty -> trap loc "expected a scalar, got %s" (string_of_ty ty)

let float_value s f = VFloat (s, if s = Types.SFloat then R.f32 f else f)

let lookup env loc name =
  match Hashtbl.find_opt env.vars name with
  | Some cell -> cell
  | None -> (
      match Hashtbl.find_opt env.machine.globals name with
      | Some cell -> cell
      | None -> trap loc "undefined %s" name)

let field_index env name field =
  let r = find_record env.machine.program name in
  let rec go i = function [] -> invalid_arg field | (f, _) :: rest -> if f = field then i else go (i + 1) rest in
  go 0 r.rfields

let zero_of env =
  let rec zero = function
    | Sc s when is_float s -> VFloat (s, 0.0)
    | Sc SBool -> VBool false
    | Sc s -> VInt (s, 0L)
    | Array (n, t) -> VArr (Array.init n (fun _ -> zero t))
    | Record name -> VRec (name, Array.of_list (List.map (fun (_, t) -> zero t) (find_record env.machine.program name).rfields))
    | Ptr _ -> VNull
    | _ -> VUnit
  in
  zero

let rec eval env (e : expr) : value =
  let ev = eval env in
  let loc = e.loc in
  match e.k with
  | Int v -> (match e.ty with Sc s when is_float s -> float_value s (Int64.to_float v) | Sc SBool -> VBool (v <> 0L) | Sc s -> VInt (s, normalise s v) | _ -> VInt (SInt, v))
  | Float f -> float_value (scalar_of loc e.ty) f
  | Bool b -> VBool b
  | Str_lit s -> VStr s
  | Var name | Global name -> !(lookup env loc name)
  | Unary (Neg, a) -> (
      match ev a with
      | VInt (s, v) -> VInt (s, checked_arith loc Sub s 0L v)
      | VFloat (s, f) -> VFloat (s, Float.neg f)
      | _ -> trap loc "negation")
  | Unary (Not, a) -> VBool (not (as_bool loc (ev a)))
  | Unary (Bit_not, a) -> (match ev a with VInt (s, v) -> VInt (s, normalise s (Int64.lognot v)) | _ -> trap loc "bit_not")
  | Binary (op, a, b) -> (
      match (ev a, ev b) with
      | VInt (s, x), VInt (_, y) -> (
          match op with
          | Add | Sub | Mul | Div | Rem -> VInt (s, checked_arith loc op s x y)
          | Min -> VInt (s, if (if is_signed s then compare x y else Int64.unsigned_compare x y) <= 0 then x else y)
          | Max -> VInt (s, if (if is_signed s then compare x y else Int64.unsigned_compare x y) >= 0 then x else y)
          | Shl | Shr | Shr_signed | Rotl | Rotr | Wrap_add | Wrap_sub | Wrap_mul | Bit_and | Bit_or | Bit_xor | Bit_andnot ->
              VInt (s, bit_op op s x y))
      | VFloat (s, x), VFloat (_, y) ->
          let canonical = Int32.float_of_bits 0x7fc00000l in
          let r =
            match op with
            | Add -> x +. y | Sub -> x -. y | Mul -> x *. y | Div -> x /. y
            | Min -> if Float.is_nan x || Float.is_nan y then canonical else if x = y then (if Float.sign_bit x then x else y) else Float.min x y
            | Max -> if Float.is_nan x || Float.is_nan y then canonical else if x = y then (if Float.sign_bit x then y else x) else Float.max x y
            | _ -> trap loc "float operation"
          in
          float_value s r
      | _ -> trap loc "binary operands")
  | Compare (op, a, b) -> (
      let c x y = match op with Eq -> x = 0 | Ne -> x <> 0 | Lt -> x < 0 | Le -> x <= 0 | Gt -> x > 0 | Ge -> x >= 0 |> fun r -> ignore y; r in
      match (ev a, ev b) with
      | VInt (s, x), VInt (_, y) -> VBool (c (if is_signed s then compare x y else Int64.unsigned_compare x y) 0)
      | VFloat (_, x), VFloat (_, y) ->
          VBool
            (match op with
             | Eq -> x = y | Ne -> x < y || x > y | Lt -> x < y | Le -> x <= y | Gt -> x > y | Ge -> x >= y)
      | VBool x, VBool y -> VBool (if op = Eq then x = y else x <> y)
      | _ -> trap loc "comparison operands")
  | Logic (conj, a, b) ->
      let x = as_bool loc (ev a) in
      VBool (if conj then x && as_bool loc (ev b) else x || as_bool loc (ev b))
  | Math (name, [ a ]) -> (
      match ev a with
      | VFloat (s, x) ->
          let f =
            match name with
            | "sqrt" -> Float.sqrt | "floor" -> Float.floor | "ceil" -> Float.ceil | "abs" -> Float.abs
            | "exp" -> Rake_math.exp | "log" -> Rake_math.log | "log2" -> Rake_math.log2 | "tanh" -> Rake_math.tanh
            | _ -> trap loc "math %s" name
          in
          float_value s (f x)
      | VInt (s, x) when name = "abs" -> VInt (s, if x < 0L then checked_arith loc Sub s 0L x else x)
      | _ -> trap loc "math operand")
  | Math _ -> trap loc "math arity"
  | Count_bits (kind, a) -> (
      match ev a with
      | VInt (s, x) ->
          let w = width s in
          let u = unsigned s x in
          let rec ones v n = if v = 0L then n else ones (Int64.logand v (Int64.sub v 1L)) (n + 1) in
          let r =
            match kind with
            | Popcnt -> ones u 0
            | Clz -> if u = 0L then w else let rec go b = if Int64.logand (Int64.shift_right_logical u b) 1L = 1L then w - 1 - b else go (b - 1) in go (w - 1)
            | Ctz -> if u = 0L then w else let rec go b = if Int64.logand (Int64.shift_right_logical u b) 1L = 1L then b else go (b + 1) in go 0
          in
          VInt (s, Int64.of_int r)
      | _ -> trap loc "count bits")
  | Call (name, args) -> call env loc name args
  | Extern_call (name, args) -> (
      let values = List.map ev args in
      match Hashtbl.find_opt env.machine.externs name with
      | Some f -> f values
      | None -> trap loc "extern %s has no implementation in this interpreter" name)
  | Vector_call (name, args) -> vector_call env loc name args
  | Field _ | Elem _ -> fst (place env e) ()
  | Convert (kind, target, a) -> convert loc kind target (ev a)
  | Cond (c, a, b) -> if as_bool loc (ev c) then ev a else ev b
  | Record_lit (name, fields) ->
      let r = find_record env.machine.program name in
      VRec (name, Array.of_list (List.map (fun (f, _) -> copy (ev (List.assoc f fields))) r.rfields))
  | Pack_lit (_, fields) -> VPack (List.map (fun (f, v) -> (f, ev v)) fields)
  | Array_lit items -> VArr (Array.of_list (List.map (fun i -> copy (ev i)) items))
  | Addr p -> (
      match p.k with
      | Elem (base, index, _) -> (
          match ev base with
          | VArr a -> VPtr { store = a; index = Int64.to_int (as_int loc (ev index)) }
          | VView v -> VPtr { store = v.store; index = v.start + Int64.to_int (as_int loc (ev index)) }
          | VPtr p -> VPtr { p with index = p.index + Int64.to_int (as_int loc (ev index)) }
          | _ -> trap loc "addr")
      | _ ->
          (* A pointer to a whole location: a one-element store holding it. *)
          let get, set = place env p in
          let store = [| get () |] in
          ignore set;
          VPtr { store; index = 0 })
  | Length a -> (match ev a with VArr x -> VInt (SInt, Int64.of_int (Array.length x)) | VView v -> VInt (SInt, Int64.of_int v.count) | _ -> trap loc "count")
  | Slice (base, start, count) -> (
      let s = Int64.to_int (as_int loc (ev start)) and n = Int64.to_int (as_int loc (ev count)) in
      let store, from, total =
        match ev base with
        | VArr a -> (a, 0, Array.length a)
        | VView v -> (v.store, v.start, v.count)
        | _ -> trap loc "slice"
      in
      if s < 0 || n < 0 || s > total - n then trap loc "slice [%d, %d) outside %d elements" s (s + n) total;
      VView { store; start = from + s; count = n })
  | Ptr_view (p, count) -> (
      match ev p with
      | VPtr { store; index } -> VView { store; start = index; count = Int64.to_int (as_int loc (ev count)) }
      | _ -> trap loc "unchecked_view of a null pointer")
  | Is_null p -> VBool (ev p = VNull)
  | Block (body, value) ->
      let inner = { env with vars = Hashtbl.copy env.vars } in
      exec_block inner body;
      (match value with None -> VUnit | Some value -> eval inner value)

and place env (e : expr) : (unit -> value) * (value -> unit) =
  let loc = e.loc in
  match e.k with
  | Var name | Global name ->
      let cell = lookup env loc name in
      ((fun () -> !cell), fun v -> cell := v)
  | Field (base, field) -> (
      let record =
        match eval env base with
        | VRec (n, fields) -> (n, fields)
        | VPtr { store; index } -> (
            match store.(index) with VRec (n, fields) -> (n, fields) | _ -> trap loc "field through a pointer")
        | _ -> trap loc "field of a non-record"
      in
      let name, fields = record in
      let i = field_index env name field in
      ((fun () -> fields.(i)), fun v -> fields.(i) <- v))
  | Elem (base, index, checked) ->
      let i = Int64.to_int (as_int loc (eval env index)) in
      let store, at, count =
        match eval env base with
        | VArr a -> (a, i, Array.length a)
        | VView v -> (v.store, v.start + i, v.count)
        | VPtr p -> (p.store, p.index + i, max_int)
        | _ -> trap loc "index of a non-array"
      in
      if checked && (i < 0 || i >= count) then trap loc "index %d outside %d elements" i count;
      if at < 0 || at >= Array.length store then trap loc "unchecked index %d outside its storage: outside Rake's defined semantics" i;
      ((fun () -> store.(at)), fun v -> store.(at) <- v)
  | _ -> trap loc "not a location"

and convert loc kind target v =
  match (kind, v) with
  | Ast.Convert_bitcast, VFloat (_, f) ->
      if target = SDouble || target = SInt64 || target = SUint64 then VInt (target, Int64.bits_of_float f)
      else VInt (target, normalise target (Int64.of_int32 (Int32.bits_of_float f)))
  | Convert_bitcast, VInt (_, x) ->
      if target = SFloat then VFloat (SFloat, Int32.float_of_bits (Int64.to_int32 x))
      else if target = SDouble then VFloat (SDouble, Int64.float_of_bits x)
      else VInt (target, normalise target x)
  | Convert_wrap, VInt (_, x) -> VInt (target, normalise target x)
  | Convert_checked, VInt (s, x) when is_float target -> float_value target (to_float target s x)
  | Convert_checked, VInt (s, x) ->
      if target = SBool then VBool (x <> 0L)
      else
        let value_in_range =
          if s = SUint64 && x < 0L then target = SUint64
          else if target = SUint64 then x >= 0L || s = SUint64
          else fits target x
        in
        if not value_in_range then trap loc "%Ld does not fit %s" x (string_of_ty (Sc target));
        VInt (target, x)
  | Convert_checked, VFloat (_, f) when is_float target -> float_value target f
  | Convert_checked, VFloat (_, f) ->
      let low, high =
        match target with
        | SInt8 -> (-129.0, 128.0) | SUint8 -> (-1.0, 256.0) | SInt16 -> (-32769.0, 32768.0) | SUint16 -> (-1.0, 65536.0)
        | SInt -> (-2147483904.0, 2147483648.0) | SUint -> (-1.0, 4294967296.0)
        | SInt64 -> (-9223373136366403584.0, 9223372036854775808.0) | _ -> (-1.0, 18446744073709551616.0)
      in
      if not (f > low && f < high) then trap loc "%g does not fit %s" f (string_of_ty (Sc target));
      let t = Float.trunc f in
      VInt (target, if target = SUint64 && t >= 9223372036854775808.0 then Int64.add (Int64.of_float (t -. 9223372036854775808.0)) Int64.min_int else Int64.of_float t)
  | Convert_checked, VBool b -> if target = SBool then VBool b else VInt (target, if b then 1L else 0L)
  | _ -> trap loc "conversion"

and call env loc name args =
  let f = List.find (fun f -> f.fname = name) env.machine.program.slows in
  let vars = Hashtbl.create 16 in
  List.iter2
    (fun p (a : expr) ->
      let v =
        match p.pass with
        | By_value -> eval env a
        | Borrow | Borrow_mut -> (
            (* The callee reads and writes the caller's location itself. *)
            match a.k with
            | Var _ | Global _ | Field _ | Elem _ -> fst (place env a) ()
            | _ -> eval env a)
      in
      Hashtbl.replace vars p.pname (ref v))
    f.fparams args;
  ignore loc;
  let inner = { env with vars } in
  try
    exec_block inner f.fbody;
    VUnit
  with Return_value v -> v

and exec_block env stmts = List.iter (exec env) stmts

and exec env (s : stmt) =
  match s.s with
  | Decl (name, _, Some v, _) -> Hashtbl.replace env.vars name (ref (copy (eval env v)))
  | Decl (name, ty, None, _) -> Hashtbl.replace env.vars name (ref (zero_of env ty))
  | Assign (target, v) ->
      let value = copy (eval env v) in
      (snd (place env target)) value
  | Eval e -> ignore (eval env e)
  | If (c, a, b) -> exec_block env (if as_bool s.sloc (eval env c) then a else b)
  | While (c, body) -> (
      try
        while as_bool s.sloc (eval env c) do
          try exec_block env body with Continue_loop -> ()
        done
      with Break_loop -> ())
  | For (name, sc, from, upto, by, body) -> (
      let start = as_int s.sloc (eval env from) and stop = as_int s.sloc (eval env upto) in
      let step = match by with Some b -> as_int s.sloc (eval env b) | None -> 1L in
      if step <= 0L then trap s.sloc "a loop steps forward";
      let less a b = if is_signed sc then compare a b < 0 else Int64.unsigned_compare a b < 0 in
      let i = ref start in
      try
        while less !i stop do
          Hashtbl.replace env.vars name (ref (VInt (sc, !i)));
          (try exec_block env body with Continue_loop -> ());
          (* As the emitted C: stop rather than step past the bound. *)
          if Int64.unsigned_compare (Int64.sub stop !i) step <= 0 && not (is_signed sc) then i := stop
          else if is_signed sc && Int64.sub stop !i <= step then i := stop
          else i := Int64.add !i step
        done
      with Break_loop -> ())
  | Break -> raise Break_loop
  | Continue -> raise Continue_loop
  | Return None -> raise (Return_value VUnit)
  | Return (Some v) -> raise (Return_value (eval env v))

(* ─── Runs ──────────────────────────────────────────────────────────── *)

and vector_call env loc name args =
  match List.find_opt (fun r -> r.run_name = name) env.machine.program.runs with
  | Some run -> run_call env loc run args
  | None ->
      (* A crunch with uniform parameters. *)
      let def =
        List.find (fun (d : Ast.def) -> match d.v with DCrunch (n, _, _, _) | DRake (n, _, _, _, _, _, _) -> n = name | _ -> false)
          env.machine.program.vector_defs
      in
      R.definitions := env.machine.program.vector_defs;
      let values = List.map (function Arg_uniform a | Arg_memory a -> to_reference (eval env a)) args in
      let result =
        match def.v with
        | DCrunch _ -> R.eval_crunch ~lanes:4 def values
        | _ -> R.eval_rake ~lanes:4 def values
      in
      (match result with
       | Ok v -> of_reference_scalar loc v
       | Error error -> trap loc "%s" (R.format_error error))

and to_reference = function
  | VFloat (_, f) -> R.F32_scalar f
  | VInt (s, v) -> R.Int_scalar (s, v)
  | VBool b -> R.Int_scalar (Types.SBool, if b then 1L else 0L)
  | VRack r -> r
  | _ -> R.F32_scalar 0.0

and of_reference_scalar loc = function
  | R.F32_scalar f -> VFloat (SFloat, f)
  | R.Int_scalar (s, v) -> if s = SBool then VBool (v <> 0L) else VInt (s, v)
  | R.U32_scalar v -> VInt (SUint, Int64.of_int v)
  | _ -> trap loc "a vector call returns a scalar"

and rack_of_elements element (values : value array) =
  match element with
  | Types.SFloat -> R.F32_rack (Array.map (function VFloat (_, f) -> f | _ -> 0.0) values)
  | _ ->
      R.int_rack element (Array.map (function VInt (_, v) -> v | VBool b -> if b then 1L else 0L | _ -> 0L) values)

and elements_of_rack element (rack : R.value) =
  match rack with
  | R.F32_rack xs -> Array.map (fun f -> VFloat (SFloat, f)) xs
  | other -> (
      match R.int_lanes other with
      | Some (_, xs) -> Array.map (fun v -> VInt (element, normalise element v)) xs
      | None -> [||])

and run_call env loc run args =
  let vars = Hashtbl.create 32 in
  let params = run.run_params in
  List.iteri
    (fun i a ->
      let v = match a with Arg_uniform e | Arg_memory e -> eval env e in
      match List.nth_opt params i with
      | Some (Run_pack (n, _, _) | Run_view (n, _, _) | Run_uniform (n, _) | Run_rack (n, _)) -> Hashtbl.replace vars n (ref v)
      | None -> Hashtbl.replace vars "$result" (ref v))
    args;
  let renv = { env with vars } in
  (* As the C boundary: each traversed column and the output hold the count. *)
  let rec outputs stmts =
    List.concat_map (fun s -> match s.r with R_output (o, _, _) -> [ o ] | R_for (_, _, _, _, b) | R_block b -> outputs b | R_if (_, a, b) -> outputs a @ outputs b | _ -> []) stmts
  in
  let rec traversals stmts =
    List.concat_map
      (fun s ->
        match s.r with
        | R_traverse t ->
            (match t.t_count.k with Var count -> (t.t_pack, count) :: List.map (fun o -> (o, count)) (outputs t.t_body) | _ -> [])
            @ traversals t.t_body
        | R_for (_, _, _, _, b) | R_block b -> traversals b
        | R_if (_, a, b) -> traversals a @ traversals b
        | _ -> [])
      stmts
  in
  List.iter
    (fun (pack, count) ->
      match (Hashtbl.find_opt vars pack, Hashtbl.find_opt vars count) with
      | Some { contents = VPack columns }, Some { contents = VInt (_, n) } ->
          let views = List.map snd columns @ (match Hashtbl.find_opt vars "$result" with Some r -> [ !r ] | None -> []) in
          List.iter (function VView v -> if n > Int64.of_int v.count then trap loc "run %s traverses %Ld records of %d" run.run_name n v.count | _ -> ()) views
      | _ -> ())
    (traversals run.run_body);
  exec_run renv loc run.run_body ~tail:None

(** The scope a run statement sees, as Native_reference values. *)
and reference_env renv =
  Hashtbl.fold
    (fun name cell acc ->
      match !cell with
      | VRack r -> (name, r) :: acc
      | VFloat (_, f) -> (name, R.F32_scalar f) :: acc
      | VInt (s, v) -> (name, R.Int_scalar (s, v)) :: acc
      | VBool b -> (name, R.Int_scalar (Types.SBool, if b then 1L else 0L)) :: acc
      | _ -> acc)
    renv.vars []

and exec_run renv loc stmts ~tail = List.iter (exec_rstmt renv ~tail) stmts |> fun () -> ignore loc; VUnit

and exec_rstmt renv ~tail (s : rstmt) =
  let loc = s.rloc in
  let set name v =
    Hashtbl.replace renv.vars name (ref v);
    match v with
    | VRack trace_value ->
        renv.machine.trace
          { trace_name = name; trace_loc = loc; trace_value; trace_active = tail }
    | _ -> ()
  in
  let view_of e = match eval renv e with VView v -> v | _ -> trap loc "a view" in
  match s.r with
  | R_uniform (name, e) -> set name (eval renv e)
  | R_pure (name, ty, pure, _) -> (
      R.definitions := renv.machine.program.vector_defs;
      match R.eval_expr ~lanes:4 (reference_env renv) pure with
      | Ok v -> (
          match ty with
          | Sc s -> set name (match of_reference_scalar loc v with VInt (_, x) -> VInt (s, normalise s x) | VFloat (_, f) -> VFloat (s, f) | other -> other)
          | Rack element -> (
              (* A uniform written where a rack is expected, as in out[<i>] <- <x>, is broadcast. *)
              match v with
              | R.F32_scalar f -> set name (VRack (R.splat 4 f))
              | R.Int_scalar (_, x) -> set name (VRack (R.splat_int element x))
              | R.U32_scalar x -> set name (VRack (R.splat_int element (Int64.of_int x)))
              | rack -> set name (VRack rack))
          | _ -> set name (VRack v))
      | Error error -> trap loc "%s" (R.format_error error))
  | R_load (name, element, view, index, checked) ->
      let v = view_of view and i = Int64.to_int (as_int loc (eval renv index)) in
      let n = lanes element in
      if checked && (i < 0 || i + n > v.count) then trap loc "rack load [%d, %d) outside %d elements" i (i + n) v.count;
      if v.start + i < 0 || v.start + i + n > Array.length v.store then trap loc "unchecked load outside its storage: outside Rake's defined semantics";
      set name (VRack (rack_of_elements element (Array.sub v.store (v.start + i) n)))
  | R_gather (name, element, view, indices, checked) ->
      let v = view_of view in
      let idx = match !(lookup renv loc indices) with VRack r -> (match R.int_lanes r with Some (_, xs) -> xs | None -> [||]) | _ -> [||] in
      (* In a traversal's tail only the active lanes are checked and read. *)
      let active = match tail with Some n -> n | None -> Array.length idx in
      if checked then Array.iteri (fun k i -> if k < active && (i < 0L || i >= Int64.of_int v.count) then trap loc "gather index %Ld outside %d elements" i v.count) idx;
      let zero = if is_float element then VFloat (element, 0.0) else VInt (element, 0L) in
      set name (VRack (rack_of_elements element (Array.mapi (fun k i -> if k < active then v.store.(v.start + Int64.to_int i) else zero) idx)))
  | R_location (name, _, first) -> set name !(lookup renv loc first)
  | R_set (name, value) -> (
      let next = !(lookup renv loc value) in
      match (tail, !(lookup renv loc name), next) with
      | Some active, VRack old, VRack fresh ->
          (* A tail updates only its active lanes. *)
          let blend o f =
            match (o, f) with
            | R.F32_rack os, R.F32_rack fs -> R.F32_rack (Array.mapi (fun i x -> if i < active then fs.(i) else x) os)
            | _ -> (
                match (R.int_lanes o, R.int_lanes f) with
                | Some (e, os), Some (_, fs) -> R.int_rack e (Array.mapi (fun i x -> if i < active then fs.(i) else x) os)
                | _ -> f)
          in
          let trace_value = blend old fresh in
          (lookup renv loc name) := VRack trace_value;
          renv.machine.trace
            { trace_name = name; trace_loc = loc; trace_value; trace_active = tail }
      | _ ->
          (lookup renv loc name) := next;
          (match next with
          | VRack trace_value ->
              renv.machine.trace
                { trace_name = name; trace_loc = loc; trace_value; trace_active = tail }
          | _ -> ()))
  | R_store (view, index, value, checked) ->
      let v = view_of view and i = Int64.to_int (as_int loc (eval renv index)) in
      let element = match view.ty with View (Sc e, _) -> e | _ -> SInt in
      let n = lanes element in
      if checked && (i < 0 || i + n > v.count) then trap loc "rack store [%d, %d) outside %d elements" i (i + n) v.count;
      (match !(lookup renv loc value) with
       | VRack r -> Array.iteri (fun k x -> v.store.(v.start + i + k) <- x) (elements_of_rack element r)
       | _ -> trap loc "store of a non-rack")
  | R_for (name, from, upto, by, body) ->
      let sc = scalar_of loc from.ty in
      let start = as_int loc (eval renv from) and stop = as_int loc (eval renv upto) in
      let step = match by with Some b -> as_int loc (eval renv b) | None -> 1L in
      if step <= 0L then trap loc "a loop steps forward";
      let i = ref start in
      while !i < stop do
        set name (VInt (sc, !i));
        List.iter (exec_rstmt renv ~tail) body;
        i := if Int64.sub stop !i <= step then stop else Int64.add !i step
      done
  | R_if (c, a, b) -> List.iter (exec_rstmt renv ~tail) (if as_bool loc (eval renv c) then a else b)
  | R_block body -> List.iter (exec_rstmt renv ~tail) body
  | R_slow e -> ignore (eval renv e)
  | R_traverse t ->
      let count = as_int loc (eval renv t.t_count) in
      (* A wasm32 traversal counts its records in 32 bits. *)
      if count > 0xFFFFFFFFL then trap loc "a traversal of %Ld records exceeds 2^32 - 1" count;
      if count > 0L then (
        let pack = match !(lookup renv loc t.t_pack) with VPack columns -> columns | _ -> trap loc "a pack" in
        let l = lanes t.t_domain in
        let stack = find_stack renv.machine.program t.t_stack in
        let i = ref 0 in
        while Int64.of_int !i < count do
          let active = min l (Int64.to_int count - !i) in
          set "$chunk_offset" (VInt (SInt, Int64.of_int !i));
          List.iter
            (fun st ->
              match st.r with
              | R_chunk_load (name, element, field, stored) ->
                  let column = match List.assoc_opt field pack with Some (VView v) -> v | _ -> trap loc "column %s" field in
                  let values =
                    Array.init l (fun k ->
                        if k < active then column.store.(column.start + !i + k)
                        else if is_float stored then VFloat (stored, 0.0) else VInt (stored, 0L))
                  in
                  let values = Array.map (function VInt (_, v) -> VInt (element, v) | VFloat (_, f) -> VFloat (element, f) | x -> x) values in
                  ignore stack;
                  set name (VRack (rack_of_elements element values))
              | R_yield value | R_output (_, _, value) ->
                  let out, element =
                    match st.r with
                    | R_output (output, field, _) -> (
                        match !(lookup renv loc output) with
                        | VPack columns -> (match List.assoc_opt field columns with Some (VView v) ->
                            (* The output pack may be another stack's: its column's own elements give the type. *)
                            let element = if v.count > 0 then (match v.store.(v.start) with VFloat (s, _) | VInt (s, _) -> s | _ -> t.t_domain) else t.t_domain in
                            (v, element) | _ -> trap loc "output column")
                        | _ -> trap loc "output pack")
                    | _ -> ((match !(lookup renv loc "$result") with VView v -> v | _ -> trap loc "the output view"), t.t_domain)
                  in
                  (match !(lookup renv loc value) with
                   | VRack r ->
                       let values = elements_of_rack element r in
                       for k = 0 to active - 1 do out.store.(out.start + !i + k) <- values.(k) done
                   | _ -> trap loc "yield of a non-rack")
              | _ ->
                  (* Nested in an outer tail, both prefix masks apply. *)
                  let own = if active < l then Some active else None in
                  let combined = match (tail, own) with Some o, Some a -> Some (min o a) | Some o, None -> Some o | None, own -> own in
                  exec_rstmt renv ~tail:combined st)
            t.t_body;
          i := !i + l
        done)
  | R_chunk_load _ | R_output _ | R_yield _ -> trap loc "a traversal statement outside its traversal"

(* ─── Programs ──────────────────────────────────────────────────────── *)

let machine ?(externs = Hashtbl.create 1) ?(trace = fun _ -> ())
    (program : program) =
  let m = { program; globals = Hashtbl.create 16; externs; trace } in
  let env = { machine = m; vars = Hashtbl.create 1 } in
  List.iter (fun (name, _, value) -> Hashtbl.replace m.globals name (ref (eval env value))) program.consts;
  List.iter
    (fun (name, contents) ->
      let store = Array.init (String.length contents) (fun i -> VInt (SUint8, Int64.of_int (Char.code contents.[i]))) in
      Hashtbl.replace m.globals name (ref (VView { store; start = 0; count = Array.length store })))
    program.embeds;
  List.iter
    (fun (name, ty, init) ->
      Hashtbl.replace m.globals name (ref (match init with Some v -> copy (eval env v) | None -> zero_of env ty)))
    program.states;
  m

(** Call a slow function with argument values. *)
let call_function m name (args : value list) =
  let f = List.find (fun f -> f.fname = name) m.program.slows in
  let vars = Hashtbl.create 16 in
  List.iter2 (fun p v -> Hashtbl.replace vars p.pname (ref v)) f.fparams args;
  let env = { machine = m; vars } in
  try
    exec_block env f.fbody;
    VUnit
  with Return_value v -> v

let run_main ?externs ?trace program =
  let m = machine ?externs ?trace program in
  if not (List.exists (fun f -> f.fname = "main") program.slows) then
    Error "the program has no slow main() -> i32 to run"
  else
    match call_function m "main" [] with
    | VInt (_, v) -> Ok v
    | _ -> Error "main returned no integer"
    | exception Trap (loc, message) -> Error (Printf.sprintf "%s:%d:%d: trap: %s" loc.file loc.line loc.col message)
