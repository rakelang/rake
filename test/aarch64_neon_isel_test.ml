module N = Rake.Native_ir
module M = Rake.Aarch64_neon_mir
module I = Rake.Aarch64_neon_isel

let instruction ?(provenance = N.source) result op : N.instruction =
  { result; op; provenance; loc = N.unknown_location }

let contains needle haystack =
  let rec search offset =
    if offset + String.length needle > String.length haystack then false
    else if String.sub haystack offset (String.length needle) = needle then true
    else search (offset + 1)
  in
  search 0

let expect_ok func =
  match I.select_function func with
  | Ok selected -> selected
  | Error error -> failwith (I.format_error error)

let expect_error text func =
  match I.select_function func with
  | Ok _ -> failwith ("expected selection failure containing: " ^ text)
  | Error error ->
      let message = I.format_error error in
      if not (contains text message) then
        failwith (Printf.sprintf "missing error %S in:\n%s" text message)

let rack_parameter id name : N.parameter =
  { id; typ = N.Rack N.F32; name = Some name }

let valid_function =
  let fused = { N.fused = Some 7; through = None } in
  let through = { N.fused = None; through = Some 12 } in
  {
    N.name = "neon_all_operations";
    parameters =
      [ rack_parameter 0 "a"; rack_parameter 1 "b"; rack_parameter 2 "c" ];
    result = Some (N.Rack N.F32);
    body =
      {
        instructions =
          [ instruction (Some (3, N.Rack N.F32)) (N.Unary (N.Neg, 0));
            instruction (Some (4, N.Rack N.F32)) (N.Unary (N.Sqrt, 1));
            instruction (Some (5, N.Rack N.F32)) (N.Binary (N.Add, 3, 4));
            instruction (Some (6, N.Rack N.F32)) (N.Binary (N.Sub, 5, 2));
            instruction (Some (7, N.Rack N.F32)) (N.Binary (N.Mul, 6, 1));
            instruction (Some (8, N.Rack N.F32)) (N.Binary (N.Div, 7, 0));
            instruction ~provenance:fused (Some (9, N.Rack N.F32))
              (N.Fma (0, 1, 2));
            instruction (Some (10, N.Mask)) (N.Compare (N.Eq, 8, 9));
            instruction (Some (11, N.Mask)) (N.Compare (N.Ne, 0, 1));
            instruction (Some (12, N.Mask)) (N.Mask_binary (N.And, 10, 11));
            instruction (Some (13, N.Mask)) (N.Mask_binary (N.Or, 10, 12));
            instruction (Some (14, N.Mask)) (N.Mask_binary (N.Xor, 13, 11));
            instruction (Some (15, N.Mask)) (N.Mask_not 14);
            instruction ~provenance:through (Some (16, N.Rack N.F32))
              (N.Select { condition = 15; if_true = 9; if_false = 8 }) ];
        terminators = [ N.Return (Some 16) ];
      };
    loc = N.unknown_location;
  }

let () =
  let selected = expect_ok valid_function in
  if List.length selected.M.instructions <> 17 then
    failwith
      (Printf.sprintf "selected %d instructions; expected 17"
         (List.length selected.M.instructions));
  (match selected.instructions with
  | M.Uniform_f32 { bits; dst = sign; _ }
    :: M.Eor { left = 0; right; dst = 3; _ } :: _
    when bits = Int32.min_int && sign = right -> ()
  | _ -> failwith "negation was not selected as exact sign-bit XOR");
  (match List.nth selected.instructions 7 with
  | M.Fma { provenance = { fused = Some 7; _ }; _ } -> ()
  | _ -> failwith "FMA or fused provenance was not retained");
  (match
     (List.nth selected.instructions 9, List.nth selected.instructions 10,
      List.nth selected.instructions 11)
   with
  | ( M.Compare { predicate = M.Cgt; left = 0; right = 1; dst = greater; _ },
      M.Compare { predicate = M.Cgt; left = 1; right = 0; dst = less; _ },
      M.Orr { dst = 11; left; right; _ } )
    when greater = left && less = right -> ()
  | _ ->
      failwith
        "ordered != must be selected as (left > right) OR (right > left), not inverted equality");
  (match List.nth selected.instructions 16 with
  | M.Select { provenance = { through = Some 12; _ }; _ } -> ()
  | _ -> failwith "select did not retain through provenance");

  let predicated =
    {
      N.name = "predicated";
      parameters = [ rack_parameter 0 "active"; rack_parameter 1 "benign" ];
      result = Some (N.Rack N.F32);
      body =
        {
          instructions =
            [ instruction (Some (2, N.Mask)) (N.Mask_const true);
              instruction (Some (3, N.Rack N.F32))
                (N.Sanitize { mask = 2; active = 0; benign = 1 }) ];
          terminators = [ N.Return (Some 3) ];
        };
      loc = N.unknown_location;
    }
  in
  (match (expect_ok predicated).instructions with
  | [ M.Mask_const { dst = 2; value = true; _ };
      M.Select { dst = 3; mask = 2; if_true = 0; if_false = 1; _ } ] -> ()
  | _ -> failwith "mask constants or sanitize selection were not retained");

  let scalar_broadcast =
    {
      N.name = "scalar_broadcast";
      parameters = [ { N.id = 0; typ = N.Scalar N.F32; name = Some "scale" } ];
      result = Some (N.Rack N.F32);
      body =
        {
          instructions =
            [ instruction (Some (1, N.Rack N.F32)) (N.Broadcast 0) ];
          terminators = [ N.Return (Some 1) ];
        };
      loc = N.unknown_location;
    }
  in
  (match (expect_ok scalar_broadcast).instructions with
  | [ M.Broadcast_f32 { dst = 1; source = 0; _ } ] -> ()
  | _ -> failwith "uniform scalar parameter did not select a NEON DUP broadcast");

  let with_body name parameters result instructions terminator =
    {
      N.name;
      parameters;
      result;
      body = { instructions; terminators = [ terminator ] };
      loc = N.unknown_location;
    }
  in
  expect_error "exactly 4 f32 lanes"
    (with_body "wrong_width" [] (Some (N.Rack N.F32))
       [ instruction (Some (0, N.Rack N.F32))
           (N.Rack_const [ N.Float32_bits 0l; N.Float32_bits 0l ]) ]
       (N.Return (Some 0)));
  expect_error "call @helper is forbidden"
    (with_body "call" [ rack_parameter 0 "x" ] (Some (N.Rack N.F32))
       [ instruction (Some (1, N.Rack N.F32))
           (N.Call
              {
                callee = "helper";
                arguments = [ 0 ];
                parameter_types = [ N.Rack N.F32 ];
                return_type = Some (N.Rack N.F32);
                call_effect = N.Pure;
              }) ]
       (N.Return (Some 1)));
  print_endline "AArch64 NEON instruction-selection tests passed"
