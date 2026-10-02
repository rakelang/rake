(** JavaScript boundary for the in-browser playground. *)

open Js_of_ocaml

let js_string value = Js.Unsafe.inject (Js.string value)
let js_int value = Js.Unsafe.inject value

let js_option_string = function
  | Some value -> js_string value
  | None -> Js.Unsafe.inject Js.null

let js_lane_trace (trace : Rake.Playground.lane_trace) =
  Js.Unsafe.obj
    [|
      ("name", js_string trace.name);
      ("line", js_int trace.line);
      ("column", js_int trace.column);
      ("kind", js_string trace.kind);
      ( "values",
        Js.Unsafe.inject
          (Js.array (Array.of_list (List.map Js.string trace.values))) );
      ( "active",
        match trace.active with
        | Some value -> js_int value
        | None -> Js.Unsafe.inject Js.null );
    |]

let target = function
  | "wasm-simd128" -> Ok Rake.Playground.Wasm_simd128
  | "x86-sse2" -> Ok X86_sse2
  | "x86-avx2" -> Ok X86_avx2
  | "x86-avx512" -> Ok X86_avx512
  | "aarch64-neon" -> Ok Aarch64_neon
  | value -> Error (Printf.sprintf "unknown playground target '%s'" value)

let compile source target_name =
  let result =
    match target (Js.to_string target_name) with
    | Error message -> Error message
    | Ok target ->
        Rake.Playground.compile ~source:(Js.to_string source) ~target
  in
  match result with
  | Error message ->
      Js.Unsafe.obj
        [|
          ("ok", Js.Unsafe.inject Js._false);
          ("message", js_string message);
        |]
  | Ok output ->
      Js.Unsafe.obj
        [|
          ("ok", Js.Unsafe.inject Js._true);
          ("result", js_option_string output.result);
          ("code", js_string output.code);
          ( "traces",
            Js.Unsafe.inject
              (Js.array
                 (Array.of_list (List.map js_lane_trace output.traces))) );
        |]

let () = Js.export "rakePlaygroundCompile" (Js.wrap_callback compile)
