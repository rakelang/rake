module M = Rake.X86_avx2_mir
module A = Rake.X86_avx2_regalloc

let loc line =
  { Rake.Native_ir.file = "regalloc.rk"; line; col = 2; offset = line * 10 }

let parameter reg = { M.reg; name = Some ("p" ^ string_of_int reg) }

let fma_function =
  let provenance = { Rake.Native_ir.fused = Some 0; through = None } in
  {
    M.name = "fma";
    loc = loc 1;
    parameters = [ parameter 0; parameter 1; parameter 2 ];
    instructions =
      [ M.Fma_ps
          {
            dst = 3;
            multiplicand = 0;
            multiplier = 1;
            addend = 2;
            provenance;
          } ];
    result = Some 3;
    result_type = Some (Rake.Native_ir.Rack Rake.Native_ir.F32);
    value_locations = [ (3, loc 2) ];
  }

let expect_ok function_ =
  match A.allocate_function function_ with
  | Ok allocated -> allocated
  | Error error -> failwith (A.format_error error)

let () =
  let allocated = expect_ok fma_function in
  (match allocated.instructions with
  | [ { A.operation = A.Fma231ps { dst = 2; multiplicand = 0; multiplier = 1 }; _ };
      { operation = A.Moveaps { dst = 0; source = 2 }; _ } ] -> ()
  | _ -> failwith "FMA did not reuse its dying addend and return through ymm0");
  if allocated.maximum_live <> 3 then failwith "unexpected FMA live-register count";

  let source = Rake.Native_ir.source in
  let add =
    {
      M.name = "add";
      loc = loc 10;
      parameters = [ parameter 0; parameter 1 ];
      instructions = [ M.Addps { dst = 2; left = 0; right = 1; provenance = source } ];
      result = Some 2;
      result_type = Some (Rake.Native_ir.Rack Rake.Native_ir.F32);
      value_locations = [ (2, loc 11) ];
    }
  in
  (match (expect_ok add).instructions with
  | [ { A.operation = A.Addps { dst = 0; left = 0; right = 1 }; _ } ] -> ()
  | _ -> failwith "three-operand add did not coalesce a dying input into ymm0");

  let cross_lane name operation result_type =
    {
      M.name;
      loc = loc 30;
      parameters = [ parameter 0 ];
      instructions = [ operation ];
      result = Some 1;
      result_type = Some result_type;
      value_locations = [ (1, loc 31) ];
    }
  in
  let reduction =
    cross_lane "strict_reduce_min"
      (M.Reduce_f32
         { dst = 1; source = 0; operation = Rake.Native_ir.Reduce_min;
           provenance = source })
      (Rake.Native_ir.Scalar Rake.Native_ir.F32)
    |> expect_ok
  in
  (match reduction.instructions with
  | [ { A.operation = A.Reduce_f32 { dst = 1; source = 0; scratch; _ }; _ };
      { operation = A.Moveaps { dst = 0; source = 1 }; _ } ]
    when List.length scratch = 6 -> ()
  | _ -> failwith "strict min reduction did not reserve six no-spill temporaries");
  if reduction.result_type <> Some (Rake.Native_ir.Scalar Rake.Native_ir.F32) then
    failwith "register allocation lost the scalar reduction result type";
  let scan =
    cross_lane "strict_scan_add"
      (M.Scan_f32
         { dst = 1; source = 0; operation = Rake.Native_ir.Scan_add;
           provenance = source })
      (Rake.Native_ir.Rack Rake.Native_ir.F32)
    |> expect_ok
  in
  (match scan.instructions with
  | [ { A.operation = A.Scan_f32 { dst = 1; source = 0; scratch; _ }; _ };
      { operation = A.Moveaps { dst = 0; source = 1 }; _ } ]
    when List.length scratch = 2 -> ()
  | _ -> failwith "strict add scan did not reserve two no-spill temporaries");

  let fused = { Rake.Native_ir.fused = Some 4; through = None } in
  let constants =
    List.init 9 (fun index ->
        M.Uniform_f32 { dst = 8 + index; bits = Int32.of_int index; provenance = fused })
  in
  let consumers =
    List.init 9 (fun index ->
        M.Addps
          {
            dst = 17 + index;
            left = index mod 8;
            right = 8 + index;
            provenance = source;
          })
  in
  let pressure =
    {
      M.name = "pressure";
      loc = loc 60;
      parameters = List.init 8 parameter;
      instructions = constants @ consumers;
      result = Some 25;
      result_type = Some (Rake.Native_ir.Rack Rake.Native_ir.F32);
      value_locations =
        List.init 9 (fun index -> (8 + index, loc (69 + index)))
        @ List.init 9 (fun index -> (17 + index, loc (90 + index)));
    }
  in
  (match A.allocate_function pressure with
  | Error { required = 17; available = 16; fused = true; loc = failure_loc; _ }
    when failure_loc.line = 77 -> ()
  | Error error -> failwith ("unexpected pressure error: " ^ A.format_error error)
  | Ok _ -> failwith "17-live-rack fused region unexpectedly allocated");

  let too_many_arguments =
    {
      M.name = "too_many_arguments";
      loc = loc 120;
      parameters = List.init 9 parameter;
      instructions = [];
      result = Some 0;
      result_type = Some (Rake.Native_ir.Rack Rake.Native_ir.F32);
      value_locations = [];
    }
  in
  (match A.allocate_function too_many_arguments with
  | Error { required = 9; available = 8; _ } -> ()
  | Error error ->
      failwith ("unexpected argument-boundary error: " ^ A.format_error error)
  | Ok _ -> failwith "nine SSE-class arguments unexpectedly used a stack slot");
  print_endline "x86 AVX2 no-spill register-allocation tests passed"
