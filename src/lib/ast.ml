(** Rake abstract syntax tree

    Core design: Tines declare masks, Through executes under masks,
    Sweep collects results. Data "rakes through" tine patterns.
*)

(** Source location for error reporting *)
type loc = {
  file: string;
  line: int;
  col: int;
  offset: int;
}
[@@deriving show]

let dummy_loc = { file = "<none>"; line = 0; col = 0; offset = 0 }

(** AST node with location *)
type 'a node = { v: 'a; loc: loc }
[@@deriving show]

let node v loc = { v; loc }
let node_v n = n.v
let node_loc n = n.loc

(** Identifiers *)
type ident = string
[@@deriving show]

(** Primitive scalar types *)
type prim =
  | PFloat | PDouble
  | PInt | PInt8 | PInt16 | PInt64
  | PUint | PUint8 | PUint16 | PUint64
  | PBool
[@@deriving show]

(** Compound types (vec2, vec3, etc.) *)
type compound =
  | CVec2 | CVec3 | CVec4
  | CMat3 | CMat4
[@@deriving show]

(** Type expressions *)
type typ = typ_kind node
and typ_kind =
  | TRack of prim                      (** float rack *)
  | TCompoundRack of compound          (** vec3 rack *)
  | TScalar of prim                    (** scalar float (uniform) *)
  | TCompoundScalar of compound        (** scalar vec3 *)
  | TStack of ident                    (** Particle stack *)
  | TPack of ident                     (** Particle pack *)
  | TSingle of ident                   (** Config single *)
  | TMask                              (** boolean rack (tine result) *)
  | TFun of typ list * typ             (** function type *)
  | TTuple of typ list                 (** (a, b, c) *)
  | TUnit                              (** () *)
[@@deriving show]

(** Binary operators *)
type binop =
  (* Arithmetic *)
  | Add | Sub | Mul | Div | Mod
  (* Comparison (produce masks) *)
  | Lt | Le | Gt | Ge | Eq | Ne
  (* Logical (for masks) *)
  | And | Or
  (* Pipeline *)
  | Pipe
  (** Legacy representation retained while downstream semantic passes migrate.
      The parser never produces these constructors; lane shifts and rotates
      use [EShift] and [ERotate]. *)
  | Shl | Shr | Rol | Ror
  (** Low-half lane zip. Unlike shifts and rotates, interleave is an ordinary
      two-rack binary form. *)
  | Interleave
[@@deriving show]

(** Direction in which lane values move within a rack. *)
type lane_direction = Left | Right
[@@deriving show]

(** Unary operators *)
type unop =
  | Neg     (** -x (arithmetic) *)
  | FNeg    (** -x (floating) *)
  | Not     (** !x (logical) *)
[@@deriving show]

(** Reduction operators *)
type reduceop =
  | RAdd | RMul | RMin | RMax | RAnd | ROr
[@@deriving show]

(** Expressions *)
type expr = expr_kind node
and expr_kind =
  (* Literals *)
  | EInt of int64                      (** 42 *)
  | EFloat of float                    (** 3.14 *)
  | EBool of bool                      (** true, false *)

  (* Variables *)
  | EVar of ident                      (** x (rack variable) *)
  | EScalarVar of ident                (** <x> (scalar, broadcasts) *)

  (* Operators *)
  | EBinop of expr * binop * expr      (** a + b *)
  | EUnop of unop * expr               (** -x *)

  (* Functions *)
  | ECall of ident * expr list         (** f(a, b, c) *)
  | ELambda of param list * expr       (** fun x y -> body *)
  | EPipe of expr * expr               (** x |> f *)
  | EFusedPipe of expr * expr          (** x <| f (reserved optimization contract) *)

  (* Bindings *)
  | ELet of binding * expr             (** let x = e1 in e2 *)

  (* Records *)
  | EField of expr * ident             (** p.pos *)
  | ERecord of ident * field_init list (** Point { x := a, y := b } *)
  | EWith of expr * field_init list    (** { p with x := a } *)

  (* Lane operations *)
  | ELaneIndex                         (** @ (lane indices) *)
  | ELanes                             (** lanes (vector width) *)
  | EExtract of expr * expr            (** v@i (extract lane) *)
  | EInsert of expr * expr * expr      (** v@i := x *)

  (* Reductions and scans *)
  | EReduce of reduceop * expr         (** x \+/ *)
  | EScan of reduceop * expr           (** x \+\ *)

  (* Static lane rearrangement *)
  | EShuffle of expr * int list        (** v ~> [3,2,1,0] *)
  | EShift of expr * int * lane_direction  (** v << 2, v >> 2 *)
  | ERotate of expr * int * lane_direction (** v <<< 2, v >>> 2 *)

  (* Memory *)
  | EGather of expr * expr             (** base[offsets] *)
  | EScatter of expr * expr * expr     (** base[offsets] <- values *)
  | ECompress of expr * expr           (** v |> compress through mask *)
  | EExpand of expr * expr * expr      (** expand base through mask else passthru *)

  (* Divergence (tines, through, sweep) *)
  | ETines of tine list * through list * sweep

  (* FMA *)
  | EFma of expr * expr * expr         (** fma(a, b, c) *)

  (* Outer product *)
  | EOuter of expr * expr              (** a outer b *)

  (* Tuple *)
  | ETuple of expr list                (** (a, b, c) *)

  (* Broadcast (explicit) *)
  | EBroadcast of expr                 (** broadcast e *)

  (* Unit *)
  | EUnit                              (** () *)

