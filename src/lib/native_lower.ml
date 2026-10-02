(** Direct lowering from checked Rake AST to native, rack-preserving SSA.

    The executable slice covers straight-line [crunch] definitions and
    predicated [rake] definitions. Unsupported forms fail here rather than
    leaking into target legalization. *)

open Ast

module Ir = Native_ir
module StringMap = Map.Make (String)
module Int32Map = Map.Make (Int32)

let ( let* ) = Result.bind

type error = { loc : loc; message : string }

let format_error error =
  Printf.sprintf "%s:%d:%d: native lowering: %s" error.loc.file error.loc.line error.loc.col
    error.message

let error loc message = Error { loc; message }
let errorf loc format = Printf.ksprintf (fun message -> error loc message) format

let ir_location (loc : Ast.loc) : Ir.source_location =
  { file = loc.file; line = loc.line; col = loc.col; offset = loc.offset }

type binding = Ir.value * Ir.typ

type state = {
  mutable next_value : int;
  mutable next_fused_region : int;
  mutable instructions_rev : Ir.instruction list;
  mutable bindings : binding StringMap.t;
  mutable tines : binding StringMap.t;
  mutable rack_constants : binding Int32Map.t;
  mutable mask_constants : binding option * binding option;
  mutable locations : unit StringMap.t;  (** names bound with :=, which <- may rebind *)
}

let element_bytes = function
  | Ir.U8 -> 1 | Ir.I16 -> 2 | Ir.I32 | Ir.F32 -> 4 | Ir.I64 | Ir.F64 -> 8 | Ir.I1 -> 16

let ir_typ_of_annotation typ =
  match typ.v with
  | TRack PFloat -> Ok (Ir.Rack Ir.F32)
  | TScalar PFloat -> Ok (Ir.Scalar Ir.F32)
  | TRack PUint8 -> Ok (Ir.Rack Ir.U8)
  | TRack PInt16 -> Ok (Ir.Rack Ir.I16)
  | TRack (PInt | PUint) -> Ok (Ir.Rack Ir.I32)
  | TRack (PInt64 | PUint64) -> Ok (Ir.Rack Ir.I64)
  | TScalar PUint -> Ok (Ir.Scalar Ir.I32)
  | TScalar PInt -> Ok (Ir.Scalar Ir.I32)
  | TScalar PInt16 -> Ok (Ir.Scalar Ir.I16)
  | TScalar PUint8 -> Ok (Ir.Scalar Ir.U8)
  | TScalar (PInt64 | PUint64) -> Ok (Ir.Scalar Ir.I64)
  | TScalar PBool -> Ok (Ir.Scalar Ir.I1)
  | TMask -> Ok Ir.Mask
  | _ ->
      error typ.loc
        "only f32, u8, i16, i32, u32, i64 and u64 rack, f32 and u32 scalar, and mask annotations are supported by native crunch lowering"

(** Racks a native crunch takes and returns. *)
let native_racks = [ Ir.Rack Ir.F32; Ir.Rack Ir.U8; Ir.Rack Ir.I16; Ir.Rack Ir.I32; Ir.Rack Ir.I64 ]

let is_integer_rack = function Ir.Rack (Ir.I16 | Ir.I32) -> true | _ -> false

(** Racks whose lanes bitwise operations and shifts take, and their lane bits. *)
let lane_bits = function
  | Ir.Rack Ir.U8 -> Some 8
  | Ir.Rack Ir.I16 -> Some 16
  | Ir.Rack Ir.I32 -> Some 32
  | Ir.Rack Ir.I64 -> Some 64
  | _ -> None

(** A splat of an integer literal, in the element of the integer rack it meets. *)
let integer_splat loc typ value =
  match typ with
  | Ir.Rack Ir.I16 when value >= -32768L && value <= 32767L -> Ok (Ir.Rack_splat (Ir.Int16 (Int64.to_int value)))
  | Ir.Rack Ir.I32 when value >= -2147483648L && value <= 2147483647L -> Ok (Ir.Rack_splat (Ir.Int32 (Int64.to_int32 value)))
  | _ -> errorf loc "integer literal %Ld does not fit a lane of %s" value (Ir.string_of_typ typ)

(** An integer literal, written bare or as a uniform <n>. *)
let integer_literal (expr : expr) =
  match expr.v with
  | EInt value | EBroadcast { v = EInt value; _ } -> Some value
  | _ -> None

let check_annotation annotation actual =
  match annotation with
  | None -> Ok ()
  | Some typ ->
      let* annotated = ir_typ_of_annotation typ in
      if annotated = actual then Ok ()
      else
        errorf typ.loc "annotation has type %s but expression has type %s"
          (Ir.string_of_typ annotated) (Ir.string_of_typ actual)

let find_binding state loc name =
  match StringMap.find_opt name state.bindings with
  | Some binding -> Ok binding
  | None -> errorf loc "undefined variable '%s'" name

let bind state loc name binding =
  if StringMap.mem name state.bindings then errorf loc "SSA name '%s' is already bound" name
  else (
    state.bindings <- StringMap.add name binding state.bindings;
    Ok ())

let emit state loc provenance typ op =
  let id = state.next_value in
  state.next_value <- id + 1;
  state.instructions_rev <-
    { Ir.result = Some (id, typ); op; provenance; loc = ir_location loc }
    :: state.instructions_rev;
  (id, typ)

let rack_constant state loc _provenance value =
  let bits = Int32.bits_of_float value in
  match Int32Map.find_opt bits state.rack_constants with
  | Some binding -> binding
  | None ->
      let binding =
        emit state loc Ir.source (Ir.Rack Ir.F32)
          (Ir.Rack_splat (Ir.Float32_bits bits))
      in
      state.rack_constants <- Int32Map.add bits binding state.rack_constants;
      binding

let mask_constant state loc value =
  let false_value, true_value = state.mask_constants in
  match if value then true_value else false_value with
  | Some binding -> binding
  | None ->
      let binding = emit state loc Ir.source Ir.Mask (Ir.Mask_const value) in
      state.mask_constants <-
        if value then (false_value, Some binding) else (Some binding, true_value);
      binding

let sanitize_operand state loc provenance benign ((value, typ) as operand) =
  match provenance.Ir.through with
  | None -> operand
  | Some _ when not !Ir.floating_point_exceptions -> operand
  | Some mask ->
      let benign = rack_constant state loc provenance benign in
      emit state loc provenance typ
        (Ir.Sanitize { mask; active = value; benign = fst benign })

let expect_type loc description expected (_, actual) =
  if actual = expected then Ok ()
  else
    errorf loc "%s requires %s, got %s" description (Ir.string_of_typ expected)
      (Ir.string_of_typ actual)

let expect_same loc description ((_, left_type) as left) ((_, right_type) as right) =
  if left_type = right_type then Ok (left, right)
  else
    errorf loc "%s requires equal operands, got %s and %s" description
      (Ir.string_of_typ left_type) (Ir.string_of_typ right_type)

let ir_binary = function
  | Ast.Add -> Some Ir.Add
  | Ast.Sub -> Some Ir.Sub
  | Ast.Mul -> Some Ir.Mul
  | Ast.Div -> Some Ir.Div
  | Ast.Mod | Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge | Ast.Eq | Ast.Ne | Ast.And | Ast.Or
  | Ast.Pipe | Ast.Shl | Ast.Shr | Ast.Rol | Ast.Ror | Ast.Interleave -> None

let ir_comparison = function
  | Ast.Lt -> Some Ir.Lt
  | Ast.Le -> Some Ir.Le
  | Ast.Gt -> Some Ir.Gt
  | Ast.Ge -> Some Ir.Ge
  | Ast.Eq -> Some Ir.Eq
  | Ast.Ne -> Some Ir.Ne
  | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod | Ast.And | Ast.Or | Ast.Pipe
  | Ast.Shl | Ast.Shr | Ast.Rol | Ast.Ror | Ast.Interleave -> None

let ir_reduction = function
  | Ast.RAdd -> Some Ir.Reduce_add
  | Ast.RMul -> Some Ir.Reduce_mul
  | Ast.RMin -> Some Ir.Reduce_min
  | Ast.RMax -> Some Ir.Reduce_max
  | Ast.RAnd | Ast.ROr -> None

let ir_scan = function
  | Ast.RAdd -> Some Ir.Scan_add
  | Ast.RMul -> Some Ir.Scan_mul
  | Ast.RMin -> Some Ir.Scan_min
  | Ast.RMax -> Some Ir.Scan_max
  | Ast.RAnd | Ast.ROr -> None

(** Integer elements of racks that integer arithmetic and comparison take. *)
let is_integer_element = function Ir.U8 | Ir.I16 | Ir.I32 | Ir.I64 -> true | _ -> false

