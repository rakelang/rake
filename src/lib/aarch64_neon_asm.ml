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

type pool = { mutable entries : (int32 list * string) list; mutable next_label : int }
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
  | A.Integer_parameter { dst; _ } -> [ dst ]
  | A.Uniform_f32 { dst; _ } -> [ dst ]
  | A.Mask_const { dst; _ } -> [ dst ]
  | A.Broadcast_f32 { dst; source; _ } -> [ dst; source ]
  | A.Broadcast_bool { dst; source } -> [ dst; source ]
  | A.Insert_f32 { dst; inserted; _ } -> [ dst; inserted ]
  | A.Reduce_mask { dst; source; scratch; _ } -> [ dst; source; scratch ]
  | A.Fadd { dst; left; right }
  | A.Fsub { dst; left; right }
  | A.Add_i32 { dst; left; right }
  | A.Sub_i32 { dst; left; right }
  | A.Mul_i32 { dst; left; right }
  | A.Min_i32 { dst; left; right; _ }
  | A.Max_i32 { dst; left; right; _ }
  | A.Compare_i32 { dst; left; right; _ }
  | A.Fmul { dst; left; right }
  | A.Fdiv { dst; left; right }
  | A.Fmin { dst; left; right }
  | A.Fmax { dst; left; right }
  | A.Compare { dst; left; right; _ }
  | A.And { dst; left; right }
  | A.Bic { dst; left; right }
  | A.Orr { dst; left; right }
  | A.Eor { dst; left; right } -> [ dst; left; right ]
  | A.Neg_i32 { dst; source } | A.Abs_i32 { dst; source } | A.Shift_i32 { dst; source; _ } | A.Fsqrt { dst; source } | A.Round_f32 { dst; source; _ } | A.Mvn { dst; source } | A.Move { dst; source } ->
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
              if (match operation with A.Integer_parameter { argument; _ } -> argument < 0 || argument >= 8 | _ -> false) then
                Error { function_name = func.name; loc; message = "integer argument is outside the AAPCS64 register boundary" }
              else
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
  | A.Integer_parameter { dst; argument } -> emit "fmov s%d, w%d" dst argument
  | A.Uniform_f32 { dst; bits } ->
      if bits = Int32.zero then emit "movi %s, #0" (lanes_f32 dst)
      else
        let label = intern pool (List.init 4 (fun _ -> bits)) in
        emit "ldr %s, %s" (q dst) label
  | A.Mask_const { dst; value } ->
      emit "movi %s, #0x%02x" (lanes_bits dst) (if value then 0xff else 0)
  | A.Broadcast_f32 { dst; source; lane } ->
      emit "dup %s, %s.s[%d]" (lanes_f32 dst) (vector source) (M.f32_lane_index lane)
  | A.Broadcast_bool { dst; source } ->
      emit "dup %s, %s.s[0]" (lanes_f32 dst) (vector source);
      emit "shl %s, %s, #31" (lanes_f32 dst) (lanes_f32 dst);
      emit "sshr %s, %s, #31" (lanes_f32 dst) (lanes_f32 dst)
  | A.Insert_f32 { dst; inserted; lane } ->
      emit "ins %s.s[%d], %s.s[0]" (vector dst) (M.f32_lane_index lane) (vector inserted)
  | A.Reduce_mask { dst; source; operation; scratch } ->
      if dst <> source then emit "mov %s, %s" (lanes_bits dst) (lanes_bits source);
      if operation = Native_ir.Mask_bits then (
        let weights = intern pool [ 1l; 2l; 4l; 8l ] in
        emit "ldr %s, %s" (q scratch) weights;
        emit "and %s, %s, %s" (lanes_bits dst) (lanes_bits dst) (lanes_bits scratch));
      List.iter (fun bytes ->
        emit "ext %s, %s, %s, #%d" (lanes_bits scratch) (lanes_bits dst) (lanes_bits dst) bytes;
        emit "%s %s, %s, %s" (if operation = Native_ir.Mask_all then "and" else "orr")
          (lanes_bits dst) (lanes_bits dst) (lanes_bits scratch)) [ 8; 4 ];
      if operation <> Native_ir.Mask_bits then (
        emit "movi %s, #1" (lanes_f32 scratch);
        emit "and %s, %s, %s" (lanes_bits dst) (lanes_bits dst) (lanes_bits scratch))
  | A.Fadd { dst; left; right } ->
      emit "fadd %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Fsub { dst; left; right } ->
      emit "fsub %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Add_i32 { dst; left; right } ->
      emit "add %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Sub_i32 { dst; left; right } ->
      emit "sub %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Mul_i32 { dst; left; right } ->
      emit "mul %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Min_i32 { dst; left; right; unsigned } ->
      emit "%s %s, %s, %s" (if unsigned then "umin" else "smin") (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Max_i32 { dst; left; right; unsigned } ->
      emit "%s %s, %s, %s" (if unsigned then "umax" else "smax") (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Neg_i32 { dst; source } ->
      emit "neg %s, %s" (lanes_f32 dst) (lanes_f32 source)
  | A.Abs_i32 { dst; source } ->
      emit "abs %s, %s" (lanes_f32 dst) (lanes_f32 source)
  | A.Shift_i32 { dst; source; count; shift } ->
      let count = Native_ir.I32_shift_count.to_int count in
      if count = 0 then (
        if dst <> source then emit "mov %s, %s" (lanes_bits dst) (lanes_bits source))
      else
        let mnemonic = match shift with
          | Native_ir.Shift_left -> "shl"
          | Native_ir.Shift_right -> "ushr"
          | Native_ir.Shift_right_signed -> "sshr" in
        emit "%s %s, %s, #%d" mnemonic (lanes_f32 dst) (lanes_f32 source) count
  | A.Compare_i32 { dst; predicate; unsigned; left; right } ->
      let greater = if unsigned then "cmhi" else "cmgt" in
      let greater_equal = if unsigned then "cmhs" else "cmge" in
      let mnemonic, left, right = match predicate with
        | Native_ir.Eq | Native_ir.Ne -> "cmeq", left, right
        | Native_ir.Lt -> greater, right, left
        | Native_ir.Le -> greater_equal, right, left
        | Native_ir.Gt -> greater, left, right
        | Native_ir.Ge -> greater_equal, left, right in
      emit "%s %s, %s, %s" mnemonic (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right);
      if predicate = Native_ir.Ne then emit "mvn %s, %s" (lanes_bits dst) (lanes_bits dst)
  | A.Fmul { dst; left; right } ->
      emit "fmul %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Fdiv { dst; left; right } ->
      emit "fdiv %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Fmin { dst; left; right } ->
      emit "fmin %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Fmax { dst; left; right } ->
      emit "fmax %s, %s, %s" (lanes_f32 dst) (lanes_f32 left) (lanes_f32 right)
  | A.Fsqrt { dst; source } ->
      emit "fsqrt %s, %s" (lanes_f32 dst) (lanes_f32 source)
  | A.Round_f32 { dst; source; mode } ->
      let mnemonic = match mode with
        | Native_ir.Toward_negative -> "frintm" | Native_ir.Toward_positive -> "frintp"
        | Native_ir.Toward_zero -> "frintz" | Native_ir.Nearest_even -> "frintn" in
      emit "%s %s, %s" mnemonic (lanes_f32 dst) (lanes_f32 source)
  | A.Fmla { dst; multiplicand; multiplier } ->
      emit "fmla %s, %s, %s" (lanes_f32 dst) (lanes_f32 multiplicand)
        (lanes_f32 multiplier)
  | A.Compare { dst; predicate; left; right } ->
      let mnemonic = match predicate with M.Ceq -> "fcmeq" | M.Cgt -> "fcmgt" | M.Cge -> "fcmge" in
      emit "%s %s, %s, %s" mnemonic (lanes_f32 dst) (lanes_f32 left)
        (lanes_f32 right)
  | A.And { dst; left; right } ->
      emit "and %s, %s, %s" (lanes_bits dst) (lanes_bits left) (lanes_bits right)
  | A.Bic { dst; left; right } ->
      emit "bic %s, %s, %s" (lanes_bits dst) (lanes_bits left) (lanes_bits right)
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
  (match func.result_type with
  | Some (Native_ir.Scalar (Native_ir.I1 | Native_ir.I32 | Native_ir.U32)) -> Buffer.add_string buffer "    umov w0, v0.s[0]\n"
  | _ -> ());
  Buffer.add_string buffer "    ret\n";
  Printf.bprintf buffer ".size %s, .-%s\n\n" func.name func.name

let emit_constant buffer (bits, label) =
  Buffer.add_string buffer
    ".section .rodata.cst16,\"aM\",%progbits,16\n.p2align 4\n";
  Printf.bprintf buffer "%s:\n" label;
  List.iter (fun bits -> Printf.bprintf buffer "    .long 0x%08lx\n" bits) bits

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
