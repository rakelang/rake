open Rake
open Ast
open Native_reference

let loc = { dummy_loc with file = "native-semantics-test" }
let expression value = node value loc
let var name = expression (EVar name)
let scalar_var name = expression (EScalarVar name)
let float value = expression (EFloat value)
let binop left op right = expression (EBinop (left, op, right))

let fail error = failwith (format_error error)
let get = function Ok value -> value | Error error -> fail error

let expect_bits expected actual =
  let expected = Int32.bits_of_float expected in
  let actual = Int32.bits_of_float actual in
  if expected <> actual then
    failwith
      (Printf.sprintf "expected f32 bits %lx, got %lx" expected actual)

let expect_rack expected = function
  | F32_rack actual when Array.length expected = Array.length actual ->
      Array.iter2 expect_bits expected actual
  | value ->
      failwith
        (Printf.sprintf "expected %d-lane rack, got %s" (Array.length expected)
           (string_of_value_kind (value_kind value)))

let expect_scalar expected = function
  | F32_scalar actual -> expect_bits expected actual
  | value ->
      failwith
        ("expected f32 scalar, got " ^ string_of_value_kind (value_kind value))

let expect_mask expected = function
  | Mask actual when expected = Array.to_list actual -> ()
  | Mask actual ->
      failwith
        (Printf.sprintf "unexpected mask width/value (%d lanes)"
           (Array.length actual))
  | value ->
      failwith
        ("expected mask, got " ^ string_of_value_kind (value_kind value))

let test_round_after_each_operation () =
  let a = 16_777_216.0 in
  let expr = binop (binop (var "x") Add (float 1.0)) Sub (var "x") in
  eval_expr ~lanes:8 [ "x", rack (Array.make 8 a) ] expr
  |> get |> expect_rack (Array.make 8 0.0)

let test_broadcast_arithmetic () =
  let expr = binop (var "x") Mul (expression (EBroadcast (scalar_var "scale"))) in
  eval_expr ~lanes:4
    [ "x", rack [| 1.0; -2.0; 3.5; 0.25 |]; "scale", scalar 2.0 ]
    expr
  |> get |> expect_rack [| 2.0; -4.0; 7.0; 0.5 |]

let test_comparison_and_select () =
  let condition = binop (var "x") Gt (float 0.0) in
  let env = [ "x", rack [| -1.0; 2.0; -3.0; 4.0 |] ] in
  let selected =
    expression
      (ECall ("select", [ condition; var "x"; float 0.0 ]))
  in
  eval_expr ~lanes:4 env selected
  |> get |> expect_rack [| 0.0; 2.0; 0.0; 4.0 |];
  eval_expr ~lanes:4 [ "x", rack [| -1.0; 2.0; nan; 4.0 |] ]
    condition
  |> get |> expect_mask [ false; true; false; true ]

let test_short_circuit_boolean_shapes () =
  (* Independent truth tables: Boolean results remain scalars, while skipped
     comparisons retain one mask entry per compared element. *)
  let boolean value = expression (EBroadcast (expression (EBool value))) in
  List.iter (fun lanes ->
    List.iter (fun (left, right) ->
      List.iter (fun (operation, expected) ->
        match eval_expr ~lanes [] (binop (boolean left) operation (boolean right)) |> get with
        | Int_scalar (Types.SBool, value) when (value <> 0L) = expected -> ()
        | _ -> failwith "uniform logical result lost its Boolean shape")
        [And, left && right; Or, left || right])
      [false, false; false, true; true, false; true, true];
    let positive = binop (var "values") Gt (float 0.0) in
    let floats = ["values", rack (Array.make lanes 1.0)] in
    eval_expr ~lanes floats (binop (boolean true) Or positive)
    |> get |> expect_mask (List.init lanes (fun _ -> true));
    eval_expr ~lanes floats (binop (boolean false) And positive)
    |> get |> expect_mask (List.init lanes (fun _ -> false));
    let byte_count = 4 * lanes in
    let bytes = ["values", U8_rack (Array.make byte_count 1)] in
    let positive = binop (expression (EInt 0L)) Lt (var "values") in
    List.iter (fun (operation, enabled, expected) ->
      eval_expr ~lanes bytes (binop (boolean enabled) operation positive)
      |> get |> expect_mask (List.init byte_count (fun _ -> expected)))
      [Or, true, true; Or, false, true; And, false, false; And, true, true])
    [4; 8; 16]