(** A literal typed by the rack it meets: an integer splat in the rack's
    element, or an f32 constant for an f32 rack. *)
let typed_literal state loc provenance typ value =
  match typ with
  | Ir.Rack Ir.F32 -> Ok (rack_constant state loc provenance (Int64.to_float value))
  | Ir.Rack Ir.U8 when value >= 0L && value <= 255L ->
      Ok (emit state loc provenance typ (Ir.Rack_splat (Ir.Uint8 (Int64.to_int value))))
  | Ir.Rack Ir.I64 -> Ok (emit state loc provenance typ (Ir.Rack_splat (Ir.Int64 value)))
  | Ir.Rack (Ir.I16 | Ir.I32) -> (
      match integer_splat loc typ value with
      | Ok splat -> Ok (emit state loc provenance typ splat)
      | Error _ as failure -> failure)
  | _ -> errorf loc "integer literal %Ld does not fit a lane of %s" value (Ir.string_of_typ typ)

(** Rake's exp, log, log2 and tanh on an f32 rack: the binary32 operations
    of {!Rake_math}, lane by lane, special cases chosen by vector select. *)
let expand_math state loc name x =
  let f32_rack = Ir.Rack Ir.F32 and i32_rack = Ir.Rack Ir.I32 in
  let e typ op = fst (emit state loc Ir.source typ op) in
  let k value = fst (rack_constant state loc Ir.source value) in
  let fop op a b = e f32_rack (Ir.Binary (op, a, b)) in
  let iop op a b = e i32_rack (Ir.Binary (op, a, b)) in
  let ik n = e i32_rack (Ir.Rack_splat (Ir.Int32 n)) in
  let cmp c a b = e Ir.Mask (Ir.Compare (c, a, b)) in
  let sel typ m a b = e typ (Ir.Select { condition = m; if_true = a; if_false = b }) in
  let shift kind v n =
    let count = e (Ir.Scalar Ir.I32) (Ir.Const (Ir.Int32 n)) in
    e i32_rack (Ir.Shift { operand = v; count; shift = kind })
  in
  let as_f32 v = e f32_rack (Ir.Reinterpret { operand = v; element = Ir.F32 }) in
  let as_i32 v = e i32_rack (Ir.Reinterpret { operand = v; element = Ir.I32 }) in
  let nan_lanes v = e Ir.Mask (Ir.Mask_not (cmp Ir.Eq v v)) in
  let poly coefficients v =
    List.fold_left (fun y c -> fop Ir.Add (fop Ir.Mul y v) (k c)) (k (List.hd coefficients)) (List.tl coefficients)
  in
  let exp_core v =
    let n = e f32_rack (Ir.Unary (Ir.Floor, fop Ir.Add (fop Ir.Mul v (k Rake_math.log2e)) (k 0.5))) in
    let r = fop Ir.Sub v (fop Ir.Mul n (k Rake_math.ln2_high)) in
    let r = fop Ir.Sub r (fop Ir.Mul n (k Rake_math.ln2_low)) in
    let z = fop Ir.Mul r r in
    let y = poly Rake_math.exp_poly r in
    let y = fop Ir.Add (fop Ir.Mul y z) r in
    let y = fop Ir.Add y (k 1.0) in
    let kk = e i32_rack (Ir.Convert { operand = n; element = Ir.I32 }) in
    let k1 = shift Ir.Shift_right_signed kk 1l in
    let k2 = iop Ir.Sub kk k1 in
    let pow2 v = as_f32 (shift Ir.Shift_left (iop Ir.Add v (ik 127l)) 23l) in
    let result = fop Ir.Mul (fop Ir.Mul y (pow2 k1)) (pow2 k2) in
    let result = sel f32_rack (cmp Ir.Gt v (k Rake_math.exp_high)) (k Float.infinity) result in
    let result = sel f32_rack (cmp Ir.Lt v (k Rake_math.exp_low)) (k 0.0) result in
    sel f32_rack (nan_lanes v) v result
  in
  let log_core two =
    let small = cmp Ir.Lt x (k Rake_math.min_normal) in
    let xs = sel f32_rack small (fop Ir.Mul x (k Rake_math.two_23)) x in
    let adjust = sel i32_rack small (ik (-23l)) (ik 0l) in
    let b = as_i32 xs in
    let exponent = iop Ir.Add (iop Ir.Sub (iop Ir.And (shift Ir.Shift_right b 23l) (ik 0xffl)) (ik 126l)) adjust in
    let m = as_f32 (iop Ir.Or (iop Ir.And b (ik 0x807fffffl)) (ik 0x3f000000l)) in
    let low = cmp Ir.Lt m (k Rake_math.sqrt_half) in
    let exponent = iop Ir.Sub exponent (sel i32_rack low (ik 1l) (ik 0l)) in
    let m = sel f32_rack low (fop Ir.Sub (fop Ir.Add m m) (k 1.0)) (fop Ir.Sub m (k 1.0)) in
    let z = fop Ir.Mul m m in
    let y = fop Ir.Mul (fop Ir.Mul (poly Rake_math.log_poly m) m) z in
    let fe = e f32_rack (Ir.Convert { operand = exponent; element = Ir.F32 }) in
    let result =
      if two then
        let y = fop Ir.Sub y (fop Ir.Mul (k 0.5) z) in
        fop Ir.Add (fop Ir.Mul (fop Ir.Add m y) (k Rake_math.log2e)) fe
      else
        let y = fop Ir.Add y (fop Ir.Mul fe (k Rake_math.ln2_low)) in
        let y = fop Ir.Sub y (fop Ir.Mul (k 0.5) z) in
        fop Ir.Add (fop Ir.Add m y) (fop Ir.Mul fe (k Rake_math.ln2_high))
    in
    let result = sel f32_rack (cmp Ir.Eq x (k Float.infinity)) x result in
    let result = sel f32_rack (cmp Ir.Eq x (k 0.0)) (k Float.neg_infinity) result in
    let result = sel f32_rack (cmp Ir.Lt x (k 0.0)) (k Rake_math.canonical_nan) result in
    sel f32_rack (nan_lanes x) x result
  in
  let value =
    match name with
    | "exp" -> exp_core x
    | "log" -> log_core false
    | "log2" -> log_core true
    | _ ->
        let a = e f32_rack (Ir.Unary (Ir.Abs, x)) in
        let big =
          let ex = exp_core (fop Ir.Add a a) in
          let r = fop Ir.Sub (k 1.0) (fop Ir.Div (k 2.0) (fop Ir.Add ex (k 1.0))) in
          sel f32_rack (cmp Ir.Lt x (k 0.0)) (e f32_rack (Ir.Unary (Ir.Neg, r))) r
        in
        let z = fop Ir.Mul x x in
        let small = fop Ir.Add (fop Ir.Mul (fop Ir.Mul (poly Rake_math.tanh_poly z) z) x) x in
        let result = sel f32_rack (cmp Ir.Eq x (k 0.0)) x small in
        let result = sel f32_rack (cmp Ir.Ge a (k Rake_math.tanh_switch)) big result in
        let result =
          sel f32_rack (cmp Ir.Gt a (k Rake_math.tanh_limit)) (sel f32_rack (cmp Ir.Gt x (k 0.0)) (k 1.0) (k (-1.0))) result
        in
        sel f32_rack (nan_lanes x) x result
  in
  (value, f32_rack)

(* Inlining of user crunches and rakes: set by the lowering entry points,
   implemented once the statement lowering below exists. *)
let callees : def StringMap.t ref = ref StringMap.empty

(** The opt-in relaxed profile: relaxed-SIMD operations lower only under it. *)
let relaxed = ref false

let inline_call :
    (state -> Ir.provenance -> loc -> def -> binding list -> (binding, error) result) ref =
  ref (fun _ _ loc _ _ -> error loc "inlining is not initialised")

