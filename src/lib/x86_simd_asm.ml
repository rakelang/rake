(** Intel-syntax assembly emission for allocated x86-64 SIMD machine IR. *)

module A = X86_simd_regalloc
module M = X86_simd_mir

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

let vector_register profile register =
  Printf.sprintf "%s%d" (Option.get (Target.info profile).mir_register_class) register

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

let validate_function profile (func : A.func) =
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
                "allocated SSE-class result must use register 0, not %s"
                (vector_register profile register);
          }
    | _ ->
        let rec check = function
          | [] -> Ok ()
          | ({ A.operation; loc; _ } : A.instruction) :: rest -> (
              match List.find_opt (fun register -> register < 0 || register >= Target.x86_register_count profile) (registers operation) with
              | None -> check rest
              | Some register ->
                  Error
                    {
                      function_name = func.name;
                      loc;
                      message =
                        Printf.sprintf
                          "invalid physical %s register %d; %s provides %d vector registers"
                          (String.uppercase_ascii (Option.get (Target.info profile).mir_register_class))
                          register (Target.profile_name profile) (Target.x86_register_count profile);
                    })
        in
        check func.instructions

let emit_instruction profile pool buffer ({ A.operation; _ } : A.instruction) =
  let emit format = Printf.bprintf buffer ("    " ^^ format ^^ "\n") in
  let ymm = vector_register profile in
  let lanes = (Target.info profile).f32_lanes in
  let sse = profile = Target.X86_sse2 in
  let avx512 = profile = Target.X86_avx512 in
  let memory = if sse then "XMMWORD" else if avx512 then "ZMMWORD" else "YMMWORD" in
  let move dst source =
    if dst <> source then emit "%smovaps %s, %s" (if sse then "" else "v") (ymm dst) (ymm source)
  in
  let binary mnemonic dst left right =
    if sse then (
      (* A two-address operation may reuse its dying right operand. Save it
         before copying the left operand into the destination. *)
      let right =
        if dst = right && dst <> left then (move 15 right; 15) else right
      in
      move dst left;
      emit "%s %s, %s" mnemonic (ymm dst) (ymm right))
    else emit "v%s %s, %s, %s" mnemonic (ymm dst) (ymm left) (ymm right)
  in
  let logical mnemonic dst left right =
    let mnemonic = if avx512 then (match mnemonic with "andps" -> "pandd" | "orps" -> "pord" | "xorps" -> "pxord" | _ -> assert false) else mnemonic in
    binary mnemonic dst left right
  in
  let load_splat dst bits =
    if bits = Int32.zero then logical "xorps" dst dst dst
    else if sse then (
      let label = intern pool (Vector_f32 (List.init lanes (fun _ -> bits))) in
      emit "movaps %s, %s PTR [rip + %s]" (ymm dst) memory label)
    else (
      let label = intern pool (Splat_f32 bits) in
      emit "vbroadcastss %s, DWORD PTR [rip + %s]" (ymm dst) label)
  in
  let compare predicate dst left right =
    if sse then (
      if predicate = M.One then (
        move 15 left;
        emit "cmpps xmm15, %s, 0x07" (ymm right);
        move dst left;
        emit "cmpps %s, %s, 0x04" (ymm dst) (ymm right);
        emit "andps %s, xmm15" (ymm dst))
      else (
        move dst left;
        let immediate = match predicate with M.Oeq -> 0 | M.Olt -> 1 | M.Ole -> 2 | M.Ounord -> 3 | M.One -> assert false in
        emit "cmpps %s, %s, 0x%02x" (ymm dst) (ymm right) immediate))
    else if avx512 then (
      emit "vcmpps k1, %s, %s, 0x%02x" (ymm left) (ymm right) (M.comparison_immediate predicate);
      logical "xorps" dst dst dst;
      (* Expanding an opmask with vpternlogd needs AVX-512F, unlike vpmovm2d
         which would accidentally require the optional DQ extension. *)
      emit "vpternlogd %s{k1}, %s, %s, 0xff" (ymm dst) (ymm dst) (ymm dst))
    else emit "vcmpps %s, %s, %s, 0x%02x" (ymm dst) (ymm left) (ymm right) (M.comparison_immediate predicate)
  in
  let blend dst mask if_true if_false =
    if sse then (
      move 15 if_true;
      emit "xorps xmm15, %s" (ymm if_false);
      emit "andps xmm15, %s" (ymm mask);
      move dst if_false;
      emit "xorps %s, xmm15" (ymm dst))
    else if avx512 then (
      emit "vptestmd k1, %s, %s" (ymm mask) (ymm mask);
      emit "vblendmps %s{k1}, %s, %s" (ymm dst) (ymm if_false) (ymm if_true))
    else emit "vblendvps %s, %s, %s, %s" (ymm dst) (ymm if_false) (ymm if_true) (ymm mask)
  in
  let splat_lane dst source lane =
    let within = [| 0x00; 0x55; 0xaa; 0xff |].(lane land 3) in
    if sse then (
      move dst source;
      emit "shufps %s, %s, 0x%02x" (ymm dst) (ymm dst) within)
    else (
      if avx512 then
        emit "vshuff32x4 %s, %s, %s, 0x%02x" (ymm dst) (ymm source) (ymm source) ((lane / 4) * 0x55)
      else emit "vperm2f128 %s, %s, %s, 0x%02x" (ymm dst) (ymm source) (ymm source) (if lane < 4 then 0x00 else 0x11);
      emit "vpermilps %s, %s, 0x%02x" (ymm dst) (ymm dst) within)
  in
  let simple_combine operation dst right =
    match operation with
    | `Add -> binary "addps" dst dst right
    | `Mul -> binary "mulps" dst dst right
  in
  let strict_combine operation prefix lane temporaries =
    match temporaries with
    | [ comparison; candidate; zero; left_zero; right_zero ] ->
        load_splat zero 0l;
        compare M.Oeq left_zero prefix zero;
        compare M.Oeq right_zero lane zero;
        logical "andps" left_zero left_zero right_zero;
        (match operation with
        | `Min ->
            logical "orps" right_zero prefix lane;
            compare M.Olt comparison prefix lane
        | `Max ->
            logical "andps" right_zero prefix lane;
            compare M.Olt comparison lane prefix);
        blend candidate comparison prefix lane;
        blend candidate left_zero right_zero candidate;
        compare M.Ounord comparison prefix lane;
        load_splat right_zero 0x7fc00000l;
        blend prefix comparison right_zero candidate
    | _ -> invalid_arg "strict x86 SIMD combine requires five temporary registers"
  in
  match operation with
  | A.Uniform_f32 { dst; bits } ->
      load_splat dst bits
  | A.Uniform_mask { dst; value = false } ->
      if avx512 then logical "xorps" dst dst dst
      else if sse then emit "pxor %s, %s" (ymm dst) (ymm dst)
      else emit "vpxor %s, %s, %s" (ymm dst) (ymm dst) (ymm dst)
  | A.Uniform_mask { dst; value = true } ->
      if avx512 then emit "vpternlogd %s, %s, %s, 0xff" (ymm dst) (ymm dst) (ymm dst)
      else if sse then emit "pcmpeqd %s, %s" (ymm dst) (ymm dst)
      else emit "vpcmpeqd %s, %s, %s" (ymm dst) (ymm dst) (ymm dst)
  | A.Broadcastss { dst; source } ->
      if sse then (move dst source; emit "shufps %s, %s, 0x00" (ymm dst) (ymm dst))
      else emit "vbroadcastss %s, xmm%d" (ymm dst) source
  | A.Reduce_f32 { dst; source; operation; scratch } ->
      splat_lane dst source 0;
      let lane_register, strict_temporaries =
        match scratch with
        | lane :: rest -> (lane, rest)
        | [] -> invalid_arg "strict x86 SIMD reduction requires a temporary register"
      in
      for lane = 1 to lanes - 1 do
        splat_lane lane_register source lane;
        match operation with
        | Native_ir.Reduce_add -> simple_combine `Add dst lane_register
        | Native_ir.Reduce_mul -> simple_combine `Mul dst lane_register
        | Native_ir.Reduce_min -> strict_combine `Min dst lane_register strict_temporaries
        | Native_ir.Reduce_max -> strict_combine `Max dst lane_register strict_temporaries
        | Native_ir.Reduce_and | Native_ir.Reduce_or | Native_ir.Reduce_bitmask ->
            invalid_arg "mask reduction reached f32 x86 SIMD emission"
      done
  | A.Scan_f32 { dst; source; operation; scratch } ->
      let prefix, lane_register, strict_temporaries =
        match scratch with
        | prefix :: lane :: rest -> (prefix, lane, rest)
        | _ -> invalid_arg "strict x86 SIMD scan requires two temporary registers"
      in
      move dst source;
      splat_lane prefix source 0;
      for lane = 1 to lanes - 1 do
        splat_lane lane_register source lane;
        (match operation with
        | Native_ir.Scan_add -> simple_combine `Add prefix lane_register
        | Native_ir.Scan_mul -> simple_combine `Mul prefix lane_register
        | Native_ir.Scan_min -> strict_combine `Min prefix lane_register strict_temporaries
        | Native_ir.Scan_max -> strict_combine `Max prefix lane_register strict_temporaries);
        if sse then (
          let mask = intern pool (Vector_f32 (List.init lanes (fun index -> if index = lane then -1l else 0l))) in
          move 15 prefix;
          emit "xorps xmm15, %s" (ymm dst);
          emit "andps xmm15, XMMWORD PTR [rip + %s]" mask;
          emit "xorps %s, xmm15" (ymm dst))
        else if avx512 then (
          emit "kxnorw k1, k1, k1";
          emit "kshiftlw k1, k1, 15";
          emit "kshiftrw k1, k1, %d" (15 - lane);
          emit "vmovaps %s{k1}, %s" (ymm dst) (ymm prefix))
        else emit "vblendps %s, %s, %s, 0x%02x" (ymm dst) (ymm dst) (ymm prefix) (1 lsl lane)
      done
  | A.Addps { dst; left; right } ->
      binary "addps" dst left right
  | A.Subps { dst; left; right } ->
      binary "subps" dst left right
  | A.Mulps { dst; left; right } ->
      binary "mulps" dst left right
  | A.Divps { dst; left; right } ->
      binary "divps" dst left right
  | A.Sqrtps { dst; source } -> emit "%ssqrtps %s, %s" (if sse then "" else "v") (ymm dst) (ymm source)
  | A.Negps { dst; source } ->
      let sign = intern pool (Vector_f32 (List.init lanes (fun _ -> Int32.min_int))) in
      if sse then (move dst source; emit "xorps %s, XMMWORD PTR [rip + %s]" (ymm dst) sign)
      else emit "%s %s, %s, %s PTR [rip + %s]" (if avx512 then "vpxord" else "vxorps") (ymm dst) (ymm source) memory sign
  | A.Fma213ps { dst; multiplier; addend } ->
      emit "vfmadd213ps %s, %s, %s" (ymm dst) (ymm multiplier) (ymm addend)
  | A.Fma231ps { dst; multiplicand; multiplier } ->
      emit "vfmadd231ps %s, %s, %s" (ymm dst) (ymm multiplicand) (ymm multiplier)
  | A.Cmpps { dst; predicate; left; right } ->
      compare predicate dst left right
  | A.Blendvps { dst; mask; if_true; if_false } ->
      blend dst mask if_true if_false
  | A.Mask_andps { dst; left; right } ->
      logical "andps" dst left right
  | A.Mask_orps { dst; left; right } ->
      logical "orps" dst left right
  | A.Mask_xorps { dst; left; right } ->
      logical "xorps" dst left right
  | A.Mask_notps { dst; source } ->
      let ones = intern pool (Vector_f32 (List.init lanes (fun _ -> Int32.minus_one))) in
      if sse then (move dst source; emit "xorps %s, XMMWORD PTR [rip + %s]" (ymm dst) ones)
      else emit "%s %s, %s, %s PTR [rip + %s]" (if avx512 then "vpxord" else "vxorps") (ymm dst) (ymm source) memory ones
  | A.Moveaps { dst; source } -> move dst source

