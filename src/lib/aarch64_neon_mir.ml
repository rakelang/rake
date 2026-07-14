(** Virtual-register machine IR for the AArch64 Advanced SIMD profile.

    Every virtual value occupies one complete 128-bit vector register.  Masks
    use four 32-bit lanes containing either all zeroes or all ones. *)

type vreg = int
type provenance = Native_ir.provenance

type comparison = Ceq | Cgt | Cge

type instruction =
  | Uniform_f32 of { dst : vreg; bits : int32; provenance : provenance }
  | Mask_const of { dst : vreg; value : bool; provenance : provenance }
  | Broadcast_f32 of { dst : vreg; source : vreg; provenance : provenance }
  | Fadd of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Fsub of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Fmul of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Fdiv of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Fsqrt of { dst : vreg; source : vreg; provenance : provenance }
  | Fma of {
      dst : vreg;
      multiplicand : vreg;
      multiplier : vreg;
      addend : vreg;
      provenance : provenance;
    }
  | Compare of {
      dst : vreg;
      predicate : comparison;
      left : vreg;
      right : vreg;
      provenance : provenance;
    }
  | Select of {
      dst : vreg;
      mask : vreg;
      if_true : vreg;
      if_false : vreg;
      provenance : provenance;
    }
  | And of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Orr of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Eor of { dst : vreg; left : vreg; right : vreg; provenance : provenance }
  | Mvn of { dst : vreg; source : vreg; provenance : provenance }

type parameter = { reg : vreg; name : string option }

type func = {
  name : string;
  loc : Native_ir.source_location;
  parameters : parameter list;
  instructions : instruction list;
  result : vreg option;
  value_locations : (vreg * Native_ir.source_location) list;
}

type t = func list

let def = function
  | Uniform_f32 { dst; _ }
  | Mask_const { dst; _ }
  | Broadcast_f32 { dst; _ }
  | Fadd { dst; _ }
  | Fsub { dst; _ }
  | Fmul { dst; _ }
  | Fdiv { dst; _ }
  | Fsqrt { dst; _ }
  | Fma { dst; _ }
  | Compare { dst; _ }
  | Select { dst; _ }
  | And { dst; _ }
  | Orr { dst; _ }
  | Eor { dst; _ }
  | Mvn { dst; _ } -> dst

let operands = function
  | Uniform_f32 _ | Mask_const _ -> []
  | Broadcast_f32 { source; _ } -> [ source ]
  | Fadd { left; right; _ }
  | Fsub { left; right; _ }
  | Fmul { left; right; _ }
  | Fdiv { left; right; _ }
  | Compare { left; right; _ }
  | And { left; right; _ }
  | Orr { left; right; _ }
  | Eor { left; right; _ } -> [ left; right ]
  | Fsqrt { source; _ } | Mvn { source; _ } -> [ source ]
  | Fma { multiplicand; multiplier; addend; _ } ->
      [ multiplicand; multiplier; addend ]
  | Select { mask; if_true; if_false; _ } -> [ mask; if_true; if_false ]

let provenance = function
  | Uniform_f32 { provenance; _ }
  | Mask_const { provenance; _ }
  | Broadcast_f32 { provenance; _ }
  | Fadd { provenance; _ }
  | Fsub { provenance; _ }
  | Fmul { provenance; _ }
  | Fdiv { provenance; _ }
  | Fsqrt { provenance; _ }
  | Fma { provenance; _ }
  | Compare { provenance; _ }
  | Select { provenance; _ }
  | And { provenance; _ }
  | Orr { provenance; _ }
  | Eor { provenance; _ }
  | Mvn { provenance; _ } -> provenance

let value_location func value =
  Option.value (List.assoc_opt value func.value_locations) ~default:func.loc

let instruction_name = function
  | Uniform_f32 _ -> "uniform.f32"
  | Mask_const _ -> "mask.const"
  | Broadcast_f32 _ -> "dup.scalar.f32"
  | Fadd _ -> "fadd"
  | Fsub _ -> "fsub"
  | Fmul _ -> "fmul"
  | Fdiv _ -> "fdiv"
  | Fsqrt _ -> "fsqrt"
  | Fma _ -> "fmla"
  | Compare _ -> "fcmp"
  | Select _ -> "select"
  | And _ -> "and"
  | Orr _ -> "orr"
  | Eor _ -> "eor"
  | Mvn _ -> "mvn"
