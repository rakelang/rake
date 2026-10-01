(** Rake's transcendental functions on binary32.

    exp, log, log2 and tanh are defined as fixed sequences of binary32
    operations (Cephes' single-precision polynomials, Moshier 1984-1992), not
    as whatever a platform library returns. One definition serves the
    interpreter (evaluated here), the slow tier's C (printed by {!c_source})
    and the rack expansions, which apply the same operations lane by lane, so
    every target and the interpreter agree bit for bit. Accuracy is within a
    few ulp over the normal range. *)

let f32 x = Int32.float_of_bits (Int32.bits_of_float x)
let bits = Int32.bits_of_float
let of_bits = Int32.float_of_bits

(* Constants, each rounded once to binary32. *)
let log2e = f32 1.44269504088896341
let exp_high = f32 88.72283905206835
let exp_low = f32 (-103.97207708)
let ln2_high = f32 0.693359375
let ln2_low = f32 (-2.12194440e-4)
let exp_poly = List.map f32 [ 1.9875691500E-4; 1.3981999507E-3; 8.3334519073E-3; 4.1665795894E-2; 1.6666665459E-1; 5.0000001201E-1 ]
let sqrt_half = f32 0.707106781186547524
let log_poly = List.map f32 [ 7.0376836292E-2; -1.1514610310E-1; 1.1676998740E-1; -1.2420140846E-1; 1.4249322787E-1; -1.6668057665E-1; 2.0000714765E-1; -2.4999993993E-1; 3.3333331174E-1 ]
let tanh_poly = List.map f32 [ -5.70498872745E-3; 2.06390887954E-2; -5.37397155531E-2; 1.33314422036E-1; -3.33332819422E-1 ]
let tanh_switch = f32 0.625
let tanh_limit = f32 9.0
let min_normal = of_bits 0x00800000l
let two_23 = f32 8388608.0

let add a b = f32 (a +. b)
let sub a b = f32 (a -. b)
let mul a b = f32 (a *. b)
let div a b = f32 (a /. b)
let canonical_nan = of_bits 0x7fc00000l

(** 2^k for k in [-126, 127], built from its bits. *)
let pow2 k = of_bits (Int32.shift_left (Int32.of_int (k + 127)) 23)

let exp x =
  if Float.is_nan x then x
  else if x > exp_high then Float.infinity
  else if x < exp_low then 0.0
  else
    let n = Float.floor (add (mul x log2e) 0.5) in
    let r = sub x (mul n ln2_high) in
    let r = sub r (mul n ln2_low) in
    let z = mul r r in
    let y = List.fold_left (fun y c -> add (mul y r) c) (List.hd exp_poly) (List.tl exp_poly) in
    let y = add (mul y z) r in
    let y = add y 1.0 in
    let k = int_of_float n in
    let k1 = k asr 1 in
    let k2 = k - k1 in
    mul (mul y (pow2 k1)) (pow2 k2)

(* The shared mantissa step of log and log2: the exponent and ln of the
   mantissa, before the exponent's terms are added. *)
let log_parts x =
  let x, adjust = if x < min_normal then (mul x two_23, -23) else (x, 0) in
  let b = bits x in
  let e = Int32.to_int (Int32.logand (Int32.shift_right_logical b 23) 0xffl) - 126 + adjust in
  let m = of_bits (Int32.logor (Int32.logand b 0x807fffffl) 0x3f000000l) in
  let e, m = if m < sqrt_half then (e - 1, sub (add m m) 1.0) else (e, sub m 1.0) in
  let z = mul m m in
  let y = List.fold_left (fun y c -> add (mul y m) c) (List.hd log_poly) (List.tl log_poly) in
  let y = mul (mul y m) z in
  (e, m, z, y)

let log_special x =
  if Float.is_nan x then Some x
  else if x < 0.0 then Some canonical_nan
  else if x = 0.0 then Some Float.neg_infinity
  else if x = Float.infinity then Some x
  else None

let log x =
  match log_special x with
  | Some v -> v
  | None ->
      let e, m, z, y = log_parts x in
      let fe = f32 (float_of_int e) in
      let y = add y (mul fe ln2_low) in
      let y = sub y (mul 0.5 z) in
      let r = add m y in
      add r (mul fe ln2_high)

let log2 x =
  match log_special x with
  | Some v -> v
  | None ->
      let e, m, z, y = log_parts x in
      let fe = f32 (float_of_int e) in
      let y = sub y (mul 0.5 z) in
      let r = add m y in
      add (mul r log2e) fe

let tanh x =
  if Float.is_nan x then x
  else
    let a = Float.abs x in
    if a > tanh_limit then (if x > 0.0 then 1.0 else -1.0)
    else if a >= tanh_switch then
      let e = exp (add a a) in
      let r = sub 1.0 (div 2.0 (add e 1.0)) in
      if x < 0.0 then Float.neg r else r
    else if x = 0.0 then x
    else
      let z = mul x x in
      let y = List.fold_left (fun y c -> add (mul y z) c) (List.hd tanh_poly) (List.tl tanh_poly) in
      add (mul (mul y z) x) x

(** A binary32 constant as an exact C literal. *)
let c_float x =
  if Float.is_nan x then "__builtin_nanf(\"\")"
  else if x = Float.infinity then "__builtin_inff()"
  else if x = Float.neg_infinity then "(-__builtin_inff())"
  else Printf.sprintf "%hf" x

(** The same definitions as C, for slow code. *)
let c_source () =
  let poly var coefficients =
    let first = c_float (List.hd coefficients) in
    String.concat ""
      (Printf.sprintf "    float y = %s;\n" first
       :: List.map (fun c -> Printf.sprintf "    y = y * %s + %s;\n" var (c_float c)) (List.tl coefficients))
  in
  String.concat ""
    [
      "static inline float rake_pow2_f32(int32_t k) { return __builtin_bit_cast(float, (uint32_t)(k + 127) << 23); }\n";
      "static float rake_exp_f32(float x)\n{\n";
      "    if (x != x) return x;\n";
      Printf.sprintf "    if (x > %s) return __builtin_inff();\n" (c_float exp_high);
      Printf.sprintf "    if (x < %s) return 0.0f;\n" (c_float exp_low);
      Printf.sprintf "    const float n = __builtin_floorf(x * %s + 0.5f);\n" (c_float log2e);
      Printf.sprintf "    float r = x - n * %s;\n" (c_float ln2_high);
      Printf.sprintf "    r = r - n * %s;\n" (c_float ln2_low);
      "    const float z = r * r;\n";
      poly "r" exp_poly;
      "    y = y * z + r;\n    y = y + 1.0f;\n";
      "    const int32_t k = (int32_t)n;\n    const int32_t k1 = k >> 1;\n    const int32_t k2 = k - k1;\n";
      "    return y * rake_pow2_f32(k1) * rake_pow2_f32(k2);\n}\n";
      "static float rake_log_parts_f32(float x, int32_t *exponent, float *mantissa, float *square)\n{\n";
      "    int32_t adjust = 0;\n";
      Printf.sprintf "    if (x < %s) { x = x * %s; adjust = -23; }\n" (c_float min_normal) (c_float two_23);
      "    const uint32_t b = __builtin_bit_cast(uint32_t, x);\n";
      "    int32_t e = (int32_t)((b >> 23) & 0xffu) - 126 + adjust;\n";
      "    float m = __builtin_bit_cast(float, (b & 0x807fffffu) | 0x3f000000u);\n";
      Printf.sprintf "    if (m < %s) { e = e - 1; m = m + m - 1.0f; } else { m = m - 1.0f; }\n" (c_float sqrt_half);
      "    const float z = m * m;\n";
      poly "m" log_poly;
      "    y = y * m * z;\n";
      "    *exponent = e; *mantissa = m; *square = z;\n    return y;\n}\n";
      "static float rake_log_f32(float x)\n{\n";
      "    if (x != x) return x;\n    if (x < 0.0f) return __builtin_nanf(\"\");\n";
      "    if (x == 0.0f) return -__builtin_inff();\n    if (x == __builtin_inff()) return x;\n";
      "    int32_t e; float m, z;\n    float y = rake_log_parts_f32(x, &e, &m, &z);\n";
      "    const float fe = (float)e;\n";
      Printf.sprintf "    y = y + fe * %s;\n" (c_float ln2_low);
      "    y = y - 0.5f * z;\n    const float r = m + y;\n";
      Printf.sprintf "    return r + fe * %s;\n}\n" (c_float ln2_high);
      "static float rake_log2_f32(float x)\n{\n";
      "    if (x != x) return x;\n    if (x < 0.0f) return __builtin_nanf(\"\");\n";
      "    if (x == 0.0f) return -__builtin_inff();\n    if (x == __builtin_inff()) return x;\n";
      "    int32_t e; float m, z;\n    float y = rake_log_parts_f32(x, &e, &m, &z);\n";
      "    const float fe = (float)e;\n    y = y - 0.5f * z;\n    const float r = m + y;\n";
      Printf.sprintf "    return r * %s + fe;\n}\n" (c_float log2e);
      "static float rake_tanh_f32(float x)\n{\n";
      "    if (x != x) return x;\n    const float a = __builtin_fabsf(x);\n";
      Printf.sprintf "    if (a > %s) return x > 0.0f ? 1.0f : -1.0f;\n" (c_float tanh_limit);
      Printf.sprintf "    if (a >= %s) {\n" (c_float tanh_switch);
      "        const float e = rake_exp_f32(a + a);\n        const float r = 1.0f - 2.0f / (e + 1.0f);\n";
      "        return x < 0.0f ? -r : r;\n    }\n    if (x == 0.0f) return x;\n";
      "    const float z = x * x;\n";
      poly "z" tanh_poly;
      "    return y * z * x + x;\n}\n";
    ]
