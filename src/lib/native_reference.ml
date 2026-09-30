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

type value_kind = Scalar | Rack | Mask_kind | U8_rack_kind | U32_scalar_kind | I16_rack_kind | I32_rack_kind

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

let string_of_value_kind = function
  | Scalar -> "f32 scalar"
  | Rack -> "f32 rack"
  | Mask_kind -> "mask"
  | U8_rack_kind -> "u8 rack"
  | U32_scalar_kind -> "u32 scalar"
  | I16_rack_kind -> "i16 rack"
  | I32_rack_kind -> "i32 rack"

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
        Printf.sprintf "crunch expects %d arguments, got %d" expected actual
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
      (* A mask has one lane per lane of the racks compared to make it: f32 or u8. *)
      let actual = Array.length xs in
      if actual = lanes || actual = 4 * lanes then Ok value
      else error loc (Lane_count_mismatch { expected = lanes; actual })
  | U8_rack xs as value ->
      let actual = Array.length xs in
      if actual = 4 * lanes then Ok value
      else error loc (Lane_count_mismatch { expected = 4 * lanes; actual })
  | U32_scalar _ as value -> Ok value
  | I16_rack xs as value ->
      let actual = Array.length xs in
      if actual = 2 * lanes then Ok value
      else error loc (Lane_count_mismatch { expected = 2 * lanes; actual })
  | I32_rack xs as value ->
      let actual = Array.length xs in
      if actual = lanes then Ok value
      else error loc (Lane_count_mismatch { expected = lanes; actual })

(** Two's-complement wrapping to 16 and 32 bits. *)
let wrap16 x = ((x + 0x8000) land 0xffff) - 0x8000
let wrap32 x = ((x + 0x80000000) land 0xffffffff) - 0x80000000
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
  | U32_scalar x -> U32_scalar (x land 0xffffffff)
  | I16_rack xs -> I16_rack (Array.map wrap16 xs)
  | I32_rack xs -> I32_rack (Array.map wrap32 xs)

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
  | (Mask _ | U8_rack _ | U32_scalar _ | I16_rack _ | I32_rack _) as value ->
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
  | (Mask _ | U8_rack _ | U32_scalar _ | I16_rack _ | I32_rack _) as value ->
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

let rec eval_expr ~lanes env (expr : expr) =
  if lanes <= 0 then error expr.loc (Invalid_lane_count lanes)
  else
    match expr.v with
    | EFloat value -> Ok (splat lanes value)
    | EBool value -> Ok (Mask (Array.make lanes value))
    | EVar name ->
        let* value = lookup expr.loc lanes env name in
        (match value with
         | F32_rack _ | Mask _ | U8_rack _ | I16_rack _ | I32_rack _ -> Ok value
         | U32_scalar _ ->
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
         | (Mask _ | U8_rack _ | U32_scalar _ | I16_rack _ | I32_rack _) as value ->
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
           || (match eval_expr ~lanes env a with Ok (I16_rack _ | I32_rack _) -> true | _ -> false) ->
        let literal_first = integer_literal a <> None in
        let rack_expr, other_expr = if literal_first then (b, a) else (a, b) in
        let* rack = eval_expr ~lanes env rack_expr in
        let* other =
          match (integer_literal other_expr, rack) with
          | Some value, I16_rack xs -> Ok (I16_rack (Array.make (Array.length xs) value))
          | Some value, I32_rack xs -> Ok (I32_rack (Array.make (Array.length xs) value))
          | Some _, value -> error expr.loc (Operand_kind_mismatch { operation = name; left = value_kind value; right = None })
          | None, _ -> eval_expr ~lanes env other_expr
        in
        let f = if name = "min" then min else max in
        (match (rack, other) with
         | I16_rack xs, I16_rack ys when Array.length xs = Array.length ys -> Ok (I16_rack (Array.map2 f xs ys))
         | I32_rack xs, I32_rack ys when Array.length xs = Array.length ys -> Ok (I32_rack (Array.map2 f xs ys))
         | _ -> error expr.loc (Operand_kind_mismatch { operation = name; left = value_kind rack; right = Some (value_kind other) }))
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
    | EReduce ((RAnd | ROr), _) ->
        error expr.loc
          (Unsupported_expression "logical mask reduction in f32 native slice")
    | EScan (((RAdd | RMul | RMin | RMax) as operation), operand) ->
        let* value = eval_expr ~lanes env operand in
        eval_f32_scan expr.loc operation value
    | EScan ((RAnd | ROr), _) ->
        error expr.loc (Unsupported_expression "logical prefix scan")
    | kind -> error expr.loc (Unsupported_expression (Ast.show_expr_kind kind))

let bind_parameter ~lanes env parameter argument loc =
  let* argument = validate_width loc lanes (normalize_value argument) in
  match (parameter, argument) with
  | PRack (name, _), (F32_rack _ | Mask _ | U8_rack _ | I16_rack _ | I32_rack _) -> Ok ((name, argument) :: env)
  | PRack (name, _), U32_scalar _ ->
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
  | PScalar (name, _), F32_scalar _ -> Ok ((name, argument) :: env)
  | PScalar (name, _), argument ->
      error loc
        (Expected_variable_kind {
           name;
           expected = Scalar;
           actual = value_kind argument;
         })
  | PSpread _, _ -> error loc (Unsupported_definition "spread crunch parameter")

let eval_crunch ~lanes definition arguments =
  match definition.v with
  | DCrunch (_, parameters, result, body) ->
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
              | SExpr expression ->
                  let* _ = eval_expr ~lanes env expression in
                  eval_body env rest
              | kind ->
                  error statement.loc
                    (Unsupported_statement (Ast.show_stmt_kind kind)))
        in
        eval_body env body
  | kind -> error definition.loc (Unsupported_definition (Ast.show_def_kind kind))

let project_value lane = function
  | F32_scalar _ as value -> value
  | U32_scalar _ as value -> value
  | F32_rack values -> F32_rack [| values.(lane) |]
  | Mask values -> Mask [| values.(lane) |]
  | U8_rack values -> U8_rack [| values.(lane) |]
  | I16_rack values -> I16_rack [| values.(lane) |]
  | I32_rack values -> I32_rack [| values.(lane) |]

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
        let arms = sweep.sweep_arms in
        let rec selected_arm lane = function
          | [] -> None
          | arm :: rest -> (
              match arm.arm_tine with
              | None -> Some arm
              | Some name ->
                  if (List.assoc name tines).(lane) then Some arm
                  else selected_arm lane rest)
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
