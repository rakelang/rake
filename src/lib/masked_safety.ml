(** Audited operation policy for predicated [through] blocks.

    A native profile may speculate an operation across inactive lanes only
    after replacing every floating-point operand in those lanes with the safe
    values described here. The checker exposes one target-independent semantic
    contract; each native profile must prove that its lowering preserves it. *)

open Ast

type builtin = Sanitized | Unsupported

let classify_builtin = function
  | "sqrt" | "sin" | "cos" | "tan" | "exp" | "log" | "abs"
  | "floor" | "ceil" | "min" | "max" | "pow" | "atan2" | "select" ->
      Sanitized
  | _ -> Unsupported

let supports_binop = function Mod -> false | _ -> true

(** A benign value for an inactive operand of a binary floating-point op.
    Multiplication and division use one so sanitization cannot manufacture
    [0 * infinity].  Other arithmetic and comparisons use zero. *)
let binop_operand op operand_index =
  match op with
  | Mul -> 1.0
  | Div -> if operand_index = 0 then 0.0 else 1.0
  | _ -> 0.0

(** Benign inactive arguments for supported math built-ins. *)
let builtin_operand name operand_index =
  match name with
  | "sqrt" | "log" | "pow" -> 1.0
  | "atan2" -> if operand_index = 0 then 0.0 else 1.0
  | _ -> 0.0

let fma_operand _operand_index = 0.0
