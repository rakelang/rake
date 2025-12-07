(** Rake 0.2.0 Type System

    Runtime type representation and operations.
*)

open Ast

(** Scalar (element) types *)
type scalar =
  | SFloat | SDouble
  | SInt | SInt8 | SInt16 | SInt64
  | SUint | SUint8 | SUint16 | SUint64
  | SBool
[@@deriving show, eq]

(** Compound types *)
type compound =
  | CVec2 | CVec3 | CVec4
  | CMat3 | CMat4
[@@deriving show, eq]

(** Field type for structs *)
type field = string * t

(** Runtime types *)
and t =
  | Rack of scalar                     (** vector<N x scalar> *)
  | CompoundRack of compound           (** vector of compound *)
  | Scalar of scalar                   (** single scalar value *)
  | CompoundScalar of compound         (** single compound value *)
  | Stack of ident * field list        (** SoA struct type *)
  | Pack of ident * field list         (** collection of stacks *)
  | Single of ident * field list       (** all-scalar struct *)
  | Mask                               (** boolean vector (tine result) *)
  | Fun of t list * t                  (** function type *)
  | Tuple of t list                    (** tuple type *)
  | Unit                               (** unit type *)
  | Unknown                            (** placeholder for inference *)
[@@deriving show]

(** Convert AST primitive to scalar *)
let of_prim = function
  | PFloat -> SFloat
  | PDouble -> SDouble
  | PInt -> SInt
  | PInt8 -> SInt8
  | PInt16 -> SInt16
  | PInt64 -> SInt64
  | PUint -> SUint
  | PUint8 -> SUint8
  | PUint16 -> SUint16
  | PUint64 -> SUint64
  | PBool -> SBool

(** Convert AST compound to compound *)
let of_compound = function
  | Ast.CVec2 -> CVec2
  | Ast.CVec3 -> CVec3
  | Ast.CVec4 -> CVec4
  | Ast.CMat3 -> CMat3
  | Ast.CMat4 -> CMat4

(** Is this a rack (vector) type? *)
let is_rack = function
  | Rack _ | CompoundRack _ | Mask -> true
  | _ -> false

(** Is this a scalar (uniform) type? *)
let is_scalar = function
  | Scalar _ | CompoundScalar _ -> true
  | _ -> false

(** Is this a numeric type? *)
let is_numeric = function
  | Rack s | Scalar s -> (
      match s with
      | SFloat | SDouble | SInt | SInt8 | SInt16 | SInt64
      | SUint | SUint8 | SUint16 | SUint64 -> true
      | SBool -> false)
  | CompoundRack _ | CompoundScalar _ -> true
  | _ -> false

(** Is this a floating-point type? *)
let is_float = function
  | Rack SFloat | Rack SDouble
  | Scalar SFloat | Scalar SDouble
  | CompoundRack _ | CompoundScalar _ -> true
  | _ -> false

(** Broadcast a scalar to a rack *)
let broadcast = function
  | Scalar s -> Rack s
  | CompoundScalar c -> CompoundRack c
  | t -> t  (* already a rack or other *)

(** Get element type of a rack *)
let element_type = function
  | Rack s -> Scalar s
  | CompoundRack c -> CompoundScalar c
  | Mask -> Scalar SBool
  | t -> t

(** Binary operation result type *)
let binop_result t1 t2 =
  match (t1, t2) with
  (* Rack + Rack -> Rack *)
  | Rack s1, Rack s2 when s1 = s2 -> Rack s1
  (* Rack + Scalar -> Rack (broadcast) *)
  | Rack s, Scalar _ -> Rack s
  | Scalar _, Rack s -> Rack s
  (* Float takes precedence *)
  | Rack SFloat, _ | _, Rack SFloat -> Rack SFloat
  | Rack SDouble, _ | _, Rack SDouble -> Rack SDouble
  (* Default to first operand *)
  | t, _ -> t

(** Comparison result type (always mask) *)
let cmp_result _t1 _t2 = Mask

(** Pretty-print type *)
let rec show_concise = function
  | Rack s -> show_scalar s ^ " rack"
  | CompoundRack c -> show_compound c ^ " rack"
  | Scalar s -> show_scalar s
  | CompoundScalar c -> show_compound c
  | Stack (name, _) -> name ^ " stack"
  | Pack (name, _) -> name ^ " pack"
  | Single (name, _) -> name ^ " single"
  | Mask -> "mask"
  | Fun (args, ret) ->
      "(" ^ String.concat ", " (List.map show_concise args) ^
      ") -> " ^ show_concise ret
  | Tuple ts ->
      "(" ^ String.concat ", " (List.map show_concise ts) ^ ")"
  | Unit -> "()"
  | Unknown -> "?"
