(* Writes a C harness that checks compiled Rake functions against Rake's scalar
   reference semantics on one target profile.

     reference_harness PROFILE CASES.tsv SOURCE.rk... > harness.c

   CASES.tsv documents its columns and value syntax. Cases whose function no
   source defines are skipped, so one case table serves profiles that compile
   different fixture sets. The profile's native IR supplies every function's
   parameter and result types and its lane count; the reference interpreter
   evaluates each case at that lane count; and the harness calls the compiled
   function on the same inputs and compares the result bits under the case's
   NaN rule.

   [run_reference_cases] returns 0, or 1000 times the failing case's line
   number plus the failing lane, plus 999 when a quiet case raised a flag.
   Define RAKE_HARNESS_FENV where the platform has floating-point exception
   flags, and RAKE_HARNESS_MAIN for a main that reports the failure. *)

open Rake

let fail message =
  prerr_endline ("reference_harness: " ^ message);
  exit 1

type word_element = Word_f32 | Word_i32 | Word_u32

type word_shape = Word_rack | Word_uniform

type word_type = { shape : word_shape; element : word_element }

type reference_definition = {
  ast_definition   : Ast.def;              (* evaluated by the interpreter *)
  module_definitions : Ast.def list;       (* resolve its calls and global tines *)
  native_function  : Native_ir.func;       (* supplies its machine signature *)
}

let word_type_of_native_type function_name = function
  | Native_ir.Rack Native_ir.F32 -> { shape = Word_rack; element = Word_f32 }
  | Native_ir.Rack Native_ir.I32 -> { shape = Word_rack; element = Word_i32 }
  | Native_ir.Rack Native_ir.U32 -> { shape = Word_rack; element = Word_u32 }
  | Native_ir.Scalar Native_ir.F32 -> { shape = Word_uniform; element = Word_f32 }
  | Native_ir.Scalar Native_ir.I32 -> { shape = Word_uniform; element = Word_i32 }
  | Native_ir.Scalar Native_ir.U32 -> { shape = Word_uniform; element = Word_u32 }
  | native_type ->
      fail
        (Printf.sprintf "%s uses %s, which the harness can't pass as 32-bit words" function_name
           (Native_ir.string_of_typ native_type))

let c_type_name = function
  | { shape = Word_rack; element = Word_f32 } -> "rake_f32_rack"
  | { shape = Word_rack; element = Word_i32 } -> "rake_i32_rack"
  | { shape = Word_rack; element = Word_u32 } -> "rake_u32_rack"
  | { shape = Word_uniform; element = Word_f32 } -> "float"
  | { shape = Word_uniform; element = Word_i32 } -> "int32_t"
  | { shape = Word_uniform; element = Word_u32 } -> "uint32_t"

let parse_word_bits element text =
  match (element, text) with
  | Word_f32, "inf" -> Int32.bits_of_float infinity
  | Word_f32, "-inf" -> Int32.bits_of_float neg_infinity
  | Word_f32, "nan" -> 0x7fc00000l
  | _, _ when String.starts_with ~prefix:"0x" text -> Int32.of_string text
  | Word_f32, _ -> Int32.bits_of_float (float_of_string text)
  | Word_i32, _ -> Int32.of_string text
  | Word_u32, _ ->
      let value = Int64.of_string text in
      if value < 0L || value > 0xffffffffL then fail ("u32 value out of range: " ^ text);
      Int64.to_int32 value

let parse_argument_bits ~lanes word_type text =
  let values = String.split_on_char ',' text |> List.map (parse_word_bits word_type.element) in
  match word_type.shape with
  | Word_uniform when List.length values = 1 -> Array.of_list values
  | Word_uniform -> fail ("a uniform argument takes one value: " ^ text)
  | Word_rack when List.length values >= lanes -> Array.sub (Array.of_list values) 0 lanes
  | Word_rack -> fail (Printf.sprintf "a rack argument needs at least %d lanes: %s" lanes text)

let unsigned_word bits = Int64.logand (Int64.of_int32 bits) 0xffffffffL

let reference_value word_type bits =
  match word_type with
  | { shape = Word_rack; element = Word_f32 } ->
      Native_reference.rack (Array.map Int32.float_of_bits bits)
  | { shape = Word_rack; element = Word_i32 } -> Native_reference.I32_rack (Array.map Int32.to_int bits)
  | { shape = Word_rack; element = Word_u32 } -> Native_reference.U32_rack (Array.map unsigned_word bits)
  | { shape = Word_uniform; element = Word_f32 } -> Native_reference.scalar (Int32.float_of_bits bits.(0))
  | { shape = Word_uniform; element = Word_i32 } ->
      Native_reference.Int_scalar (Types.SInt, Int64.of_int32 bits.(0))
  | { shape = Word_uniform; element = Word_u32 } ->
      Native_reference.Int_scalar (Types.SUint, unsigned_word bits.(0))

