(** GNU assembly emission for allocated AArch64 Advanced SIMD machine IR. *)

module A = Aarch64_neon_regalloc
module M = Aarch64_neon_mir

type error = {
  function_name : string;
  loc : Native_ir.source_location;
  message : string;
}

let format_error error =
  Printf.sprintf "%s: %s: %s" (Native_ir.format_source_location error.loc)
    error.function_name error.message

type pool = { mutable entries : (int32 * string) list; mutable next_label : int }
let create_pool () = { entries = []; next_label = 0 }

let intern pool bits =
  match List.assoc_opt bits pool.entries with
  | Some label -> label
  | None ->
      let label = Printf.sprintf ".Lrake_neon_const_%d" pool.next_label in
      pool.next_label <- pool.next_label + 1;
      pool.entries <- pool.entries @ [ (bits, label) ];
      label

let vector register = Printf.sprintf "v%d" register
let q register = Printf.sprintf "q%d" register
let lanes_f32 register = vector register ^ ".4s"
let lanes_bits register = vector register ^ ".16b"

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

let valid_physical_register register =
  (register >= 0 && register <= 7) || (register >= 16 && register <= 31)

let valid_symbol name =
  let initial = function
    | 'a' .. 'z' | 'A' .. 'Z' | '_' | '.' | '$' -> true
    | _ -> false
  in
  let subsequent character =
    initial character || (character >= '0' && character <= '9')
  in
  String.length name > 0 && initial name.[0] && String.for_all subsequent name

let validate_function (func : A.func) =
  if not (valid_symbol func.name) then
    Error { function_name = func.name; loc = func.loc; message = "invalid assembly symbol" }
  else
    match func.result with
    | Some register when register <> 0 ->
        Error
          {
            function_name = func.name;
            loc = func.loc;
            message =
              Printf.sprintf
                "allocated rack result must use the AAPCS64 return register v0, not v%d"
                register;
          }
    | _ ->
        let rec check = function
          | [] -> Ok ()
          | ({ A.operation; loc; _ } : A.instruction) :: rest -> (
              match
                List.find_opt
                  (fun register -> not (valid_physical_register register))
                  (registers operation)
              with
              | None -> check rest
              | Some register ->
                  Error
                    {
                      function_name = func.name;
                      loc;
                      message =
                        Printf.sprintf
                          "invalid physical vector register v%d; spill-free AAPCS64 leaf profile provides v0..v7 and v16..v31"
                          register;
                    })
        in
        check func.instructions

let emit_instruction pool buffer ({ A.operation; _ } : A.instruction) =
  let emit format = Printf.bprintf buffer ("    " ^^ format ^^ "\n") in
  match operation with
  | A.Uniform_f32 { dst; bits } ->
      if bits = Int32.zero then emit "movi %s, #0" (lanes_f32 dst)
      else
        let label = intern pool bits in
        emit "ldr %s, %s" (q dst) label
  | A.Mask_const { dst; value } ->
      emit "movi %s, #0x%02x" (lanes_bits dst) (if value then 0xff else 0)
  | A.Broadcast_f32 { dst; source } ->
      emit "dup %s, %s.s[0]" (lanes_f32 dst) (vector source)
  | A.Fadd { dst; left; right } ->
      emit "fadd %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Fsub { dst; left; right } ->
      emit "fsub %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Fmul { dst; left; right } ->
      emit "fmul %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Fdiv { dst; left; right } ->
      emit "fdiv %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Fsqrt { dst; source } ->
      emit "fsqrt %s, %s" (lanes_f32 dst) (lanes_f32 source)
  | A.Fmla { dst; multiplicand; multiplier } ->
      emit "fmla %s, %s, %s" (lanes_f32 dst) (lanes_f32 multiplicand)
        (lanes_f32 multiplier)
  | A.Compare { dst; predicate; left; right } ->
      let mnemonic = match predicate with M.Ceq -> "fcmeq" | M.Cgt -> "fcmgt" | M.Cge -> "fcmge" in
      emit "%s %s, %s, %s" mnemonic (lanes_f32 dst) (lanes_f32 left)
        (lanes_f32 right)
  | A.And { dst; left; right } ->
      emit "and %s, %s, %s" (lanes_bits dst) (lanes_bits left) (lanes_bits right)
  | A.Orr { dst; left; right } ->
      emit "orr %s, %s, %s" (lanes_bits dst) (lanes_bits left) (lanes_bits right)
  | A.Eor { dst; left; right } ->
      emit "eor %s, %s, %s" (lanes_bits dst) (lanes_bits left) (lanes_bits right)
  | A.Mvn { dst; source } ->
      emit "mvn %s, %s" (lanes_bits dst) (lanes_bits source)
  | A.Bsl { dst_mask; if_true; if_false } ->
      emit "bsl %s, %s, %s" (lanes_bits dst_mask) (lanes_bits if_true)
        (lanes_bits if_false)
  | A.Bit { dst_false; if_true; mask } ->
      emit "bit %s, %s, %s" (lanes_bits dst_false) (lanes_bits if_true)
        (lanes_bits mask)
  | A.Bif { dst_true; if_false; mask } ->
      emit "bif %s, %s, %s" (lanes_bits dst_true) (lanes_bits if_false)
        (lanes_bits mask)
  | A.Move { dst; source } ->
      emit "mov %s, %s" (lanes_bits dst) (lanes_bits source)

let emit_function pool buffer (func : A.func) =
  Printf.bprintf buffer
    ".p2align 4\n.globl %s\n.hidden %s\n.type %s, %%function\n%s:\n"
    func.name func.name func.name func.name;
  List.iter (emit_instruction pool buffer) func.instructions;
  Buffer.add_string buffer "    ret\n";
  Printf.bprintf buffer ".size %s, .-%s\n\n" func.name func.name

let emit_constant buffer (bits, label) =
  Buffer.add_string buffer
    ".section .rodata.cst16,\"aM\",%progbits,16\n.p2align 4\n";
  Printf.bprintf buffer "%s:\n" label;
  for _ = 0 to 3 do
    Printf.bprintf buffer "    .long 0x%08lx\n" bits
  done

let emit (module_ : A.func list) =
  let rec validate = function
    | [] -> Ok ()
    | func :: rest -> (
        match validate_function func with
        | Ok () -> validate rest
        | Error _ as error -> error)
  in
  match validate module_ with
  | Error _ as error -> error
  | Ok () ->
      let pool = create_pool () in
      let buffer = Buffer.create 4096 in
      Buffer.add_string buffer ".arch armv8-a+simd\n.text\n";
      List.iter (emit_function pool buffer) module_;
      List.iter (emit_constant buffer) pool.entries;
      Buffer.add_string buffer ".section .note.GNU-stack,\"\",%progbits\n";
      Ok (Buffer.contents buffer)
