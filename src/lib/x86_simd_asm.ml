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

type constant = Splat_f32 of int32 | Vector_bits of int32 list

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
  | A.Convert_i32_f32 { dst; source; scratch; _ } -> dst :: source :: scratch
  | A.Integer_parameter { dst; _ } -> [ dst ]
  | A.Uniform_f32 { dst; _ } -> [ dst ]
  | A.Uniform_mask { dst; _ } -> [ dst ]
  | A.Broadcastss { dst; source } -> [ dst; source ]
  | A.Broadcast_bool { dst; source } -> [ dst; source ]
  | A.Extract_f32 { dst; source; _ } -> [ dst; source ]
  | A.Insert_f32 { dst; previous; inserted; broadcast; _ } -> [ dst; previous; inserted; broadcast ]
  | A.Shuffle_word { dst; racks; scratch; _ } -> dst :: racks @ scratch
  | A.Reduce_mask { dst; source; scratch; _ } -> [ dst; source; scratch ]
  | A.Reduce_f32 { dst; source; scratch; _ }
  | A.Scan_f32 { dst; source; scratch; _ } -> dst :: source :: scratch
  | A.Round_f32 { dst; source; scratch; _ } -> dst :: source :: scratch
  | A.Extreme_f32 { dst; left; right; scratch; _ } -> dst :: left :: right :: scratch
  | A.Extreme_i32 { dst; left; right; scratch; _ } -> dst :: left :: right :: scratch
  | A.Mul_i32 { dst; left; right; scratch } -> dst :: left :: right :: scratch
  | A.Abs_i32 { dst; source; sign } -> dst :: source :: Option.to_list sign
  | A.Addps { dst; left; right }
  | A.Subps { dst; left; right }
  | A.Add_i32 { dst; left; right }
  | A.Sub_i32 { dst; left; right }
  | A.Compare_i32 { dst; left; right; _ }
  | A.Mulps { dst; left; right }
  | A.Divps { dst; left; right }
  | A.Mask_andps { dst; left; right }
  | A.Mask_andnotps { dst; left; right }
  | A.Mask_orps { dst; left; right }
  | A.Mask_xorps { dst; left; right } -> [ dst; left; right ]
  | A.Sqrtps { dst; source }
  | A.Negps { dst; source }
  | A.Neg_i32 { dst; source }
  | A.Shift_i32 { dst; source; _ }
  | A.Absps { dst; source }
  | A.Mask_notps { dst; source }
  | A.Moveaps { dst; source } -> [ dst; source ]
  | A.Cmpps { dst; left; right; ordered_mask; _ } ->
      [ dst; left; right ] @ Option.to_list ordered_mask
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
              match operation with
              | A.Integer_parameter { argument; _ } when argument < 0 || argument >= 6 ->
                  Error { function_name = func.name; loc; message = "integer argument is outside the System V register boundary" }
              | A.Extract_f32 { lane; _ } | A.Insert_f32 { lane; _ }
                  when M.f32_lane_index lane >= (Target.info profile).f32_lanes ->
                  Error { function_name = func.name; loc; message = "lane transfer is outside the selected profile's rack" }
              | A.Shuffle_word { racks; indices; _ }
                  when let lanes = (Target.info profile).f32_lanes in
                    List.length indices <> lanes || List.length racks < 1 || List.length racks > 2
                    || List.exists (fun lane -> lane < 0 || lane >= lanes * List.length racks) indices ->
                  Error { function_name = func.name; loc; message = "shuffle is outside the selected profile's rack" }
              | _ -> match List.find_opt (fun register -> register < 0 || register >= Target.x86_register_count profile) (registers operation) with
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
      let label = intern pool (Vector_bits (List.init lanes (fun _ -> bits))) in
      emit "movaps %s, %s PTR [rip + %s]" (ymm dst) memory label)
    else (
      let label = intern pool (Splat_f32 bits) in
      emit "vbroadcastss %s, DWORD PTR [rip + %s]" (ymm dst) label)
  in
  let unsigned_order_operands left right = function
    | [ biased_left; biased_right ] ->
        let sign = intern pool (Vector_bits (List.init lanes (fun _ -> Int32.min_int))) in
        let bias dst source =
          if sse then (move dst source; emit "xorps %s, XMMWORD PTR [rip + %s]" (ymm dst) sign)
          else emit "vxorps %s, %s, YMMWORD PTR [rip + %s]" (ymm dst) (ymm source) sign in
        bias biased_left left;
        bias biased_right right;
        biased_left, biased_right
    | [] -> left, right
    | _ -> invalid_arg "unsigned ordering requires two temporary racks"
  in
  let compare ?ordered_mask predicate dst left right =
    if sse then (
      if predicate = M.Olt || predicate = M.Ole then (
        (* Legacy LT/LE signal on quiet NaNs. First identify ordered lanes
           with quiet ORD, then compare benign operands in every gap.
           LT's zero/zero gap is false; LE must retain and reapply ORD. *)
        move 15 left;
        emit "cmpps xmm15, %s, 0x07" (ymm right);
        if predicate = M.Olt then (
          move dst left;
          emit "andps %s, xmm15" (ymm dst);
          emit "andps xmm15, %s" (ymm right);
          emit "cmpps %s, xmm15, 0x01" (ymm dst))
        else (
          let ordered = match ordered_mask with
            | Some register -> register
            | None -> invalid_arg "SSE2 quiet LE requires an allocated ordered mask" in
          move ordered 15;
          emit "andps xmm15, %s" (ymm right);
          move dst left;
          emit "andps %s, %s" (ymm dst) (ymm ordered);
          emit "cmpps %s, xmm15, 0x02" (ymm dst);
          emit "andps %s, %s" (ymm dst) (ymm ordered)))
      else if predicate = M.One then (
        move 15 left;
        emit "cmpps xmm15, %s, 0x07" (ymm right);
        move dst left;
        emit "cmpps %s, %s, 0x04" (ymm dst) (ymm right);
        emit "andps %s, xmm15" (ymm dst))
      else (
        move dst left;
        let immediate = match predicate with M.Oeq -> 0 | M.Ounord -> 3 | M.Olt | M.Ole | M.One -> assert false in
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
  let insert_broadcast_lane dst previous inserted lane =
    if sse then (
      let mask = intern pool (Vector_bits (List.init lanes (fun index -> if index = lane then -1l else 0l))) in
      move dst previous;
      move 15 inserted;
      emit "xorps xmm15, %s" (ymm dst);
      emit "andps xmm15, XMMWORD PTR [rip + %s]" mask;
      emit "xorps %s, xmm15" (ymm dst))
    else if avx512 then (
      move dst previous;
      emit "kxnorw k1, k1, k1";
      emit "kshiftlw k1, k1, 15";
      emit "kshiftrw k1, k1, %d" (15 - lane);
      emit "vmovaps %s{k1}, %s" (ymm dst) (ymm inserted))
    else emit "vblendps %s, %s, %s, 0x%02x" (ymm dst) (ymm previous) (ymm inserted) (1 lsl lane)
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
  | A.Integer_parameter { dst; argument } ->
      let register = List.nth [ "edi"; "esi"; "edx"; "ecx"; "r8d"; "r9d" ] argument in
      emit "%smovd xmm%d, %s" (if sse then "" else "v") dst register
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
  | A.Broadcast_bool { dst; source } ->
      if sse then (move dst source; emit "shufps %s, %s, 0x00" (ymm dst) (ymm dst))
      else emit "vbroadcastss %s, xmm%d" (ymm dst) source;
      if sse then (
        emit "pslld %s, 31" (ymm dst);
        emit "psrad %s, 31" (ymm dst))
      else (
        emit "vpslld %s, %s, 31" (ymm dst) (ymm dst);
        emit "vpsrad %s, %s, 31" (ymm dst) (ymm dst))
  | A.Extract_f32 { dst; source; lane } -> splat_lane dst source (M.f32_lane_index lane)
  | A.Insert_f32 { dst; previous; inserted; lane; broadcast } ->
      if sse then (move broadcast inserted; emit "shufps %s, %s, 0x00" (ymm broadcast) (ymm broadcast))
      else emit "vbroadcastss %s, xmm%d" (ymm broadcast) inserted;
      insert_broadcast_lane dst previous broadcast (M.f32_lane_index lane)
  | A.Shuffle_word { dst; racks; indices; scratch } ->
      let mask_bits = List.map (fun index -> if index >= lanes then -1l else 0l) indices in
      let load_indices register =
        let label = intern pool (Vector_bits (List.map (fun index -> Int32.of_int (index mod lanes)) indices)) in
        emit "vmovaps %s, %s PTR [rip + %s]" (ymm register) memory label in
      let permute destination source =
        if sse then (
          let immediate = List.mapi (fun lane input -> (input mod lanes) lsl (2 * lane)) indices
            |> List.fold_left (lor) 0 in
          move destination source;
          emit "shufps %s, %s, 0x%02x" (ymm destination) (ymm destination) immediate)
        else emit "vpermps %s, %s, %s" (ymm destination) (ymm (List.hd scratch)) (ymm source) in
      if not sse then load_indices (List.hd scratch);
      permute dst (List.hd racks);
      (match racks with
      | [ _ ] -> ()
      | [ _; right ] ->
          let other = if sse then List.hd scratch else List.nth scratch 1 in
          permute other right;
          if sse then (
            let mask = intern pool (Vector_bits mask_bits) in
            move 15 other;
            emit "xorps xmm15, %s" (ymm dst);
            emit "andps xmm15, XMMWORD PTR [rip + %s]" mask;
            emit "xorps %s, xmm15" (ymm dst))
          else if avx512 then (
            let mask = intern pool (Vector_bits mask_bits) in
            let mask_register = List.hd scratch in
            emit "vmovaps %s, ZMMWORD PTR [rip + %s]" (ymm mask_register) mask;
            blend dst mask_register other dst)
          else (
            let mask = List.mapi (fun lane index -> if index >= lanes then 1 lsl lane else 0) indices
              |> List.fold_left (lor) 0 in
            emit "vblendps %s, %s, %s, 0x%02x" (ymm dst) (ymm dst) (ymm other) mask)
      | _ -> invalid_arg "32-bit shuffle requires one or two racks")
  | A.Reduce_mask { dst; source; operation; scratch } ->
      move dst source;
      if operation = Native_ir.Mask_bits then (
        let weights = intern pool (Vector_bits (List.init lanes (fun lane -> Int32.shift_left 1l lane))) in
        emit "%smovaps %s, %s PTR [rip + %s]" (if sse then "" else "v") (ymm scratch) memory weights;
        logical "andps" dst dst scratch);
      let combine () = logical
        (if operation = Native_ir.Mask_all then "andps" else "orps") dst dst scratch in
      (* Associative bit operations can use a butterfly reduction. Every
         stage still operates on the full profile-width vector register. *)
      if avx512 then List.iter (fun immediate ->
        emit "vshuff32x4 %s, %s, %s, 0x%02x" (ymm scratch) (ymm dst) (ymm dst) immediate;
        combine ()) [ 0x4e; 0xb1 ]
      else if not sse then (
        emit "vperm2f128 %s, %s, %s, 0x01" (ymm scratch) (ymm dst) (ymm dst);
        combine ());
      List.iter (fun immediate ->
        if sse then (
          move scratch dst;
          emit "shufps %s, %s, 0x%02x" (ymm scratch) (ymm scratch) immediate)
        else emit "vpermilps %s, %s, 0x%02x" (ymm scratch) (ymm dst) immediate;
        combine ()) [ 0x4e; 0xb1 ];
      if operation <> Native_ir.Mask_bits then (
        load_splat scratch 1l;
        logical "andps" dst dst scratch)
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
        insert_broadcast_lane dst dst prefix lane
      done
  | A.Addps { dst; left; right } ->
      binary "addps" dst left right
  | A.Subps { dst; left; right } ->
      binary "subps" dst left right
  | A.Add_i32 { dst; left; right } ->
      binary "paddd" dst left right
  | A.Sub_i32 { dst; left; right } ->
      binary "psubd" dst left right
  | A.Mul_i32 { dst; left; right; scratch } ->
      if sse then (
        let odd_left, odd_right = match scratch with
          | [ odd_left; odd_right ] -> odd_left, odd_right
          | _ -> invalid_arg "SSE2 integer multiplication requires two allocated temporaries" in
        (* PMULUDQ multiplies lanes 0 and 2 into two 64-bit products.
           Capture lanes 1 and 3 before a dying input becomes the destination.
           The final shuffles keep each product's low word in source order. *)
        move odd_left left;
        emit "shufps %s, %s, 0xb1" (ymm odd_left) (ymm odd_left);
        move odd_right right;
        emit "shufps %s, %s, 0xb1" (ymm odd_right) (ymm odd_right);
        binary "pmuludq" dst left right;
        emit "pmuludq %s, %s" (ymm odd_left) (ymm odd_right);
        emit "shufps %s, %s, 0x88" (ymm dst) (ymm odd_left);
        emit "shufps %s, %s, 0xd8" (ymm dst) (ymm dst))
      else binary "pmulld" dst left right
  | A.Neg_i32 { dst; source } ->
      logical "xorps" dst dst dst;
      binary "psubd" dst dst source
  | A.Abs_i32 { dst; source; sign } ->
      if sse then (
        let sign = match sign with
          | Some register -> register
          | None -> invalid_arg "SSE2 integer absolute value requires an allocated sign register" in
        (* (x xor sign) - sign preserves the wrapping minimum i32 value.
           Capture the sign before reusing a dying source as destination. *)
        move sign source;
        emit "psrad %s, 31" (ymm sign);
        logical "xorps" dst source sign;
        binary "psubd" dst dst sign)
      else emit "vpabsd %s, %s" (ymm dst) (ymm source)
  | A.Extreme_i32 { dst; left; right; operation; unsigned; scratch } ->
      if sse then (
        let mask, biased_left, biased_right = match unsigned, scratch with
          | true, [ biased_left; biased_right; mask ] ->
              let biased_left, biased_right = unsigned_order_operands left right [biased_left; biased_right] in
              mask, biased_left, biased_right
          | false, [ mask ] -> mask, left, right
          | _ -> invalid_arg "SSE2 integer extrema require an allocated mask register" in
        binary "pcmpgtd" mask biased_left biased_right;
        (match operation with
        | M.Minimum -> blend dst mask right left
        | M.Maximum -> blend dst mask left right))
      else binary (match operation, unsigned with
        | M.Minimum, false -> "pminsd" | M.Maximum, false -> "pmaxsd"
        | M.Minimum, true -> "pminud" | M.Maximum, true -> "pmaxud") dst left right
  | A.Shift_i32 { dst; source; count; shift } ->
      let count = Native_ir.I32_shift_count.to_int count in
      let mnemonic = match shift with
        | Native_ir.Shift_left -> "pslld"
        | Native_ir.Shift_right -> "psrld"
        | Native_ir.Shift_right_signed -> "psrad" in
      if count = 0 then move dst source
      else if sse then (
        move dst source;
        emit "%s %s, %d" mnemonic (ymm dst) count)
      else emit "v%s %s, %s, %d" mnemonic (ymm dst) (ymm source) count
  | A.Compare_i32 { dst; predicate; unsigned; left; right; scratch } ->
      if avx512 then (
        let immediate = match predicate with
          | Native_ir.Eq -> 0 | Native_ir.Lt -> 1 | Native_ir.Le -> 2
          | Native_ir.Ne -> 4 | Native_ir.Ge -> 5 | Native_ir.Gt -> 6 in
        emit "%s k1, %s, %s, 0x%02x" (if unsigned then "vpcmpud" else "vpcmpd") (ymm left) (ymm right) immediate;
        logical "xorps" dst dst dst;
        emit "vpternlogd %s{k1}, %s, %s, 0xff" (ymm dst) (ymm dst) (ymm dst))
      else (
        (* XORing the sign bit maps unsigned order to signed order. Both
           temporary racks are allocated so live inputs remain unchanged. *)
        let left, right = unsigned_order_operands left right scratch in
        let mnemonic, left, right, invert = match predicate with
          | Native_ir.Eq -> "pcmpeqd", left, right, false
          | Native_ir.Ne -> "pcmpeqd", left, right, true
          | Native_ir.Lt -> "pcmpgtd", right, left, false
          | Native_ir.Le -> "pcmpgtd", left, right, true
          | Native_ir.Gt -> "pcmpgtd", left, right, false
          | Native_ir.Ge -> "pcmpgtd", right, left, true in
        binary mnemonic dst left right;
        if invert then (
          let ones = intern pool (Vector_bits (List.init lanes (fun _ -> Int32.minus_one))) in
          if sse then emit "xorps %s, XMMWORD PTR [rip + %s]" (ymm dst) ones
          else emit "vxorps %s, %s, YMMWORD PTR [rip + %s]" (ymm dst) (ymm dst) ones))
  | A.Mulps { dst; left; right } ->
      binary "mulps" dst left right
  | A.Divps { dst; left; right } ->
      binary "divps" dst left right
  | A.Extreme_f32 { dst; left; right; operation; scratch } ->
      move dst left;
      strict_combine (match operation with M.Minimum -> `Min | M.Maximum -> `Max)
        dst right scratch
  | A.Sqrtps { dst; source } -> emit "%ssqrtps %s, %s" (if sse then "" else "v") (ymm dst) (ymm source)
  | A.Negps { dst; source } ->
      let sign = intern pool (Vector_bits (List.init lanes (fun _ -> Int32.min_int))) in
      if sse then (move dst source; emit "xorps %s, XMMWORD PTR [rip + %s]" (ymm dst) sign)
      else emit "%s %s, %s, %s PTR [rip + %s]" (if avx512 then "vpxord" else "vxorps") (ymm dst) (ymm source) memory sign
  | A.Absps { dst; source } ->
      let magnitude = intern pool (Vector_bits (List.init lanes (fun _ -> Int32.max_int))) in
      if sse then (move dst source; emit "andps %s, XMMWORD PTR [rip + %s]" (ymm dst) magnitude)
      else emit "%s %s, %s, %s PTR [rip + %s]" (if avx512 then "vpandd" else "vandps") (ymm dst) (ymm source) memory magnitude
  | A.Convert_i32_f32 { dst; source; conversion = Native_ir.I32_to_f32; _ } ->
      emit "%scvtdq2ps %s, %s" (if sse then "" else "v") (ymm dst) (ymm source)
  | A.Convert_i32_f32 { dst; source; conversion = Native_ir.F32_to_i32; scratch } ->
      (match scratch with
      | [ low; high; safe; constant ] ->
          (* Keep NaNs and overflow away from CVTPS2DQ. Packed masks restore
             saturated endpoints afterwards; every lane still converts in
             parallel. The caller supplies nearest-even MXCSR rounding. *)
          compare M.Oeq low source source;
          logical "andps" safe source low;
          load_splat constant 0xcf000000l;
          compare M.Olt low safe constant;
          load_splat constant 0x4f000000l;
          compare M.Olt high safe constant;
          logical "andps" safe safe high;
          binary (if avx512 then "pandnd" else "andnps") safe low safe;
          emit "%scvtps2dq %s, %s" (if sse then "" else "v") (ymm dst) (ymm safe);
          load_splat constant Int32.min_int;
          logical "andps" low low constant;
          logical "orps" dst dst low;
          load_splat constant Int32.max_int;
          binary (if avx512 then "pandnd" else "andnps") high high constant;
          logical "orps" dst dst high
      | _ -> invalid_arg "saturating x86 conversion requires four temporary registers")
  | A.Round_f32 { dst; source; mode; scratch } ->
      let immediate = match mode with
        | Native_ir.Nearest_even -> 0 | Native_ir.Toward_negative -> 1
        | Native_ir.Toward_positive -> 2 | Native_ir.Toward_zero -> 3 in
      if not sse then
        (* Bit 3 suppresses inexact, not invalid from a signaling NaN. *)
        emit "%s %s, %s, 0x%02x" (if avx512 then "vrndscaleps" else "vroundps")
          (ymm dst) (ymm source) (immediate lor 8)
      else (match scratch with
        | [ small; safe; rounded; mask; constant ] ->
            (* Every finite binary32 value at or above 2^23 is integral.
               Convert only smaller magnitudes, avoiding integer overflow
               and preserving infinities. This is SSE2, not SSE4.1 ROUNDPS. *)
            load_splat constant 0x7fffffffl;
            logical "andps" safe source constant;
            load_splat constant 0x4b000000l;
            compare M.Olt small safe constant;
            logical "andps" safe source small;
            emit "%s %s, %s"
              (if mode = Native_ir.Nearest_even then "cvtps2dq" else "cvttps2dq")
              (ymm rounded) (ymm safe);
            emit "cvtdq2ps %s, %s" (ymm rounded) (ymm rounded);
            load_splat constant 0x80000000l;
            logical "andps" mask source constant;
            logical "orps" rounded rounded mask;
            (match mode with
            | Native_ir.Toward_negative | Native_ir.Toward_positive ->
                if mode = Native_ir.Toward_negative then compare M.Olt mask safe rounded
                else compare M.Olt mask rounded safe;
                load_splat constant (if mode = Native_ir.Toward_negative then 0xbf800000l else 0x3f800000l);
                logical "andps" constant constant mask;
                binary "addps" safe rounded constant;
                (* Selecting only corrected lanes preserves an unchanged -0. *)
                blend rounded mask safe rounded
            | Native_ir.Toward_zero | Native_ir.Nearest_even -> ());
            compare M.Ounord mask source source;
            load_splat constant 0x00400000l;
            logical "andps" constant constant mask;
            logical "orps" dst source constant;
            blend dst small rounded dst
        | _ -> invalid_arg "SSE2 rounding requires five temporary registers")
  | A.Fma213ps { dst; multiplier; addend } ->
      emit "vfmadd213ps %s, %s, %s" (ymm dst) (ymm multiplier) (ymm addend)
  | A.Fma231ps { dst; multiplicand; multiplier } ->
      emit "vfmadd231ps %s, %s, %s" (ymm dst) (ymm multiplicand) (ymm multiplier)
  | A.Cmpps { dst; predicate; left; right; ordered_mask } ->
      compare ?ordered_mask predicate dst left right
  | A.Blendvps { dst; mask; if_true; if_false } ->
      blend dst mask if_true if_false
  | A.Mask_andps { dst; left; right } ->
      logical "andps" dst left right
  | A.Mask_andnotps { dst; left; right } ->
      (* x86 AND-NOT complements its first source. Rake complements the
         right operand, so reverse the sources, including SSE2 alias saves. *)
      binary (if avx512 then "pandnd" else "andnps") dst right left
  | A.Mask_orps { dst; left; right } ->
      logical "orps" dst left right
  | A.Mask_xorps { dst; left; right } ->
      logical "xorps" dst left right
  | A.Mask_notps { dst; source } ->
      let ones = intern pool (Vector_bits (List.init lanes (fun _ -> Int32.minus_one))) in
      if sse then (move dst source; emit "xorps %s, XMMWORD PTR [rip + %s]" (ymm dst) ones)
      else emit "%s %s, %s, %s PTR [rip + %s]" (if avx512 then "vpxord" else "vxorps") (ymm dst) (ymm source) memory ones
  | A.Moveaps { dst; source } -> move dst source

let emit_function profile pool buffer (func : A.func) =
  Printf.bprintf buffer ".p2align 4\n.globl %s\n.hidden %s\n.type %s, @function\n%s:\n"
    func.name func.name func.name func.name;
  List.iter (emit_instruction profile pool buffer) func.instructions;
  (match func.result_type with
  | Some (Native_ir.Scalar (Native_ir.I1 | Native_ir.I32 | Native_ir.U32)) ->
      Printf.bprintf buffer "    %smovd eax, xmm0\n" (if profile = Target.X86_sse2 then "" else "v")
  | _ -> ());
  Buffer.add_string buffer "    ret\n";
  Printf.bprintf buffer ".size %s, .-%s\n\n" func.name func.name

let emit_constant buffer (constant, label) =
  match constant with
  | Splat_f32 bits ->
      Buffer.add_string buffer ".section .rodata.cst4,\"aM\",@progbits,4\n.p2align 2\n";
      Printf.bprintf buffer "%s:\n    .long 0x%08lx\n" label bits
  | Vector_bits bits ->
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
