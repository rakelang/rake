module M = Rake.Aarch64_neon_mir
module A = Rake.Aarch64_neon_regalloc

let loc line =
  { Rake.Native_ir.file = "neon-regalloc.rk"; line; col = 2; offset = line * 10 }

let parameter reg = { M.reg; name = Some ("p" ^ string_of_int reg) }
let source = Rake.Native_ir.source

let expect_ok function_ =
  match A.allocate_function function_ with
  | Ok allocated -> allocated
  | Error error -> failwith (A.format_error error)

let registers = function
  | A.Uniform_f32 { dst; _ } -> [ dst ]
  | A.Mask_const { dst; _ } -> [ dst ]
  | A.Broadcast_f32 { dst; source } -> [ dst; source ]
  | A.Fadd { dst; left; right }
  | A.Fsub { dst; left; right }
  | A.Fmul { dst; left; right }
  | A.Fdiv { dst; left; right }
  | A.Compare { dst; left; right; _ }
  | A.And { dst; left; right }
  | A.Orr { dst; left; right }
  | A.Eor { dst; left; right } -> [ dst; left; right ]
  | A.Fsqrt { dst; source } | A.Mvn { dst; source } | A.Move { dst; source } ->
      [ dst; source ]
  | A.Fmla { dst; multiplicand; multiplier } -> [ dst; multiplicand; multiplier ]
  | A.Bsl { dst_mask; if_true; if_false } -> [ dst_mask; if_true; if_false ]
  | A.Bit { dst_false; if_true; mask } -> [ dst_false; if_true; mask ]
  | A.Bif { dst_true; if_false; mask } -> [ dst_true; if_false; mask ]

let assert_abi_registers allocated =
  List.iter
    (fun (instruction : A.instruction) ->
      List.iter
        (fun register ->
          if register >= 8 && register <= 15 then
            failwith "allocator used partially callee-saved v8..v15")
        (registers instruction.operation))
    allocated.A.instructions

let () =
  if A.allocatable_registers
     <> List.init 8 Fun.id @ List.init 16 (fun index -> index + 16)
  then failwith "AAPCS64 leaf register set changed";

  let fused = { Rake.Native_ir.fused = Some 0; through = None } in
  let fma =
    {
      M.name = "fma";
      loc = loc 1;
      parameters = [ parameter 0; parameter 1; parameter 2 ];
      instructions =
        [ M.Fma
            {
              dst = 3;
              multiplicand = 0;
              multiplier = 1;
              addend = 2;
              provenance = fused;
            } ];
      result = Some 3;
      value_locations = [ (3, loc 2) ];
    }
  in
  let allocated = expect_ok fma in
  (match allocated.instructions with
  | [ { A.operation = A.Fmla { dst = 2; multiplicand = 0; multiplier = 1 }; _ };
      { operation = A.Move { dst = 0; source = 2 }; _ } ] -> ()
  | _ -> failwith "FMA did not reuse its dying addend and return through v0");
  assert_abi_registers allocated;

  let select =
    {
      M.name = "select";
      loc = loc 10;
      parameters = [ parameter 0; parameter 1; parameter 2 ];
      instructions =
        [ M.Select
            { dst = 3; mask = 0; if_true = 1; if_false = 2; provenance = source } ];
      result = Some 3;
      value_locations = [ (3, loc 11) ];
    }
  in
  (match (expect_ok select).instructions with
  | [ { A.operation = A.Bsl { dst_mask = 0; if_true = 1; if_false = 2 }; _ } ] -> ()
  | _ -> failwith "select did not reuse its dying mask with BSL");

  let select_bit =
    {
      M.name = "select_bit";
      loc = loc 20;
      parameters = [ parameter 0; parameter 1; parameter 2 ];
      instructions =
        [ M.Select
            { dst = 3; mask = 0; if_true = 1; if_false = 2; provenance = source };
          M.And { dst = 4; left = 0; right = 0; provenance = source } ];
      result = Some 3;
      value_locations = [ (3, loc 21); (4, loc 22) ];
    }
  in
  (match (expect_ok select_bit).instructions with
  | { A.operation = A.Bit { dst_false = 2; if_true = 1; mask = 0 }; _ } :: _ -> ()
  | _ -> failwith "select did not reuse its dying false arm with BIT");

  let constants =
    List.init 17 (fun index ->
        M.Uniform_f32
          { dst = 8 + index; bits = Int32.of_int index; provenance = fused })
  in
  let consumers =
    List.init 17 (fun index ->
        M.Fadd
          {
            dst = 25 + index;
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
      result = Some 41;
      value_locations =
        List.init 17 (fun index -> (8 + index, loc (70 + index)))
        @ List.init 17 (fun index -> (25 + index, loc (100 + index)));
    }
  in
  (match A.allocate_function pressure with
  | Error { required = 25; available = 24; fused = true; _ } -> ()
  | Error error -> failwith ("unexpected pressure error: " ^ A.format_error error)
  | Ok _ -> failwith "25-live-rack fused region unexpectedly allocated");
  print_endline "AArch64 NEON no-spill register-allocation tests passed"
