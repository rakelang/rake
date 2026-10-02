(** The frontend semantic contract.

    The parser intentionally recognizes more syntax than the type checker can
    validate.  A [Checked] entry means that the frontend defines and checks the
    construct's semantics; it does not claim that every production backend can
    lower it.  Native lowering is a separate, stricter compiler gate. *)

open Ast

type target = Frontend
type status = Checked | Reserved | Unavailable

type feature =
  | Type_float_rack | Type_scalar | Type_mask | Type_stack | Type_pack
  | Type_single | Type_compound_rack | Type_compound_scalar
  | Type_function | Type_tuple | Type_unit
  | Primitive_float | Primitive_int | Primitive_int64 | Primitive_other
  | Def_stack | Def_single | Def_alias | Def_crunch | Def_rake | Def_run
  | Param_rack | Param_scalar | Param_spread
  | Result_annotation
  | Expr_int | Expr_float | Expr_bool | Expr_var | Expr_scalar_var
  | Expr_arithmetic | Expr_comparison | Expr_mask_logic
  | Expr_pipeline_operator | Expr_shift_rotate | Expr_interleave
  | Expr_negate | Expr_not | Expr_call | Expr_lambda | Expr_pipeline
  | Expr_fused_pipeline | Expr_let | Expr_field | Expr_record
  | Expr_record_update | Expr_lane_index | Expr_lane_count
  | Expr_extract | Expr_insert | Expr_reduce | Expr_scan | Expr_shuffle
  | Expr_gather | Expr_scatter | Expr_compress | Expr_expand
  | Expr_inline_tines | Expr_fma | Expr_outer | Expr_tuple
  | Expr_broadcast | Expr_unit
  | Stmt_let | Stmt_location | Stmt_assign | Stmt_fused
  | Stmt_expression | Stmt_over
  | Predicate_expr | Predicate_comparison | Predicate_is
  | Predicate_and | Predicate_or | Predicate_not | Predicate_tine_ref
  | Rake_tines | Rake_through | Rake_sweep
  | Masked_user_call | Masked_modulo | Masked_mutation | Masked_loop
  | Masked_cross_lane
  | Integer_rack_comparison | Bitmask_reduction
  | Integer_rack_arithmetic | Integer_rack_conversion | Integer_rack_bits
  | Crunch_scalar_param | Rake_spread_param | Run_spread_param
  | Crunch_implicit_result | Value_non_f32 | Pack_non_f32_field
  | Result_non_float_rack
  (* The slow tier, general runs and control flow *)
  | Type_array | Type_view | Type_pointer | Type_mutable | Type_record
  | Def_record | Def_slow | Def_extern | Def_state | Def_embed | Def_const
  | Expr_string | Expr_index | Expr_conversion | Expr_if | Expr_array | Expr_slow
  | Stmt_store | Stmt_return | Stmt_yield | Stmt_break | Stmt_continue
  | Stmt_if | Stmt_while | Stmt_loop | Stmt_repeat | Stmt_uniform

type entry = {
  feature : feature;
  id : string;
  category : string;
  description : string;
  frontend : status;
}

let entry feature id category description status =
  { feature; id; category; description; frontend = status }

let supported feature id category description =
  entry feature id category description Checked

let experimental feature id category description =
  entry feature id category description Reserved

let unavailable feature id category description =
  entry feature id category description Unavailable

