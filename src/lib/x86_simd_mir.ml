(** Shared virtual-register machine IR for x86-64 SIMD profiles.

    Every value in this IR occupies one profile-width vector register. Destructive FMA form
    selection and physical register allocation deliberately happen later. *)

type vreg = int

type provenance = Native_ir.provenance

type ordered_comparison = Oeq | One | Olt | Ole | Ounord
type extremum = Minimum | Maximum
type f32_lane =
  | Lane0 | Lane1 | Lane2 | Lane3 | Lane4 | Lane5 | Lane6 | Lane7
  | Lane8 | Lane9 | Lane10 | Lane11 | Lane12 | Lane13 | Lane14 | Lane15

let f32_lane_index = function
  | Lane0 -> 0 | Lane1 -> 1 | Lane2 -> 2 | Lane3 -> 3
  | Lane4 -> 4 | Lane5 -> 5 | Lane6 -> 6 | Lane7 -> 7
  | Lane8 -> 8 | Lane9 -> 9 | Lane10 -> 10 | Lane11 -> 11
  | Lane12 -> 12 | Lane13 -> 13 | Lane14 -> 14 | Lane15 -> 15

let f32_lane_of_int = function
  | 0 -> Some Lane0 | 1 -> Some Lane1 | 2 -> Some Lane2 | 3 -> Some Lane3
  | 4 -> Some Lane4 | 5 -> Some Lane5 | 6 -> Some Lane6 | 7 -> Some Lane7
  | 8 -> Some Lane8 | 9 -> Some Lane9 | 10 -> Some Lane10 | 11 -> Some Lane11
  | 12 -> Some Lane12 | 13 -> Some Lane13 | 14 -> Some Lane14 | 15 -> Some Lane15
  | _ -> None

type instruction =
  | Uniform_f32 of { dst : vreg; bits : int32; provenance : provenance }
  | Uniform_mask of { dst : vreg; value : bool; provenance : provenance }
  | Broadcastss of { dst : vreg; source : vreg; provenance : provenance }
  | Extract_f32 of { dst : vreg; source : vreg; lane : f32_lane; provenance : provenance }
  | Insert_f32 of { dst : vreg; previous : vreg; inserted : vreg; lane : f32_lane; provenance : provenance }
  | Shuffle_word of { dst : vreg; racks : vreg list; indices : int list; provenance : provenance }
  | Reduce_mask of { dst : vreg; source : vreg; operation : Native_ir.mask_reduction; provenance : provenance }
  | Reduce_f32 of {
      dst : vreg;
      source : vreg;
      operation : Native_ir.reduction;
      provenance : provenance;
    }
  | Scan_f32 of {
      dst : vreg;
      source : vreg;
      operation : Native_ir.scan;
      provenance : provenance;
    }
  | Addps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Subps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Add_i32 of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Sub_i32 of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Mul_i32 of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Extreme_i32 of { dst : vreg; left : vreg; right : vreg; operation : extremum; provenance : provenance }
  | Neg_i32 of { dst : vreg; source : vreg; provenance : provenance }
  | Abs_i32 of { dst : vreg; source : vreg; provenance : provenance }
  | Shift_i32 of { dst : vreg; source : vreg; count : Native_ir.I32_shift_count.t; shift : Native_ir.shift; provenance : provenance }
  | Compare_i32 of { dst : vreg; predicate : Native_ir.comparison; unsigned : bool; left : vreg; right : vreg; provenance : provenance }
  | Mulps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Divps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Extreme_f32 of {
      dst : vreg;
      left : vreg;
      right : vreg;
      operation : extremum;
      provenance : provenance;
    }
  | Negps of { dst : vreg; source : vreg; provenance : provenance }
  | Absps of { dst : vreg; source : vreg; provenance : provenance }
  | Sqrtps of { dst : vreg; source : vreg; provenance : provenance }
  | Round_f32 of { dst : vreg; source : vreg; mode : Native_ir.rounding_mode; provenance : provenance }
  | Fma_ps of {
      dst : vreg;
      multiplicand : vreg;
      multiplier : vreg;
      addend : vreg;
      provenance : provenance;
    }
  | Cmpps of {
      dst : vreg;
      predicate : ordered_comparison;
      left : vreg;
      right : vreg;
      provenance : provenance;
    }
  | Blendvps of {
      dst : vreg;
      mask : vreg;
      if_true : vreg;
      if_false : vreg;
      provenance : provenance;
    }
  | Mask_andps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Mask_andnotps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Mask_orps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Mask_xorps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Mask_notps of { dst : vreg; source : vreg; provenance : provenance }

