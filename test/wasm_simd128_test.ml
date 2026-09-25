module N = Rake.Native_ir
module I = Rake.Wasm_simd128_isel
module C = Rake.Wasm_simd128_c

let instruction result op : N.instruction =
  { result; op; provenance = N.source; loc = N.unknown_location }

let contains needle haystack =
  let rec search offset =
    offset + String.length needle <= String.length haystack
    && (String.sub haystack offset (String.length needle) = needle || search (offset + 1))
  in
  search 0

let select func =
  match I.select [ func ] with
  | Ok [ selected ] -> selected
  | Ok _ -> failwith "expected one selected function"
  | Error error -> failwith (I.format_error error)

let parameter id name typ : N.parameter = { id; typ; name = Some name }

(* s = a + b is shared by the selected value and the condition, and the condition is the last
   bitselect operand, so emitting operands out of order would get s before computing it. *)
let shared_value =
  {
    N.name = "shared";
    parameters = [ parameter 0 "a" (N.Rack N.F32); parameter 1 "b" (N.Rack N.F32) ];
    result = Some (N.Rack N.F32);
    body =
      {
        instructions =
          [ instruction (Some (2, N.Rack N.F32)) (N.Binary (N.Add, 0, 1));
            instruction (Some (3, N.Rack N.F32)) (N.Binary (N.Mul, 2, 2));
            instruction (Some (4, N.Mask)) (N.Compare (N.Gt, 2, 0));
            instruction (Some (5, N.Rack N.F32)) (N.Select { condition = 4; if_true = 3; if_false = 1 }) ];
        terminators = [ N.Return (Some 5) ];
      };
    loc = N.unknown_location;
  }

let side_bits =
  {
    N.name = "side_bits";
    parameters = [ parameter 0 "a" (N.Rack N.U8); parameter 1 "b" (N.Rack N.U8) ];
    result = Some (N.Scalar N.I32);
    body =
      {
        instructions =
          [ instruction (Some (2, N.Rack N.U8))
              (N.Shuffle { racks = [ 0; 1 ]; indices = [ 0; 4; 8; 12; 16; 20; 24; 28; 0; 0; 0; 0; 0; 0; 0; 0 ] });
            instruction (Some (3, N.Rack N.U8)) (N.Rack_splat (N.Uint8 0));
            instruction (Some (4, N.Mask)) (N.Compare (N.Ne, 2, 3));
            instruction (Some (5, N.Scalar N.I32)) (N.Reduce (N.Reduce_bitmask, 4)) ];
        terminators = [ N.Return (Some 5) ];
      };
    loc = N.unknown_location;
  }

let () =
  let selected = select shared_value in
  let teed = Hashtbl.create 4 in
  List.iter
    (function
      | I.Local_tee local -> Hashtbl.replace teed local ()
      | I.Local_get (I.Scratch_local _ as local) when not (Hashtbl.mem teed local) ->
          failwith "a scratch local is read before it is written"
      | _ -> ())
    selected.instructions;
  let source = C.emit ~source:"shared.rk" [ selected ] in
  List.iter
    (fun expected -> if not (contains expected source) then failwith ("missing " ^ expected ^ " in:\n" ^ source))
    [ "wasm_f32x4_add(a, b)"; "wasm_f32x4_mul(step0, step0)"; "wasm_f32x4_gt(step0, a)";
      "wasm_v128_bitselect(step1, b, step2)" ];
  let source = C.emit ~source:"side_bits.rk" [ select side_bits ] in
  List.iter
    (fun expected -> if not (contains expected source) then failwith ("missing " ^ expected ^ " in:\n" ^ source))
    [ "uint32_t side_bits(v128_t a, v128_t b)";
      "wasm_i8x16_shuffle(a, b, 0, 4, 8, 12, 16, 20, 24, 28, 0, 0, 0, 0, 0, 0, 0, 0)";
      "wasm_i8x16_ne(step0, step1)"; "wasm_i8x16_bitmask(step2)" ];
  print_endline "wasm-simd128 selection and C emission tests passed"