(** Parameter: either rack (default), scalar (angle brackets), or spread type *)
and param =
  | PRack of ident * typ option        (** x or (x : float rack) *)
  | PScalar of ident * typ option      (** <x> or (<x> : float) *)
  | PSpread of ident list * ident      (** TypeName as x y z - spreads type fields to names *)

(** Binding in let expressions *)
and binding = {
  bind_name: ident;
  bind_type: typ option;
  bind_expr: expr;
}

(** Field initialization in records *)
and field_init = {
  init_field: ident;
  init_value: expr;
}

(** Tine: a named mask declaration
    | tine name := predicate
*)
and tine = {
  tine_name: ident;
  tine_pred: predicate;
}

(** Predicate for tine conditions *)
and predicate = predicate_kind node
and predicate_kind =
  | PExpr of expr                      (** arbitrary boolean expr *)
  | PCmp of expr * cmp_op * expr       (** x > y *)
  | PIs of expr * expr                 (** x is <val> *)
  | PIsNot of expr * expr              (** x is not <val> *)
  | PAnd of predicate * predicate      (** p && q *)
  | POr of predicate * predicate       (** p || q *)
  | PNot of predicate                  (** !p *)
  | PTineRef of ident                  (** reference another tine *)

and cmp_op = CLt | CLe | CGt | CGe | CEq | CNe

(** Through block: execute under a mask.
    through #tine else <passthrough> into result_binding:
      body
*)
and through = {
  through_tine: tine_ref;              (** which tine(s) to use *)
  through_passthru: expr option;       (** else value for inactive lanes *)
  through_body: stmt list;             (** statements in the block *)
  through_result: expr;                (** final expression *)
  through_binding: ident;              (** -> binding_name *)
}

and tine_ref =
  | TRSingle of ident                  (** through tine_name *)
  | TRComposed of predicate            (** through (a && b) *)

(** Sweep block: collect results from tines.
    return sweep:
      | #tine => value
      | _     => fallback
*)
and sweep = {
  sweep_arms: sweep_arm list;
  sweep_binding: ident;
}

and sweep_arm = {
  arm_tine: ident option;              (** None = catch-all _ *)
  arm_value: expr;
}

(** Location binding: introduces mutable storage *)
and loc_binding = {
  loc_name: ident;
  loc_type: typ option;
  loc_expr: expr;
}

(** Fused binding: pure expression subject to the inlineable-SSA contract *)
and fused_binding = {
  fused_name: ident;
  fused_type: typ option;
  fused_expr: expr;
}

(** Statements (in through/run blocks) *)
and stmt = stmt_kind node
and stmt_kind =
  | SLet of binding                    (** let x = e (SSA, immutable) *)
  | SLocBind of loc_binding            (** x := e (introduces mutable storage) *)
  | SAssign of ident * expr            (** x <- e (mutates existing location) *)
  | SFused of fused_binding            (** | x <| e (verified inlineable SSA) *)
  | SExpr of expr                      (** expression statement *)
  | SOver of over_loop                 (** for chunk in pack using f32s up to <count> *)

(** Pack traversal: iterate over storage in target-native rack chunks.
    for chunk in pack using f32s up to <count>:
      yield expression

    Expands to:
      for i = 0 to ceil(count / lanes):
        chunk = load_stack(pack, i * lanes)
        body (with tail masking on last iteration)
*)
and over_loop = {
  over_pack: ident;                    (** pack variable to iterate *)
  over_domain: prim;                   (** physical rack type fixing logical lanes *)
  over_count: expr;                    (** element count expression *)
  over_chunk: ident;                   (** binding for each stack chunk *)
  over_body: stmt list;                (** body executed per chunk *)
}

[@@deriving show]

(** Field in stack/single definitions *)
type field = {
  field_name: ident;
  field_type: typ;
}
[@@deriving show]

(** Top-level definitions *)
type def = def_kind node
and def_kind =
  (* Type definitions *)
  | DStack of ident * field list       (** stack Particle { ... } *)
  | DSingle of ident * field list      (** single Config { ... } *)
  | DType of ident * typ               (** type alias *)

  (* Function definitions *)
  | DCrunch of ident * param list * result_spec * stmt list
      (** crunch name(parameters) -> type: body return expression *)
  | DRake of ident * param list * result_spec * stmt list * tine list * through list * sweep
      (** rake name params -> result: setup tines through* sweep *)
  | DRun of ident * param list * result_spec * stmt list
      (** run name params -> result: body *)

and result_spec = {
  result_name: ident;
  result_type: typ option;
}
[@@deriving show]

(** Module *)
type module_ = {
  mod_name: ident;
  mod_defs: def list;
}
[@@deriving show]

(** Program: list of modules *)
type program = module_ list
[@@deriving show]