type parameter = { reg : vreg; name : string option }

type func = {
  name : string;
  loc : Native_ir.source_location;
  parameters : parameter list;
  instructions : instruction list;
  result : vreg option;
  result_type : Native_ir.typ option;
  value_locations : (vreg * Native_ir.source_location) list;
}

type t = func list

let def = function
  | Uniform_f32 { dst; _ }
  | Uniform_mask { dst; _ }
  | Broadcastss { dst; _ }
  | Extract_f32 { dst; _ }
  | Insert_f32 { dst; _ }
  | Shuffle_word { dst; _ }
  | Reduce_mask { dst; _ }
  | Reduce_f32 { dst; _ }
  | Scan_f32 { dst; _ }
  | Addps { dst; _ }
  | Subps { dst; _ }
  | Add_i32 { dst; _ }
  | Sub_i32 { dst; _ }
  | Mul_i32 { dst; _ }
  | Extreme_i32 { dst; _ }
  | Neg_i32 { dst; _ }
  | Abs_i32 { dst; _ }
  | Shift_i32 { dst; _ }
  | Compare_i32 { dst; _ }
  | Mulps { dst; _ }
  | Divps { dst; _ }
  | Extreme_f32 { dst; _ }
  | Negps { dst; _ }
  | Absps { dst; _ }
  | Sqrtps { dst; _ }
  | Round_f32 { dst; _ }
  | Fma_ps { dst; _ }
  | Cmpps { dst; _ }
  | Blendvps { dst; _ }
  | Mask_andps { dst; _ }
  | Mask_andnotps { dst; _ }
  | Mask_orps { dst; _ }
  | Mask_xorps { dst; _ }
  | Mask_notps { dst; _ } -> dst

let operands = function
  | Uniform_f32 _ | Uniform_mask _ -> []
  | Broadcastss { source; _ }
  | Extract_f32 { source; _ }
  | Reduce_mask { source; _ }
  | Reduce_f32 { source; _ }
  | Scan_f32 { source; _ }
  | Round_f32 { source; _ } -> [ source ]
  | Shift_i32 { source; _ } -> [ source ]
  | Insert_f32 { previous; inserted; _ } -> [ previous; inserted ]
  | Shuffle_word { racks; _ } -> racks
  | Addps { left; right; _ }
  | Subps { left; right; _ }
  | Add_i32 { left; right; _ }
  | Sub_i32 { left; right; _ }
  | Mul_i32 { left; right; _ }
  | Extreme_i32 { left; right; _ }
  | Compare_i32 { left; right; _ }
  | Mulps { left; right; _ }
  | Divps { left; right; _ }
  | Extreme_f32 { left; right; _ }
  | Cmpps { left; right; _ }
  | Mask_andps { left; right; _ }
  | Mask_andnotps { left; right; _ }
  | Mask_orps { left; right; _ }
  | Mask_xorps { left; right; _ } -> [ left; right ]
  | Neg_i32 { source; _ } | Abs_i32 { source; _ } | Negps { source; _ } | Absps { source; _ } | Sqrtps { source; _ } | Mask_notps { source; _ } -> [ source ]
  | Fma_ps { multiplicand; multiplier; addend; _ } -> [ multiplicand; multiplier; addend ]
  | Blendvps { mask; if_true; if_false; _ } -> [ mask; if_true; if_false ]