let test_sqrt () =
  let expr = expression (ECall ("sqrt", [ var "x" ])) in
  eval_expr ~lanes:4 [ "x", rack [| 0.0; 1.0; 2.0; 9.0 |] ] expr
  |> get |> expect_rack [| 0.0; 1.0; f32 (Float.sqrt 2.0); 3.0 |]

let test_integral_rounding () =
  (* Independently specified nearest ties and zero signs, also checked by
     the physical-target oracle using integer binary32 decomposition. *)
  let values = [| -0.5; -0.25; -0.0; 0.5; 1.5; 2.5; -1.5; -2.5 |] in
  let cases = [
    "floor", [| -1.0; -1.0; -0.0; 0.0; 1.0; 2.0; -2.0; -3.0 |];
    "ceil", [| -0.0; -0.0; -0.0; 1.0; 2.0; 3.0; -1.0; -2.0 |];
    "trunc", [| -0.0; -0.0; -0.0; 0.0; 1.0; 2.0; -1.0; -2.0 |];
    "nearest", [| -0.0; -0.0; -0.0; 0.0; 2.0; 2.0; -2.0; -2.0 |];
  ] in
  List.iter (fun (operation, expected) ->
    eval_expr ~lanes:8 [ "x", rack values ] (expression (ECall (operation, [ var "x" ])))
    |> get |> expect_rack expected) cases

let test_division () =
  let expr = binop (var "x") Div (float 2.0) in
  eval_expr ~lanes:4 [ "x", rack [| 1.0; -3.0; 8.0; 0.0 |] ] expr
  |> get |> expect_rack [| 0.5; -1.5; 4.0; 0.0 |]

let test_explicit_fma_is_fused () =
  (* These binary32 inputs make separately rounded multiply/add differ from
     one fused operation. *)
  let a = f32 1.00000011920928955078125 in
  let b = a in
  let c = f32 (-1.0000002384185791015625) in
  let fused = expression (EFma (var "a", var "b", var "c")) in
  let separate = binop (binop (var "a") Mul (var "b")) Add (var "c") in
  let env = [ "a", rack [| a |]; "b", rack [| b |]; "c", rack [| c |] ] in
  let fused_value = get (eval_expr ~lanes:1 env fused) in
  let separate_value = get (eval_expr ~lanes:1 env separate) in
  expect_rack [| Float.fma a b c |> f32 |] fused_value;
  match fused_value, separate_value with
  | F32_rack fused, F32_rack separate
    when Int32.bits_of_float fused.(0) <> Int32.bits_of_float separate.(0) -> ()
  | _ -> failwith "test vector did not distinguish fused rounding"

let test_typed_error () =
  match eval_expr ~lanes:8 [] (var "missing") with
  | Error { kind = Undefined_variable "missing"; _ } -> ()
  | Error error -> fail error
  | Ok _ -> failwith "undefined variable unexpectedly evaluated"

let test_scratch_evaluation () =
  let result = { result_name = "result"; result_type = None } in
  let binding =
    {
      bind_name = "result";
      bind_type = None;
      bind_expr = binop (var "left") Add (var "right");
    }
  in
  let definition =
    node
      (DScratch
         ( "add",
           [ PRack ("left", None); PRack ("right", None) ],
           result,
           [ node (SLet binding) loc; node (SExpr (var "result")) loc ] ))
      loc
  in
  eval_scratch ~lanes:4 definition
    [ rack [| 1.0; -2.0; 16_777_216.0; -0.0 |];
      rack [| 3.0; 0.5; 1.0; 0.0 |] ]
  |> get |> expect_rack [| 4.0; -1.5; 16_777_216.0; 0.0 |]

