module N = Rake.Native_ir
module M = Rake.X86_avx2_mir
module I = Rake.X86_avx2_isel

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
  let through = { N.fused = None; through = Some 13 } in
  {
    N.name = "all_operations";
    parameters =
      [ rack_parameter 0 "a"; rack_parameter 1 "b"; rack_parameter 2 "c" ];
    result = Some (N.Rack N.F32);
    body =
      {
        instructions =
          [ instruction (Some (3, N.Rack N.F32)) (N.Rack_splat (N.Float32_bits 0x80000000l));
            instruction (Some (4, N.Rack N.F32)) (N.Unary (N.Neg, 0));
            instruction (Some (5, N.Rack N.F32)) (N.Unary (N.Sqrt, 1));
            instruction (Some (6, N.Rack N.F32)) (N.Binary (N.Add, 4, 5));
            instruction (Some (7, N.Rack N.F32)) (N.Binary (N.Sub, 6, 2));
            instruction (Some (8, N.Rack N.F32)) (N.Binary (N.Mul, 7, 1));
            instruction (Some (9, N.Rack N.F32)) (N.Binary (N.Div, 8, 0));
            instruction ~provenance:fused (Some (10, N.Rack N.F32)) (N.Fma (0, 1, 2));
            instruction (Some (11, N.Mask)) (N.Compare (N.Gt, 9, 10));
            instruction (Some (12, N.Mask)) (N.Compare (N.Ne, 0, 1));
            instruction (Some (13, N.Mask)) (N.Mask_binary (N.And, 11, 12));
            instruction (Some (14, N.Mask)) (N.Mask_binary (N.Or, 11, 13));
            instruction (Some (15, N.Mask)) (N.Mask_binary (N.Xor, 14, 12));
            instruction (Some (16, N.Mask)) (N.Mask_not 15);
            instruction ~provenance:through (Some (17, N.Rack N.F32))
              (N.Select { condition = 16; if_true = 10; if_false = 9 }) ];
        terminators = [ N.Return (Some 17) ];
      };
    loc = N.unknown_location;
  }