let all = [
  supported Type_float_rack "type.float-rack" "type" "float rack values";
  supported Type_scalar "type.scalar" "type" "scalar type syntax";
  supported Type_mask "type.mask" "type" "lane masks";
  supported Type_stack "type.stack" "type" "stack references";
  supported Type_pack "type.pack" "type" "pack references";
  unavailable Type_single "type.single" "type" "single references";
  unavailable Type_compound_rack "type.compound-rack" "type" "compound racks";
  unavailable Type_compound_scalar "type.compound-scalar" "type" "compound scalars";
  supported Type_function "type.function" "type" "typed C function pointers in slow code";
  unavailable Type_tuple "type.tuple" "type" "tuple types";
  unavailable Type_unit "type.unit" "type" "unit type";
  supported Primitive_float "primitive.float" "type" "32-bit float";
  supported Primitive_int "primitive.int" "type" "run-loop scalar int";
  supported Primitive_int64 "primitive.int64" "type" "run-loop scalar int64";
  supported Primitive_other "primitive.other" "type" "fixed-width primitive storage and rack types";
  supported Def_stack "definition.stack" "definition" "stack declarations";
  unavailable Def_single "definition.single" "definition" "single declarations";
  unavailable Def_alias "definition.type-alias" "definition" "type aliases";
  supported Def_crunch "definition.crunch" "definition" "crunch semantic checks";
  supported Def_rake "definition.rake" "definition" "rake semantic checks";
  supported Def_run "definition.run" "definition" "run semantic checks";
  supported Param_rack "parameter.rack" "parameter" "rack parameters";
  supported Param_scalar "parameter.scalar" "parameter" "scalar parameters where target ABI permits";
  unavailable Param_spread "parameter.spread" "parameter" "spread parameters";
  supported Result_annotation "result.annotation" "result" "explicit result annotations";
  supported Expr_int "expression.integer-literal" "expression" "integer literals, typed by the rack or scalar beside them";
  supported Expr_float "expression.float-literal" "expression" "float literals";
  supported Expr_bool "expression.bool-literal" "expression" "mask literals";
  supported Expr_var "expression.variable" "expression" "rack variables";
  supported Expr_scalar_var "expression.scalar-variable" "expression" "scalar variables";
  supported Expr_arithmetic "operator.arithmetic" "operator" "arithmetic of racks and of slow and uniform scalars";
  supported Expr_comparison "operator.comparison" "operator" "comparisons of racks and scalars";
  supported Expr_mask_logic "operator.mask-logic" "operator" "mask logic";
  unavailable Expr_pipeline_operator "operator.pipeline" "operator" "binary pipeline operator";
  unavailable Expr_shift_rotate "operator.shift-rotate" "operator" "shift and rotate operators";
  unavailable Expr_interleave "operator.interleave" "operator" "interleave operator";
  supported Expr_negate "operator.negate" "operator" "negation of float and signed integer racks and scalars";
  supported Expr_not "operator.not" "operator" "mask negation";
  supported Expr_call "expression.call" "expression" "built-in and checked function calls";
  unavailable Expr_lambda "expression.lambda" "expression" "lambda expressions";
  unavailable Expr_pipeline "expression.pipeline" "expression" "expression pipelines";
  unavailable Expr_fused_pipeline "expression.fused-pipeline" "expression" "fused expression pipelines";
  unavailable Expr_let "expression.let" "expression" "let expressions (no source syntax)";
  supported Expr_field "expression.field" "expression" "field access";
  supported Expr_record "expression.record" "expression" "record and pack literals in slow code";
  unavailable Expr_record_update "expression.record-update" "expression" "record updates";
  unavailable Expr_lane_index "expression.lane-index" "expression" "zero-based profile-resolved rack lane index (reserved; no lowering yet)";
  unavailable Expr_lane_count "expression.lane-count" "expression" "profile-resolved rack lane count (reserved; no lowering yet)";
  supported Expr_extract "expression.lane-extract" "expression" "extract(rack, lane): one lane as a uniform scalar, lane a literal";
  supported Expr_insert "expression.lane-insert" "expression" "insert(rack, lane, <value>): a rack with one lane replaced, lane a literal";
  supported Expr_reduce "expression.reduction" "expression"
    "strict ascending-lane f32 reductions";
  supported Expr_scan "expression.scan" "expression"
    "strict inclusive f32 prefix scans";
  supported Expr_shuffle "expression.shuffle" "expression"
    "static lane shuffles of one rack, or of two equal racks laid end to end";
  supported Expr_gather "expression.gather" "expression" "gathers: view[indices] with an i32s index rack in a run, checked unless written unchecked";
  unavailable Expr_scatter "expression.scatter" "expression" "scatters: no profile stores lanes to rack-chosen indices without a scalar lane loop";
  unavailable Expr_compress "expression.compress" "expression" "compression";
  unavailable Expr_expand "expression.expand" "expression" "expansion";
  unavailable Expr_inline_tines "expression.inline-tines" "expression" "inline tines";
  {
    feature = Expr_fma;
    id = "expression.fma";
    category = "expression";
    description = "explicit fused multiply-add with one rounded result";
    frontend = Checked;
  };
  unavailable Expr_outer "expression.outer" "expression" "outer products";
  unavailable Expr_tuple "expression.tuple" "expression" "tuple expressions";
  supported Expr_broadcast "expression.broadcast" "expression" "explicit scalar broadcast";
  unavailable Expr_unit "expression.unit" "expression" "unit expressions";
  supported Stmt_let "statement.let" "statement" "SSA let bindings";
  supported Stmt_location "statement.location" "statement" "mutable location bindings";
  supported Stmt_assign "statement.assignment" "statement" "location assignment";
  supported Stmt_fused "statement.fused" "statement" "verified pure inlineable-SSA bindings";
  supported Stmt_expression "statement.expression" "statement" "expression statements";
  supported Stmt_over "statement.over" "statement" "pack iteration";
  unavailable Predicate_expr "predicate.expression" "predicate" "mask expressions as predicates (no source syntax)";
  supported Predicate_comparison "predicate.comparison" "predicate" "comparisons";
  unavailable Predicate_is "predicate.is" "predicate" "is and is-not comparisons (no source syntax)";
  supported Predicate_and "predicate.and" "predicate" "predicate conjunction";
  supported Predicate_or "predicate.or" "predicate" "predicate disjunction";
  supported Predicate_not "predicate.not" "predicate" "predicate negation";
  supported Predicate_tine_ref "predicate.tine-reference" "predicate" "tine references";
  supported Rake_tines "rake.tines" "rake" "named tine declarations";
  supported Rake_through "rake.through" "rake" "through blocks";
  supported Rake_sweep "rake.sweep" "rake" "sweep selection";
  unavailable Masked_user_call "masked.user-call" "masked" "user-defined calls inside through blocks";
  unavailable Masked_modulo "masked.modulo" "masked" "modulo inside through blocks";
  unavailable Masked_mutation "masked.mutation" "masked" "mutable bindings and assignments inside through blocks";
  unavailable Masked_loop "masked.loop" "masked" "over loops inside through blocks";
  unavailable Masked_cross_lane "masked.cross-lane" "masked"
    "reductions and scans inside through blocks";
  supported Integer_rack_comparison "operator.integer-rack-comparison" "operator"
    "comparisons of equal integer racks, or of an integer rack with an integer literal";
  supported Bitmask_reduction "expression.bitmask" "expression"
    "bitmask(mask): one bit per lane as a u32, lane zero in bit zero";
  supported Integer_rack_arithmetic "operator.integer-rack-arithmetic" "operator"
    "+ and - of equal i16 or i32 racks, wrapping, and their min and max, against a rack or an integer literal";
  supported Integer_rack_conversion "expression.integer-rack-conversion" "expression"
    "dot of i16 racks into i32, narrow of i32 racks into saturated i16, widen_low and widen_high of u8 racks into i16, to_f32 of i32 racks and to_i32 of f32 racks";
  supported Integer_rack_bits "expression.integer-rack-bits" "expression"
    "bit_and, bit_or, bit_xor and bit_andnot of equal integer racks, and shift_bits_left, shift_bits_right and shift_bits_right_signed of an integer rack by an integer literal or a uniform u32";
  supported Crunch_scalar_param "crunch.scalar-parameter" "boundary"
    "explicit uniform f32 and u32 crunch parameters";
  unavailable Rake_spread_param "rake.spread-parameter" "boundary" "spread rake parameters";
  unavailable Run_spread_param "run.spread-parameter" "boundary" "spread run parameters";
  supported Crunch_implicit_result "crunch.implicit-result" "boundary" "a crunch's final expression supplies its result";
  supported Value_non_f32 "value.non-f32" "boundary" "typed non-f32 frontend values";
  supported Pack_non_f32_field "pack.non-f32-field" "boundary" "mixed-width pack storage fields";
  supported Result_non_float_rack "result.non-float-rack" "boundary"
    "typed non-f32 frontend rack results";
  supported Type_array "type.array" "type" "[N]T: fixed arrays in memory, or rack arrays held in registers";
  supported Type_view "type.view" "type" "[]T: a borrowed run of elements with a runtime count";
  supported Type_pointer "type.pointer" "type" "ptr T: C pointers for extern interoperation, accessed unchecked";
  supported Type_mutable "type.mutable" "type" "mut T: parameters the callee may write";
  supported Type_record "type.record" "type" "records, with Rake or C layout";
  supported Def_record "definition.record" "definition" "record declarations, including C structs named by header";
  supported Def_slow "definition.slow" "definition" "slow functions: scalar orchestration code";
  supported Def_extern "definition.extern" "definition" "extern slow declarations of C functions";
  supported Def_state "definition.state" "definition" "module state that persists across calls";
  supported Def_embed "definition.embed" "definition" "embedded constant bytes from a file";
  supported Def_const "definition.const" "definition" "compile-time constants";
  supported Expr_string "expression.string" "expression" "string literals";
  supported Expr_index "expression.index" "expression" "element, rack and gather indexing, checked or unchecked";
  supported Expr_conversion "expression.conversion" "expression" "checked, wrapping and bit-cast scalar conversions";
  supported Expr_if "expression.if" "expression" "value-producing if, by scalar condition or rack mask";
  supported Expr_slow "expression.slow-block" "expression" "lexically scoped scalar escape in runs and slow functions";
  supported Expr_array "expression.array" "expression" "array literals";
  supported Stmt_store "statement.store" "statement" "stores to fields, elements and memory";
  supported Stmt_return "statement.return" "statement" "return";
  supported Stmt_yield "statement.yield" "statement" "yield, ending a traversal";
  supported Stmt_break "statement.break" "statement" "break";
  supported Stmt_continue "statement.continue" "statement" "continue";
  supported Stmt_if "statement.if" "statement" "if, else if and else statements";
  supported Stmt_while "statement.while" "statement" "while loops";
  supported Stmt_loop "statement.loop" "statement" "counted for loops";
  supported Stmt_repeat "statement.repeat" "statement" "fixed-count repeat, unrolled";
  supported Stmt_uniform "statement.uniform" "statement" "let <name: T> = e: a uniform scalar binding in vector code";
]

