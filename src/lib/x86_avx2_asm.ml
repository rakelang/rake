(** Intel-syntax assembly emission for allocated AVX2+FMA machine IR. *)

module A = X86_avx2_regalloc
module M = X86_avx2_mir

type error = {
  function_name : string;
  loc : Native_ir.source_location;
  message : string;
}

let format_error error =
  Printf.sprintf "%s: %s: %s" (Native_ir.format_source_location error.loc)
    error.function_name error.message

type constant = Splat_f32 of int32 | Vector_f32 of int32 list

type pool = {
  mutable entries : (constant * string) list;
  mutable next_label : int;
}

let create_pool () = { entries = []; next_label = 0 }

let intern pool constant =
  match List.assoc_opt constant pool.entries with
  | Some label -> label
  | None ->
      let label = Printf.sprintf ".Lrake_const_%d" pool.next_label in
      pool.next_label <- pool.next_label + 1;
      pool.entries <- pool.entries @ [ (constant, label) ];
      label

let ymm register = Printf.sprintf "ymm%d" register

let registers = function
  | A.Uniform_f32 { dst; _ } -> [ dst ]
  | A.Uniform_mask { dst; _ } -> [ dst ]
  | A.Broadcastss { dst; source } -> [ dst; source ]
  | A.Reduce_f32 { dst; source; scratch; _ }
  | A.Scan_f32 { dst; source; scratch; _ } -> dst :: source :: scratch
  | A.Addps { dst; left; right }
  | A.Subps { dst; left; right }
  | A.Mulps { dst; left; right }
  | A.Divps { dst; left; right }
  | A.Cmpps { dst; left; right; _ }
  | A.Mask_andps { dst; left; right }
  | A.Mask_orps { dst; left; right }
  | A.Mask_xorps { dst; left; right } -> [ dst; left; right ]
  | A.Sqrtps { dst; source }
  | A.Negps { dst; source }
  | A.Mask_notps { dst; source }
  | A.Moveaps { dst; source } -> [ dst; source ]
  | A.Fma213ps { dst; multiplier; addend } -> [ dst; multiplier; addend ]
  | A.Fma231ps { dst; multiplicand; multiplier } ->
      [ dst; multiplicand; multiplier ]
  | A.Blendvps { dst; mask; if_true; if_false } ->
      [ dst; mask; if_true; if_false ]

let valid_symbol name =
  let initial = function
    | 'a' .. 'z' | 'A' .. 'Z' | '_' | '.' | '$' -> true
    | _ -> false
  in
  let subsequent character = initial character || Char.code character >= Char.code '0' && Char.code character <= Char.code '9' in
  String.length name > 0 && initial name.[0]
  && String.for_all subsequent name

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
                "allocated SSE-class result must use register 0, not ymm%d"
                register;
          }
    | _ ->
        let rec check = function
          | [] -> Ok ()
          | ({ A.operation; loc; _ } : A.instruction) :: rest -> (
              match List.find_opt (fun register -> register < 0 || register >= 16) (registers operation) with
              | None -> check rest
              | Some register ->
                  Error
                    {
                      function_name = func.name;
                      loc;
                      message =
                        Printf.sprintf
                          "invalid physical YMM register %d; AVX2 profile provides ymm0..ymm15"
                          register;
                    })
        in
        check func.instructions

