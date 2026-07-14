open Rake.Native_ir

let instruction ?(provenance = source) result op =
  { result; op; provenance; loc = unknown_location }

let valid_function =
  let fused = { fused = Some 0; through = None } in
  {
    name = "axpy";
    parameters =
      [ { id = 0; typ = Rack F32; name = Some "x" }; { id = 1; typ = Rack F32; name = Some "y" } ];
    result = Some (Rack F32);
    body =
      {
        instructions =
          [ instruction ~provenance:fused (Some (2, Rack F32)) (Fma (0, 1, 0));
            instruction ~provenance:fused (Some (3, Rack F32)) (Binary (Add, 2, 1)) ];
        terminators = [ Return (Some 3) ];
      };
    loc = unknown_location;
  }

let expect_valid module_ =
  match verify module_ with
  | Ok () -> ()
  | Error errors -> failwith (String.concat "\n" (List.map format_error errors))

let contains substring string =
  let rec at offset =
    if offset + String.length substring > String.length string then false
    else if String.sub string offset (String.length substring) = substring then true
    else at (offset + 1)
  in
  at 0

let expect_error substring module_ =
  match verify module_ with
  | Ok () -> failwith ("expected verifier error containing: " ^ substring)
  | Error errors ->
      let rendered = String.concat "\n" (List.map format_error errors) in
      if not (contains substring rendered) then failwith ("missing error '" ^ substring ^ "' in:\n" ^ rendered)

let with_body body = [ { valid_function with body } ]

let () =
  expect_valid [ valid_function ];
  let valid_reduction =
    {
      name = "strict_reduce_add";
      parameters = [ { id = 0; typ = Rack F32; name = Some "values" } ];
      result = Some (Scalar F32);
      body =
        {
          instructions =
            [ instruction (Some (1, Scalar F32)) (Reduce (Reduce_add, 0)) ];
          terminators = [ Return (Some 1) ];
        };
      loc = unknown_location;
    }
  in
  expect_valid [ valid_reduction ];
  let valid_scan =
    {
      valid_reduction with
      name = "strict_scan_max";
      result = Some (Rack F32);
      body =
        {
          instructions = [ instruction (Some (1, Rack F32)) (Scan (Scan_max, 0)) ];
          terminators = [ Return (Some 1) ];
        };
    }
  in
  expect_valid [ valid_scan ];
  expect_error "operation produces scalar<f32>"
    [ { valid_reduction with
        body =
          { instructions =
              [ instruction (Some (1, Rack F32)) (Reduce (Reduce_add, 0)) ];
            terminators = [ Return (Some 1) ] } } ];
  expect_error "expected mask"
    [ { valid_reduction with
        body =
          { instructions =
              [ instruction (Some (1, Scalar I1)) (Reduce (Reduce_and, 0)) ];
            terminators = [ Return (Some 1) ] } } ];
  let masked = { fused = None; through = Some 2 } in
  let valid_masked =
    {
      valid_function with
      name = "masked_add";
      parameters =
        valid_function.parameters @ [ { id = 2; typ = Mask; name = Some "active" } ];
      body =
        {
          instructions =
            [ instruction (Some (3, Rack F32)) (Rack_splat (Float32_bits 0l));
              instruction ~provenance:masked (Some (4, Rack F32))
                (Sanitize { mask = 2; active = 0; benign = 3 });
              instruction ~provenance:masked (Some (5, Rack F32))
                (Sanitize { mask = 2; active = 1; benign = 3 });
              instruction ~provenance:masked (Some (6, Rack F32))
                (Binary (Add, 4, 5)) ];
          terminators = [ Return (Some 6) ];
        };
    }
  in
  expect_valid [ valid_masked ];
  expect_error "not produced by sanitize"
    [ { valid_masked with
        body =
          { instructions =
              [ instruction ~provenance:masked (Some (3, Rack F32))
                  (Binary (Add, 0, 1)) ];
            terminators = [ Return (Some 3) ] } } ];
  let expected =
    "func @axpy(%0 : rack<f32> x, %1 : rack<f32> y) -> rack<f32> {\n\
     \  %2 : rack<f32> = rack.fma %0, %1, %0 {fused=0}\n\
     \  %3 : rack<f32> = add %2, %1 {fused=0}\n\
     \  return %3\n\
     }\n"
  in
  if dump [ valid_function ] <> expected then failwith ("unstable dump:\n" ^ dump [ valid_function ]);
  let constants =
    {
      name = "constant_bits";
      parameters = [];
      result = Some (Rack F32);
      body =
        {
          instructions =
            [ instruction (Some (0, Rack F32))
                (Rack_const [ Float32_bits 0x80000000l; Float32_bits 0x7fc01234l ]);
              instruction (Some (1, Rack F32)) (Unary (Sqrt, 0)) ];
          terminators = [ Return (Some 1) ];
        };
      loc = unknown_location;
    }
  in
  expect_valid [ constants ];
  let constants_dump = dump [ constants ] in
  if not (contains "f32:0x80000000" constants_dump && contains "f32:0x7fc01234" constants_dump)
  then failwith ("floating-point bits were not retained:\n" ^ constants_dump);
  expect_error "used before it is defined"
    (with_body
       { instructions = [ instruction (Some (2, Rack F32)) (Binary (Add, 0, 99)) ]; terminators = [ Return (Some 2) ] });
  expect_error "operation produces rack<f32>"
    (with_body
       { instructions = [ instruction (Some (2, Scalar F32)) (Binary (Add, 0, 1)) ]; terminators = [ Return (Some 2) ] });
  expect_error "more than one terminator"
    (with_body { instructions = []; terminators = [ Return (Some 0); Return (Some 1) ] });
  expect_error "expected scalar<f32>"
    (with_body
       {
         instructions =
           [ instruction None
               (Call
                  {
                    callee = "sink";
                    arguments = [ 0 ];
                    parameter_types = [ Scalar F32 ];
                    return_type = None;
                    call_effect = Pure;
                  }) ];
         terminators = [ Return (Some 0) ];
       });
  expect_error "not permitted in a fused region"
    (with_body
       {
         instructions =
           [ instruction ~provenance:{ fused = Some 0; through = None } None
               (Store { address = 0; stored = 1; alignment = 32 }) ];
         terminators = [ Return (Some 0) ];
       });
  expect_error "must retain rack identity"
    (with_body
       {
         instructions =
           [ instruction ~provenance:{ fused = Some 0; through = None }
               (Some (2, Scalar F32)) (Reduce (Reduce_add, 0)) ];
         terminators = [ Return (Some 0) ];
       });
  expect_error "expected mask"
    (with_body
       {
         instructions =
           [ instruction ~provenance:{ fused = None; through = Some 0 }
               (Some (2, Rack F32)) (Binary (Add, 0, 1)) ];
         terminators = [ Return (Some 2) ];
       });
  expect_error "is not contiguous"
    (with_body
       {
         instructions =
           [ instruction ~provenance:{ fused = Some 0; through = None }
               (Some (2, Rack F32)) (Binary (Add, 0, 1));
             instruction (Some (3, Rack F32)) (Binary (Add, 2, 1));
             instruction ~provenance:{ fused = Some 0; through = None }
               (Some (4, Rack F32)) (Binary (Add, 3, 1)) ];
         terminators = [ Return (Some 4) ];
       });
  print_endline "native IR tests passed"
