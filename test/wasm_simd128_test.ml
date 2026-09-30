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

(* The student network's inner step and requantisation: a dot product accumulated
   into i32 sums, then two i32 racks scaled, rounded, narrowed and clamped at zero. *)
let integer_kernel =
  {
    N.name = "requantise";
    parameters =
      [ parameter 0 "pair" (N.Rack N.I16); parameter 1 "weights" (N.Rack N.I16);
        parameter 2 "sums" (N.Rack N.I32); parameter 3 "scale" (N.Rack N.F32) ];
    result = Some (N.Rack N.I16);
    body =
      {
        instructions =
          [ instruction (Some (4, N.Rack N.I32)) (N.Dot (0, 1));
            instruction (Some (5, N.Rack N.I32)) (N.Binary (N.Add, 2, 4));
            instruction (Some (6, N.Rack N.F32)) (N.Convert { operand = 5; element = N.F32 });
            instruction (Some (7, N.Rack N.F32)) (N.Binary (N.Mul, 6, 3));
            instruction (Some (8, N.Rack N.I32)) (N.Convert { operand = 7; element = N.I32 });
            instruction (Some (9, N.Rack N.I16)) (N.Narrow (8, 8));
            instruction (Some (10, N.Rack N.I16)) (N.Rack_splat (N.Int16 0));
            instruction (Some (11, N.Rack N.I16)) (N.Binary (N.Max, 9, 10)) ];
        terminators = [ N.Return (Some 11) ];
      };
    loc = N.unknown_location;
  }

let () =
  let source = C.emit ~source:"requantise.rk" [ select integer_kernel ] in
  List.iter
    (fun expected -> if not (contains expected source) then failwith ("missing " ^ expected ^ " in:\n" ^ source))
    [ "v128_t requantise(v128_t pair, v128_t weights, v128_t sums, v128_t scale)";
      "wasm_i32x4_dot_i16x8(pair, weights)"; "wasm_i32x4_add(sums, step0)"; "wasm_f32x4_convert_i32x4(step1)";
      "wasm_f32x4_nearest("; "wasm_i32x4_trunc_sat_f32x4("; "wasm_i16x8_narrow_i32x4("; "wasm_i16x8_splat(0)";
      "wasm_i16x8_max(" ]

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

(* A bitboard row step: the cells reached, those one step east within a board of
   width w (a rotation by 1 and by w - 1), masked to the board. *)
let bits_kernel =
  {
    N.name = "spread_east";
    parameters =
      [ parameter 0 "here" (N.Rack N.I64); parameter 1 "open" (N.Rack N.I64);
        parameter 2 "board" (N.Rack N.I64); parameter 3 "wrap" (N.Scalar N.I32) ];
    result = Some (N.Rack N.I64);
    body =
      {
        instructions =
          [ instruction (Some (4, N.Rack N.I64)) (N.Binary (N.And, 0, 1));
            instruction (Some (5, N.Scalar N.I32)) (N.Const (N.Int32 1l));
            instruction (Some (6, N.Rack N.I64)) (N.Shift { operand = 4; count = 5; shift = N.Shift_left });
            instruction (Some (7, N.Rack N.I64)) (N.Shift { operand = 4; count = 3; shift = N.Shift_right });
            instruction (Some (8, N.Rack N.I64)) (N.Binary (N.Or, 6, 7));
            instruction (Some (9, N.Rack N.I64)) (N.Binary (N.And, 8, 2));
            instruction (Some (10, N.Rack N.I64)) (N.Binary (N.Andnot, 9, 0)) ];
        terminators = [ N.Return (Some 10) ];
      };
    loc = N.unknown_location;
  }

let () =
  let source = C.emit ~source:"spread.rk" [ select bits_kernel ] in
  List.iter
    (fun expected -> if not (contains expected source) then failwith ("missing " ^ expected ^ " in:\n" ^ source))
    [ "v128_t spread_east(v128_t here, v128_t open, v128_t board, uint32_t wrap)";
      "wasm_v128_and(here, open)"; "wasm_i64x2_shl("; ", 1)"; "wasm_u64x2_shr("; ", wrap)";
      "wasm_v128_or("; "wasm_v128_andnot(" ]
