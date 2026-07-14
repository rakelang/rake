open Rake
open Ast
open Native_semantics

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

let test_sqrt () =
  let expr = expression (ECall ("sqrt", [ var "x" ])) in
  eval_expr ~lanes:4 [ "x", rack [| 0.0; 1.0; 2.0; 9.0 |] ] expr
  |> get |> expect_rack [| 0.0; 1.0; f32 (Float.sqrt 2.0); 3.0 |]

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

let test_crunch_evaluation () =
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
      (DCrunch
         ( "add",
           [ PRack ("left", None); PRack ("right", None) ],
           result,
           [ node (SLet binding) loc; node (SExpr (var "result")) loc ] ))
      loc
  in
  eval_crunch ~lanes:4 definition
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
        [ { arm_tine = Some "first"; arm_value = var "first_value" };
          { arm_tine = Some "second"; arm_value = var "second_value" };
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

let () =
  test_round_after_each_operation ();
  test_broadcast_arithmetic ();
  test_comparison_and_select ();
  test_sqrt ();
  test_division ();
  test_explicit_fma_is_fused ();
  test_typed_error ();
  test_crunch_evaluation ();
  test_strict_reductions_and_scans ();
  test_rake_priority_and_inactive_lanes ();
  print_endline "native executable semantics tests passed"