let rec lower_expr state provenance (expr : expr) =
  match expr.v with
  | EVar name -> find_binding state expr.loc name
  | EScalarVar name | EBroadcast { v = EScalarVar name; _ } -> (
      let* scalar = find_binding state expr.loc name in
      match snd scalar with
      | Ir.Scalar Ir.F32 -> Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Broadcast (fst scalar)))
      | Ir.Scalar element when is_integer_element element ->
          Ok (emit state expr.loc provenance (Ir.Rack element) (Ir.Broadcast (fst scalar)))
      | _ -> expect_type expr.loc "uniform scalar use" (Ir.Scalar Ir.F32) scalar |> Result.map (fun () -> scalar))
  | EBroadcast { v = EFloat value; _ } ->
      Ok (rack_constant state expr.loc provenance value)
  | EFloat value ->
      Ok (rack_constant state expr.loc provenance value)
  | EInt value | EBroadcast { v = EInt value; _ } -> typed_literal state expr.loc provenance (Ir.Rack Ir.I32) value
  | EBinop (left, ((Add | Sub | Mul | Div) as operation), right) ->
      let* left, right = lower_operands state provenance left right in
      let* left, right = expect_same expr.loc "arithmetic" left right in
      (match snd left with
       | Ir.Rack element when is_integer_element element -> (
           match operation with
           | Add | Sub ->
               let operation = Option.get (ir_binary operation) in
               Ok (emit state expr.loc provenance (snd left) (Ir.Binary (operation, fst left, fst right)))
           | Mul when element <> Ir.U8 ->
               Ok (emit state expr.loc provenance (snd left) (Ir.Binary (Ir.Mul, fst left, fst right)))
           | Mul -> error expr.loc "wasm-simd128 has no byte multiply; widen the bytes first"
           | _ -> error expr.loc "integer racks have no lane division")
       | _ ->
           let* () = expect_type expr.loc "arithmetic" (Ir.Rack Ir.F32) left in
           let left_benign, right_benign =
             (Masked_safety.binop_operand operation 0, Masked_safety.binop_operand operation 1)
           in
           let operation = Option.get (ir_binary operation) in
           let left = sanitize_operand state expr.loc provenance left_benign left in
           let right = sanitize_operand state expr.loc provenance right_benign right in
           Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Binary (operation, fst left, fst right))))
  | EBinop (left, ((Lt | Le | Gt | Ge | Eq | Ne) as comparison), right) ->
      let* left, right = lower_operands state provenance left right in
      let* left, right = expect_same expr.loc "comparison" left right in
      let comparison = Option.get (ir_comparison comparison) in
      (match snd left with
       | Ir.Rack element when is_integer_element element ->
           Ok (emit state expr.loc provenance Ir.Mask (Ir.Compare (comparison, fst left, fst right)))
       | Ir.Scalar element when element <> Ir.I1 ->
           Ok (emit state expr.loc provenance (Ir.Scalar Ir.I1) (Ir.Compare (comparison, fst left, fst right)))
       | _ ->
           let* () = expect_type expr.loc "comparison" (Ir.Rack Ir.F32) left in
           let left = sanitize_operand state expr.loc provenance 0.0 left in
           let right = sanitize_operand state expr.loc provenance 0.0 right in
           Ok (emit state expr.loc provenance Ir.Mask (Ir.Compare (comparison, fst left, fst right))))
  | EBinop (left, ((And | Or) as operation), right) ->
      let* left = lower_expr state provenance left in
      let* right = lower_expr state provenance right in
      let* () = expect_type expr.loc "mask operation" Ir.Mask left in
      let* () = expect_type expr.loc "mask operation" Ir.Mask right in
      let operation = match operation with And -> Ir.And | Or -> Ir.Or | _ -> assert false in
      Ok (emit state expr.loc provenance Ir.Mask (Ir.Mask_binary (operation, fst left, fst right)))
  | EBinop (_, operation, _) ->
      errorf expr.loc "binary operator %s is not supported by native crunch lowering"
        (show_binop operation)
  | EUnop ((Neg | FNeg), operand) ->
      let* operand = lower_expr state provenance operand in
      (match snd operand with
       | Ir.Rack element when is_integer_element element && element <> Ir.U8 ->
           Ok (emit state expr.loc provenance (snd operand) (Ir.Unary (Ir.Neg, fst operand)))
       | _ ->
           let* () = expect_type expr.loc "negation" (Ir.Rack Ir.F32) operand in
           Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Unary (Ir.Neg, fst operand))))
  | ECall (("relaxed_madd" | "relaxed_nmadd" | "relaxed_min" | "relaxed_max") as name, arguments) ->
      if not !relaxed then
        errorf expr.loc "%s is a relaxed-SIMD operation, which only --target wasm-simd128-relaxed selects; the online judge hasn't been shown to accept relaxed SIMD" name
      else if provenance.Ir.through <> None then
        errorf expr.loc "%s is not defined under predication" name
      else
        let rec lower_all reversed = function
          | [] -> Ok (List.rev reversed)
          | a :: rest -> let* v = lower_expr state provenance a in lower_all (v :: reversed) rest
        in
        let* operands = lower_all [] arguments in
        let* () = List.fold_left (fun r v -> let* () = r in expect_type expr.loc name (Ir.Rack Ir.F32) v) (Ok ()) operands in
        Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Relaxed { name; operands = List.map fst operands }))
  | ECall (("exp" | "log" | "log2" | "tanh") as name, [ operand ]) ->
      let* operand = lower_expr state provenance operand in
      let* () = expect_type expr.loc name (Ir.Rack Ir.F32) operand in
      (* The input is sanitised once under predication; every later step is
         total on a benign lane, so the sequence runs unmasked. *)
      let x = sanitize_operand state expr.loc provenance 0.0 operand in
      Ok (expand_math state expr.loc name (fst x))
  | ECall (("abs" | "floor" | "ceil" | "trunc" | "nearest") as name, [ operand ]) ->
      let* operand = lower_expr state provenance operand in
      let unary =
        match name with
        | "abs" -> Ir.Abs | "floor" -> Ir.Floor | "ceil" -> Ir.Ceil | "trunc" -> Ir.Trunc | _ -> Ir.Nearest
      in
      (match (snd operand, unary) with
       | Ir.Rack Ir.F32, _ -> Ok (emit state expr.loc provenance (snd operand) (Ir.Unary (unary, fst operand)))
       | Ir.Rack (Ir.U8 | Ir.I16 | Ir.I32 | Ir.I64), Ir.Abs ->
           Ok (emit state expr.loc provenance (snd operand) (Ir.Unary (Ir.Abs, fst operand)))
       | typ, _ -> errorf expr.loc "%s of %s is not available" name (Ir.string_of_typ typ))
  | ECall (name, arguments) when StringMap.mem name !callees ->
      let callee = StringMap.find name !callees in
      let parameters =
        match callee.v with
        | DCrunch (_, parameters, _, _) | DRake (_, parameters, _, _, _, _, _) -> parameters
        | _ -> []
      in
      if List.length parameters <> List.length arguments then
        errorf expr.loc "%s takes %d arguments, got %d" name (List.length parameters) (List.length arguments)
      else
        let rec lower_arguments reversed = function
          | [], [] -> Ok (List.rev reversed)
          | parameter :: parameters, (argument : expr) :: rest ->
              (* A scalar parameter takes the uniform marked at the call; a
                 literal takes the type its parameter declares. *)
              let* value =
                match parameter with
                | PScalar (_, Some typ) ->
                    let* expected = ir_typ_of_annotation typ in
                    lower_scalar state argument expected
                | PRack (_, Some typ) when integer_literal argument <> None ->
                    let* expected = ir_typ_of_annotation typ in
                    typed_literal state argument.loc provenance expected (Option.get (integer_literal argument))
                | _ -> lower_expr state provenance argument
              in
              lower_arguments (value :: reversed) (parameters, rest)
          | _ -> errorf expr.loc "%s takes %d arguments" name (List.length parameters)
        in
        let* values = lower_arguments [] (parameters, arguments) in
        !inline_call state provenance expr.loc callee values
  | EIf (condition, if_true, if_false) -> lower_if state provenance expr.loc condition if_true if_false
  | EExtract (rack, lane) -> (
      match integer_literal lane with
      | None -> error lane.loc "a lane is chosen by an integer literal"
      | Some lane_value ->
          let* rack = lower_expr state provenance rack in
          (match snd rack with
           | Ir.Rack element ->
               let lanes = 16 / element_bytes element in
               if lane_value < 0L || lane_value >= Int64.of_int lanes then
                 errorf lane.loc "lane %Ld is outside a %d-lane rack" lane_value lanes
               else
                 let lane = emit state expr.loc Ir.source (Ir.Scalar Ir.I32) (Ir.Const (Ir.Int32 (Int64.to_int32 lane_value))) in
                 Ok (emit state expr.loc provenance (Ir.Scalar element) (Ir.Extract { rack = fst rack; lane = fst lane }))
           | typ -> errorf expr.loc "extract takes a rack, got %s" (Ir.string_of_typ typ)))
  | EInsert (rack, lane, inserted) -> (
      match integer_literal lane with
      | None -> error lane.loc "a lane is chosen by an integer literal"
      | Some lane_value ->
          let* rack = lower_expr state provenance rack in
          (match snd rack with
           | Ir.Rack element ->
               let lanes = 16 / element_bytes element in
               if lane_value < 0L || lane_value >= Int64.of_int lanes then
                 errorf lane.loc "lane %Ld is outside a %d-lane rack" lane_value lanes
               else
                 let* value = lower_scalar state inserted (Ir.Scalar element) in
                 let lane = emit state expr.loc Ir.source (Ir.Scalar Ir.I32) (Ir.Const (Ir.Int32 (Int64.to_int32 lane_value))) in
                 Ok (emit state expr.loc provenance (snd rack) (Ir.Insert { rack = fst rack; inserted = fst value; lane = fst lane }))
           | typ -> errorf expr.loc "insert takes a rack, got %s" (Ir.string_of_typ typ)))
  | EConvert (Convert_bitcast, target, operand) -> (
      let* target = ir_typ_of_annotation target in
      let* operand = lower_expr state provenance operand in
      match (target, snd operand) with
      | Ir.Rack element, (Ir.Rack _ | Ir.Mask) ->
          Ok (emit state expr.loc provenance target (Ir.Reinterpret { operand = fst operand; element }))
      | _ -> errorf expr.loc "bitcast reinterprets a rack as a rack of another element")
  | EUnop (Not, operand) ->
      let* operand = lower_expr state provenance operand in
      let* () = expect_type expr.loc "mask not" Ir.Mask operand in
      Ok (emit state expr.loc provenance Ir.Mask (Ir.Mask_not (fst operand)))
  | ECall ("sqrt", [ operand ]) ->
      let* operand = lower_expr state provenance operand in
      let* () = expect_type expr.loc "sqrt" (Ir.Rack Ir.F32) operand in
      let operand = sanitize_operand state expr.loc provenance 1.0 operand in
      Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Unary (Ir.Sqrt, fst operand)))
  | ECall ("sqrt", arguments) ->
      errorf expr.loc "sqrt expects one argument, got %d" (List.length arguments)
  | ECall ("select", [ condition; if_true; if_false ]) ->
      let* condition = lower_expr state provenance condition in
      let* if_true = lower_expr state provenance if_true in
      let* if_false = lower_expr state provenance if_false in
      let* () = expect_type expr.loc "select condition" Ir.Mask condition in
      let* if_true, if_false = expect_same expr.loc "select" if_true if_false in
      let* () = match snd if_true with Ir.Rack _ -> Ok () | _ -> expect_type expr.loc "select arms" (Ir.Rack Ir.F32) if_true in
      Ok
        (emit state expr.loc provenance (snd if_true)
           (Ir.Select
              { condition = fst condition; if_true = fst if_true; if_false = fst if_false }))
  | ECall ("select", arguments) ->
      errorf expr.loc "select expects three arguments, got %d" (List.length arguments)
  | ECall ("bitmask", [ operand ]) ->
      if provenance.Ir.through <> None then
        error expr.loc "bitmask is a cross-lane reduction and is forbidden in predicated regions"
      else
        let* operand = lower_expr state provenance operand in
        let* () = expect_type expr.loc "bitmask" Ir.Mask operand in
        Ok (emit state expr.loc provenance (Ir.Scalar Ir.I32) (Ir.Reduce (Ir.Reduce_bitmask, fst operand)))
  | ECall (("min" | "max") as name, [ a; b ]) ->
      (* i16, i32 and f32 racks; an integer literal becomes a splat of the integer rack beside it. *)
      let literal_first = integer_literal a <> None in
      let rack_expr, other_expr = if literal_first then (b, a) else (a, b) in
      let* rack = lower_expr state provenance rack_expr in
      if not (is_integer_rack (snd rack) || snd rack = Ir.Rack Ir.F32 || snd rack = Ir.Rack Ir.U8) then
        errorf expr.loc "native %s is available for u8, i16, i32 and f32 racks only" name
      else
        let* other =
          match integer_literal other_expr with
          | Some value -> typed_literal state other_expr.loc provenance (snd rack) value
          | None ->
              let* other = lower_expr state provenance other_expr in
              let* rack, other = expect_same expr.loc name rack other in
              ignore rack;
              Ok other
        in
        let left, right = if literal_first then (other, rack) else (rack, other) in
        (* Under predication an f32 operand is sanitised, as every masked f32 operation is. *)
        let left, right =
          if snd left = Ir.Rack Ir.F32 then
            (sanitize_operand state expr.loc provenance 0.0 left, sanitize_operand state expr.loc provenance 0.0 right)
          else (left, right)
        in
        let operation = if name = "min" then Ir.Min else Ir.Max in
        Ok (emit state expr.loc provenance (snd rack) (Ir.Binary (operation, fst left, fst right)))
  | ECall (("dot" | "narrow") as name, [ a; b ]) ->
      let* a = lower_expr state provenance a in
      let* b = lower_expr state provenance b in
      let operand, result = if name = "dot" then (Ir.Rack Ir.I16, Ir.Rack Ir.I32) else (Ir.Rack Ir.I32, Ir.Rack Ir.I16) in
      let* () = expect_type expr.loc name operand a in
      let* () = expect_type expr.loc name operand b in
      let op = if name = "dot" then Ir.Dot (fst a, fst b) else Ir.Narrow (fst a, fst b) in
      Ok (emit state expr.loc provenance result op)
  | ECall (("widen_low" | "widen_high") as name, [ x ]) ->
      let* x = lower_expr state provenance x in
      let* () = expect_type expr.loc name (Ir.Rack Ir.U8) x in
      Ok (emit state expr.loc provenance (Ir.Rack Ir.I16) (Ir.Widen { operand = fst x; high = name = "widen_high" }))
  | ECall (("to_f32" | "to_i32") as name, [ x ]) ->
      let* x = lower_expr state provenance x in
      let operand, element = if name = "to_f32" then (Ir.Rack Ir.I32, Ir.F32) else (Ir.Rack Ir.F32, Ir.I32) in
      let* () = expect_type expr.loc name operand x in
      Ok (emit state expr.loc provenance (Ir.Rack element) (Ir.Convert { operand = fst x; element }))
  | ECall (("bit_and" | "bit_or" | "bit_xor" | "bit_andnot") as name, [ a; b ]) ->
        let* a, b = lower_operands state provenance a b in
        let* a, b = expect_same expr.loc name a b in
        if lane_bits (snd a) = None then errorf expr.loc "%s takes two equal integer racks" name
        else
          let operation =
            match name with
            | "bit_and" -> Ir.And | "bit_or" -> Ir.Or | "bit_xor" -> Ir.Xor | _ -> Ir.Andnot
          in
          Ok (emit state expr.loc provenance (snd a) (Ir.Binary (operation, fst a, fst b)))
  | ECall (("shift_bits_left" | "shift_bits_right" | "shift_bits_right_signed") as name, [ x; count ]) ->
        let* x = lower_expr state provenance x in
        (match lane_bits (snd x) with
         | None -> errorf expr.loc "%s shifts an integer rack" name
         | Some bits ->
             let* count =
               match (integer_literal count, count.v) with
               | Some value, _ ->
                   if value < 0L || value >= Int64.of_int bits then
                     errorf count.loc "a shift of %d-bit lanes takes a count from 0 to %d, got %Ld" bits (bits - 1) value
                   else
                     Ok (fst (emit state count.loc provenance (Ir.Scalar Ir.I32) (Ir.Const (Ir.Int32 (Int64.to_int32 value)))))
               | None, (EScalarVar scalar | EBroadcast { v = EScalarVar scalar; _ }) ->
                   let* found = find_binding state count.loc scalar in
                   let* () = expect_type count.loc name (Ir.Scalar Ir.I32) found in
                   Ok (fst found)
               | None, _ -> errorf count.loc "%s takes its count as an integer literal or a uniform u32" name
             in
             let shift =
               match name with
               | "shift_bits_left" -> Ir.Shift_left | "shift_bits_right" -> Ir.Shift_right | _ -> Ir.Shift_right_signed
             in
             Ok (emit state expr.loc provenance (snd x) (Ir.Shift { operand = fst x; count; shift })))
  | ECall (name, _) -> errorf expr.loc "call to '%s' is not supported by native crunch lowering" name
  | EFma (a, b, c) ->
      let* a = lower_expr state provenance a in
      let* b = lower_expr state provenance b in
      let* c = lower_expr state provenance c in
      let* a, b = expect_same expr.loc "fma" a b in
      let* a, c = expect_same expr.loc "fma" a c in
      let* () = expect_type expr.loc "fma" (Ir.Rack Ir.F32) a in
      let a = sanitize_operand state expr.loc provenance (Masked_safety.fma_operand 0) a in
      let b = sanitize_operand state expr.loc provenance (Masked_safety.fma_operand 1) b in
      let c = sanitize_operand state expr.loc provenance (Masked_safety.fma_operand 2) c in
      Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Fma (fst a, fst b, fst c)))
  | EBool _ -> error expr.loc "boolean literals are not supported by native crunch lowering"
  | ELambda _ -> error expr.loc "lambdas are not supported by native crunch lowering"
  | EPipe _ -> error expr.loc "pipelines are not supported by native crunch lowering"
  | EFusedPipe _ -> error expr.loc "fused pipelines are not supported by native crunch lowering"
  | ELet _ -> error expr.loc "expression-local let is not supported by native crunch lowering"
  | EField _ -> error expr.loc "field access is not supported by native crunch lowering"
  | ERecord _ -> error expr.loc "record construction is not supported by native crunch lowering"
  | EWith _ -> error expr.loc "record updates are not supported by native crunch lowering"
  | ELaneIndex -> error expr.loc "lane indices are not supported by native crunch lowering"
  | ELanes -> error expr.loc "lane counts are not supported by native crunch lowering"
  | EReduce (operation, operand) ->
      if provenance.Ir.through <> None then
        error expr.loc "reductions are forbidden in predicated regions"
      else
        let* operand = lower_expr state provenance operand in
        if snd operand = Ir.Mask && (operation = RAnd || operation = ROr) then
          Ok (emit state expr.loc provenance (Ir.Scalar Ir.I1)
                (Ir.Reduce ((if operation = RAnd then Ir.Reduce_and else Ir.Reduce_or), fst operand)))
        else
        let* () = expect_type expr.loc "f32 reduction" (Ir.Rack Ir.F32) operand in
        (match ir_reduction operation with
        | Some operation ->
            Ok
              (emit state expr.loc provenance (Ir.Scalar Ir.F32)
                 (Ir.Reduce (operation, fst operand)))
        | None -> error expr.loc "logical mask reductions are not implemented")
  | EScan (operation, operand) ->
      if provenance.Ir.through <> None then
        error expr.loc "prefix scans are forbidden in predicated regions"
      else
        let* operand = lower_expr state provenance operand in
        let* () = expect_type expr.loc "f32 prefix scan" (Ir.Rack Ir.F32) operand in
        (match ir_scan operation with
        | Some operation ->
            Ok
              (emit state expr.loc provenance (Ir.Rack Ir.F32)
                 (Ir.Scan (operation, fst operand)))
        | None -> error expr.loc "logical prefix scans are not defined")
  | EShuffle (operand, indices) ->
      let rack_exprs = match operand.v with ETuple racks -> racks | _ -> [ operand ] in
      let rec lower_racks reversed = function
        | [] -> Ok (List.rev reversed)
        | rack :: rest ->
            let* rack = lower_expr state provenance rack in
            lower_racks (rack :: reversed) rest
      in
      let* racks = lower_racks [] rack_exprs in
      (match racks with
       | (_, (Ir.Rack _ as typ)) :: rest when List.for_all (fun (_, other) -> other = typ) rest ->
           Ok (emit state expr.loc provenance typ
                 (Ir.Shuffle { racks = List.map fst racks; indices }))
       | _ -> error expr.loc "shuffle requires one rack or two equal racks")
  | EShift _ -> error expr.loc "lane shifts are not supported by native crunch lowering"
  | ERotate _ -> error expr.loc "lane rotates are not supported by native crunch lowering"
  | EGather _ -> error expr.loc "gather is not supported by native crunch lowering"
  | EScatter _ -> error expr.loc "scatter is not supported by native crunch lowering"
  | ECompress _ -> error expr.loc "compression is not supported by native crunch lowering"
  | EExpand _ -> error expr.loc "expansion is not supported by native crunch lowering"
  | ETines _ -> error expr.loc "inline tines are not supported by native crunch lowering"
  | EOuter _ -> error expr.loc "outer products are not supported by native crunch lowering"
  | ETuple _ -> error expr.loc "tuples are not supported by native crunch lowering"
  | EBroadcast _ ->
      error expr.loc
        "native crunch lowering currently supports broadcasts of literal f32 values"
  | EUnit -> error expr.loc "unit expressions are not supported by native crunch lowering"
  | EString _ | EIndex _ | EConvert _ | EArray _ | ESlow _ ->
      errorf expr.loc "%s is not supported by native crunch lowering"
        (Capabilities.id (Capabilities.feature_of_expr expr.v))

