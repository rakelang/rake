open Rake
open Ast

let loc line = { file = "native_lower_test.rk"; line; col = 3; offset = line * 10 }
let expr line value = node value (loc line)
let stmt line value = node value (loc line)
let var line name = expr line (EVar name)

let let_statement line name value =
  stmt line (SLet { bind_name = name; bind_type = None; bind_expr = value })

let fused_statement line name value =
  stmt line (SFused { fused_name = name; fused_type = None; fused_expr = value })

let crunch ?(line = 1) name parameters result_name body =
  node (DCrunch (name, parameters, { result_name; result_type = None }, body)) (loc line)

let valid =
  crunch "kernel" [ PRack ("a", None); PRack ("b", None); PRack ("c", None) ] "result"
    [ fused_statement 2 "sum" (expr 2 (EBinop (var 2 "a", Add, var 2 "b")));
      fused_statement 3 "root" (expr 3 (ECall ("sqrt", [ var 3 "sum" ])));
      let_statement 4 "difference" (expr 4 (EBinop (var 4 "root", Sub, var 4 "c")));
      let_statement 5 "product" (expr 5 (EBinop (var 5 "difference", Mul, var 5 "b")));
      let_statement 6 "quotient" (expr 6 (EBinop (var 6 "product", Div, var 6 "c")));
      let_statement 7 "low" (expr 7 (EBinop (var 7 "quotient", Lt, var 7 "a")));
      let_statement 8 "high" (expr 8 (EBinop (var 8 "quotient", Gt, var 8 "b")));
      let_statement 9 "not_high" (expr 9 (EUnop (Not, var 9 "high")));
      let_statement 10 "inside" (expr 10 (EBinop (var 10 "low", And, var 10 "not_high")));
      let_statement 11 "chosen"
        (expr 11 (ECall ("select", [ var 11 "inside"; var 11 "quotient"; var 11 "a" ])));
      let_statement 12 "negative" (expr 12 (EUnop (Neg, var 12 "chosen")));
      let_statement 13 "half"
        (expr 13 (EBroadcast (expr 13 (EFloat 0.5))));
      let_statement 14 "scaled"
        (expr 14 (EBinop (var 14 "negative", Mul, var 14 "half")));
      let_statement 15 "minus_zero" (expr 15 (EFloat (-0.0)));
      fused_statement 16 "result"
        (expr 16 (EFma (var 16 "scaled", var 16 "b", var 16 "minus_zero")));
      stmt 17 (SExpr (var 17 "result")) ]

let contains substring string =
  let rec at offset =
    offset + String.length substring <= String.length string
    &&
    (String.sub string offset (String.length substring) = substring || at (offset + 1))
  in
  at 0

let expect_error expected_line substring definition =
  match Native_lower.lower_definition definition with
  | Ok _ -> failwith ("expected native lowering error containing: " ^ substring)
  | Error error ->
      if error.loc.line <> expected_line then
        failwith
          (Printf.sprintf "wrong error location: expected line %d, got %d" expected_line error.loc.line);
      if not (contains substring error.message) then
        failwith ("missing error '" ^ substring ^ "' in: " ^ error.message)

let () =
  let lowered =
    match Native_lower.lower_definition valid with
    | Ok func -> func
    | Error error -> failwith (Native_lower.format_error error)
  in
  (match Native_ir.verify_function lowered with
  | Ok () -> ()
  | Error errors -> failwith (String.concat "\n" (List.map Native_ir.format_error errors)));
  if lowered.loc.file <> "native_lower_test.rk" || lowered.loc.line <> 1 then
    failwith "function source location was not retained";
  (match lowered.body.instructions with
  | first :: _ when first.loc.file = "native_lower_test.rk" && first.loc.line = 2 -> ()
  | _ -> failwith "instruction source location was not retained");
  let dump = Native_ir.dump [ lowered ] in
  List.iter
    (fun spelling ->
      if not (contains spelling dump) then failwith ("missing native IR spelling: " ^ spelling))
    [ "add "; "sqrt "; "sub "; "mul "; "div "; "compare.lt"; "compare.gt";
      "mask.not"; "mask.and"; "select "; "neg "; "rack.fma";
      "f32:0x3f000000"; "f32:0x80000000" ];
  let fused_ids =
    List.filter_map
      (fun (instruction : Native_ir.instruction) -> instruction.provenance.fused)
      lowered.body.instructions
  in
  if fused_ids <> [ 0; 0; 1 ] then
    failwith
      ("unexpected fused region IDs: " ^ String.concat "," (List.map string_of_int fused_ids));
  let scalar_float = node (TScalar PFloat) (loc 37) in
  let reduction =
    node
      (DCrunch
         ( "reduction",
           [ PRack ("a", None) ],
           { result_name = "result"; result_type = Some scalar_float },
           [ let_statement 37 "result" (expr 37 (EReduce (RAdd, var 37 "a"))) ] ))
      (loc 36)
  in
  (match Native_lower.lower_definition reduction with
  | Ok { result = Some (Native_ir.Scalar Native_ir.F32); body = { instructions; _ }; _ }
    when List.exists
           (fun (instruction : Native_ir.instruction) ->
             match instruction.op with Native_ir.Reduce (Native_ir.Reduce_add, _) -> true | _ -> false)
           instructions -> ()
  | Ok _ -> failwith "f32 reduction did not lower to scalar native IR"
  | Error error -> failwith (Native_lower.format_error error));
  let unsupported_expr =
    crunch "unsupported" [ PRack ("a", None) ] "result"
      [ let_statement 39 "result" (expr 39 (EReduce (RAnd, var 39 "a"))) ]
  in
  expect_error 39 "logical mask reductions are not implemented" unsupported_expr;
  let unsupported_statement =
    crunch "mutation" [ PRack ("a", None) ] "a" [ stmt 41 (SAssign ("a", var 41 "a")) ]
  in
  expect_error 41 "assignment is not supported" unsupported_statement;
  let unsupported_definition = node (DStack ("Things", [])) (loc 51) in
  expect_error 51 "stack definitions are not supported" unsupported_definition;
  let duplicate_parameter =
    crunch ~line:61 "duplicate" [ PRack ("a", None); PRack ("a", None) ] "a" []
  in
  expect_error 61 "already bound" duplicate_parameter;
  print_endline "native lowering tests passed"
