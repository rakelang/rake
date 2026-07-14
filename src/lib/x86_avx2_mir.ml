(** Virtual-register machine IR for the x86-64 AVX2+FMA profile.

    Every value in this IR occupies one YMM register.  Destructive FMA form
    selection and physical register allocation deliberately happen later. *)

type vreg = int

type provenance = Native_ir.provenance

type ordered_comparison = Oeq | One | Olt | Ole | Ounord

type instruction =
  | Uniform_f32 of { dst : vreg; bits : int32; provenance : provenance }
  | Uniform_mask of { dst : vreg; value : bool; provenance : provenance }
  | Broadcastss of { dst : vreg; source : vreg; provenance : provenance }
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
  | Mulps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Divps of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Negps of { dst : vreg; source : vreg; provenance : provenance }
  | Sqrtps of { dst : vreg; source : vreg; provenance : provenance }
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
  | Reduce_f32 { dst; _ }
  | Scan_f32 { dst; _ }
  | Addps { dst; _ }
  | Subps { dst; _ }
  | Mulps { dst; _ }
  | Divps { dst; _ }
  | Negps { dst; _ }
  | Sqrtps { dst; _ }
  | Fma_ps { dst; _ }
  | Cmpps { dst; _ }
  | Blendvps { dst; _ }
  | Mask_andps { dst; _ }
  | Mask_orps { dst; _ }
  | Mask_xorps { dst; _ }
  | Mask_notps { dst; _ } -> dst

let operands = function
  | Uniform_f32 _ | Uniform_mask _ -> []
  | Broadcastss { source; _ }
  | Reduce_f32 { source; _ }
  | Scan_f32 { source; _ } -> [ source ]
  | Addps { left; right; _ }
  | Subps { left; right; _ }
  | Mulps { left; right; _ }
  | Divps { left; right; _ }
  | Cmpps { left; right; _ }
  | Mask_andps { left; right; _ }
  | Mask_orps { left; right; _ }
  | Mask_xorps { left; right; _ } -> [ left; right ]
  | Negps { source; _ } | Sqrtps { source; _ } | Mask_notps { source; _ } -> [ source ]
  | Fma_ps { multiplicand; multiplier; addend; _ } -> [ multiplicand; multiplier; addend ]
  | Blendvps { mask; if_true; if_false; _ } -> [ mask; if_true; if_false ]

let provenance = function
  | Uniform_f32 { provenance; _ }
  | Uniform_mask { provenance; _ }
  | Broadcastss { provenance; _ }
  | Reduce_f32 { provenance; _ }
  | Scan_f32 { provenance; _ }
  | Addps { provenance; _ }
  | Subps { provenance; _ }
  | Mulps { provenance; _ }
  | Divps { provenance; _ }
  | Negps { provenance; _ }
  | Sqrtps { provenance; _ }
  | Fma_ps { provenance; _ }
  | Cmpps { provenance; _ }
  | Blendvps { provenance; _ }
  | Mask_andps { provenance; _ }
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
  | Reduce_f32 _ -> "strict.reduce.f32"
  | Scan_f32 _ -> "strict.scan.f32"
  | Addps _ -> "vaddps"
  | Subps _ -> "vsubps"
  | Mulps _ -> "vmulps"
  | Divps _ -> "vdivps"
  | Negps _ -> "vxorps.sign"
  | Sqrtps _ -> "vsqrtps"
  | Fma_ps _ -> "vfma.ps"
  | Cmpps _ -> "vcmpps"
  | Blendvps _ -> "vblendvps"
  | Mask_andps _ -> "vandps"
  | Mask_orps _ -> "vorps"
  | Mask_xorps _ -> "vxorps"
  | Mask_notps _ -> "vxorps.not"