(** Two operands, an integer literal among them typed by the other. Without
    a literal they are lowered left to right, as they always were. *)
and lower_operands state provenance left right =
  match (integer_literal left, integer_literal right) with
  | Some value, None ->
      let* right = lower_expr state provenance right in
      let* left = typed_literal state left.loc provenance (snd right) value in
      Ok (left, right)
  | None, Some value ->
      let* left = lower_expr state provenance left in
      let* right = typed_literal state right.loc provenance (snd left) value in
      Ok (left, right)
  | _ ->
      let* left = lower_expr state provenance left in
      let* right = lower_expr state provenance right in
      Ok (left, right)

(** A uniform scalar of the given type: a scalar name, or a literal. *)
and lower_scalar state (expr : expr) typ =
  match (expr.v, typ) with
  | (EScalarVar name | EBroadcast { v = EScalarVar name; _ } | EVar name), _ ->
      let* value = find_binding state expr.loc name in
      let* () = expect_type expr.loc "a uniform scalar" typ value in
      Ok value
  | (EInt value | EBroadcast { v = EInt value; _ }), Ir.Scalar element when is_integer_element element ->
      let literal =
        match element with
        | Ir.U8 -> Ir.Uint8 (Int64.to_int value)
        | Ir.I16 -> Ir.Int16 (Int64.to_int value)
        | Ir.I64 -> Ir.Int64 value
        | _ -> Ir.Int32 (Int64.to_int32 value)
      in
      Ok (emit state expr.loc Ir.source typ (Ir.Const literal))
  | (EFloat value | EBroadcast { v = EFloat value; _ }), Ir.Scalar Ir.F32 ->
      Ok (emit state expr.loc Ir.source typ (Ir.Const (Ir.Float32_bits (Int32.bits_of_float value))))
  | (EInt value | EBroadcast { v = EInt value; _ }), Ir.Scalar Ir.F32 ->
      Ok (emit state expr.loc Ir.source typ (Ir.Const (Ir.Float32_bits (Int32.bits_of_float (Int64.to_float value)))))
  | _ -> errorf expr.loc "a uniform %s is written <name> or a literal" (Ir.string_of_typ typ)