let reference_result_bits function_name = function
  | Native_reference.F32_rack values -> Array.map Int32.bits_of_float values
  | Native_reference.I32_rack values -> Array.map Int32.of_int values
  | Native_reference.U32_rack values -> Array.map Int64.to_int32 values
  | Native_reference.F32_scalar value -> [| Int32.bits_of_float value |]
  | Native_reference.Int_scalar (_, value) -> [| Int64.to_int32 value |]
  | Native_reference.U32_scalar value -> [| Int32.of_int value |]
  | value ->
      fail
        (Printf.sprintf "%s returns a %s, which the harness can't compare as words" function_name
           (Native_reference.string_of_value_kind (Native_reference.value_kind value)))

let evaluate_reference_definition ~lanes definition arguments =
  Native_reference.definitions := definition.module_definitions;
  let evaluate =
    match definition.ast_definition.v with
    | Ast.DRake _ -> Native_reference.eval_rake
    | _ -> Native_reference.eval_scratch
  in
  match evaluate ~lanes definition.ast_definition arguments with
  | Ok value -> value
  | Error error ->
      fail (definition.native_function.name ^ ": " ^ Native_reference.format_error error)

let definition_name (definition : Ast.def) =
  match definition.v with
  | Ast.DScratch (name, _, _, _) | Ast.DRake (name, _, _, _, _, _, _) -> Some name
  | _ -> None

let load_reference_definitions ~config source_path =
  let program =
    match Source.parse_file source_path with Ok program -> program | Error message -> fail message
  in
  (match Typecheck.check program with Ok _ -> () | Error message -> fail message);
  let native_functions =
    match Native_backend.lower ~config program with
    | Ok native_functions -> native_functions
    | Error error -> fail (source_path ^ ": " ^ Native_backend.format_error error)
  in
  let module_definitions = List.concat_map (fun (m : Ast.module_) -> m.mod_defs) program in
  List.filter_map
    (fun (native_function : Native_ir.func) ->
      List.find_opt
        (fun definition -> definition_name definition = Some native_function.name)
        module_definitions
      |> Option.map (fun ast_definition ->
             (native_function.name, { ast_definition; module_definitions; native_function })))
    native_functions

let c_word_list bits =
  String.concat ", " (List.map (Printf.sprintf "0x%08lxu") (Array.to_list bits))