let emit_function profile pool buffer (func : A.func) =
  Printf.bprintf buffer ".p2align 4\n.globl %s\n.hidden %s\n.type %s, @function\n%s:\n"
    func.name func.name func.name func.name;
  List.iter (emit_instruction profile pool buffer) func.instructions;
  Buffer.add_string buffer "    ret\n";
  Printf.bprintf buffer ".size %s, .-%s\n\n" func.name func.name

let emit_constant buffer (constant, label) =
  match constant with
  | Splat_f32 bits ->
      Buffer.add_string buffer ".section .rodata.cst4,\"aM\",@progbits,4\n.p2align 2\n";
      Printf.bprintf buffer "%s:\n    .long 0x%08lx\n" label bits
  | Vector_f32 bits ->
      let bytes = List.length bits * 4 in
      Printf.bprintf buffer ".section .rodata.cst%d,\"aM\",@progbits,%d\n.p2align %d\n"
        bytes bytes (if bytes = 16 then 4 else if bytes = 32 then 5 else 6);
      Printf.bprintf buffer "%s:\n" label;
      List.iter (fun bits -> Printf.bprintf buffer "    .long 0x%08lx\n" bits) bits

let emit ?(profile = Target.X86_avx2) (module_ : A.func list) =
  let rec validate = function
    | [] -> Ok ()
    | func :: rest -> (
        match validate_function profile func with
        | Ok () -> validate rest
        | Error _ as error -> error)
  in
  match validate module_ with
  | Error _ as error -> error
  | Ok () ->
      let pool = create_pool () in
      let buffer = Buffer.create 4096 in
      Buffer.add_string buffer ".intel_syntax noprefix\n.text\n";
      List.iter (emit_function profile pool buffer) module_;
      List.iter (emit_constant buffer) pool.entries;
      Buffer.add_string buffer ".section .note.GNU-stack,\"\",@progbits\n";
      Ok (Buffer.contents buffer)