let emit_instruction pool buffer ({ A.operation; _ } : A.instruction) =
  let emit format = Printf.bprintf buffer ("    " ^^ format ^^ "\n") in
  let splat_lane dst source lane =
    let half = if lane < 4 then 0x00 else 0x11 in
    let within = [| 0x00; 0x55; 0xaa; 0xff |].(lane land 3) in
    emit "vperm2f128 %s, %s, %s, 0x%02x" (ymm dst) (ymm source) (ymm source) half;
    emit "vpermilps %s, %s, 0x%02x" (ymm dst) (ymm dst) within
  in
  let simple_combine operation dst right =
    match operation with
    | `Add -> emit "vaddps %s, %s, %s" (ymm dst) (ymm dst) (ymm right)
    | `Mul -> emit "vmulps %s, %s, %s" (ymm dst) (ymm dst) (ymm right)
  in
  let strict_combine operation prefix lane temporaries =
    match temporaries with
    | [ comparison; candidate; zero; left_zero; right_zero ] ->
        emit "vxorps %s, %s, %s" (ymm zero) (ymm zero) (ymm zero);
        emit "vcmpps %s, %s, %s, 0x00" (ymm left_zero) (ymm prefix) (ymm zero);
        emit "vcmpps %s, %s, %s, 0x00" (ymm right_zero) (ymm lane) (ymm zero);
        emit "vandps %s, %s, %s" (ymm left_zero) (ymm left_zero) (ymm right_zero);
        (match operation with
        | `Min ->
            emit "vorps %s, %s, %s" (ymm right_zero) (ymm prefix) (ymm lane);
            emit "vcmpps %s, %s, %s, 0x11" (ymm comparison) (ymm prefix) (ymm lane)
        | `Max ->
            emit "vandps %s, %s, %s" (ymm right_zero) (ymm prefix) (ymm lane);
            emit "vcmpps %s, %s, %s, 0x11" (ymm comparison) (ymm lane) (ymm prefix));
        emit "vblendvps %s, %s, %s, %s" (ymm candidate) (ymm lane) (ymm prefix)
          (ymm comparison);
        emit "vblendvps %s, %s, %s, %s" (ymm candidate) (ymm candidate)
          (ymm right_zero) (ymm left_zero);
        emit "vcmpps %s, %s, %s, 0x03" (ymm comparison) (ymm prefix) (ymm lane);
        let canonical_nan = intern pool (Splat_f32 0x7fc00000l) in
        emit "vbroadcastss %s, DWORD PTR [rip + %s]" (ymm right_zero) canonical_nan;
        emit "vblendvps %s, %s, %s, %s" (ymm prefix) (ymm candidate)
          (ymm right_zero) (ymm comparison)
    | _ -> invalid_arg "strict AVX2 combine requires five temporary registers"
  in
  match operation with
  | A.Uniform_f32 { dst; bits } ->
      if bits = Int32.zero then emit "vxorps %s, %s, %s" (ymm dst) (ymm dst) (ymm dst)
      else
        let label = intern pool (Splat_f32 bits) in
        emit "vbroadcastss %s, DWORD PTR [rip + %s]" (ymm dst) label
  | A.Uniform_mask { dst; value = false } ->
      emit "vpxor %s, %s, %s" (ymm dst) (ymm dst) (ymm dst)
  | A.Uniform_mask { dst; value = true } ->
      emit "vpcmpeqd %s, %s, %s" (ymm dst) (ymm dst) (ymm dst)
  | A.Broadcastss { dst; source } ->
      emit "vbroadcastss %s, xmm%d" (ymm dst) source
  | A.Reduce_f32 { dst; source; operation; scratch } ->
      splat_lane dst source 0;
      let lane_register, strict_temporaries =
        match scratch with
        | lane :: rest -> (lane, rest)
        | [] -> invalid_arg "strict AVX2 reduction requires a temporary register"
      in
      for lane = 1 to 7 do
        splat_lane lane_register source lane;
        match operation with
        | Native_ir.Reduce_add -> simple_combine `Add dst lane_register
        | Native_ir.Reduce_mul -> simple_combine `Mul dst lane_register
        | Native_ir.Reduce_min -> strict_combine `Min dst lane_register strict_temporaries
        | Native_ir.Reduce_max -> strict_combine `Max dst lane_register strict_temporaries
        | Native_ir.Reduce_and | Native_ir.Reduce_or ->
            invalid_arg "logical reduction reached f32 AVX2 emission"
      done
  | A.Scan_f32 { dst; source; operation; scratch } ->
      let prefix, lane_register, strict_temporaries =
        match scratch with
        | prefix :: lane :: rest -> (prefix, lane, rest)
        | _ -> invalid_arg "strict AVX2 scan requires two temporary registers"
      in
      emit "vmovaps %s, %s" (ymm dst) (ymm source);
      splat_lane prefix source 0;
      for lane = 1 to 7 do
        splat_lane lane_register source lane;
        (match operation with
        | Native_ir.Scan_add -> simple_combine `Add prefix lane_register
        | Native_ir.Scan_mul -> simple_combine `Mul prefix lane_register
        | Native_ir.Scan_min -> strict_combine `Min prefix lane_register strict_temporaries
        | Native_ir.Scan_max -> strict_combine `Max prefix lane_register strict_temporaries);
        emit "vblendps %s, %s, %s, 0x%02x" (ymm dst) (ymm dst) (ymm prefix)
          (1 lsl lane)
      done
  | A.Addps { dst; left; right } ->
      emit "vaddps %s, %s, %s" (ymm dst) (ymm left) (ymm right)
  | A.Subps { dst; left; right } ->
      emit "vsubps %s, %s, %s" (ymm dst) (ymm left) (ymm right)
  | A.Mulps { dst; left; right } ->
      emit "vmulps %s, %s, %s" (ymm dst) (ymm left) (ymm right)
  | A.Divps { dst; left; right } ->
      emit "vdivps %s, %s, %s" (ymm dst) (ymm left) (ymm right)
  | A.Sqrtps { dst; source } -> emit "vsqrtps %s, %s" (ymm dst) (ymm source)
  | A.Negps { dst; source } ->
      let sign = intern pool (Vector_f32 (List.init 8 (fun _ -> Int32.min_int))) in
      emit "vxorps %s, %s, YMMWORD PTR [rip + %s]" (ymm dst) (ymm source) sign
  | A.Fma213ps { dst; multiplier; addend } ->
      emit "vfmadd213ps %s, %s, %s" (ymm dst) (ymm multiplier) (ymm addend)
  | A.Fma231ps { dst; multiplicand; multiplier } ->
      emit "vfmadd231ps %s, %s, %s" (ymm dst) (ymm multiplicand) (ymm multiplier)
  | A.Cmpps { dst; predicate; left; right } ->
      emit "vcmpps %s, %s, %s, 0x%02x" (ymm dst) (ymm left) (ymm right)
        (M.comparison_immediate predicate)
  | A.Blendvps { dst; mask; if_true; if_false } ->
      emit "vblendvps %s, %s, %s, %s" (ymm dst) (ymm if_false) (ymm if_true)
        (ymm mask)
  | A.Mask_andps { dst; left; right } ->
      emit "vandps %s, %s, %s" (ymm dst) (ymm left) (ymm right)
  | A.Mask_orps { dst; left; right } ->
      emit "vorps %s, %s, %s" (ymm dst) (ymm left) (ymm right)
  | A.Mask_xorps { dst; left; right } ->
      emit "vxorps %s, %s, %s" (ymm dst) (ymm left) (ymm right)
  | A.Mask_notps { dst; source } ->
      let ones = intern pool (Vector_f32 (List.init 8 (fun _ -> Int32.minus_one))) in
      emit "vxorps %s, %s, YMMWORD PTR [rip + %s]" (ymm dst) (ymm source) ones
  | A.Moveaps { dst; source } -> emit "vmovaps %s, %s" (ymm dst) (ymm source)

let emit_function pool buffer (func : A.func) =
  Printf.bprintf buffer ".p2align 4\n.globl %s\n.hidden %s\n.type %s, @function\n%s:\n"
    func.name func.name func.name func.name;
  List.iter (emit_instruction pool buffer) func.instructions;
  Buffer.add_string buffer "    ret\n";
  Printf.bprintf buffer ".size %s, .-%s\n\n" func.name func.name

let emit_constant buffer (constant, label) =
  match constant with
  | Splat_f32 bits ->
      Buffer.add_string buffer ".section .rodata.cst4,\"aM\",@progbits,4\n.p2align 2\n";
      Printf.bprintf buffer "%s:\n    .long 0x%08lx\n" label bits
  | Vector_f32 bits ->
      Buffer.add_string buffer
        ".section .rodata.cst32,\"aM\",@progbits,32\n.p2align 5\n";
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
      Buffer.add_string buffer ".intel_syntax noprefix\n.text\n";
      List.iter (emit_function pool buffer) module_;
      List.iter (emit_constant buffer) pool.entries;
      Buffer.add_string buffer ".section .note.GNU-stack,\"\",@progbits\n";
      Ok (Buffer.contents buffer)