let () =
  let selected = expect_ok valid_function in
  let instructions = selected.M.instructions in
  if List.length instructions <> 15 then
    failwith (Printf.sprintf "selected %d instructions; expected 15" (List.length instructions));
  (match List.nth instructions 0 with
  | M.Uniform_f32 { bits; _ } when bits = 0x80000000l -> ()
  | _ -> failwith "negative-zero rack constant did not retain its exact f32 bits");
  (match List.nth instructions 7 with
  | M.Fma_ps { provenance = { fused = Some 7; _ }; _ } -> ()
  | _ -> failwith "FMA pseudo-op or fused provenance was not retained");
  (match List.nth instructions 8 with
  | M.Cmpps { predicate = M.Olt; left = 10; right = 9; _ } -> ()
  | _ -> failwith "ordered greater-than was not canonicalized to swapped LT_OQ");
  (match List.nth instructions 9 with
  | M.Cmpps { predicate = M.One; _ } -> ()
  | _ -> failwith "ordered not-equal predicate was not selected");
  (match List.nth instructions 14 with
  | M.Blendvps
      { mask = 16; if_true = 10; if_false = 9; provenance = { through = Some 13; _ }; _ } ->
      ()
  | _ -> failwith "select operands or through provenance were not retained");
  if M.comparison_immediate M.Oeq <> 0x00 || M.comparison_immediate M.One <> 0x0c
     || M.comparison_immediate M.Olt <> 0x11 || M.comparison_immediate M.Ole <> 0x12
  then failwith "ordered comparison immediates changed";
  List.iter
    (fun selected_instruction ->
      if M.def selected_instruction < 0 then failwith "invalid MIR definition";
      ignore (M.operands selected_instruction))
    instructions;

  let broadcast_function =
    {
      N.name = "broadcast";
      parameters = [];
      result = Some (N.Rack N.F32);
      body =
        {
          instructions =
            [ instruction (Some (0, N.Scalar N.F32))
                (N.Const (N.Float32_bits 0x7fc01234l));
              instruction (Some (1, N.Rack N.F32)) (N.Broadcast 0) ];
          terminators = [ N.Return (Some 1) ];
        };
      loc = N.unknown_location;
    }
  in
  (match (expect_ok broadcast_function).M.instructions with
  | [ M.Uniform_f32 { bits; _ } ] when bits = 0x7fc01234l -> ()
  | _ -> failwith "constant broadcast did not select one bit-exact uniform-rack pseudo-op");

  let parameter_broadcast_function =
    {
      N.name = "parameter_broadcast";
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
  (match (expect_ok parameter_broadcast_function).M.instructions with
  | [ M.Broadcastss { source = 0; _ } ] -> ()
  | _ -> failwith "scalar parameter broadcast did not select vbroadcastss from XMM");

  let reduction_function =
    {
      N.name = "strict_reduce_min";
      parameters = [ rack_parameter 0 "values" ];
      result = Some (N.Scalar N.F32);
      body =
        {
          instructions =
            [ instruction (Some (1, N.Scalar N.F32))
                (N.Reduce (N.Reduce_min, 0)) ];
          terminators = [ N.Return (Some 1) ];
        };
      loc = N.unknown_location;
    }
  in
  (match expect_ok reduction_function with
  | { M.instructions = [ M.Reduce_f32 { source = 0; operation = N.Reduce_min; _ } ];
      result_type = Some (N.Scalar N.F32); _ } -> ()
  | _ -> failwith "strict f32 reduction did not retain its scalar result type");
  let scan_function =
    {
      reduction_function with
      N.name = "strict_scan_max";
      result = Some (N.Rack N.F32);
      body =
        {
          instructions =
            [ instruction (Some (1, N.Rack N.F32)) (N.Scan (N.Scan_max, 0)) ];
          terminators = [ N.Return (Some 1) ];
        };
    }
  in
  (match expect_ok scan_function with
  | { M.instructions = [ M.Scan_f32 { source = 0; operation = N.Scan_max; _ } ];
      result_type = Some (N.Rack N.F32); _ } -> ()
  | _ -> failwith "strict f32 scan did not retain its rack result type");

  let with_body name parameters result instructions terminator =
    {
      N.name;
      parameters;
      result;
      body = { instructions; terminators = [ terminator ] };
      loc = N.unknown_location;
    }
  in
  expect_error "non-uniform rack constants"
    (with_body "nonuniform" [] (Some (N.Rack N.F32))
       [ instruction (Some (0, N.Rack N.F32))
           (N.Rack_const
              [ N.Float32_bits 0l; N.Float32_bits 1l; N.Float32_bits 0l; N.Float32_bits 0l;
                N.Float32_bits 0l; N.Float32_bits 0l; N.Float32_bits 0l; N.Float32_bits 0l ]) ]
       (N.Return (Some 0)));
  expect_error "exactly 8 f32 lanes"
    (with_body "wrong_width" [] (Some (N.Rack N.F32))
       [ instruction (Some (0, N.Rack N.F32))
           (N.Rack_const [ N.Float32_bits 0l; N.Float32_bits 0l ]) ]
       (N.Return (Some 0)));
  expect_error "only rack<f32>, scalar<f32>, and mask parameters"
    (with_body "f64" [ { N.id = 0; typ = N.Rack N.F64; name = None } ]
       (Some (N.Rack N.F64)) [] (N.Return (Some 0)));
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
  expect_error "must use Unary(Sqrt, value)"
    (with_body "old_sqrt" [ rack_parameter 0 "x" ] (Some (N.Rack N.F32))
       [ instruction (Some (1, N.Rack N.F32))
           (N.Call
              {
                callee = "sqrt";
                arguments = [ 0 ];
                parameter_types = [ N.Rack N.F32 ];
                return_type = Some (N.Rack N.F32);
                call_effect = N.Pure;
              }) ]
       (N.Return (Some 1)));
  print_endline "x86 AVX2 instruction-selection tests passed"