let find feature =
  List.find (fun entry -> entry.feature = feature) all

let status target feature =
  let entry = find feature in
  match target with Frontend -> entry.frontend

let is_available target feature = status target feature <> Unavailable
let id feature = (find feature).id
let description feature = (find feature).description

let string_of_target Frontend = "frontend"
let string_of_status = function
  | Checked -> "checked"
  | Reserved -> "reserved"
  | Unavailable -> "unavailable"

let feature_of_prim = function
  | PFloat -> Primitive_float
  | PInt -> Primitive_int
  | PInt64 -> Primitive_int64
  | PDouble | PInt8 | PInt16 | PUint | PUint8 | PUint16 | PUint64 | PBool ->
      Primitive_other

let feature_of_type = function
  | TRack PFloat -> Type_float_rack
  | TRack _ -> Value_non_f32
  | TCompoundRack _ -> Type_compound_rack
  | TScalar _ -> Type_scalar
  | TCompoundScalar _ -> Type_compound_scalar
  | TStack _ -> Type_stack
  | TPack _ -> Type_pack
  | TSingle _ -> Type_single
  | TMask -> Type_mask
  | TFun _ -> Type_function
  | TTuple _ -> Type_tuple
  | TUnit -> Type_unit
  | TArray _ -> Type_array | TView _ -> Type_view | TPtr _ -> Type_pointer
  | TMut _ -> Type_mutable | TNamed _ -> Type_record