let test_strict_reductions_and_scans () =
  let inputs = rack [| 16_777_216.0; 1.0; -16_777_216.0; 2.0 |] in
  let reduction = expression (EReduce (RAdd, var "x")) in
  eval_expr ~lanes:4 [ "x", inputs ] reduction
  |> get |> expect_scalar 2.0;
  let scan = expression (EScan (RAdd, var "x")) in
  eval_expr ~lanes:4 [ "x", inputs ] scan
  |> get
  |> expect_rack [| 16_777_216.0; 16_777_216.0; 0.0; 2.0 |];
  let minimum = expression (EReduce (RMin, var "x")) in
  eval_expr ~lanes:4 [ "x", rack [| 0.0; -0.0; 2.0; 3.0 |] ] minimum
  |> get |> expect_scalar (-0.0);
  eval_expr ~lanes:4
    [ "x", rack [| 1.0; Int32.float_of_bits 0x7fa12345l; 2.0; 3.0 |] ]
    minimum
  |> get |> expect_scalar (Int32.float_of_bits 0x7fc00000l)

let test_rake_priority_and_inactive_lanes () =
  let predicate operation =
    node (PCmp (var "values", operation, expression (EBroadcast (float 0.0)))) loc
  in
  let through name value passthrough binding =
    {
      through_tine = TRSingle name;
      through_passthru = Some (expression (EBroadcast (float passthrough)));
      through_body = [];
      through_result = expression (EBroadcast (float value));
      through_binding = binding;
    }
  in
  let sweep =
    {
      sweep_arms =
        [ { arm_tine = Some (expression (PTineRef "first")); arm_value = var "first_value" };
          { arm_tine = Some (expression (PTineRef "second")); arm_value = var "second_value" };
          { arm_tine = None; arm_value = expression (EBroadcast (float 3.0)) } ];
      sweep_binding = "result";
    }
  in
  let definition =
    node
      (DRake
         ( "priority",
           [ PRack ("values", None) ],
           { result_name = "result"; result_type = None },
           [],
           [ { tine_name = "first"; tine_pred = predicate CGe };
             { tine_name = "second"; tine_pred = predicate CLe } ],
           [ through "first" 1.0 (-1.0) "first_value";
             through "second" 2.0 (-2.0) "second_value" ],
           sweep ))
      loc
  in
  eval_rake ~lanes:4 definition [ rack [| -1.0; 0.0; 1.0; nan |] ]
  |> get |> expect_rack [| 2.0; 1.0; 1.0; 3.0 |]

