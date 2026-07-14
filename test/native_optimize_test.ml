open Rake.Native_ir

let instruction ?(provenance = source) result op =
  { result; op; provenance; loc = unknown_location }

let fused = { fused = Some 0; through = None }

let function_with instructions result =
  {
    name = "advance";
    parameters =
      [ { id = 0; typ = Rack F32; name = Some "positions" };
        { id = 1; typ = Rack F32; name = Some "velocities" } ];
    result = Some (Rack F32);
    body = { instructions; terminators = [ Return (Some result) ] };
    loc = unknown_location;
  }

let expect_optimized func =
  match Rake.Native_optimize.optimize ~profile:Rake.Target.X86_avx2 [ func ] with
  | Ok [ optimized ] -> optimized
  | Ok _ -> failwith "optimizer changed the function count"
  | Error errors -> failwith (Rake.Native_optimize.format_error errors)

let () =
  let named_chain =
    function_with
      [ instruction (Some (2, Rack F32)) (Rack_splat (Float32_bits 0x3f000000l));
        instruction ~provenance:fused (Some (3, Rack F32)) (Binary (Mul, 1, 2));
        instruction ~provenance:fused (Some (4, Rack F32)) (Binary (Add, 0, 3)) ]
      4
    |> expect_optimized
  in
  (match named_chain.body.instructions with
  | [ _constant; { op = Fma (1, 2, 0); provenance = { fused = Some 0; _ }; _ } ] -> ()
  | _ -> failwith ("named fused chain did not contract:\n" ^ dump [ named_chain ]));
  let shared_multiply =
    function_with
      [ instruction (Some (2, Rack F32)) (Rack_splat (Float32_bits 0x3f000000l));
        instruction ~provenance:fused (Some (3, Rack F32)) (Binary (Mul, 1, 2));
        instruction ~provenance:fused (Some (4, Rack F32)) (Binary (Add, 3, 3)) ]
      4
    |> expect_optimized
  in
  (match shared_multiply.body.instructions with
  | [ _constant; { op = Binary (Mul, 1, 2); _ }; { op = Fma (1, 2, 3); _ } ] -> ()
  | _ -> failwith ("shared multiply was not retained:\n" ^ dump [ shared_multiply ]));
  let unfused =
    function_with
      [ instruction (Some (2, Rack F32)) (Binary (Mul, 0, 1));
        instruction (Some (3, Rack F32)) (Binary (Add, 2, 1)) ]
      3
    |> expect_optimized
  in
  (match unfused.body.instructions with
  | [ { op = Binary (Mul, _, _); _ }; { op = Binary (Add, _, _); _ } ] -> ()
  | _ -> failwith "optimizer contracted arithmetic outside a fused region");
  print_endline "native optimizer tests passed"