let feature_of_binop = function
  | Add | Sub | Mul | Div | Mod -> Expr_arithmetic
  | Lt | Le | Gt | Ge | Eq | Ne -> Expr_comparison
  | And | Or -> Expr_mask_logic
  | Pipe -> Expr_pipeline_operator
  | Shl | Shr | Rol | Ror -> Expr_shift_rotate
  | Interleave -> Expr_interleave

let feature_of_unop = function Neg | FNeg -> Expr_negate | Not -> Expr_not

let feature_of_expr = function
  | ESlow _ -> Expr_slow
  | EInt _ -> Expr_int | EFloat _ -> Expr_float | EBool _ -> Expr_bool
  | EVar _ -> Expr_var | EScalarVar _ -> Expr_scalar_var
  | EBinop (_, op, _) -> feature_of_binop op
  | EUnop (op, _) -> feature_of_unop op
  | ECall _ -> Expr_call | ELambda _ -> Expr_lambda
  | EPipe _ -> Expr_pipeline | EFusedPipe _ -> Expr_fused_pipeline
  | ELet _ -> Expr_let | EField _ -> Expr_field | ERecord _ -> Expr_record
  | EWith _ -> Expr_record_update | ELaneIndex -> Expr_lane_index
  | ELanes -> Expr_lane_count | EExtract _ -> Expr_extract
  | EInsert _ -> Expr_insert | EReduce _ -> Expr_reduce | EScan _ -> Expr_scan
  | EShuffle _ -> Expr_shuffle | EShift _ | ERotate _ -> Expr_shift_rotate
  | EGather _ -> Expr_gather | EScatter _ -> Expr_scatter
  | ECompress _ -> Expr_compress | EExpand _ -> Expr_expand
  | ETines _ -> Expr_inline_tines | EFma _ -> Expr_fma | EOuter _ -> Expr_outer
  | ETuple _ -> Expr_tuple | EBroadcast _ -> Expr_broadcast | EUnit -> Expr_unit
  | EString _ -> Expr_string | EIndex _ -> Expr_index | EConvert _ -> Expr_conversion
  | EIf _ -> Expr_if | EArray _ -> Expr_array