(** Whether an expression is a uniform condition: comparisons of uniform
    scalars and literals, or a uniform bool. *)
and is_uniform (expr : expr) =
  match expr.v with
  | EScalarVar _ | EInt _ | EFloat _ | EBool _ | EBroadcast { v = EScalarVar _ | EInt _ | EFloat _; _ } -> true
  | EBinop (l, (Lt | Le | Gt | Ge | Eq | Ne), r) -> is_uniform l && is_uniform r
  | _ -> false

and uniform_condition state (expr : expr) =
  match expr.v with
  | EScalarVar name | EBroadcast { v = EScalarVar name; _ } ->
      let* value = find_binding state expr.loc name in
      let* () = expect_type expr.loc "a uniform condition" (Ir.Scalar Ir.I1) value in
      Ok value
  | EBinop (l, ((Lt | Le | Gt | Ge | Eq | Ne) as comparison), r) ->
      let scalar_of (e : expr) =
        match e.v with
        | EScalarVar name | EBroadcast { v = EScalarVar name; _ } -> Option.map snd (StringMap.find_opt name state.bindings)
        | _ -> None
      in
      let typ =
        match (scalar_of l, scalar_of r) with
        | Some t, _ | None, Some t -> Ok t
        | None, None -> error expr.loc "a uniform comparison names at least one uniform scalar"
      in
      let* typ = typ in
      let* l = lower_scalar state l typ in
      let* r = lower_scalar state r typ in
      Ok (emit state expr.loc Ir.source (Ir.Scalar Ir.I1)
            (Ir.Compare (Option.get (ir_comparison comparison), fst l, fst r)))
  | _ -> error expr.loc "a uniform condition is a uniform bool or a comparison of uniform scalars"

(** Value-producing if. A uniform condition chooses one whole rack; both
    candidates are pure, so computing both and selecting is unobservable. A
    mask chooses each lane: each candidate is computed under its lanes'
    predication, so inactive lanes are sanitised exactly as in a through
    region, then a vector select merges them. *)
