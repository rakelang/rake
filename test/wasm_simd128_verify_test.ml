module N = Rake.Native_ir
module W = Rake.Wasm_simd128_widening
module T = Rake.Wasm_simd128_toolchain

let instruction result op : N.instruction =
  { result; op; provenance = N.source; loc = N.unknown_location }

let parameter id typ : N.parameter = { id; typ; name = None }

(* These C objects are authored independently of Rake's emitter. Their compact
   operations must be refused without operand bounds, even when the source
   contains the corresponding 32-bit operation and widening instructions. *)
let check_object ~name ~source ~func ~parameters ~selected ~forbidden =
  let object_bytes =
    match T.assemble source with
    | Ok bytes -> bytes
    | Error error -> failwith (T.format_error error)
  in
  let verify alternatives =
    T.verify_program ~relaxed:false ~scratches:[]
      ~runs:
        [
          ( name,
            {
              T.loops = 0;
              lane_operations = 0;
              selected;
              alternatives;
              slow_calls = [];
            } );
        ]
      object_bytes
  in
  let _, unproved = W.expression_alternatives ~parameters:[] func in
  (match verify unproved with
  | Error error when T.contains (T.format_error error) forbidden -> ()
  | Error error -> failwith ("unexpected rejection: " ^ T.format_error error)
  | Ok () ->
      failwith
        (name
       ^ ": a compact operation without operand bounds passed verification"));
  let _, proved = W.expression_alternatives ~parameters func in
  match verify proved with
  | Ok () -> ()
  | Error error -> failwith (T.format_error error)

let () =
  check_object ~name:"compared_bytes"
    ~source:
      {|#include <stdint.h>
#include <wasm_simd128.h>
v128_t compared_bytes(v128_t left, v128_t right, v128_t seed) {
  v128_t mask = wasm_i8x16_gt(left, right);
  mask = wasm_v128_xor(mask, seed);
  return wasm_i32x4_extend_low_i16x8(wasm_i16x8_extend_low_i8x16(mask));
}
|}
    ~func:
      {
        N.name = "compared_bytes";
        parameters =
          [
            parameter 0 (N.Rack N.I32);
            parameter 1 (N.Rack N.I32);
            parameter 2 (N.Rack N.I32);
          ];
        result = Some (N.Rack N.I32);
        loc = N.unknown_location;
        body =
          {
            instructions =
              [
                instruction (Some (3, N.Mask)) (N.Compare (N.Gt, 0, 1));
                instruction
                  (Some (4, N.Rack N.I32))
                  (N.Rack_splat (N.Int32 (-1l)));
                instruction (Some (5, N.Rack N.I32)) (N.Binary (N.Xor, 2, 4));
                instruction
                  (Some (6, N.Rack N.I32))
                  (N.Select { condition = 3; if_true = 5; if_false = 2 });
              ];
            terminators = [ N.Return (Some 6) ];
          };
      }
    ~parameters:
      [
        (0, W.compact_column_range Rake.Types.SInt8);
        (1, W.compact_column_range Rake.Types.SInt8);
        (2, W.compact_column_range Rake.Types.SInt8);
      ]
    ~selected:
      [
        "i32x4.gt_s";
        "i32x4.splat";
        "v128.xor";
        "v128.bitselect";
        "i16x8.extend_low_i8x16_s";
        "i32x4.extend_low_i16x8_s";
      ]
    ~forbidden:"i8x16.";
  check_object ~name:"multiplied_words"
    ~source:
      {|#include <stdint.h>
#include <wasm_simd128.h>
v128_t multiplied_words(v128_t left, v128_t right) {
  return wasm_u32x4_extmul_low_u16x8(left, right);
}
|}
    ~func:
      {
        N.name = "multiplied_words";
        parameters = [ parameter 0 (N.Rack N.U32); parameter 1 (N.Rack N.U32) ];
        result = Some (N.Rack N.U32);
        loc = N.unknown_location;
        body =
          {
            instructions =
              [ instruction (Some (2, N.Rack N.U32)) (N.Binary (N.Mul, 0, 1)) ];
            terminators = [ N.Return (Some 2) ];
          };
      }
    ~parameters:
      [
        (0, W.compact_column_range Rake.Types.SUint16);
        (1, W.compact_column_range Rake.Types.SUint16);
      ]
    ~selected:[ "i32x4.mul"; "i32x4.extend_low_i16x8_u" ]
    ~forbidden:"i32x4.extmul_low_i16x8_u";
  print_endline "WebAssembly widened-operation object verification passed"
