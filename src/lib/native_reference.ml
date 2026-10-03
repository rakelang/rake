(** Deterministic executable semantics for the initial native f32 rack slice.

    This module is deliberately independent of code generation.  Every
    arithmetic result is rounded back to IEEE-754 binary32 so that an OCaml
    host's binary64 arithmetic does not accidentally define Rake arithmetic. *)

open Ast

type value =
  | F32_scalar of float
  | F32_rack of float array
  | Mask of bool array
  | U8_rack of int array   (** lanes 0 to 255; four byte lanes per f32 lane *)
  | U32_scalar of int      (** 0 to 2^32 - 1, e.g. a bitmask result *)
  | I16_rack of int array  (** lanes -32768 to 32767; two per f32 lane *)
  | I32_rack of int array  (** lanes -2^31 to 2^31 - 1; one per f32 lane *)
  | I64_rack of int64 array  (** 64-bit two's complement lanes; one per two f32 lanes *)
  | Int_scalar of Types.scalar * int64  (** a uniform integer or bool, normalised to its type *)

type value_kind =
  | Scalar | Rack | Mask_kind | U8_rack_kind | U32_scalar_kind | I16_rack_kind | I32_rack_kind | I64_rack_kind
  | Int_scalar_kind

type error_kind =
  | Invalid_lane_count of int
  | Undefined_variable of ident
  | Expected_variable_kind of {
      name: ident;
      expected: value_kind;
      actual: value_kind;
    }
  | Lane_count_mismatch of { expected: int; actual: int }
  | Operand_kind_mismatch of {
      operation: string;
      left: value_kind;
      right: value_kind option;
    }
  | Wrong_arity of { operation: string; expected: int; actual: int }
  | Unsupported_expression of string
  | Unsupported_statement of string
  | Unsupported_definition of string
  | Argument_count_mismatch of { expected: int; actual: int }

type error = { kind: error_kind; loc: loc }

type env = (ident * value) list

let value_kind = function
  | F32_scalar _ -> Scalar
  | F32_rack _ -> Rack
  | Mask _ -> Mask_kind
  | U8_rack _ -> U8_rack_kind
  | U32_scalar _ -> U32_scalar_kind
  | I16_rack _ -> I16_rack_kind
  | I32_rack _ -> I32_rack_kind
  | I64_rack _ -> I64_rack_kind
  | Int_scalar _ -> Int_scalar_kind

let string_of_value_kind = function
  | Scalar -> "f32 scalar"
  | Rack -> "f32 rack"
  | Mask_kind -> "mask"
  | U8_rack_kind -> "u8 rack"
  | U32_scalar_kind -> "u32 scalar"
  | I16_rack_kind -> "i16 rack"
  | I32_rack_kind -> "i32 rack"
  | I64_rack_kind -> "i64 rack"
  | Int_scalar_kind -> "uniform integer"

let f32 x = Int32.float_of_bits (Int32.bits_of_float x)
let scalar x = F32_scalar (f32 x)
let rack xs = F32_rack (Array.map f32 xs)
let mask xs = Mask (Array.copy xs)

let error loc kind = Error { kind; loc }

let format_error { kind; loc } =
  let detail =
    match kind with
    | Invalid_lane_count lanes ->
        Printf.sprintf "lane count must be positive, got %d" lanes
    | Undefined_variable name -> Printf.sprintf "undefined variable: %s" name
    | Expected_variable_kind { name; expected; actual } ->
        Printf.sprintf "%s must be a %s, got %s" name
          (string_of_value_kind expected) (string_of_value_kind actual)
    | Lane_count_mismatch { expected; actual } ->
        Printf.sprintf "rack has %d lanes, expected %d" actual expected
    | Operand_kind_mismatch { operation; left; right = None } ->
        Printf.sprintf "%s does not accept %s" operation
          (string_of_value_kind left)
    | Operand_kind_mismatch { operation; left; right = Some right } ->
        Printf.sprintf "%s does not accept %s and %s" operation
          (string_of_value_kind left) (string_of_value_kind right)
    | Wrong_arity { operation; expected; actual } ->
        Printf.sprintf "%s expects %d operands, got %d" operation expected actual
    | Unsupported_expression shape ->
        Printf.sprintf "unsupported semantic expression: %s" shape
    | Unsupported_statement shape ->
        Printf.sprintf "unsupported semantic statement: %s" shape
    | Unsupported_definition shape ->
        Printf.sprintf "unsupported semantic definition: %s" shape
    | Argument_count_mismatch { expected; actual } ->
        Printf.sprintf "scratch expects %d arguments, got %d" expected actual
  in
  Printf.sprintf "%s:%d:%d: %s" loc.file loc.line loc.col detail

let ( let* ) = Result.bind

let validate_width loc lanes = function
  | F32_scalar _ as value -> Ok value
  | F32_rack xs as value ->
      let actual = Array.length xs in
      if actual = lanes then Ok value
      else error loc (Lane_count_mismatch { expected = lanes; actual })
  | Mask xs as value ->
      (* A mask has one lane per lane of the racks compared to make it. *)
      let actual = Array.length xs in
      if actual = lanes || actual = 4 * lanes || actual = 2 * lanes || 2 * actual = lanes then Ok value
      else error loc (Lane_count_mismatch { expected = lanes; actual })
  | U8_rack xs as value ->
      let actual = Array.length xs in
      if actual = 4 * lanes then Ok value
      else error loc (Lane_count_mismatch { expected = 4 * lanes; actual })
  | U32_scalar _ as value -> Ok value
  | Int_scalar _ as value -> Ok value
  | I16_rack xs as value ->
      let actual = Array.length xs in
      if actual = 2 * lanes then Ok value
      else error loc (Lane_count_mismatch { expected = 2 * lanes; actual })
  | I32_rack xs as value ->
      let actual = Array.length xs in
      if actual = lanes then Ok value
      else error loc (Lane_count_mismatch { expected = lanes; actual })
  | I64_rack xs as value ->
      let actual = Array.length xs in
      if 2 * actual = lanes then Ok value
      else error loc (Lane_count_mismatch { expected = lanes / 2; actual })

(** Two's-complement wrapping to 16 and 32 bits. *)
let wrap16 x = ((x + 0x8000) land 0xffff) - 0x8000
let wrap32 x = Int32.to_int (Int32.of_int x)
let saturate low high x = if x < low then low else if x > high then high else x

(** Rounds a binary32 value to the nearest integer, ties to even, saturated to
    i32; NaN becomes zero, as WebAssembly's nearest then trunc_sat. *)
let nearest_i32 x =
  if Float.is_nan x then 0
  else
    let floor = Float.of_int (int_of_float (Float.round (x -. 0.5))) in
    let nearest =
      if x -. floor > 0.5 then floor +. 1.0
      else if x -. floor < 0.5 then floor
      else if Float.rem floor 2.0 = 0.0 then floor
      else floor +. 1.0
    in
    if nearest >= 2147483647.0 then 2147483647
    else if nearest <= -2147483648.0 then -2147483648
    else int_of_float nearest

let normalize_value = function
  | F32_scalar x -> scalar x
  | F32_rack xs -> rack xs
  | Mask xs -> mask xs
  | U8_rack xs -> U8_rack (Array.map (fun x -> x land 0xff) xs)
  | U32_scalar x -> U32_scalar (Int64.to_int (Int64.logand (Int64.of_int x) 0xffffffffL))
  | I16_rack xs -> I16_rack (Array.map wrap16 xs)
  | I32_rack xs -> I32_rack (Array.map wrap32 xs)
  | I64_rack xs -> I64_rack (Array.copy xs)
  | Int_scalar (s, v) -> Int_scalar (s, v)

let lookup loc lanes env name =
  match List.assoc_opt name env with
  | None -> error loc (Undefined_variable name)
  | Some value -> validate_width loc lanes (normalize_value value)

let splat lanes x = F32_rack (Array.make lanes (f32 x))

let as_rack loc lanes operation = function
  | F32_scalar x -> Ok (Array.make lanes x)
  | F32_rack xs ->
      let* value = validate_width loc lanes (F32_rack xs) in
      (match value with F32_rack ys -> Ok ys | _ -> assert false)
  | (Mask _ | U8_rack _ | U32_scalar _ | I16_rack _ | I32_rack _ | I64_rack _ | Int_scalar _) as value ->
      error loc
        (Operand_kind_mismatch {
           operation;
           left = value_kind value;
           right = None;
         })

let unary_f32 loc lanes operation f value =
  match value with
  | F32_scalar x -> Ok (F32_scalar (f32 (f x)))
  | F32_rack xs ->
      let* xs = as_rack loc lanes operation (F32_rack xs) in
      Ok (F32_rack (Array.map (fun x -> f32 (f x)) xs))
  | (Mask _ | U8_rack _ | U32_scalar _ | I16_rack _ | I32_rack _ | I64_rack _ | Int_scalar _) as value ->
      error loc
        (Operand_kind_mismatch {
           operation;
           left = value_kind value;
           right = None;
         })

let binary_f32 loc lanes operation f left right =
  match left, right with
  | F32_scalar x, F32_scalar y -> Ok (F32_scalar (f32 (f x y)))
  | (F32_scalar _ | F32_rack _), (F32_scalar _ | F32_rack _) ->
      let* xs = as_rack loc lanes operation left in
      let* ys = as_rack loc lanes operation right in
      Ok (F32_rack (Array.init lanes (fun i -> f32 (f xs.(i) ys.(i)))))
  | _ ->
      error loc
        (Operand_kind_mismatch {
           operation;
           left = value_kind left;
           right = Some (value_kind right);
         })

let compare_f32 loc lanes operation predicate left right =
  let ordered predicate x y =
    (not (Float.is_nan x || Float.is_nan y)) && predicate x y
  in
  match left, right with
  | F32_scalar x, F32_scalar y ->
      Ok (Mask (Array.make lanes (ordered predicate x y)))
  | (F32_scalar _ | F32_rack _), (F32_scalar _ | F32_rack _) ->
      let* xs = as_rack loc lanes operation left in
      let* ys = as_rack loc lanes operation right in
      Ok (Mask (Array.init lanes (fun i -> ordered predicate xs.(i) ys.(i))))
  | _ ->
      error loc
        (Operand_kind_mismatch {
           operation;
           left = value_kind left;
           right = Some (value_kind right);
         })

let mask_binary loc lanes operation f left right =
  match left, right with
  | Mask xs, Mask ys ->
      let* _ = validate_width loc lanes left in
      let* _ = validate_width loc lanes right in
      if Array.length xs <> Array.length ys then
        error loc (Lane_count_mismatch { expected = Array.length xs; actual = Array.length ys })
      else Ok (Mask (Array.map2 f xs ys))
  | _ ->
      error loc
        (Operand_kind_mismatch {
           operation;
           left = value_kind left;
           right = Some (value_kind right);
         })

let select ~loc ~lanes condition if_true if_false =
  let operation = "select" in
  match condition with
  | Mask conditions ->
      let* _ = validate_width loc lanes condition in
      let* trues = as_rack loc lanes operation if_true in
      let* falses = as_rack loc lanes operation if_false in
      Ok
        (F32_rack
           (Array.init lanes (fun i ->
                f32 (if conditions.(i) then trues.(i) else falses.(i)))))
  | value ->
      error loc
        (Operand_kind_mismatch {
           operation;
           left = value_kind value;
           right = None;
         })

let ternary_fma loc lanes a b c =
  match a, b, c with
  | F32_scalar x, F32_scalar y, F32_scalar z ->
      Ok (F32_scalar (f32 (Float.fma x y z)))
  | (F32_scalar _ | F32_rack _),
    (F32_scalar _ | F32_rack _),
    (F32_scalar _ | F32_rack _) ->
      let* xs = as_rack loc lanes "fma" a in
      let* ys = as_rack loc lanes "fma" b in
      let* zs = as_rack loc lanes "fma" c in
      Ok
        (F32_rack
           (Array.init lanes (fun i -> f32 (Float.fma xs.(i) ys.(i) zs.(i)))))
  | _ ->
      error loc
        (Operand_kind_mismatch {
           operation = "fma";
           left = value_kind a;
           right = Some (value_kind b);
         })

let canonical_nan = Int32.float_of_bits 0x7fc00000l

let strict_minimum left right =
  if Float.is_nan left || Float.is_nan right then canonical_nan
  else if left = 0.0 && right = 0.0 then
    Int32.float_of_bits
      (Int32.logor (Int32.bits_of_float left) (Int32.bits_of_float right))
  else if left <= right then left
  else right

let strict_maximum left right =
  if Float.is_nan left || Float.is_nan right then canonical_nan
  else if left = 0.0 && right = 0.0 then
    Int32.float_of_bits
      (Int32.logand (Int32.bits_of_float left) (Int32.bits_of_float right))
  else if left >= right then left
  else right

let reduction_step = function
  | RAdd -> ( +. )
  | RMul -> ( *. )
  | RMin -> strict_minimum
  | RMax -> strict_maximum
  | RAnd | ROr -> invalid_arg "logical reduction is not an f32 operation"

let eval_f32_reduction loc operation = function
  | F32_rack values when Array.length values > 0 ->
      let step = reduction_step operation in
      let result = ref values.(0) in
      for lane = 1 to Array.length values - 1 do
        result := f32 (step !result values.(lane))
      done;
      Ok (F32_scalar !result)
  | value ->
      error loc
        (Operand_kind_mismatch {
           operation = "f32 reduction";
           left = value_kind value;
           right = None;
         })

let eval_f32_scan loc operation = function
  | F32_rack values when Array.length values > 0 ->
      let step = reduction_step operation in
      let prefixes = Array.copy values in
      for lane = 1 to Array.length prefixes - 1 do
        prefixes.(lane) <- f32 (step prefixes.(lane - 1) values.(lane))
      done;
      Ok (F32_rack prefixes)
  | value ->
      error loc
        (Operand_kind_mismatch {
           operation = "f32 prefix scan";
           left = value_kind value;
           right = None;
         })

let integer_literal (expr : expr) =
  match expr.v with
  | EInt value | EBroadcast { v = EInt value; _ } -> Some (Int64.to_int value)
  | _ -> None

let u8_predicate = function
  | Lt -> Some ( < ) | Le -> Some ( <= ) | Gt -> Some ( > ) | Ge -> Some ( >= )
  | Eq -> Some ( = ) | Ne -> Some ( <> )
  | Add | Sub | Mul | Div | Mod | And | Or | Pipe | Shl | Shr | Rol | Ror | Interleave -> None

let compare_u8 loc operation predicate left right =
  match left, right with
  | U8_rack xs, U8_rack ys when Array.length xs = Array.length ys ->
      Ok (Mask (Array.map2 predicate xs ys))
  | _ ->
      error loc
        (Operand_kind_mismatch {
           operation;
           left = value_kind left;
           right = Some (value_kind right);
         })

(** Lane [i] of the result is lane [indices.(i)] of the racks laid end to end. *)
let shuffle_racks loc racks indices =
  let concatenated_f32 = List.filter_map (function F32_rack xs -> Some xs | _ -> None) racks in
  let concatenated_u8 = List.filter_map (function U8_rack xs -> Some xs | _ -> None) racks in
  let pick source lanes make =
    if List.length indices <> lanes then
      error loc (Lane_count_mismatch { expected = lanes; actual = List.length indices })
    else if List.exists (fun index -> index < 0 || index >= Array.length source) indices then
      error loc (Unsupported_expression "shuffle index outside its racks")
    else Ok (make (Array.of_list (List.map (fun index -> source.(index)) indices)))
  in
  match racks with
  | [] -> error loc (Unsupported_expression "shuffle of no racks")
  | first :: _ when List.length concatenated_f32 = List.length racks ->
      let lanes = match first with F32_rack xs -> Array.length xs | _ -> 0 in
      pick (Array.concat concatenated_f32) lanes (fun xs -> F32_rack xs)
  | first :: _ when List.length concatenated_u8 = List.length racks ->
      let lanes = match first with U8_rack xs -> Array.length xs | _ -> 0 in
      pick (Array.concat concatenated_u8) lanes (fun xs -> U8_rack xs)
  | first :: _ ->
      error loc
        (Operand_kind_mismatch { operation = "shuffle"; left = value_kind first; right = None })

(* ─── Integer racks of every width, bit reinterpretation and literals ── *)

(** The callable scratches and rakes, for inlined calls. *)
let definitions : def list ref = ref []

let eval_scratch_ref : (lanes:int -> def -> value list -> (value, error) result) ref =
  ref (fun ~lanes:_ (d : def) _ -> error d.loc (Unsupported_definition "inline call"))

let eval_rake_ref : (lanes:int -> def -> value list -> (value, error) result) ref =
  ref (fun ~lanes:_ (d : def) _ -> error d.loc (Unsupported_definition "inline call"))

let int_lanes = function
  | U8_rack xs -> Some (Types.SUint8, Array.map Int64.of_int xs)
  | I16_rack xs -> Some (Types.SInt16, Array.map Int64.of_int xs)
  | I32_rack xs -> Some (Types.SInt, Array.map Int64.of_int xs)
  | I64_rack xs -> Some (Types.SInt64, Array.copy xs)
  | _ -> None

let int_rack element xs =
  match element with
  | Types.SUint8 | SInt8 -> U8_rack (Array.map (fun x -> Int64.to_int x land 0xff) xs)
  | SInt16 | SUint16 -> I16_rack (Array.map (fun x -> wrap16 (Int64.to_int (Int64.logand x 0xffffL))) xs)
  | SInt | SUint -> I32_rack (Array.map (fun x -> wrap32 (Int64.to_int (Int64.logand x 0xffffffffL))) xs)
  | _ -> I64_rack xs

let element_lanes = function
  | Types.SUint8 | SInt8 -> 16 | SInt16 | SUint16 -> 8 | SInt64 | SUint64 | SDouble -> 2 | _ -> 4

let splat_int element value = int_rack element (Array.make (element_lanes element) value)

(** A normalised uniform integer of type [s]. *)
let int_scalar s value =
  let open Int64 in
  let bits = match s with Types.SInt8 | SUint8 -> 8 | SInt16 | SUint16 -> 16 | SInt | SUint -> 32 | SBool -> 1 | _ -> 64 in
  if bits = 64 then Int_scalar (s, value)
  else
    let m = sub (shift_left 1L bits) 1L in
    let low = logand value m in
    let signed = match s with Types.SInt8 | SInt16 | SInt -> true | _ -> false in
    Int_scalar (s, if signed && logand low (shift_left 1L (bits - 1)) <> 0L then sub low (shift_left 1L bits) else low)

(** The 16 bytes of a rack or mask, little-endian. *)
let rack_bytes = function
  | F32_rack xs ->
      Some (Array.init 16 (fun i -> Int32.to_int (Int32.logand (Int32.shift_right_logical (Int32.bits_of_float xs.(i / 4)) (8 * (i mod 4))) 0xffl)))
  | Mask ms ->
      let width = 16 / Array.length ms in
      Some (Array.init 16 (fun i -> if ms.(i / width) then 0xff else 0))
  | value -> (
      match int_lanes value with
      | Some (element, xs) ->
          let width = 16 / element_lanes element in
          Some (Array.init 16 (fun i -> Int64.to_int (Int64.logand (Int64.shift_right_logical xs.(i / width) (8 * (i mod width))) 0xffL)))
      | None -> None)

let rack_of_bytes element bytes =
  match element with
  | Types.SFloat ->
      F32_rack
        (Array.init 4 (fun lane ->
             let word = ref 0l in
             for b = 3 downto 0 do
               word := Int32.logor (Int32.shift_left !word 8) (Int32.of_int bytes.((lane * 4) + b))
             done;
             Int32.float_of_bits !word))
  | _ ->
      let lanes = element_lanes element in
      let width = 16 / lanes in
      int_rack element
        (Array.init lanes (fun lane ->
             let v = ref 0L in
             for b = width - 1 downto 0 do
               v := Int64.logor (Int64.shift_left !v 8) (Int64.of_int bytes.((lane * width) + b))
             done;
             (* Sign-extend from the lane width before wrapping. *)
             if width < 8 && Int64.logand !v (Int64.shift_left 1L ((8 * width) - 1)) <> 0L then
               Int64.sub !v (Int64.shift_left 1L (8 * width))
             else !v))

(** A literal typed by the value it meets. *)
let typed_literal_value other value =
  match other with
  | F32_rack xs -> Some (F32_rack (Array.make (Array.length xs) (f32 (Int64.to_float value))))
  | F32_scalar _ -> Some (F32_scalar (f32 (Int64.to_float value)))
  | Int_scalar (s, _) -> Some (int_scalar s value)
  | other -> (match int_lanes other with Some (element, _) -> Some (splat_int element value) | None -> None)

(** A uniform integer broadcast to the integer rack beside it. *)
let broadcast_to other value =
  match (value, int_lanes other) with
  | Int_scalar (_, v), Some (element, _) -> splat_int element v
  | U32_scalar v, Some (element, _) -> splat_int element (Int64.of_int v)
  | _ -> value

let round_half_even x =
  if Float.is_nan x || Float.is_integer x then x
  else
    let floor = Float.floor x in
    let diff = x -. floor in
    let rounded =
      if diff > 0.5 then floor +. 1.0
      else if diff < 0.5 then floor
      else if Float.rem floor 2.0 = 0.0 then floor
      else floor +. 1.0 in
    if rounded = 0.0 then Float.copy_sign rounded x else rounded

let rec eval_expr ~lanes env (expr : expr) =
  if lanes <= 0 then error expr.loc (Invalid_lane_count lanes)
  else
    match expr.v with
    | EInt value | EBroadcast { v = EInt value; _ } -> Ok (splat_int Types.SInt value)
    | EScalarVar name when (match List.assoc_opt name env with Some (Int_scalar _ | U32_scalar _) -> true | _ -> false) ->
        Ok (List.assoc name env)
    | EBroadcast { v = EScalarVar name; _ } when (match List.assoc_opt name env with Some (Int_scalar _ | U32_scalar _) -> true | _ -> false) ->
        Ok (List.assoc name env)
    | EBinop (left_expr, ((Add | Sub | Mul | Lt | Le | Gt | Ge | Eq | Ne) as op), right_expr)
      when is_integer_operation ~lanes env left_expr right_expr ->
        let* left, right = operands ~lanes env left_expr right_expr in
        let left = broadcast_to right left and right = broadcast_to left right in
        (match (int_lanes left, int_lanes right) with
         | Some (element, xs), Some (_, ys) when Array.length xs = Array.length ys -> (
             match op with
             | Add | Sub | Mul ->
                 let f = match op with Add -> Int64.add | Sub -> Int64.sub | _ -> Int64.mul in
                 Ok (int_rack element (Array.map2 f xs ys))
             | _ ->
                 let p = match op with
                   | Lt -> ( < ) | Le -> ( <= ) | Gt -> ( > ) | Ge -> ( >= ) | Eq -> ( = ) | _ -> ( <> ) in
                 Ok (Mask (Array.map2 (fun x y -> p (Int64.compare x y) 0) xs ys)))
         | _ -> error expr.loc (Operand_kind_mismatch { operation = Ast.show_binop op; left = value_kind left; right = Some (value_kind right) }))
    | EBinop (left_expr, ((Add | Sub | Mul | Div | Lt | Le | Gt | Ge | Eq | Ne) as op), right_expr)
      when (integer_literal left_expr <> None) <> (integer_literal right_expr <> None) ->
        (* An integer literal beside an f32 rack is an f32 constant. *)
        let* left, right = operands ~lanes env left_expr right_expr in
        (match op with
         | Add -> binary_f32 expr.loc lanes "add" ( +. ) left right
         | Sub -> binary_f32 expr.loc lanes "sub" ( -. ) left right
         | Mul -> binary_f32 expr.loc lanes "mul" ( *. ) left right
         | Div -> binary_f32 expr.loc lanes "div" ( /. ) left right
         | Lt -> compare_f32 expr.loc lanes "lt" ( < ) left right
         | Le -> compare_f32 expr.loc lanes "le" ( <= ) left right
         | Gt -> compare_f32 expr.loc lanes "gt" ( > ) left right
         | Ge -> compare_f32 expr.loc lanes "ge" ( >= ) left right
         | Eq -> compare_f32 expr.loc lanes "eq" Float.equal left right
         | _ -> compare_f32 expr.loc lanes "ne" (fun x y -> not (Float.equal x y)) left right)
    | EUnop ((Neg | FNeg), inner) when (match eval_expr ~lanes env inner with Ok v -> int_lanes v <> None | _ -> false) ->
        let* value = eval_expr ~lanes env inner in
        let element, xs = Option.get (int_lanes value) in
        Ok (int_rack element (Array.map Int64.neg xs))
    | ECall ("abs", [ inner ]) when (match eval_expr ~lanes env inner with Ok v -> int_lanes v <> None | _ -> false) ->
        let* value = eval_expr ~lanes env inner in
        let element, xs = Option.get (int_lanes value) in
        Ok (int_rack element (Array.map Int64.abs xs))
    | ECall (("relaxed_madd" | "relaxed_nmadd") as name, [ a; b; c ]) ->
        (* Either rounding is the instruction's; the interpreter rounds the product and the sum. *)
        let* a = eval_expr ~lanes env a in
        let* b = eval_expr ~lanes env b in
        let* c = eval_expr ~lanes env c in
        let* product = binary_f32 expr.loc lanes "mul" ( *. ) a b in
        let* product = if name = "relaxed_nmadd" then unary_f32 expr.loc lanes "neg" Float.neg product else Ok product in
        binary_f32 expr.loc lanes "add" ( +. ) product c
    | ECall (("relaxed_min" | "relaxed_max") as name, [ a; b ]) ->
        let* a = eval_expr ~lanes env a in
        let* b = eval_expr ~lanes env b in
        binary_f32 expr.loc lanes name (if name = "relaxed_min" then Float.min else Float.max) a b
    | ECall (("abs" | "floor" | "ceil" | "trunc" | "nearest" | "exp" | "log" | "log2" | "tanh") as name, [ inner ]) ->
        let* value = eval_expr ~lanes env inner in
        let f =
          match name with
          | "abs" -> Float.abs | "floor" -> Float.floor | "ceil" -> Float.ceil | "trunc" -> Float.trunc
          | "nearest" -> round_half_even | "exp" -> Rake_math.exp | "log" -> Rake_math.log
          | "log2" -> Rake_math.log2 | _ -> Rake_math.tanh
        in
        unary_f32 expr.loc lanes name f value
    | ECall ("select", [ condition; if_true; if_false ])
      when (match eval_expr ~lanes env if_true with Ok v -> int_lanes v <> None | _ -> false) ->
        eval_expr ~lanes env { expr with v = EIf (condition, if_true, if_false) }
    | EIf (condition, if_true, if_false) -> (
        let* c = eval_expr ~lanes env condition in
        match c with
        | Int_scalar (_, v) -> eval_expr ~lanes env (if v <> 0L then if_true else if_false)
        | Mask ms ->
            let* a, b = operands ~lanes env if_true if_false in
            (match (a, b) with
             | F32_rack xs, F32_rack ys -> Ok (F32_rack (Array.mapi (fun i x -> if ms.(i) then x else ys.(i)) xs))
             | Mask xs, Mask ys -> Ok (Mask (Array.mapi (fun i x -> if ms.(i mod Array.length ms) then x else ys.(i)) xs))
             | _ -> (
                 match (int_lanes a, int_lanes b) with
                 | Some (element, xs), Some (_, ys) ->
                     (* A mask from a comparison of other lanes selects each byte group it covers. *)
                     let ratio = Array.length xs / Array.length ms in
                     let ratio = max 1 ratio in
                     Ok (int_rack element (Array.mapi (fun i x -> if ms.(min (Array.length ms - 1) (i / ratio)) then x else ys.(i)) xs))
                 | _ -> error expr.loc (Operand_kind_mismatch { operation = "if"; left = value_kind a; right = Some (value_kind b) })))
        | value -> error expr.loc (Operand_kind_mismatch { operation = "if"; left = value_kind value; right = None }))
    | EExtract (rack_expr, lane_expr) -> (
        let* r = eval_expr ~lanes env rack_expr in
        match (integer_literal lane_expr, r) with
        | Some lane, F32_rack xs -> Ok (F32_scalar xs.(lane))
        | Some lane, value -> (
            match int_lanes value with
            | Some (element, xs) -> Ok (int_scalar element xs.(lane))
            | None -> error expr.loc (Operand_kind_mismatch { operation = "extract"; left = value_kind value; right = None }))
        | None, _ -> error lane_expr.loc (Unsupported_expression "a lane is chosen by an integer literal"))
    | EInsert (rack_expr, lane_expr, value_expr) -> (
        let* r = eval_expr ~lanes env rack_expr in
        let* v =
          match integer_literal value_expr with
          | Some n ->
              let n = Int64.of_int n in
              Ok (Option.value (typed_literal_value (match r with F32_rack _ -> F32_scalar 0.0 | _ -> Int_scalar (Types.SInt64, 0L)) n) ~default:(Int_scalar (Types.SInt64, n)))
          | None -> eval_expr ~lanes env value_expr
        in
        match (integer_literal lane_expr, r, v) with
        | Some lane, F32_rack xs, F32_scalar x -> let ys = Array.copy xs in ys.(lane) <- x; Ok (F32_rack ys)
        | Some lane, F32_rack xs, F32_rack x -> let ys = Array.copy xs in ys.(lane) <- x.(0); Ok (F32_rack ys)
        | Some lane, value, Int_scalar (_, x) -> (
            match int_lanes value with
            | Some (element, xs) -> let ys = Array.copy xs in ys.(lane) <- x; Ok (int_rack element ys)
            | None -> error expr.loc (Operand_kind_mismatch { operation = "insert"; left = value_kind value; right = None }))
        | _ -> error expr.loc (Operand_kind_mismatch { operation = "insert"; left = value_kind r; right = Some (value_kind v) }))
    | EConvert (Convert_bitcast, { v = TRack prim; _ }, inner) -> (
        let* value = eval_expr ~lanes env inner in
        let element = Types.of_prim prim in
        (* A uniform operand is broadcast in its own type first. *)
        let value =
          match value with
          | F32_scalar x -> F32_rack (Array.make 4 x)
          | Int_scalar (s, v) -> splat_int s v
          | U32_scalar v -> splat_int Types.SUint (Int64.of_int v)
          | v -> v
        in
        match rack_bytes value with
        | Some bytes -> Ok (rack_of_bytes element bytes)
        | None -> error expr.loc (Operand_kind_mismatch { operation = "bitcast"; left = value_kind value; right = None }))
    | EReduce (((RAnd | ROr) as operation), operand) -> (
        let* value = eval_expr ~lanes env operand in
        match value with
        | Mask ms ->
            let all = Array.for_all Fun.id ms and any = Array.exists Fun.id ms in
            Ok (Int_scalar (Types.SBool, if (if operation = RAnd then all else any) then 1L else 0L))
        | value -> error expr.loc (Operand_kind_mismatch { operation = "mask reduction"; left = value_kind value; right = None }))
    | ECall (name, arguments) when List.exists (fun (d : def) -> match d.v with DScratch (n, _, _, _) | DRake (n, _, _, _, _, _, _) -> n = name | _ -> false) !definitions ->
        let definition = List.find (fun (d : def) -> match d.v with DScratch (n, _, _, _) | DRake (n, _, _, _, _, _, _) -> n = name | _ -> false) !definitions in
        let* values =
          List.fold_right (fun a acc -> let* rest = acc in let* v = eval_expr ~lanes env a in Ok (v :: rest)) arguments (Ok [])
        in
        (* A uniform passed to a rack parameter is broadcast at the call. *)
        let parameters = match definition.v with DScratch (_, ps, _, _) | DRake (_, ps, _, _, _, _, _) -> ps | _ -> [] in
        let values =
          List.map2
            (fun parameter value ->
              match (parameter, value) with
              | PRack (_, Some { v = TRack p; _ }), F32_scalar x when Types.of_prim p = Types.SFloat -> F32_rack (Array.make lanes x)
              | PRack (_, Some { v = TRack p; _ }), Int_scalar (_, x) -> splat_int (Types.of_prim p) x
              | PRack (_, Some { v = TRack p; _ }), U32_scalar x -> splat_int (Types.of_prim p) (Int64.of_int x)
              (* A marked uniform evaluates as a splat here; a scalar parameter takes one lane. *)
              | PScalar _, F32_rack xs when Array.length xs > 0 -> F32_scalar xs.(0)
              | PScalar _, value when (match int_lanes value with Some (_, xs) -> Array.length xs > 0 | None -> false) ->
                  (match int_lanes value with Some (element, xs) -> int_scalar element xs.(0) | None -> value)
              | _ -> value)
            parameters values
        in
        (match definition.v with
         | DScratch _ -> !eval_scratch_ref ~lanes definition values
         | _ -> !eval_rake_ref ~lanes definition values)
    | EFloat value -> Ok (splat lanes value)
    | EBool value -> Ok (Mask (Array.make lanes value))
    | EVar name ->
        let* value = lookup expr.loc lanes env name in
        (match value with
         | F32_rack _ | Mask _ | U8_rack _ | I16_rack _ | I32_rack _ | I64_rack _ -> Ok value
         | U32_scalar _ | Int_scalar _ ->
             error expr.loc
               (Expected_variable_kind {
                  name;
                  expected = Rack;
                  actual = U32_scalar_kind;
                })
         | F32_scalar _ ->
             error expr.loc
               (Expected_variable_kind {
                  name;
                  expected = Rack;
                  actual = Scalar;
                }))
    | EScalarVar name ->
        let* value = lookup expr.loc lanes env name in
        (match value with
         | F32_scalar _ -> Ok value
         | value ->
             error expr.loc
               (Expected_variable_kind {
                  name;
                  expected = Scalar;
                  actual = value_kind value;
                }))
    | EBroadcast inner ->
        let* value = eval_expr ~lanes env inner in
        (match value with
         | F32_scalar value -> Ok (splat lanes value)
         | F32_rack _ as value -> Ok value
         | (Mask _ | U8_rack _ | U32_scalar _ | I16_rack _ | I32_rack _ | I64_rack _ | Int_scalar _) as value ->
             error expr.loc
               (Operand_kind_mismatch {
                  operation = "broadcast";
                  left = value_kind value;
                  right = None;
                }))
    | EUnop ((Neg | FNeg), inner) ->
        let* value = eval_expr ~lanes env inner in
        unary_f32 expr.loc lanes "negate" Float.neg value
    | EUnop (Not, inner) ->
        let* value = eval_expr ~lanes env inner in
        (match value with
         | Mask xs ->
             let* _ = validate_width expr.loc lanes value in
             Ok (Mask (Array.map not xs))
         | value ->
             error expr.loc
               (Operand_kind_mismatch {
                  operation = "not";
                  left = value_kind value;
                  right = None;
                }))
    | EBinop (left_expr, ((Add | Sub) as op), right_expr)
      when (match eval_expr ~lanes env left_expr with Ok (I16_rack _ | I32_rack _) -> true | _ -> false) ->
        let* left = eval_expr ~lanes env left_expr in
        let* right = eval_expr ~lanes env right_expr in
        let f = if op = Add then ( + ) else ( - ) in
        (match (left, right) with
         | I16_rack xs, I16_rack ys when Array.length xs = Array.length ys -> Ok (I16_rack (Array.map2 (fun x y -> wrap16 (f x y)) xs ys))
         | I32_rack xs, I32_rack ys when Array.length xs = Array.length ys -> Ok (I32_rack (Array.map2 (fun x y -> wrap32 (f x y)) xs ys))
         | _ -> error expr.loc (Operand_kind_mismatch { operation = Ast.show_binop op; left = value_kind left; right = Some (value_kind right) }))
    | ECall (("min" | "max") as name, [ a; b ])
      when integer_literal a <> None || integer_literal b <> None
           || (match eval_expr ~lanes env a with Ok (U8_rack _ | I16_rack _ | I32_rack _ | F32_rack _) -> true | _ -> false) ->
        let literal_first = integer_literal a <> None in
        let rack_expr, other_expr = if literal_first then (b, a) else (a, b) in
        let* rack = eval_expr ~lanes env rack_expr in
        let* other =
          match (integer_literal other_expr, rack) with
          | Some value, U8_rack xs -> Ok (U8_rack (Array.make (Array.length xs) value))
          | Some value, I16_rack xs -> Ok (I16_rack (Array.make (Array.length xs) value))
          | Some value, I32_rack xs -> Ok (I32_rack (Array.make (Array.length xs) value))
          | Some _, value -> error expr.loc (Operand_kind_mismatch { operation = name; left = value_kind value; right = None })
          | None, _ -> eval_expr ~lanes env other_expr
        in
        let f = if name = "min" then min else max in
        (match (rack, other) with
         | F32_rack xs, F32_rack ys when Array.length xs = Array.length ys ->
             (* IEEE 754 minimum and maximum, as wasm's f32x4.min and f32x4.max: NaN if either is, -0 below +0. *)
             Ok (F32_rack (Array.map2 (if name = "min" then Float.min else Float.max) xs ys))
         | U8_rack xs, U8_rack ys when Array.length xs = Array.length ys -> Ok (U8_rack (Array.map2 f xs ys))
         | I16_rack xs, I16_rack ys when Array.length xs = Array.length ys -> Ok (I16_rack (Array.map2 f xs ys))
         | I32_rack xs, I32_rack ys when Array.length xs = Array.length ys -> Ok (I32_rack (Array.map2 f xs ys))
         | _ -> error expr.loc (Operand_kind_mismatch { operation = name; left = value_kind rack; right = Some (value_kind other) }))
    | ECall (("bit_and" | "bit_or" | "bit_xor" | "bit_andnot") as name, [ a; b ]) ->
        let literal_beside rack_expr literal =
          let* rack = eval_expr ~lanes env rack_expr in
          let value = Option.bind (integer_literal literal) (fun n -> typed_literal_value rack (Int64.of_int n)) in
          match value with Some v -> Ok (rack, v) | None -> let* v = eval_expr ~lanes env literal in Ok (rack, v)
        in
        let* a, b =
          match (integer_literal a, integer_literal b) with
          | Some _, None -> let* b, a = literal_beside b a in Ok (a, b)
          | None, Some _ -> literal_beside a b
          | _ -> let* a = eval_expr ~lanes env a in let* b = eval_expr ~lanes env b in Ok (a, b)
        in
        let f x y =
          match name with
          | "bit_and" -> x land y | "bit_or" -> x lor y | "bit_xor" -> x lxor y | _ -> x land lnot y
        in
        let f64 x y =
          match name with
          | "bit_and" -> Int64.logand x y | "bit_or" -> Int64.logor x y
          | "bit_xor" -> Int64.logxor x y | _ -> Int64.logand x (Int64.lognot y)
        in
        let same xs ys = Array.length xs = Array.length ys in
        (match (a, b) with
         | U8_rack xs, U8_rack ys when same xs ys -> Ok (U8_rack (Array.map2 (fun x y -> f x y land 0xff) xs ys))
         | I16_rack xs, I16_rack ys when same xs ys -> Ok (I16_rack (Array.map2 (fun x y -> wrap16 (f x y)) xs ys))
         | I32_rack xs, I32_rack ys when same xs ys -> Ok (I32_rack (Array.map2 (fun x y -> wrap32 (f x y)) xs ys))
         | I64_rack xs, I64_rack ys when same xs ys -> Ok (I64_rack (Array.map2 f64 xs ys))
         | _ -> error expr.loc (Operand_kind_mismatch { operation = name; left = value_kind a; right = Some (value_kind b) }))
    | ECall (("shift_bits_left" | "shift_bits_right" | "shift_bits_right_signed") as name, [ x; count ]) ->
        let* x = eval_expr ~lanes env x in
        let* count =
          match (integer_literal count, count.v) with
          | Some value, _ -> Ok value
          | None, (EScalarVar scalar | EBroadcast { v = EScalarVar scalar; _ }) -> (
              match List.assoc_opt scalar env with
              | Some (U32_scalar value) -> Ok value
              | Some (Int_scalar (_, value)) -> Ok (Int64.to_int value)
              | Some value -> error count.loc (Operand_kind_mismatch { operation = name; left = value_kind value; right = None })
              | None -> error count.loc (Undefined_variable scalar))
          | None, _ -> error count.loc (Unsupported_expression (name ^ " with a count that is not a literal or uniform u32"))
        in
        (* The count is taken modulo the lane's bits, as the hardware takes it. *)
        let shift bits wrap unsigned x =
          let c = count land (bits - 1) in
          match name with
          | "shift_bits_left" -> wrap (x lsl c)
          | "shift_bits_right" -> wrap (unsigned x lsr c)
          | _ -> wrap (wrap x asr c)
        in
        (match x with
         | U8_rack xs ->
             let signed x = if x land 0x80 <> 0 then x lor lnot 0xff else x in
             Ok (U8_rack (Array.map (fun x ->
               let c = count land 7 in
               (match name with
                | "shift_bits_left" -> x lsl c
                | "shift_bits_right" -> x lsr c
                | _ -> signed x asr c) land 0xff) xs))
         | I16_rack xs -> Ok (I16_rack (Array.map (shift 16 wrap16 (fun x -> x land 0xffff)) xs))
         | I32_rack xs ->
             let operation = match name with
               | "shift_bits_left" -> Int32.shift_left
               | "shift_bits_right" -> Int32.shift_right_logical
               | _ -> Int32.shift_right
             in
             Ok (I32_rack (Array.map (fun x -> Int32.to_int (operation (Int32.of_int x) (count land 31))) xs))
         | I64_rack xs ->
             let c = count land 63 in
             Ok (I64_rack (Array.map (fun x ->
               match name with
               | "shift_bits_left" -> Int64.shift_left x c
               | "shift_bits_right" -> Int64.shift_right_logical x c
               | _ -> Int64.shift_right x c) xs))
         | value -> error expr.loc (Operand_kind_mismatch { operation = name; left = value_kind value; right = None }))
    | ECall ("dot", [ a; b ]) ->
        let* a = eval_expr ~lanes env a in
        let* b = eval_expr ~lanes env b in
        (match (a, b) with
         | I16_rack xs, I16_rack ys when Array.length xs = Array.length ys ->
             Ok (I32_rack (Array.init (Array.length xs / 2) (fun i ->
               wrap32 ((xs.(2 * i) * ys.(2 * i)) + (xs.((2 * i) + 1) * ys.((2 * i) + 1))))))
         | _ -> error expr.loc (Operand_kind_mismatch { operation = "dot"; left = value_kind a; right = Some (value_kind b) }))
    | ECall ("narrow", [ a; b ]) ->
        let* a = eval_expr ~lanes env a in
        let* b = eval_expr ~lanes env b in
        (match (a, b) with
         | I32_rack xs, I32_rack ys when Array.length xs = Array.length ys ->
             Ok (I16_rack (Array.map (saturate (-32768) 32767) (Array.append xs ys)))
         | _ -> error expr.loc (Operand_kind_mismatch { operation = "narrow"; left = value_kind a; right = Some (value_kind b) }))
    | ECall (("widen_low" | "widen_high") as name, [ x ]) ->
        let* x = eval_expr ~lanes env x in
        (match x with
         | U8_rack xs ->
             let half = Array.length xs / 2 in
             Ok (I16_rack (Array.sub xs (if name = "widen_high" then half else 0) half))
         | value -> error expr.loc (Operand_kind_mismatch { operation = name; left = value_kind value; right = None }))
    | ECall ("to_f32", [ x ]) ->
        let* x = eval_expr ~lanes env x in
        (match x with
         | I32_rack xs -> Ok (F32_rack (Array.map (fun x -> f32 (Float.of_int x)) xs))
         | value -> error expr.loc (Operand_kind_mismatch { operation = "to_f32"; left = value_kind value; right = None }))
    | ECall ("to_i32", [ x ]) ->
        let* x = eval_expr ~lanes env x in
        (match x with
         | F32_rack xs -> Ok (I32_rack (Array.map nearest_i32 xs))
         | value -> error expr.loc (Operand_kind_mismatch { operation = "to_i32"; left = value_kind value; right = None }))
    | EBinop (left_expr, op, right_expr)
      when integer_literal left_expr <> None || integer_literal right_expr <> None -> (
        (* An integer literal takes the element type of the u8 rack it is compared with. *)
        match u8_predicate op with
        | None -> error expr.loc (Unsupported_expression (Ast.show_binop op))
        | Some predicate ->
            let literal_on_left = integer_literal left_expr <> None in
            let rack_expr = if literal_on_left then right_expr else left_expr in
            let literal =
              Option.get (integer_literal (if literal_on_left then left_expr else right_expr))
            in
            let* rack = eval_expr ~lanes env rack_expr in
            (match rack with
             | U8_rack xs ->
                 let ys = Array.make (Array.length xs) literal in
                 let left, right =
                   if literal_on_left then (U8_rack ys, U8_rack xs) else (U8_rack xs, U8_rack ys)
                 in
                 compare_u8 expr.loc (Ast.show_binop op) predicate left right
             | value ->
                 error expr.loc
                   (Operand_kind_mismatch {
                      operation = "integer literal comparison";
                      left = value_kind value;
                      right = None;
                    })))
    | EBinop (left_expr, ((Lt | Le | Gt | Ge | Eq | Ne) as op), right_expr)
      when (match eval_expr ~lanes env left_expr with Ok (U8_rack _) -> true | _ -> false) ->
        let* left = eval_expr ~lanes env left_expr in
        let* right = eval_expr ~lanes env right_expr in
        compare_u8 expr.loc (Ast.show_binop op) (Option.get (u8_predicate op)) left right
    | EBinop (left_expr, op, right_expr) ->
        let* left = eval_expr ~lanes env left_expr in
        let* right = eval_expr ~lanes env right_expr in
        (match op with
         | Add -> binary_f32 expr.loc lanes "add" ( +. ) left right
         | Sub -> binary_f32 expr.loc lanes "sub" ( -. ) left right
         | Mul -> binary_f32 expr.loc lanes "mul" ( *. ) left right
         | Div -> binary_f32 expr.loc lanes "div" ( /. ) left right
         | Lt -> compare_f32 expr.loc lanes "lt" ( < ) left right
         | Le -> compare_f32 expr.loc lanes "le" ( <= ) left right
         | Gt -> compare_f32 expr.loc lanes "gt" ( > ) left right
         | Ge -> compare_f32 expr.loc lanes "ge" ( >= ) left right
         | Eq -> compare_f32 expr.loc lanes "eq" Float.equal left right
         | Ne ->
             compare_f32 expr.loc lanes "ne" (fun x y -> not (Float.equal x y))
               left right
         | And -> mask_binary expr.loc lanes "and" ( && ) left right
         | Or -> mask_binary expr.loc lanes "or" ( || ) left right
         | Mod | Pipe | Shl | Shr | Rol | Ror | Interleave ->
             error expr.loc
               (Unsupported_expression (Ast.show_binop op)))
    | ECall ("sqrt", [ argument ]) ->
        let* value = eval_expr ~lanes env argument in
        unary_f32 expr.loc lanes "sqrt" Float.sqrt value
    | ECall ("sqrt", arguments) ->
        error expr.loc
          (Wrong_arity {
             operation = "sqrt";
             expected = 1;
             actual = List.length arguments;
           })
    | ECall ("bitmask", [ argument ]) ->
        let* value = eval_expr ~lanes env argument in
        (match value with
         | Mask lanes_set ->
             let bits = ref 0 in
             Array.iteri (fun lane set -> if set then bits := !bits lor (1 lsl lane)) lanes_set;
             Ok (U32_scalar !bits)
         | value ->
             error expr.loc
               (Operand_kind_mismatch { operation = "bitmask"; left = value_kind value; right = None }))
    | EShuffle (operand, indices) ->
        let rack_exprs = match operand.v with ETuple racks -> racks | _ -> [ operand ] in
        let* racks =
          List.fold_right
            (fun rack_expr accumulated ->
              let* racks = accumulated in
              let* rack = eval_expr ~lanes env rack_expr in
              Ok (rack :: racks))
            rack_exprs (Ok [])
        in
        shuffle_racks expr.loc racks indices
    | ECall ("select", [ condition; if_true; if_false ]) ->
        let* condition = eval_expr ~lanes env condition in
        let* if_true = eval_expr ~lanes env if_true in
        let* if_false = eval_expr ~lanes env if_false in
        select ~loc:expr.loc ~lanes condition if_true if_false
    | ECall ("select", arguments) ->
        error expr.loc
          (Wrong_arity {
             operation = "select";
             expected = 3;
             actual = List.length arguments;
           })
    | EFma (a, b, c) ->
        let* a = eval_expr ~lanes env a in
        let* b = eval_expr ~lanes env b in
        let* c = eval_expr ~lanes env c in
        ternary_fma expr.loc lanes a b c
    | EReduce (((RAdd | RMul | RMin | RMax) as operation), operand) ->
        let* value = eval_expr ~lanes env operand in
        eval_f32_reduction expr.loc operation value
    | EScan (((RAdd | RMul | RMin | RMax) as operation), operand) ->
        let* value = eval_expr ~lanes env operand in
        eval_f32_scan expr.loc operation value
    | EScan ((RAnd | ROr), _) ->
        error expr.loc (Unsupported_expression "logical prefix scan")
    | kind -> error expr.loc (Unsupported_expression (Ast.show_expr_kind kind))

(** Two operands, an integer literal among them typed by the other. *)
and operands ~lanes env left_expr right_expr =
  match (integer_literal left_expr, integer_literal right_expr) with
  | Some value, None ->
      let* right = eval_expr ~lanes env right_expr in
      (match typed_literal_value right (Int64.of_int value) with
       | Some left -> Ok (left, right)
       | None -> error left_expr.loc (Unsupported_expression "an integer literal needs an integer or f32 rack beside it"))
  | None, Some value ->
      let* left = eval_expr ~lanes env left_expr in
      (match typed_literal_value left (Int64.of_int value) with
       | Some right -> Ok (left, right)
       | None -> error right_expr.loc (Unsupported_expression "an integer literal needs an integer or f32 rack beside it"))
  | _ ->
      let* left = eval_expr ~lanes env left_expr in
      let* right = eval_expr ~lanes env right_expr in
      Ok (left, right)

(** Whether a binary operation is on integer lanes: an integer rack, or a
    uniform integer beside one. *)
and is_integer_operation ~lanes env left_expr right_expr =
  let integer (e : expr) =
    match integer_literal e with
    | Some _ -> `Literal
    | None -> (
        match eval_expr ~lanes env e with
        | Ok v when int_lanes v <> None -> `Rack
        | Ok (Int_scalar _ | U32_scalar _) -> `Uniform
        | _ -> `Other)
  in
  match (integer left_expr, integer right_expr) with
  | `Rack, (`Rack | `Literal | `Uniform) | (`Literal | `Uniform), `Rack -> true
  | _ -> false

let bind_parameter ~lanes env parameter argument loc =
  let* argument = validate_width loc lanes (normalize_value argument) in
  match (parameter, argument) with
  | PRack (name, _), (F32_rack _ | Mask _ | U8_rack _ | I16_rack _ | I32_rack _ | I64_rack _) -> Ok ((name, argument) :: env)
  | PRack (name, _), (U32_scalar _ | Int_scalar _) ->
      error loc
        (Expected_variable_kind {
           name;
           expected = Rack;
           actual = U32_scalar_kind;
         })
  | PRack (name, _), F32_scalar _ ->
      error loc
        (Expected_variable_kind {
           name;
           expected = Rack;
           actual = Scalar;
         })
  | PScalar (name, _), (F32_scalar _ | Int_scalar _ | U32_scalar _) -> Ok ((name, argument) :: env)
  | PScalar (name, _), argument ->
      error loc
        (Expected_variable_kind {
           name;
           expected = Scalar;
           actual = value_kind argument;
         })
  | PSpread _, _ -> error loc (Unsupported_definition "spread scratch parameter")

let eval_scratch ~lanes definition arguments =
  match definition.v with
  | DScratch (_, parameters, result, body) ->
      if List.length parameters <> List.length arguments then
        error definition.loc
          (Argument_count_mismatch {
             expected = List.length parameters;
             actual = List.length arguments;
           })
      else
        let* env =
          List.fold_left2
            (fun accumulated parameter argument ->
              let* env = accumulated in
              bind_parameter ~lanes env parameter argument definition.loc)
            (Ok []) parameters arguments
        in
        let rec eval_body env = function
          | [] -> lookup definition.loc lanes env result.result_name
          | statement :: rest -> (
              match statement.v with
              | SLet binding ->
                  let* value = eval_expr ~lanes env binding.bind_expr in
                  eval_body ((binding.bind_name, value) :: env) rest
              | SFused binding ->
                  let* value = eval_expr ~lanes env binding.fused_expr in
                  eval_body ((binding.fused_name, value) :: env) rest
              | SUniform binding ->
                  let* value = eval_expr ~lanes env binding.bind_expr in
                  eval_body ((binding.bind_name, value) :: env) rest
              | SLocBind location ->
                  let* value = eval_expr ~lanes env location.loc_expr in
                  eval_body ((location.loc_name, value) :: env) rest
              | SAssign (name, expression) ->
                  let* value = eval_expr ~lanes env expression in
                  eval_body ((name, value) :: env) rest
              | SLoop ({ loop_repeat = true; _ } as loop) -> (
                  match (integer_literal loop.loop_from, integer_literal loop.loop_to) with
                  | Some first, Some stop ->
                      (* Names bound in an iteration end with it; assignments to outer names carry on. *)
                      let rec iterations env k =
                        if k >= stop then Ok env
                        else
                          let* inner = eval_body_statements ((loop.loop_var, Int_scalar (Types.SInt, Int64.of_int k)) :: env) loop.loop_body in
                          let env = List.map (fun (name, value) -> (name, Option.value (List.assoc_opt name inner) ~default:value)) env in
                          iterations env (k + 1)
                      in
                      let* env = iterations env first in
                      eval_body env rest
                  | _ -> error statement.loc (Unsupported_statement "repeat with non-literal bounds"))
              | SExpr expression ->
                  let* _ = eval_expr ~lanes env expression in
                  eval_body env rest
              | kind ->
                  error statement.loc
                    (Unsupported_statement (Ast.show_stmt_kind kind)))
        and eval_body_statements env statements =
          match statements with
          | [] -> Ok env
          | statement :: rest -> (
              match statement.v with
              | SLet { bind_name = name; bind_expr = e; _ } | SFused { fused_name = name; fused_expr = e; _ }
              | SUniform { bind_name = name; bind_expr = e; _ } | SLocBind { loc_name = name; loc_expr = e; _ } | SAssign (name, e) ->
                  let* value = eval_expr ~lanes env e in
                  eval_body_statements ((name, value) :: env) rest
              | SLoop ({ loop_repeat = true; _ } as loop) -> (
                  match (integer_literal loop.loop_from, integer_literal loop.loop_to) with
                  | Some first, Some stop ->
                      let rec iterations env k =
                        if k >= stop then Ok env
                        else
                          let* inner = eval_body_statements ((loop.loop_var, Int_scalar (Types.SInt, Int64.of_int k)) :: env) loop.loop_body in
                          let env = List.map (fun (name, value) -> (name, Option.value (List.assoc_opt name inner) ~default:value)) env in
                          iterations env (k + 1)
                      in
                      let* env = iterations env first in
                      eval_body_statements env rest
                  | _ -> error statement.loc (Unsupported_statement "repeat with non-literal bounds"))
              | SExpr e -> let* _ = eval_expr ~lanes env e in eval_body_statements env rest
              | kind -> error statement.loc (Unsupported_statement (Ast.show_stmt_kind kind)))
        in
        eval_body env body
  | kind -> error definition.loc (Unsupported_definition (Ast.show_def_kind kind))

let project_value lane = function
  | F32_scalar _ as value -> value
  | U32_scalar _ as value -> value
  | Int_scalar _ as value -> value
  | F32_rack values -> F32_rack [| values.(lane) |]
  | Mask values -> Mask [| values.(lane) |]
  | U8_rack values -> U8_rack [| values.(lane) |]
  | I16_rack values -> I16_rack [| values.(lane) |]
  | I32_rack values -> I32_rack [| values.(lane) |]
  | I64_rack values -> I64_rack [| values.(lane / 2) |]

let project_env lane env =
  List.map (fun (name, value) -> (name, project_value lane value)) env

let rack_lane loc = function
  | F32_rack values when Array.length values = 1 -> Ok values.(0)
  | F32_scalar value -> Ok value
  | value ->
      error loc
        (Operand_kind_mismatch {
           operation = "lane result";
           left = value_kind value;
           right = None;
         })

let mask_value loc lanes = function
  | Mask values when Array.length values = lanes -> Ok values
  | value ->
      error loc
        (Operand_kind_mismatch {
           operation = "predicate";
           left = value_kind value;
           right = None;
         })

let rec eval_predicate ~lanes env tines (predicate : predicate) =
  match predicate.v with
  | PExpr expression ->
      let* value = eval_expr ~lanes env expression in
      mask_value predicate.loc lanes value
  | PCmp (left, comparison, right) ->
      let operation =
        match comparison with
        | CLt -> Lt | CLe -> Le | CGt -> Gt | CGe -> Ge | CEq -> Eq | CNe -> Ne
      in
      let* value =
        eval_expr ~lanes env (node (EBinop (left, operation, right)) predicate.loc)
      in
      mask_value predicate.loc lanes value
  | PIs (left, right) | PIsNot (left, right) ->
      let operation = match predicate.v with PIs _ -> Eq | _ -> Ne in
      let* value =
        eval_expr ~lanes env (node (EBinop (left, operation, right)) predicate.loc)
      in
      mask_value predicate.loc lanes value
  | PAnd (left, right) | POr (left, right) ->
      let* left = eval_predicate ~lanes env tines left in
      let* right = eval_predicate ~lanes env tines right in
      Ok
        (Array.init lanes (fun lane ->
             if match predicate.v with PAnd _ -> true | _ -> false
             then left.(lane) && right.(lane)
             else left.(lane) || right.(lane)))
  | PNot inner ->
      let* inner = eval_predicate ~lanes env tines inner in
      Ok (Array.map not inner)
  | PTineRef name -> (
      match List.assoc_opt name tines with
      | Some value -> Ok value
      | None -> error predicate.loc (Undefined_variable ("#" ^ name)))
  | PTineCall _ ->
      (try eval_predicate ~lanes env tines (Tines.expand_calls !definitions predicate)
       with Tines.Error (loc, message) -> error loc (Unsupported_definition message))

let eval_rake ~lanes definition arguments =
  match definition.v with
  | DRake (_, parameters, result, setup, tine_defs, throughs, sweep) ->
      if List.length parameters <> List.length arguments then
        error definition.loc
          (Argument_count_mismatch {
             expected = List.length parameters;
             actual = List.length arguments;
           })
      else
        let* initial_env =
          List.fold_left2
            (fun accumulated parameter argument ->
              let* env = accumulated in
              bind_parameter ~lanes env parameter argument definition.loc)
            (Ok []) parameters arguments
        in
        let rec eval_statements ~lanes env = function
          | [] -> Ok env
          | statement :: rest -> (
              match statement.v with
              | SLet binding ->
                  let* value = eval_expr ~lanes env binding.bind_expr in
                  eval_statements ~lanes ((binding.bind_name, value) :: env) rest
              | SFused binding ->
                  let* value = eval_expr ~lanes env binding.fused_expr in
                  eval_statements ~lanes ((binding.fused_name, value) :: env) rest
              | SExpr expression ->
                  let* _ = eval_expr ~lanes env expression in
                  eval_statements ~lanes env rest
              | kind ->
                  error statement.loc
                    (Unsupported_statement (Ast.show_stmt_kind kind)))
        in
        let* setup_env = eval_statements ~lanes initial_env setup in
        let rec eval_tines evaluated = function
          | [] -> Ok (List.rev evaluated)
          | tine :: rest ->
              let* value = eval_predicate ~lanes setup_env (List.rev evaluated) tine.tine_pred in
              eval_tines ((tine.tine_name, value) :: evaluated) rest
        in
        let* tines = eval_tines [] tine_defs in
        let tine_ref loc = function
          | TRSingle name -> (
              match List.assoc_opt name tines with
              | Some value -> Ok value
              | None -> error loc (Undefined_variable ("#" ^ name)))
          | TRComposed predicate -> eval_predicate ~lanes setup_env tines predicate
        in
        let rec eval_throughs env = function
          | [] -> Ok env
          | through :: rest ->
              let* active = tine_ref through.through_result.loc through.through_tine in
              let* passthrough =
                match through.through_passthru with
                | None -> Ok (Array.make lanes 0.0)
                | Some expression ->
                    let* value = eval_expr ~lanes env expression in
                    as_rack expression.loc lanes "through passthrough" value
              in
              let output = Array.copy passthrough in
              let rec eval_lanes lane =
                if lane = lanes then Ok ()
                else if not active.(lane) then eval_lanes (lane + 1)
                else
                  let lane_env = project_env lane env in
                  let* lane_env = eval_statements ~lanes:1 lane_env through.through_body in
                  let* value = eval_expr ~lanes:1 lane_env through.through_result in
                  let* value = rack_lane through.through_result.loc value in
                  output.(lane) <- value;
                  eval_lanes (lane + 1)
              in
              let* () = eval_lanes 0 in
              eval_throughs ((through.through_binding, rack output) :: env) rest
        in
        let* env = eval_throughs setup_env throughs in
        let rec masks_for_arms = function
          | [] -> Ok []
          | arm :: rest ->
              let* active = match arm.arm_tine with
                | None -> Ok (Array.make lanes true)
                | Some predicate -> eval_predicate ~lanes env tines predicate in
              let* rest = masks_for_arms rest in
              Ok ((arm, active) :: rest)
        in
        let* arms = masks_for_arms sweep.sweep_arms in
        let rec selected_arm lane = function
          | [] -> None
          | (arm, active) :: rest ->
              if active.(lane) then Some arm else selected_arm lane rest
        in
        let output = Array.make lanes 0.0 in
        let rec eval_sweep lane =
          if lane = lanes then Ok ()
          else
            match selected_arm lane arms with
            | None -> error definition.loc (Unsupported_definition "non-total sweep")
            | Some arm ->
                let* value = eval_expr ~lanes:1 (project_env lane env) arm.arm_value in
                let* value = rack_lane arm.arm_value.loc value in
                output.(lane) <- value;
                eval_sweep (lane + 1)
        in
        let* () = eval_sweep 0 in
        let env = (sweep.sweep_binding, rack output) :: env in
        lookup definition.loc lanes env result.result_name
  | kind -> error definition.loc (Unsupported_definition (Ast.show_def_kind kind))

let () =
  eval_scratch_ref := eval_scratch;
  eval_rake_ref := eval_rake