let test_integer_folds () =
  (* Hand-computed overflow and signedness goldens, independent of the tree
     selected by the compiler. Padding uses the operation's identity. *)
  List.iter (fun lanes ->
    let check element values operation expected =
      match eval_expr ~lanes ["x", values] (expression (EReduce (operation, var "x"))) |> get with
      | Int_scalar (actual_element, actual) when actual_element = element && actual = expected -> ()
      | _ -> failwith "integer reduction lost wrapping bits or signedness" in
    let signed = Array.make lanes 0 in
    signed.(0) <- -2147483648; signed.(1) <- -1;
    check Types.SInt (I32_rack signed) RAdd 2147483647L;
    check Types.SInt (I32_rack signed) RMin (-2147483648L);
    check Types.SInt (I32_rack signed) RMax 0L;
    let unsigned = Array.make lanes 0L in
    unsigned.(0) <- 0xffffffffL; unsigned.(1) <- 2L;
    check Types.SUint (U32_rack unsigned) RAdd 1L;
    check Types.SUint (U32_rack unsigned) RMin 0L;
    check Types.SUint (U32_rack unsigned) RMax 0xffffffffL;
    Array.fill signed 0 lanes 1;
    signed.(0) <- -2147483648; signed.(1) <- -1;
    check Types.SInt (I32_rack signed) RMul (-2147483648L);
    Array.fill unsigned 0 lanes 1L;
    unsigned.(0) <- 0xffffffffL; unsigned.(1) <- 2L;
    check Types.SUint (U32_rack unsigned) RMul 0xfffffffeL;
    let scan values operation first tail =
      let expected = Array.init lanes (fun lane -> if lane < 4 then first.(lane) else tail) in
      match eval_expr ~lanes ["x", values] (expression (EScan (operation, var "x"))) |> get with
      | I32_rack actual when Array.map Int64.of_int actual = expected -> ()
      | U32_rack actual when actual = expected -> ()
      | _ -> failwith "integer scan lost an inclusive prefix, wrapping bits or signedness" in
    scan (I32_rack signed) RMul
      [|-2147483648L; -2147483648L; -2147483648L; -2147483648L|] (-2147483648L);
    scan (U32_rack unsigned) RMul
      [|0xffffffffL; 0xfffffffeL; 0xfffffffeL; 0xfffffffeL|] 0xfffffffeL;
    Array.fill signed 0 lanes 0;
    signed.(0) <- -2147483648; signed.(1) <- -1; signed.(2) <- 1; signed.(3) <- 1;
    Array.fill unsigned 0 lanes 0L;
    unsigned.(0) <- 0xffffffffL; unsigned.(1) <- 2L; unsigned.(2) <- 1L; unsigned.(3) <- 1L;
    scan (I32_rack signed) RAdd
      [|-2147483648L; 2147483647L; -2147483648L; -2147483647L|] (-2147483647L);
    scan (I32_rack signed) RMin
      [|-2147483648L; -2147483648L; -2147483648L; -2147483648L|] (-2147483648L);
    scan (I32_rack signed) RMax [|-2147483648L; -1L; 1L; 1L|] 1L;
    scan (U32_rack unsigned) RAdd [|0xffffffffL; 1L; 2L; 3L|] 3L;
    scan (U32_rack unsigned) RMin [|0xffffffffL; 2L; 1L; 1L|] 0L;
    scan (U32_rack unsigned) RMax
      [|0xffffffffL; 0xffffffffL; 0xffffffffL; 0xffffffffL|] 0xffffffffL)
    [4; 8; 16]

let test_uniform_arithmetic () =
  (* Hand-derived scalar answers, independent of packed broadcast/extraction. *)
  List.iter (fun lanes ->
    let left = scalar_var "left" and right = scalar_var "right" in
    let arithmetic = binop (binop (binop left Add right) Mul right) Sub left in
    eval_expr ~lanes ["left", scalar 2.0; "right", scalar 3.0]
      (binop arithmetic Div right) |> get |> expect_scalar (f32 (13.0 /. 3.0));
    List.iter (fun (element, left_value, right_value, expected) ->
      match eval_expr ~lanes
        ["left", int_scalar element left_value; "right", int_scalar element right_value]
        arithmetic |> get with
      | Int_scalar (actual_element, actual) when actual_element = element && actual = expected -> ()
      | _ -> failwith "uniform arithmetic lost wrapping bits or signedness")
      [Types.SInt, -2147483648L, -1L, 1L;
       Types.SUint, 4294967295L, 2L, 3L];
    let values = rack (Array.init lanes (fun lane -> float_of_int (lane - 1))) in
    let spread = binop (expression (EReduce (RMax, var "x"))) Sub
      (expression (EReduce (RMin, var "x"))) in
    eval_expr ~lanes ["x", values] spread |> get
    |> expect_scalar (float_of_int (lanes - 1));
    let negated = expression (EUnop (Neg, scalar_var "value")) in
    eval_expr ~lanes ["value", scalar 0.0] negated |> get |> expect_scalar (-0.0);
    eval_expr ~lanes ["value", scalar (-3.5)] negated |> get |> expect_scalar 3.5;
    List.iter (fun (value, expected) ->
      match eval_expr ~lanes ["value", int_scalar Types.SInt value] negated |> get with
      | Int_scalar (Types.SInt, actual) when actual = expected -> ()
      | _ -> failwith "uniform negation lost signed 32-bit wrapping")
      [-2147483648L, -2147483648L; 2147483647L, -2147483647L; -1L, 1L; 0L, 0L];
    eval_expr ~lanes ["x", values] (expression (EUnop (Neg, spread))) |> get
    |> expect_scalar (float_of_int (1 - lanes)))
    [4; 8; 16]

let expect_i16 expected = function
  | I16_rack actual when expected = Array.to_list actual -> ()
  | value -> failwith ("unexpected i16 rack, got " ^ string_of_value_kind (value_kind value))

let expect_i32 expected = function
  | I32_rack actual when expected = Array.to_list actual -> ()
  | value -> failwith ("unexpected i32 rack, got " ^ string_of_value_kind (value_kind value))

let test_signed_integer_absolute_value () =
  let inputs = [| -2147483648; -2147483647; -1; 0 |] in
  let expected = [| -2147483648; 2147483647; 1; 0 |] in
  List.iter (fun lanes ->
    let env = [ "x", I32_rack (Array.init lanes (fun lane -> inputs.(lane mod 4))) ] in
    eval_expr ~lanes env (expression (ECall ("abs", [ var "x" ])))
    |> get |> expect_i32 (List.init lanes (fun lane -> expected.(lane mod 4))))
    [ 4; 8; 16 ]

let test_integer_shuffles () =
  (* Hand-specified boundary bits and lane selections, including transfers
     across AVX's 128-bit subdivisions and between both input racks. *)
  let inputs = [| -2147483648; 2147483647; -1; 0; 4; 5; 6; 7;
                 8; 9; 10; 11; 12; 13; 14; 15 |] in
  let cases = [
    4, [3; 2; 1; 0], [0; -1; 2147483647; -2147483648],
      [4; 3; 6; 1], [101; 0; 103; 2147483647];
    8, [7; 6; 5; 4; 3; 2; 1; 0], [7; 6; 5; 4; 0; -1; 2147483647; -2147483648],
      [8; 7; 10; 5; 12; 3; 14; 1], [101; 7; 103; 5; 105; 0; 107; 2147483647];
    16, [15; 14; 13; 12; 11; 10; 9; 8; 7; 6; 5; 4; 3; 2; 1; 0],
      [15; 14; 13; 12; 11; 10; 9; 8; 7; 6; 5; 4; 0; -1; 2147483647; -2147483648],
      [16; 15; 18; 13; 20; 11; 22; 9; 24; 7; 26; 5; 28; 3; 30; 1],
      [101; 15; 103; 13; 105; 11; 107; 9; 109; 7; 111; 5; 113; 0; 115; 2147483647]
  ] in
  List.iter (fun (lanes, reversed, expected_reverse, paired, expected_pair) ->
    let env = ["a", I32_rack (Array.sub inputs 0 lanes);
               "b", I32_rack (Array.init lanes (fun lane -> 101 + lane))] in
    eval_expr ~lanes env (expression (EShuffle (var "a", reversed)))
    |> get |> expect_i32 expected_reverse;
    eval_expr ~lanes env (expression (EShuffle (expression (ETuple [var "a"; var "b"]), paired)))
    |> get |> expect_i32 expected_pair) cases

let test_unsigned_extrema () =
  List.iter (fun lanes ->
    let repeated xs = Array.init lanes (fun lane -> xs.(lane mod 4)) in
    let env = ["a", U32_rack (repeated [|0L; 2147483647L; 2147483648L; 4294967295L|]);
               "b", U32_rack (repeated [|4294967295L; 2147483648L; 2147483647L; 4294967295L|])] in
    let check operation arguments expected =
      match eval_expr ~lanes env (expression (ECall (operation, arguments))) |> get with
      | U32_rack values when values = repeated expected -> ()
      | _ -> failwith "unsigned extrema disagree with boundary goldens" in
    check "min" [var "a"; var "b"] [|0L; 2147483647L; 2147483647L; 4294967295L|];
    check "max" [var "a"; var "b"] [|4294967295L; 2147483648L; 2147483648L; 4294967295L|];
    check "max" [expression (EBroadcast (expression (EInt 2147483648L))); var "a"]
      [|2147483648L; 2147483648L; 2147483648L; 4294967295L|];
    check "min" [var "a"; expression (EBroadcast (expression (EInt 4294967294L)))]
      [|0L; 2147483647L; 2147483648L; 4294967294L|]) [4; 8; 16]

let test_unsigned_comparisons () =
  (* Hand-specified order across the signed boundary, repeated at every
     physical rack width. These values distinguish unsigned from signed. *)
  List.iter (fun lanes ->
    let repeated xs = Array.init lanes (fun lane -> xs.(lane mod 4)) in
    let env = ["a", U32_rack (repeated [| 0L; 2147483647L; 2147483648L; 4294967295L |]);
               "b", U32_rack (repeated [| 4294967295L; 2147483648L; 2147483647L; 4294967295L |])] in
    List.iter (fun (op, expected) ->
      eval_expr ~lanes env (binop (var "a") op (var "b"))
      |> get |> expect_mask (List.init lanes (fun lane -> expected.(lane mod 4))))
      [Lt, [|true; true; false; false|]; Le, [|true; true; false; true|];
       Gt, [|false; false; true; false|]; Ge, [|false; false; true; true|];
       Eq, [|false; false; false; true|]; Ne, [|true; true; true; false|]];
    let boundary = expression (EBroadcast (expression (EInt 2147483648L))) in
    eval_expr ~lanes env (binop (var "a") Ge boundary)
    |> get |> expect_mask (List.init lanes (fun lane -> lane mod 4 >= 2));
    eval_expr ~lanes env (binop boundary Gt (var "a"))
    |> get |> expect_mask (List.init lanes (fun lane -> lane mod 4 < 2));
    let result = eval_expr ~lanes env (expression (EIf (binop (var "a") Lt (var "b"), var "a", var "b"))) |> get in
    match result with
    | U32_rack values when values = repeated [|0L; 2147483647L; 2147483647L; 4294967295L|] -> ()
    | _ -> failwith "unsigned mask selected incorrect lane bits") [4; 8; 16]

let test_integer_uniform_builtins () =
  (* Hand-specified bits distinguish unsigned ordering, complement operand
     order and per-operation wrapping before a uniform is broadcast. *)
  List.iter (fun lanes ->
    let repeated xs = Array.init lanes (fun lane -> xs.(lane mod 4)) in
    let env = ["values", U32_rack (repeated [|0L; 2147483647L; 2147483648L; 4294967295L|]);
               "cut", int_scalar Types.SUint 2147483648L;
               "top", int_scalar Types.SUint 4294967295L] in
    let check operation arguments expected =
      match eval_expr ~lanes env (expression (ECall (operation, arguments))) |> get with
      | U32_rack actual when actual = repeated expected -> ()
      | _ -> failwith "integer uniform built-in disagrees with boundary goldens" in
    check "bit_and" [var "values"; scalar_var "cut"] [|0L; 0L; 2147483648L; 2147483648L|];
    check "bit_or" [scalar_var "cut"; var "values"] [|2147483648L; 4294967295L; 2147483648L; 4294967295L|];
    check "bit_xor" [var "values"; scalar_var "cut"] [|2147483648L; 4294967295L; 0L; 2147483647L|];
    check "bit_andnot" [scalar_var "cut"; var "values"] [|2147483648L; 2147483648L; 0L; 0L|];
    check "bit_andnot" [scalar_var "top"; scalar_var "cut"] (Array.make 4 2147483647L);
    check "min" [scalar_var "cut"; var "values"] [|0L; 2147483647L; 2147483648L; 2147483648L|];
    check "max" [var "values"; scalar_var "cut"] [|2147483648L; 2147483648L; 2147483648L; 4294967295L|];
    check "max" [scalar_var "cut"; scalar_var "top"] (Array.make 4 4294967295L);
    let wrapped = binop (scalar_var "top") Add (expression (EInt 1L)) in
    check "bit_xor" [wrapped; scalar_var "cut"] (Array.make 4 2147483648L)) [4; 8; 16]

let test_annotated_rack_bindings () =
  (* Each explicit rack binding must fill every lane, preserving high bits
     and negative zero rather than leaving its initializer scalar. *)
  List.iter (fun lanes ->
    List.iter (fun (primitive, argument, check) ->
      let annotation = Some (node (TRack primitive) loc) in
      let initial_value = scalar_var "value" in
      let bindings = [
        SLet { bind_name = "result"; bind_type = annotation; bind_expr = initial_value };
        SFused { fused_name = "result"; fused_type = annotation; fused_expr = initial_value };
        SLocBind { loc_name = "result"; loc_type = annotation; loc_expr = initial_value };
      ] in
      List.iter (fun binding ->
        let definition = node
          (DScratch ("broadcast", [PScalar ("value", Some (node (TScalar primitive) loc))],
            { result_name = "result"; result_type = annotation },
            [node binding loc; node (SExpr (var "result")) loc])) loc in
        eval_scratch ~lanes definition [argument] |> get |> check) bindings)
      [PInt, int_scalar Types.SInt (-2147483648L), expect_i32 (List.init lanes (fun _ -> -2147483648));
       PUint, int_scalar Types.SUint 4294967295L,
         (function U32_rack values when values = Array.make lanes 4294967295L -> ()
          | _ -> failwith "annotated u32 rack lost unsigned high bits");
       PFloat, scalar (-0.0), expect_rack (Array.make lanes (-0.0))]) [4; 8; 16]

(* The wasm-simd128 integer racks: eight i16 or four i32 lanes where f32 has four. *)
let test_integer_racks () =
  let call name args = expression (ECall (name, args)) in
  let int value = expression (EBroadcast (expression (EInt value))) in
  let i16 = I16_rack [| 1; 2; 3; 4; 5; 6; 7; 8 |] in
  let weights = I16_rack [| 1; 1; 2; 2; -1; -1; 32767; 32767 |] in
  eval_expr ~lanes:4 [ "a", i16; "b", weights ] (call "dot" [ var "a"; var "b" ])
  |> get |> expect_i32 [ 3; 14; -11; 491505 ];
  eval_expr ~lanes:4 [ "a", I32_rack [| 70000; -70000; 5; -5 |]; "b", I32_rack [| 1; 2; 3; 4 |] ]
    (call "narrow" [ var "a"; var "b" ])
  |> get |> expect_i16 [ 32767; -32768; 5; -5; 1; 2; 3; 4 ];
  let bytes = U8_rack (Array.init 16 (fun i -> if i = 9 then 250 else i)) in
  eval_expr ~lanes:4 [ "x", bytes ] (call "widen_low" [ var "x" ]) |> get |> expect_i16 [ 0; 1; 2; 3; 4; 5; 6; 7 ];
  eval_expr ~lanes:4 [ "x", bytes ] (call "widen_high" [ var "x" ]) |> get |> expect_i16 [ 8; 250; 10; 11; 12; 13; 14; 15 ];
  (* Round to nearest, ties to even, saturated; NaN is zero. *)
  eval_expr ~lanes:4 [ "x", rack [| 2.5; 3.5; -2.5; 1e10 |] ] (call "to_i32" [ var "x" ])
  |> get |> expect_i32 [ 2; 4; -2; 2147483647 ];
  eval_expr ~lanes:4 [ "x", rack [| Float.nan; -1e10; 0.49999997; -0.5 |] ] (call "to_i32" [ var "x" ])
  |> get |> expect_i32 [ 0; -2147483648; 0; 0 ];
  eval_expr ~lanes:4 [ "x", I32_rack [| 16777217; -3; 0; 7 |] ] (call "to_f32" [ var "x" ])
  |> get |> expect_rack [| 16777216.0; -3.0; 0.0; 7.0 |];
  (* f32 racks: IEEE 754 maximum and minimum, as f32x4.max and f32x4.min: NaN if either is, -0 below +0. *)
  let pair = [ "x", rack [| Float.nan; -0.0; 1.0; -2.0 |]; "y", rack [| 0.0; 0.0; 3.0; -1.0 |] ] in
  eval_expr ~lanes:4 pair (call "max" [ var "x"; var "y" ]) |> get |> expect_rack [| Float.nan; 0.0; 3.0; -1.0 |];
  eval_expr ~lanes:4 pair (call "min" [ var "x"; var "y" ]) |> get |> expect_rack [| Float.nan; -0.0; 1.0; -2.0 |];
  eval_expr ~lanes:4 [ "x", I16_rack [| -3; 4; 0; -32768; 9; -1; 2; 1 |] ] (call "max" [ var "x"; int 0L ])
  |> get |> expect_i16 [ 0; 4; 0; 0; 9; 0; 2; 1 ];
  eval_expr ~lanes:4 [ "x", I16_rack (Array.make 8 32767); "y", I16_rack (Array.make 8 1) ] (binop (var "x") Add (var "y"))
  |> get |> expect_i16 (List.init 8 (fun _ -> -32768))

let expect_i64 expected = function
  | I64_rack actual when expected = Array.to_list actual -> ()
  | value -> failwith ("unexpected i64 rack, got " ^ string_of_value_kind (value_kind value))

(* Bitwise operations and shifts: a bitboard row is one 64-bit lane, two to a rack
   where f32 has four lanes. *)
let test_integer_bits () =
  let call name args = expression (ECall (name, args)) in
  let int value = expression (EInt value) in
  let rows = I64_rack [| 0b1011L; -1L |] in
  let masks = I64_rack [| 0b0110L; 0xffL |] in
  let env = [ "r", rows; "m", masks ] in
  eval_expr ~lanes:4 env (call "bit_and" [ var "r"; var "m" ]) |> get |> expect_i64 [ 0b0010L; 0xffL ];
  eval_expr ~lanes:4 env (call "bit_or" [ var "r"; var "m" ]) |> get |> expect_i64 [ 0b1111L; -1L ];
  eval_expr ~lanes:4 env (call "bit_xor" [ var "r"; var "m" ]) |> get |> expect_i64 [ 0b1101L; -256L ];
  eval_expr ~lanes:4 env (call "bit_andnot" [ var "r"; var "m" ]) |> get |> expect_i64 [ 0b1001L; -256L ];
  eval_expr ~lanes:4 env (call "shift_bits_left" [ var "r"; int 1L ]) |> get |> expect_i64 [ 0b10110L; -2L ];
  (* Logical right shifts fill with zeros, signed ones with the sign bit. *)
  eval_expr ~lanes:4 env (call "shift_bits_right" [ var "r"; int 63L ]) |> get |> expect_i64 [ 0L; 1L ];
  eval_expr ~lanes:4 env (call "shift_bits_right_signed" [ var "r"; int 63L ]) |> get |> expect_i64 [ 0L; -1L ];
  (* A uniform count is taken modulo the lane's bits. *)
  let uniform = expression (EScalarVar "n") in
  eval_expr ~lanes:4 (("n", U32_scalar 65) :: env) (call "shift_bits_left" [ var "r"; uniform ])
  |> get |> expect_i64 [ 0b10110L; -2L ];
  eval_expr ~lanes:4 [ "x", I32_rack [| -8; 1; 0; 5 |] ] (call "shift_bits_right" [ var "x"; int 1L ])
  |> get |> expect_i32 [ 2147483644; 0; 0; 2 ];
  eval_expr ~lanes:4 [ "x", I32_rack [| -8; 1; 0; 5 |] ] (call "shift_bits_right_signed" [ var "x"; int 1L ])
  |> get |> expect_i32 [ -4; 0; 0; 2 ]

let () =
  test_annotated_rack_bindings ();
  test_integer_uniform_builtins ();
  test_unsigned_extrema ();
  test_unsigned_comparisons ();
  test_integer_shuffles ();
  test_signed_integer_absolute_value ();
  test_integer_bits ();
  test_integer_racks ();
  test_round_after_each_operation ();
  test_broadcast_arithmetic ();
  test_comparison_and_select ();
  test_short_circuit_boolean_shapes ();
  test_sqrt ();
  test_integral_rounding ();
  test_division ();
  test_explicit_fma_is_fused ();
  test_typed_error ();
  test_scratch_evaluation ();
  test_strict_reductions_and_scans ();
  test_integer_folds ();
  test_uniform_arithmetic ();
  test_rake_priority_and_inactive_lanes ();
  print_endline "native executable semantics tests passed"