let feature_of_param = function
  | PRack _ -> Param_rack | PScalar _ -> Param_scalar | PSpread _ -> Param_spread

let feature_of_stmt = function
  | SLet _ -> Stmt_let | SLocBind _ -> Stmt_location
  | SAssign _ -> Stmt_assign | SFused _ -> Stmt_fused
  | SExpr _ -> Stmt_expression | SOver _ -> Stmt_over
  | SUniform _ -> Stmt_uniform | SStore _ -> Stmt_store | SReturn _ -> Stmt_return | SYield _ -> Stmt_yield
  | SBreak -> Stmt_break | SContinue -> Stmt_continue | SIf _ -> Stmt_if
  | SWhile _ -> Stmt_while | SLoop { loop_repeat = true; _ } -> Stmt_repeat | SLoop _ -> Stmt_loop

let feature_of_predicate = function
  | PExpr _ -> Predicate_expr | PCmp _ -> Predicate_comparison
  | PIs _ | PIsNot _ -> Predicate_is | PAnd _ -> Predicate_and
  | POr _ -> Predicate_or | PNot _ -> Predicate_not
  | PTineRef _ -> Predicate_tine_ref

let feature_of_def = function
  | DStack _ -> Def_stack | DSingle _ -> Def_single | DType _ -> Def_alias
  | DCrunch _ -> Def_crunch | DRake _ -> Def_rake | DRun _ -> Def_run
  | DRecord _ -> Def_record | DSlow _ -> Def_slow | DExtern _ -> Def_extern
  | DState _ -> Def_state | DEmbed _ -> Def_embed | DConst _ -> Def_const

let print oc =
  output_string oc "rake-capabilities-v2\ncontract\tstatus\tfeature\tcategory\tdescription\n";
  List.iter
    (fun entry ->
      Printf.fprintf oc "%s\t%s\t%s\t%s\t%s\n"
        (string_of_target Frontend)
        (string_of_status entry.frontend) entry.id entry.category
        entry.description)
    all