let () =
  match Array.to_list Sys.argv with
  | _ :: profile_name :: cases_path :: (_ :: _ as source_paths) ->
      let config =
        match Target.selection_of_string profile_name with
        | Ok (Target.Explicit profile) -> (
            match Target.make ~selection:(Target.Explicit profile) Target.Cpu with
            | Ok config -> config
            | Error message -> fail message)
        | Ok Target.Native -> fail "name an explicit profile"
        | Error message -> fail message
      in
      let lanes = config.width in
      let definitions = List.concat_map (load_reference_definitions ~config) source_paths in
      let declarations = Buffer.create 1024 and cases = Buffer.create 8192 in
      let declared = Hashtbl.create 32 in
      let case_count = ref 0 in
      In_channel.with_open_text cases_path In_channel.input_lines
      |> List.iteri (fun line_index line ->
             let line_number = line_index + 1 in
             if line <> "" && line.[0] <> '#' then
               match String.split_on_char '\t' line with
               | name :: exception_rule :: nan_rule :: argument_texts -> (
                   let quiet =
                     match exception_rule with
                     | "quiet" -> true
                     | "any" -> false
                     | rule -> fail (Printf.sprintf "%s:%d: unknown exception rule %s" cases_path line_number rule)
                   in
                   let any_nan_matches =
                     match nan_rule with
                     | "exact" -> false
                     | "nan-any" -> true
                     | rule -> fail (Printf.sprintf "%s:%d: unknown NaN rule %s" cases_path line_number rule)
                   in
                   match List.assoc_opt name definitions with
                   | None -> ()
                   | Some definition ->
                       incr case_count;
                       let native_function = definition.native_function in
                       let parameter_types =
                         List.map
                           (fun (parameter : Native_ir.parameter) -> word_type_of_native_type name parameter.typ)
                           native_function.parameters
                       in
                       let result_type =
                         match native_function.result with
                         | Some native_type -> word_type_of_native_type name native_type
                         | None -> fail (name ^ " returns no value")
                       in
                       if List.length argument_texts <> List.length parameter_types then
                         fail
                           (Printf.sprintf "%s:%d: %s takes %d arguments" cases_path line_number name
                              (List.length parameter_types));
                       let argument_bits = List.map2 (parse_argument_bits ~lanes) parameter_types argument_texts in
                       let expected =
                         evaluate_reference_definition ~lanes definition
                           (List.map2 reference_value parameter_types argument_bits)
                         |> reference_result_bits name
                       in
                       let expected_words = match result_type.shape with Word_rack -> lanes | Word_uniform -> 1 in
                       if Array.length expected <> expected_words then
                         fail (Printf.sprintf "%s: the reference returned %d words, not %d" name
                                 (Array.length expected) expected_words);
                       if not (Hashtbl.mem declared name) then begin
                         Hashtbl.add declared name ();
                         Printf.bprintf declarations "extern %s %s(%s);\n" (c_type_name result_type) name
                           (String.concat ", " (List.map c_type_name parameter_types))
                       end;
                       Printf.bprintf cases "    {\n";
                       List.iteri
                         (fun index (word_type, bits) ->
                           Printf.bprintf cases
                             "        static const uint32_t argument%d_words[] = { %s };\n\
                             \        %s argument%d;\n\
                             \        __builtin_memcpy(&argument%d, argument%d_words, sizeof argument%d);\n"
                             index (c_word_list bits) (c_type_name word_type) index index index index)
                         (List.combine parameter_types argument_bits);
                       Printf.bprintf cases
                         "        static const uint32_t expected_words[] = { %s };\n\
                         \        uint32_t actual_words[%d];\n\
                         \        clear_exceptions();\n\
                         \        const %s result = %s(%s);\n"
                         (c_word_list expected) expected_words (c_type_name result_type) name
                         (String.concat ", " (List.mapi (fun index _ -> Printf.sprintf "argument%d" index) parameter_types));
                       if quiet then
                         Printf.bprintf cases "        if (raised_exceptions()) return %d;\n" (line_number * 1000 + 999);
                       let word_check =
                         if any_nan_matches && result_type.element = Word_f32 then "f32_words_agree_on_nan"
                         else "words_agree_exactly"
                       in
                       Printf.bprintf cases
                         "        __builtin_memcpy(actual_words, &result, sizeof actual_words);\n\
                         \        for (int lane = 0; lane < %d; ++lane)\n\
                         \            if (!%s(actual_words[lane], expected_words[lane])) return %d + lane + 1;\n\
                         \    }\n"
                         expected_words word_check (line_number * 1000))
               | _ -> fail (Printf.sprintf "%s:%d: unreadable case" cases_path line_number));
      if !case_count = 0 then fail "no case names a function in the sources";
      Printf.printf
        {|/* Generated by test/reference_harness.ml for %s: %d cases. */
#include <stdint.h>
#ifdef RAKE_HARNESS_FENV
#include <fenv.h>
static void clear_exceptions(void) { feclearexcept(FE_ALL_EXCEPT); }
static int raised_exceptions(void) { return fetestexcept(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW) != 0; }
#else
static void clear_exceptions(void) {}
static int raised_exceptions(void) { return 0; }
#endif

typedef float rake_f32_rack __attribute__((vector_size(%d)));
typedef int32_t rake_i32_rack __attribute__((vector_size(%d)));
typedef uint32_t rake_u32_rack __attribute__((vector_size(%d)));

static int words_agree_exactly(uint32_t actual, uint32_t expected) { return actual == expected; }
static int f32_word_is_nan(uint32_t word) { return (word & 0x7fffffffu) > 0x7f800000u; }
static int f32_words_agree_on_nan(uint32_t actual, uint32_t expected) {
    return actual == expected || (f32_word_is_nan(actual) && f32_word_is_nan(expected));
}

%s
int run_reference_cases(void) {
%s    return 0;
}

#ifdef RAKE_HARNESS_MAIN
#include <stdio.h>
int main(void) {
    const int failure = run_reference_cases();
    if (failure) fprintf(stderr, "case on line %%d failed at %%d\n", failure / 1000, failure %% 1000);
    else printf("%s reference agreement: %d cases\n");
    return failure != 0;
}
#endif
|}
        profile_name !case_count (lanes * 4) (lanes * 4) (lanes * 4) (Buffer.contents declarations)
        (Buffer.contents cases) profile_name !case_count
  | _ -> fail "usage: reference_harness PROFILE CASES.tsv SOURCE.rk..."