let provenance = function
  | Uniform_f32 { provenance; _ }
  | Uniform_mask { provenance; _ }
  | Broadcastss { provenance; _ }
  | Extract_f32 { provenance; _ }
  | Insert_f32 { provenance; _ }
  | Shuffle_word { provenance; _ }
  | Reduce_mask { provenance; _ }
  | Reduce_f32 { provenance; _ }
  | Scan_f32 { provenance; _ }
  | Addps { provenance; _ }
  | Subps { provenance; _ }
  | Add_i32 { provenance; _ }
  | Sub_i32 { provenance; _ }
  | Mul_i32 { provenance; _ }
  | Extreme_i32 { provenance; _ }
  | Neg_i32 { provenance; _ }
  | Abs_i32 { provenance; _ }
  | Shift_i32 { provenance; _ }
  | Compare_i32 { provenance; _ }
  | Mulps { provenance; _ }
  | Divps { provenance; _ }
  | Extreme_f32 { provenance; _ }
  | Negps { provenance; _ }
  | Absps { provenance; _ }
  | Sqrtps { provenance; _ }
  | Round_f32 { provenance; _ }
  | Fma_ps { provenance; _ }
  | Cmpps { provenance; _ }
  | Blendvps { provenance; _ }
  | Mask_andps { provenance; _ }
  | Mask_andnotps { provenance; _ }
  | Mask_orps { provenance; _ }
  | Mask_xorps { provenance; _ }
  | Mask_notps { provenance; _ } -> provenance

let comparison_immediate = function
  | Oeq -> 0x00 | One -> 0x0c | Olt -> 0x11 | Ole -> 0x12 | Ounord -> 0x03

let value_location func value =
  Option.value (List.assoc_opt value func.value_locations) ~default:func.loc

let instruction_name = function
  | Uniform_f32 _ -> "vbroadcastss"
  | Uniform_mask _ -> "mask.constant"
  | Broadcastss _ -> "vbroadcastss.xmm"
  | Extract_f32 _ -> "extract.f32"
  | Insert_f32 _ -> "insert.f32"
  | Shuffle_word _ -> "shuffle.32"
  | Reduce_mask _ -> "reduce.mask"
  | Reduce_f32 _ -> "strict.reduce.f32"
  | Scan_f32 _ -> "strict.scan.f32"
  | Addps _ -> "vaddps"
  | Subps _ -> "vsubps"
  | Add_i32 _ -> "vpaddd"
  | Sub_i32 _ -> "vpsubd"
  | Mul_i32 _ -> "multiply.low.i32"
  | Extreme_i32 { operation = Minimum; _ } -> "min.i32"
  | Extreme_i32 { operation = Maximum; _ } -> "max.i32"
  | Neg_i32 _ -> "zero.sub.i32"
  | Abs_i32 _ -> "abs.i32"
  | Shift_i32 _ -> "shift.bits.i32"
  | Compare_i32 { unsigned; _ } -> if unsigned then "compare.u32" else "compare.i32"
  | Mulps _ -> "vmulps"
  | Divps _ -> "vdivps"
  | Extreme_f32 { operation = Minimum; _ } -> "strict.min.f32"
  | Extreme_f32 { operation = Maximum; _ } -> "strict.max.f32"
  | Negps _ -> "vxorps.sign"
  | Absps _ -> "vandps.magnitude"
  | Sqrtps _ -> "vsqrtps"
  | Round_f32 _ -> "round.f32"
  | Fma_ps _ -> "vfma.ps"
  | Cmpps _ -> "vcmpps"
  | Blendvps _ -> "vblendvps"
  | Mask_andps _ -> "vandps"
  | Mask_andnotps _ -> "vandnps"
  | Mask_orps _ -> "vorps"
  | Mask_xorps _ -> "vxorps"
  | Mask_notps _ -> "vxorps.not"