and lower_if state provenance loc condition if_true if_false =
  if is_uniform condition then
    let* condition = uniform_condition state condition in
    let* if_true, if_false = lower_operands state provenance if_true if_false in
    let* if_true, if_false = expect_same loc "if" if_true if_false in
    Ok (emit state loc provenance (snd if_true)
          (Ir.Select { condition = fst condition; if_true = fst if_true; if_false = fst if_false }))
  else
    let* mask = lower_expr state provenance condition in
    let* () = expect_type loc "an if mask" Ir.Mask mask in
    (* The branch masks belong to the conditional's fused region, if any. *)
    let mask_provenance = { Ir.source with fused = provenance.Ir.fused } in
    let within active =
      match provenance.Ir.through with
      | None -> active
      | Some outer -> fst (emit state loc mask_provenance Ir.Mask (Ir.Mask_binary (Ir.And, outer, active)))
    in
    let inactive = fst (emit state loc mask_provenance Ir.Mask (Ir.Mask_not (fst mask))) in
    let true_provenance = { provenance with through = Some (within (fst mask)) } in
    let false_provenance = { provenance with through = Some (within inactive) } in
    let* if_true, if_false =
      match (integer_literal if_true, integer_literal if_false) with
      | Some value, None ->
          let* b = lower_expr state false_provenance if_false in
          let* a = typed_literal state if_true.loc true_provenance (snd b) value in
          Ok (a, b)
      | None, Some value ->
          let* a = lower_expr state true_provenance if_true in
          let* b = typed_literal state if_false.loc false_provenance (snd a) value in
          Ok (a, b)
      | _ ->
          let* a = lower_expr state true_provenance if_true in
          let* b = lower_expr state false_provenance if_false in
          Ok (a, b)
    in
    let* if_true, if_false = expect_same loc "if" if_true if_false in
    Ok (emit state loc provenance (snd if_true)
          (Ir.Select { condition = fst mask; if_true = fst if_true; if_false = fst if_false }))

let lower_binding state provenance loc name annotation expression =
  (* A scalar result retains its uniform value; rack use still broadcasts.
     Reductions and calls produce their own scalar IR through lower_expr. *)
  let* value = match annotation, expression.v with
    | Some ({ v = TScalar _; _ } as annotation),
      (EScalarVar _ | EVar _ | EFloat _ | EInt _
       | EBroadcast { v = EScalarVar _ | EFloat _ | EInt _; _ }) ->
        let* typ = ir_typ_of_annotation annotation in
        lower_scalar state expression typ
    | _ -> lower_expr state provenance expression
  in
  let* () = check_annotation annotation (snd value) in
  let* () = bind state loc name value in
  Ok value

(** A statement of a crunch body, or of a crunch or rake inlined under the
    caller's predication [through]. Mutable locations are SSA rebindings, and
    [repeat] unrolls: a crunch stays straight-line code. *)
let rec lower_statement_in state ~through active_fused (statement : stmt) =
  let plain = { Ir.source with through } in
  match statement.v with
  | SFused binding ->
      let region =
        match active_fused with
        | Some region -> region
        | None ->
            let region = state.next_fused_region in
            state.next_fused_region <- region + 1;
            region
      in
      let provenance = { Ir.fused = Some region; through } in
      let* _ =
        lower_binding state provenance statement.loc binding.fused_name binding.fused_type
          binding.fused_expr
      in
      Ok (Some region)
  | SLet binding ->
      let* _ =
        lower_binding state plain statement.loc binding.bind_name binding.bind_type
          binding.bind_expr
      in
      Ok None
  | SExpr expression ->
      let* _ = lower_expr state plain expression in
      Ok None
  | SUniform binding ->
      let* value = lower_expr state plain binding.bind_expr in
      (match snd value with
       | Ir.Scalar _ ->
           let* () = check_annotation binding.bind_type (snd value) in
           let* () = bind state statement.loc binding.bind_name value in
           Ok None
       | typ -> errorf statement.loc "<%s> is a uniform scalar, but its value is %s" binding.bind_name (Ir.string_of_typ typ))
  | SLocBind { loc_name; loc_type; loc_expr } ->
      let* _ = lower_binding state plain statement.loc loc_name loc_type loc_expr in
      state.locations <- StringMap.add loc_name () state.locations;
      Ok None
  | SAssign (name, expression) ->
      if not (StringMap.mem name state.locations) then
        errorf statement.loc "assignment is not supported to '%s': it is not a mutable location bound with :=" name
      else
        let* previous = find_binding state statement.loc name in
        let* value = lower_expr state plain expression in
        let* () = expect_type statement.loc ("the value assigned to " ^ name) (snd previous) value in
        state.bindings <- StringMap.add name value state.bindings;
        Ok None
  | SLoop ({ loop_repeat = true; _ } as loop) -> (
      match (integer_literal loop.loop_from, integer_literal loop.loop_to) with
      | Some first, Some stop ->
          let rec copies k =
            if k >= stop then Ok None
            else
              let saved = state.bindings in
              let index =
                emit state statement.loc Ir.source (Ir.Scalar Ir.I32) (Ir.Const (Ir.Int32 (Int64.to_int32 k)))
              in
              let* () = bind state statement.loc loop.loop_var index in
              let* () = lower_statements_in state ~through loop.loop_body in
              (* The copy's own names end with it; outer locations keep their new values. *)
              state.bindings <-
                StringMap.mapi
                  (fun name value ->
                    if StringMap.mem name state.locations then
                      Option.value (StringMap.find_opt name state.bindings) ~default:value
                    else value)
                  saved;
              copies (Int64.add k 1L)
          in
          copies first
      | _ -> error statement.loc "repeat's bounds are integer literals")
  | SOver _ -> error statement.loc "over loops are not supported by native crunch lowering"
  | SStore _ | SReturn _ | SYield _ | SBreak | SContinue | SIf _ | SWhile _ | SLoop _ ->
      errorf statement.loc "%s is not supported by native crunch lowering"
        (Capabilities.id (Capabilities.feature_of_stmt statement.v))

and lower_statements_in state ~through statements =
  let rec go active_fused = function
    | [] -> Ok ()
    | statement :: rest ->
        let* active_fused = lower_statement_in state ~through active_fused statement in
        go active_fused rest
  in
  go None statements

let lower_statement state active_fused statement = lower_statement_in state ~through:None active_fused statement

let add_parameter state function_loc index = function
  | PRack (name, annotation) ->
      let* () =
        match annotation with
        | None -> Ok ()
        | Some typ ->
            let* typ = ir_typ_of_annotation typ in
            if List.mem typ (Ir.Mask :: native_racks) then Ok ()
            else error function_loc "native crunch parameters must be f32, u8, i16 or i32 racks"
      in
      let typ =
        match Option.map ir_typ_of_annotation annotation with
        | Some (Ok typ) -> typ
        | _ -> Ir.Rack Ir.F32
      in
      let parameter = { Ir.id = index; typ; name = Some name } in
      let* () = bind state function_loc name (index, typ) in
      Ok parameter
  | PScalar (name, annotation) ->
      let* typ =
        match annotation with
        | None -> Ok (Ir.Scalar Ir.F32)
        | Some typ ->
            let* typ = ir_typ_of_annotation typ in
            if List.mem typ Ir.[ Scalar F32; Scalar I32; Scalar I16; Scalar U8; Scalar I64; Scalar I1 ] then Ok typ
            else error function_loc "native scalar crunch parameters must be f32 or u32"
      in
      let parameter = { Ir.id = index; typ; name = Some name } in
      let* () = bind state function_loc name (index, typ) in
      Ok parameter
  | PSpread _ -> error function_loc "spread crunch parameters are not supported by native lowering"

let result_annotation result body =
  List.map (fun (statement : stmt) -> match statement.v with
    | SLet binding when binding.bind_name = result.result_name ->
        { statement with v = SLet { binding with bind_type = result.result_type } }
    | _ -> statement) body

let lower_crunch definition_loc name parameters result body =
  let state =
    {
      next_value = List.length parameters;
      next_fused_region = 0;
      instructions_rev = [];
      bindings = StringMap.empty;
      tines = StringMap.empty;
      rack_constants = Int32Map.empty;
      mask_constants = (None, None);
      locations = StringMap.empty;
    }
  in
  let rec add_parameters index reversed = function
    | [] -> Ok (List.rev reversed)
    | parameter :: rest ->
        let* parameter = add_parameter state definition_loc index parameter in
        add_parameters (index + 1) (parameter :: reversed) rest
  in
  let* parameters = add_parameters 0 [] parameters in
  let* () =
    match result.result_type with
    | None -> Ok ()
    | Some annotation ->
        let* typ = ir_typ_of_annotation annotation in
        if List.mem typ (native_racks @ Ir.[ Scalar F32; Scalar I32; Mask; Scalar I1; Scalar I16; Scalar U8; Scalar I64 ]) then Ok ()
        else error annotation.loc "native crunch results must be an f32, u8, i16 or i32 rack, or an f32 or u32 scalar"
  in
  let rec lower_body active_fused = function
    | [] -> Ok ()
    | statement :: rest ->
        let* active_fused = lower_statement state active_fused statement in
        lower_body active_fused rest
  in
  let* () = lower_body None (result_annotation result body) in
  let* return_value = find_binding state definition_loc result.result_name in
  let* () =
    match result.result_type with
    | Some annotation -> check_annotation (Some annotation) (snd return_value)
    | None -> expect_type definition_loc "implicit crunch result" (Ir.Rack Ir.F32) return_value
  in
  let func =
    {
      Ir.name;
      parameters;
      result = Some (snd return_value);
      body =
        {
          instructions = List.rev state.instructions_rev;
          terminators = [ Ir.Return (Some (fst return_value)) ];
        };
      loc = ir_location definition_loc;
    }
  in
  match Ir.verify_function func with
  | Ok () -> Ok func
  | Error errors ->
      errorf definition_loc "generated invalid native IR: %s"
        (String.concat "; " (List.map Ir.format_error errors))

let rec lower_predicate state (predicate : predicate) =
  match predicate.v with
  | PExpr expression ->
      let* value = lower_expr state Ir.source expression in
      let* () = expect_type predicate.loc "predicate" Ir.Mask value in
      Ok value
  | PCmp (left, comparison, right) ->
      let operation =
        match comparison with
        | CLt -> Lt | CLe -> Le | CGt -> Gt | CGe -> Ge | CEq -> Eq | CNe -> Ne
      in
      lower_expr state Ir.source (node (EBinop (left, operation, right)) predicate.loc)
  | PIs (left, right) ->
      lower_expr state Ir.source (node (EBinop (left, Eq, right)) predicate.loc)
  | PIsNot (left, right) ->
      lower_expr state Ir.source (node (EBinop (left, Ne, right)) predicate.loc)
  | PAnd (left, right) | POr (left, right) ->
      let* left = lower_predicate state left in
      let* right = lower_predicate state right in
      let operation = match predicate.v with PAnd _ -> Ir.And | _ -> Ir.Or in
      Ok
        (emit state predicate.loc Ir.source Ir.Mask
           (Ir.Mask_binary (operation, fst left, fst right)))
  | PNot inner ->
      let* inner = lower_predicate state inner in
      Ok (emit state predicate.loc Ir.source Ir.Mask (Ir.Mask_not (fst inner)))
  | PTineRef name -> (
      match StringMap.find_opt name state.tines with
      | Some value -> Ok value
      | None -> errorf predicate.loc "undefined or forward tine reference '#%s'" name)

let lower_tine_ref state loc = function
  | TRSingle name -> (
      match StringMap.find_opt name state.tines with
      | Some value -> Ok value
      | None -> errorf loc "undefined tine '#%s'" name)
  | TRComposed predicate -> lower_predicate state predicate

let lower_through ?outer state (through : through) =
  let* mask = lower_tine_ref state through.through_result.loc through.through_tine in
  let outer_bindings = state.bindings in
  (* Inlined under a caller's predication, the body's lanes are both masks' lanes. *)
  let active =
    match outer with
    | None -> fst mask
    | Some outer -> fst (emit state through.through_result.loc Ir.source Ir.Mask (Ir.Mask_binary (Ir.And, outer, fst mask)))
  in
  let provenance = { Ir.source with through = Some active } in
  (* Consecutive fused bindings share a region, as in a crunch body. *)
  let rec lower_body active_fused = function
    | [] -> Ok ()
    | statement :: rest -> (
        match statement.v with
        | SLet binding ->
            let* _ =
              lower_binding state provenance statement.loc binding.bind_name
                binding.bind_type binding.bind_expr
            in
            lower_body None rest
        | SExpr expression ->
            let* _ = lower_expr state provenance expression in
            lower_body None rest
        | SFused binding ->
            let region =
              match active_fused with
              | Some region -> region
              | None ->
                  let region = state.next_fused_region in
                  state.next_fused_region <- region + 1;
                  region
            in
            let* _ =
              lower_binding state { provenance with fused = Some region } statement.loc
                binding.fused_name binding.fused_type binding.fused_expr
            in
            lower_body (Some region) rest
        | SLocBind _ | SAssign _ | SOver _ | SUniform _ | SStore _ | SReturn _ | SYield _ | SBreak | SContinue
        | SIf _ | SWhile _ | SLoop _ ->
            error statement.loc "effectful statements are forbidden in native through blocks")
  in
  let* () = lower_body None through.through_body in
  let* computed = lower_expr state provenance through.through_result in
  state.bindings <- outer_bindings;
  let* passthrough =
    match through.through_passthru with
    | Some expression -> lower_expr state Ir.source expression
    | None -> Ok (rack_constant state through.through_result.loc Ir.source 0.0)
  in
  let* computed, passthrough =
    expect_same through.through_result.loc "through result" computed passthrough
  in
  let selected =
    emit state through.through_result.loc Ir.source (snd computed)
      (Ir.Select
         { condition = fst mask; if_true = fst computed; if_false = fst passthrough })
  in
  bind state through.through_result.loc through.through_binding selected

let rec expression_needs_inactive_guard (expression : expr) =
  match expression.v with
  | EBinop (_, (Add | Sub | Mul | Div | Lt | Le | Gt | Ge | Eq | Ne), _) -> true
  | EFma _ | ECall ("sqrt", _) -> true
  | EBinop (left, (And | Or), right)
  | EPipe (left, right) | EFusedPipe (left, right) ->
      expression_needs_inactive_guard left || expression_needs_inactive_guard right
  | EUnop (_, inner) | EBroadcast inner | EField (inner, _) ->
      expression_needs_inactive_guard inner
  | ECall ("select", arguments) -> List.exists expression_needs_inactive_guard arguments
  | ELet (binding, body) ->
      expression_needs_inactive_guard binding.bind_expr
      || expression_needs_inactive_guard body
  | EInt _ | EFloat _ | EBool _ | EVar _ | EScalarVar _ | ELaneIndex
  | ELanes | EUnit -> false
  | _ -> true

let lower_sweep ?outer state definition_loc (sweep : sweep) =
  let within loc effective =
    match outer with
    | None -> effective
    | Some outer -> fst (emit state loc Ir.source Ir.Mask (Ir.Mask_binary (Ir.And, outer, effective)))
  in
  let unmasked = { Ir.source with through = outer } in
  let needs_effective_masks =
    List.exists (fun arm -> expression_needs_inactive_guard arm.arm_value)
      sweep.sweep_arms
  in
  let claimed =
    ref
      (if needs_effective_masks then mask_constant state definition_loc false
       else (-1, Ir.Mask))
  in
  let named_rev = ref [] in
  let catchall = ref None in
  let rec lower_arms = function
    | [] -> Ok ()
    | arm :: rest -> (
        match arm.arm_tine with
        | Some name ->
            let* tine =
              match StringMap.find_opt name state.tines with
              | Some value -> Ok value
              | None -> errorf arm.arm_value.loc "undefined sweep tine '#%s'" name
            in
            let provenance =
              if not needs_effective_masks then unmasked
              else
                let not_claimed =
                  emit state arm.arm_value.loc Ir.source Ir.Mask
                    (Ir.Mask_not (fst !claimed))
                in
                let effective =
                  emit state arm.arm_value.loc Ir.source Ir.Mask
                    (Ir.Mask_binary (Ir.And, fst tine, fst not_claimed))
                in
                { Ir.source with through = Some (within arm.arm_value.loc (fst effective)) }
            in
            let* candidate = lower_expr state provenance arm.arm_value in
            named_rev := (tine, candidate, arm.arm_value.loc) :: !named_rev;
            if needs_effective_masks then
              claimed :=
                emit state arm.arm_value.loc Ir.source Ir.Mask
                  (Ir.Mask_binary (Ir.Or, fst !claimed, fst tine));
            lower_arms rest
        | None ->
            let provenance =
              if not needs_effective_masks then unmasked
              else
                let effective =
                  emit state arm.arm_value.loc Ir.source Ir.Mask
                    (Ir.Mask_not (fst !claimed))
                in
                { Ir.source with through = Some (within arm.arm_value.loc (fst effective)) }
            in
            let* candidate = lower_expr state provenance arm.arm_value in
            catchall := Some candidate;
            lower_arms rest)
  in
  let* () = lower_arms sweep.sweep_arms in
  let* seed =
    match !catchall with
    | Some value -> Ok value
    | None -> error definition_loc "native sweep requires a final catch-all arm"
  in
  let result =
    List.fold_left
      (fun accumulator (tine, candidate, loc) ->
        emit state loc Ir.source (snd accumulator)
          (Ir.Select
             { condition = fst tine; if_true = fst candidate; if_false = fst accumulator }))
      seed !named_rev
  in
  let* () = bind state definition_loc sweep.sweep_binding result in
  Ok result

let lower_rake definition_loc name parameters result setup tines throughs sweep =
  let state =
    {
      next_value = List.length parameters;
      next_fused_region = 0;
      instructions_rev = [];
      bindings = StringMap.empty;
      tines = StringMap.empty;
      rack_constants = Int32Map.empty;
      mask_constants = (None, None);
      locations = StringMap.empty;
    }
  in
  let rec add_parameters index reversed = function
    | [] -> Ok (List.rev reversed)
    | parameter :: rest ->
        let* parameter = add_parameter state definition_loc index parameter in
        add_parameters (index + 1) (parameter :: reversed) rest
  in
  let* parameters = add_parameters 0 [] parameters in
  let rec lower_setup active_fused = function
    | [] -> Ok ()
    | statement :: rest ->
        let* active_fused = lower_statement state active_fused statement in
        lower_setup active_fused rest
  in
  let* () = lower_setup None setup in
  let rec lower_tines = function
    | [] -> Ok ()
    | tine :: rest ->
        if StringMap.mem tine.tine_name state.tines then
          errorf tine.tine_pred.loc "duplicate tine '#%s'" tine.tine_name
        else
          let* value = lower_predicate state tine.tine_pred in
          state.tines <- StringMap.add tine.tine_name value state.tines;
          lower_tines rest
  in
  let* () = lower_tines tines in
  let rec lower_throughs = function
    | [] -> Ok ()
    | through :: rest ->
        let* () = lower_through state through in
        lower_throughs rest
  in
  let* () = lower_throughs throughs in
  let* sweep_value = lower_sweep state definition_loc sweep in
  let* return_value =
    match StringMap.find_opt result.result_name state.bindings with
    | Some value -> Ok value
    | None when result.result_name = sweep.sweep_binding -> Ok sweep_value
    | None ->
        errorf definition_loc
          "rake result '%s' must name the total sweep binding '%s'"
          result.result_name sweep.sweep_binding
  in
  let* () = expect_type definition_loc "rake result" (Ir.Rack Ir.F32) return_value in
  let func =
    {
      Ir.name;
      parameters;
      result = Some (Ir.Rack Ir.F32);
      body =
        {
          instructions = List.rev state.instructions_rev;
          terminators = [ Ir.Return (Some (fst return_value)) ];
        };
      loc = ir_location definition_loc;
    }
  in
  match Ir.verify_function func with
  | Ok () -> Ok func
  | Error errors ->
      errorf definition_loc "generated invalid native rake IR: %s"
        (String.concat "; " (List.map Ir.format_error errors))

(** Inlining a call to a user crunch or rake: the callee's body is lowered
    in the caller's function, with its parameters bound to the arguments and
    its operations under the caller's predication. Vector code calls no
    function at run time. *)
let inline_depth = ref 0

let inline_definition state (provenance : Ir.provenance) loc (callee : def) values =
  let bind_parameters parameters =
    let rec go = function
      | [], [] -> Ok ()
      | parameter :: parameters, value :: values ->
          let name, annotation = match parameter with PRack (n, a) | PScalar (n, a) -> (n, a) | PSpread _ -> ("", None) in
          let* () =
            match annotation with
            | Some typ ->
                let* expected = ir_typ_of_annotation typ in
                expect_type loc ("argument " ^ name) expected value
            | None -> Ok ()
          in
          let* () = bind state loc name value in
          go (parameters, values)
      | _ -> error loc "argument count mismatch"
    in
    go (parameters, values)
  in
  if !inline_depth > 32 then error loc "crunch calls nest more than 32 deep; recursion has no vector meaning"
  else (
    incr inline_depth;
    let saved_bindings = state.bindings and saved_locations = state.locations and saved_tines = state.tines in
    state.bindings <- StringMap.empty;
    state.locations <- StringMap.empty;
    state.tines <- StringMap.empty;
    let through = provenance.through in
    let result =
      match callee.v with
      | DCrunch (_, parameters, result, body) ->
          let* () = bind_parameters parameters in
          let* () = lower_statements_in state ~through (result_annotation result body) in
          let* value = find_binding state loc result.result_name in
          let* () = check_annotation result.result_type (snd value) in
          Ok value
      | DRake (_, parameters, result, setup, tines, throughs, sweep) ->
          let* () = bind_parameters parameters in
          let* () = lower_statements_in state ~through setup in
          let rec lower_tines = function
            | [] -> Ok ()
            | tine :: rest ->
                let* value = lower_predicate state tine.tine_pred in
                state.tines <- StringMap.add tine.tine_name value state.tines;
                lower_tines rest
          in
          let* () = lower_tines tines in
          let rec lower_throughs = function
            | [] -> Ok ()
            | th :: rest ->
                let* () = lower_through ?outer:through state th in
                lower_throughs rest
          in
          let* () = lower_throughs throughs in
          let* value = lower_sweep ?outer:through state loc sweep in
          let* () = check_annotation result.result_type (snd value) in
          Ok value
      | _ -> error loc "only crunches and rakes are inlined"
    in
    decr inline_depth;
    state.bindings <- saved_bindings;
    state.locations <- saved_locations;
    state.tines <- saved_tines;
    result)

let () = inline_call := inline_definition

let callee_table definitions =
  List.fold_left
    (fun table (definition : def) ->
      match definition.v with
      | DCrunch (name, _, _, _) | DRake (name, _, _, _, _, _, _) -> StringMap.add name definition table
      | _ -> table)
    StringMap.empty definitions

(** One pure expression of a run as a function of its free names, lowered by
    the same rules as a crunch body. [mask] names a parameter whose lanes are
    the only active ones: a traversal's tail, under whose predication every
    exception-capable operation is sanitised. *)
let lower_expression ~definitions ~name ~parameters ?mask ~fused loc (expression : expr) =
  callees := callee_table definitions;
  let state =
    {
      next_value = List.length parameters;
      next_fused_region = 0;
      instructions_rev = [];
      bindings = StringMap.empty;
      tines = StringMap.empty;
      rack_constants = Int32Map.empty;
      mask_constants = (None, None);
      locations = StringMap.empty;
    }
  in
  let parameters =
    List.mapi (fun index (parameter_name, typ) -> { Ir.id = index; typ; name = Some parameter_name }) parameters
  in
  let* () =
    List.fold_left
      (fun result (parameter : Ir.parameter) ->
        let* () = result in
        bind state loc (Option.get parameter.name) (parameter.id, parameter.typ))
      (Ok ()) parameters
  in
  let* through =
    match mask with
    | None -> Ok None
    | Some mask_name ->
        let* mask = find_binding state loc mask_name in
        let* () = expect_type loc "a tail mask" Ir.Mask mask in
        Ok (Some (fst mask))
  in
  let provenance = { Ir.fused = (if fused then Some 0 else None); through } in
  let* value = lower_expr state provenance expression in
  let func =
    {
      Ir.name;
      parameters;
      result = Some (snd value);
      body = { instructions = List.rev state.instructions_rev; terminators = [ Ir.Return (Some (fst value)) ] };
      loc = ir_location loc;
    }
  in
  match Ir.verify_function func with
  | Ok () -> Ok func
  | Error errors ->
      errorf loc "generated invalid native IR: %s" (String.concat "; " (List.map Ir.format_error errors))

let lower_definition (definition : def) =
  match definition.v with
  | DCrunch (name, parameters, result, body) ->
      lower_crunch definition.loc name parameters result body
  | DStack _ -> error definition.loc "stack definitions are not supported by native lowering"
  | DSingle _ -> error definition.loc "single definitions are not supported by native lowering"
  | DType _ -> error definition.loc "type aliases are not supported by native lowering"
  | DRake (name, parameters, result, setup, tines, throughs, sweep) ->
      lower_rake definition.loc name parameters result setup tines throughs sweep
  | DRun _ -> error definition.loc "run definitions are not supported by native lowering"
  | DRecord _ | DSlow _ | DExtern _ | DState _ | DEmbed _ | DConst _ ->
      errorf definition.loc "%s is lowered by the slow tier, not native crunch lowering"
        (Capabilities.id (Capabilities.feature_of_def definition.v))

let lower_module module_ =
  let rec lower reversed = function
    | [] -> Ok (List.rev reversed)
    | ({ v = (DStack _ | DSingle _ | DType _); _ } : def) :: rest ->
        lower reversed rest
    | definition :: rest ->
        let* func = lower_definition definition in
        lower (func :: reversed) rest
  in
  lower [] module_.mod_defs

let lower_program program =
  callees := callee_table (List.concat_map (fun (m : module_) -> m.mod_defs) program);
  let rec lower reversed = function
    | [] ->
        let functions = List.rev reversed in
        (match Ir.verify functions with
        | Ok () -> Ok functions
        | Error errors ->
            error Ast.dummy_loc
              ("generated invalid native module: "
              ^ String.concat "; " (List.map Ir.format_error errors)))
    | module_ :: rest ->
        let* functions = lower_module module_ in
        lower (List.rev_append functions reversed) rest
  in
  lower [] program
