(** Rake parser

    Grammar for the tine/through/sweep execution model.

    Design principle: Separate mask declaration from masked computation.
    - Tines (#name) declare masks with predicates
    - Through blocks execute under tines (by #reference)
    - Sweep collects results based on which tines matched

    The # symbol evokes grid lines / SIMD lane masks.
*)

%{
open Ast

let mk_loc startpos _endpos = {
  file = startpos.Lexing.pos_fname;
  line = startpos.Lexing.pos_lnum;
  col = startpos.Lexing.pos_cnum - startpos.Lexing.pos_bol;
  offset = startpos.Lexing.pos_cnum;
}

let mk_node v startpos endpos = { v; loc = mk_loc startpos endpos }

(* This name cannot be written by a Rake program, so an explicit return can be
   represented by the existing named-result lowering without a collision. *)
let canonical_result_name = "$return"

let result_of_type ty = {
  result_name = canonical_result_name;
  result_type = Some ty;
}

let return_binding expression startpos endpos =
  mk_node (SLet {
    bind_name = canonical_result_name;
    bind_type = None;
    bind_expr = expression;
  }) startpos endpos

let named_call name arguments =
  match name, arguments with
  | "sum", [operand] -> EReduce (RAdd, operand)
  | "product", [operand] -> EReduce (RMul, operand)
  | "minimum", [operand] -> EReduce (RMin, operand)
  | "maximum", [operand] -> EReduce (RMax, operand)
  | "all", [operand] -> EReduce (RAnd, operand)
  | "any", [operand] -> EReduce (ROr, operand)
  | "scan_sum", [operand] -> EScan (RAdd, operand)
  | "scan_product", [operand] -> EScan (RMul, operand)
  | "scan_minimum", [operand] -> EScan (RMin, operand)
  | "scan_maximum", [operand] -> EScan (RMax, operand)
  | "zip_low", [left; right] -> EBinop (left, Interleave, right)
  | _ -> ECall (name, arguments)

%}

(* Tokens: Types *)
%token BOOL
%token F32 F64 I32 I8 I16 I64 U32 U8 U16 U64
%token F32S F64S I32S I8S I16S I64S U32S U8S U16S U64S BOOLS
%token MASK STACK PACK

(* Tokens: Functions *)
%token CRUNCH RAKE RUN

(* Tokens: Tines and control *)
%token <string> TINE_REF
%token TINE WHEN THROUGH SWEEP ELSE INTO RETURN YIELD IN

(* Tokens: Iteration *)
%token FOR USING UP TO

(* Tokens: Bindings *)
%token LET

(* Tokens: Lane operations *)
%token LANES FMA SHUFFLE_FN SHIFT_LEFT_FN SHIFT_RIGHT_FN
%token ROTATE_LEFT_FN ROTATE_RIGHT_FN

(* Tokens: Boolean *)
%token TRUE FALSE NOT AND OR

(* Tokens: Operators *)
%token PLUS MINUS STAR SLASH PERCENT
%token LT LE GT GE EQ NE
%token FUSED_LEFT ARROW FAT_ARROW ASSIGN COLONEQ

(* Tokens: Delimiters *)
%token LPAREN RPAREN LBRACE RBRACE LBRACKET RBRACKET
%token COMMA COLON SEMICOLON PIPE_CHAR AT DOT UNDERSCORE

(* Tokens: Literals *)
%token <int64> INT_LIT
%token <float> FLOAT_LIT
%token <float> SCALAR_FLOAT_LIT
%token <int64> SCALAR_INT_LIT
%token <string> IDENT
%token <string> TYPE_IDENT
%token <string> SCALAR_IDENT

%token EOF

%start <Ast.program> program

%%

(* ═══════════════════════════════════════════════════════════════════ *)
(* Program structure                                                    *)
(* ═══════════════════════════════════════════════════════════════════ *)

program:
  | ds = nonempty_list(definition) EOF {
      [ { mod_name = "main"; mod_defs = ds } ]
    }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Definitions                                                          *)
(* ═══════════════════════════════════════════════════════════════════ *)

definition:
  | d = stack_def { d }
  | d = crunch_def { d }
  | d = rake_def { d }
  | d = run_def { d }

(* stack Particle { f32: position, velocity; u8: age; } *)
stack_def:
  | STACK name = TYPE_IDENT LBRACE groups = nonempty_list(field_group) RBRACE {
      mk_node (DStack (name, List.concat groups)) $startpos $endpos
    }

field_group:
  | p = storage_type COLON names = separated_nonempty_list(COMMA, IDENT) SEMICOLON {
      List.map (fun name ->
        { field_name = name; field_type = mk_node (TScalar p) $startpos $endpos }) names
    }

storage_type:
  | p = prim_type { p }

(* crunch name(parameters) -> result-type: body return expression *)
crunch_def:
  (* Canonical: crunch name(parameters) -> result-type: ... return expression *)
  | CRUNCH name = IDENT LPAREN ps = separated_list(COMMA, crunch_param) RPAREN
    ARROW result_type = typ COLON body = list(stmt) RETURN value = expr {
      let result = result_of_type result_type in
      let returned = return_binding value $startpos(value) $endpos(value) in
      mk_node (DCrunch (name, List.concat ps, result, body @ [returned]))
        $startpos $endpos
    }
(* Parameters inside parenthesized crunch definition *)
crunch_param:
  (* Typed rack or pack parameter. *)
  | name = IDENT COLON t = typ { [PRack (name, Some t)] }
  (* Canonical typed scalar: <name: type> *)
  | LT name = IDENT COLON t = typ GT { [PScalar (name, Some t)] }

(* Rake definitions add source-ordered tines, guarded through regions,
   and a total priority sweep to the typed parameter/result form. *)

rake_def:
  | RAKE name = IDENT LPAREN ps = separated_list(COMMA, crunch_param) RPAREN
    ARROW result_type = typ COLON
    setup = rake_setup
    ts = nonempty_list(canonical_tine_decl)
    ths = nonempty_list(canonical_through_block)
    RETURN SWEEP COLON arms = nonempty_list(canonical_sweep_arm) {
      let result = result_of_type result_type in
      let sweep = { sweep_arms = arms; sweep_binding = canonical_result_name } in
      mk_node (DRake (name, List.concat ps, result, setup, ts, ths, sweep))
        $startpos $endpos
    }

(* Setup statements before tines (let bindings for computation shared by all tines) *)
rake_setup:
  | ss = list(rake_setup_stmt) { ss }

rake_setup_stmt:
  | LET b = binding { mk_node (SLet b) $startpos $endpos }

(* run name params -> result: body *)
run_def:
  | RUN name = IDENT LPAREN ps = separated_list(COMMA, crunch_param) RPAREN
    ARROW result_type = typ COLON traversal = canonical_traversal {
      mk_node (DRun
        (name, List.concat ps, result_of_type result_type, [traversal]))
        $startpos $endpos
    }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Types                                                                *)
(* ═══════════════════════════════════════════════════════════════════ *)

typ:
  | t = rack_prim_type { mk_node (TRack t) $startpos $endpos }
  | t = prim_type { mk_node (TScalar t) $startpos $endpos }
  | STACK name = TYPE_IDENT { mk_node (TStack name) $startpos $endpos }
  | PACK name = TYPE_IDENT { mk_node (TPack name) $startpos $endpos }
  | MASK { mk_node TMask $startpos $endpos }

prim_type:
  | F32 { PFloat }
  | F64 { PDouble }
  | I32 { PInt }
  | I8 { PInt8 }
  | I16 { PInt16 }
  | I64 { PInt64 }
  | U32 { PUint }
  | U8 { PUint8 }
  | U16 { PUint16 }
  | U64 { PUint64 }
  | BOOL { PBool }

rack_prim_type:
  | F32S { PFloat } | F64S { PDouble }
  | I32S { PInt } | I8S { PInt8 } | I16S { PInt16 } | I64S { PInt64 }
  | U32S { PUint } | U8S { PUint8 } | U16S { PUint16 } | U64S { PUint64 }
  | BOOLS { PBool }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Tine declarations                                                    *)
(*                                                                       *)
(* Tines declare named masks using #name syntax.                         *)
(* The # evokes grid lines (SIMD lanes).                                 *)
(*                                                                       *)
(* Examples:                                                             *)
(*   | #miss  := (disc < <0.0>)                                          *)
(*   | #maybe := (!#miss)                                                *)
(*   | #hit   := (#maybe && t > <sphere.radius>)                         *)
(* ═══════════════════════════════════════════════════════════════════ *)

canonical_tine_decl:
  | TINE name = TINE_REF WHEN p = predicate {
      { tine_name = name; tine_pred = p }
    }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Predicates                                                           *)
(*                                                                       *)
(* Predicates are boolean expressions that define tine conditions.      *)
(* They support:                                                         *)
(*   - Comparisons: x < y, x >= y, etc.                                  *)
(*   - Logical operators: &&, ||, !                                      *)
(*   - Tine references: #maybe, !#miss                                   *)
(*   - Parenthesized predicates for grouping: (#a && #b)                 *)
(*                                                                       *)
(* With #tine syntax, there's no ambiguity between tine refs and vars!  *)
(* ═══════════════════════════════════════════════════════════════════ *)

predicate:
  | p = pred_or { p }

pred_or:
  | l = pred_or OR r = pred_and {
      mk_node (POr (l, r)) $startpos $endpos
    }
  | p = pred_and { p }

pred_and:
  | l = pred_and AND r = pred_not {
      mk_node (PAnd (l, r)) $startpos $endpos
    }
  | p = pred_not { p }

pred_not:
  | NOT p = pred_not { mk_node (PNot p) $startpos $endpos }
  | p = pred_cmp { p }

pred_cmp:
  (* Comparisons: left and right are expressions *)
  | l = pred_expr LT r = pred_expr { mk_node (PCmp (l, CLt, r)) $startpos $endpos }
  | l = pred_expr LE r = pred_expr { mk_node (PCmp (l, CLe, r)) $startpos $endpos }
  | l = pred_expr GT r = pred_expr { mk_node (PCmp (l, CGt, r)) $startpos $endpos }
  | l = pred_expr GE r = pred_expr { mk_node (PCmp (l, CGe, r)) $startpos $endpos }
  | l = pred_expr EQ r = pred_expr { mk_node (PCmp (l, CEq, r)) $startpos $endpos }
  | l = pred_expr NE r = pred_expr { mk_node (PCmp (l, CNe, r)) $startpos $endpos }
  (* Tine reference with # - unambiguous! *)
  | name = TINE_REF { mk_node (PTineRef name) $startpos $endpos }
  (* Parenthesized predicate for grouping: (#a && #b) *)
  | LPAREN p = predicate RPAREN { p }

(* Predicate expressions: arithmetic for use in comparisons *)
pred_expr:
  | e = pred_add { e }

pred_add:
  | l = pred_add PLUS r = pred_mul { mk_node (EBinop (l, Add, r)) $startpos $endpos }
  | l = pred_add MINUS r = pred_mul { mk_node (EBinop (l, Sub, r)) $startpos $endpos }
  | e = pred_mul { e }

pred_mul:
  | l = pred_mul STAR r = pred_unary { mk_node (EBinop (l, Mul, r)) $startpos $endpos }
  | l = pred_mul SLASH r = pred_unary { mk_node (EBinop (l, Div, r)) $startpos $endpos }
  | l = pred_mul PERCENT r = pred_unary { mk_node (EBinop (l, Mod, r)) $startpos $endpos }
  | e = pred_unary { e }

pred_unary:
  | MINUS e = pred_unary { mk_node (EUnop (Neg, e)) $startpos $endpos }
  | e = pred_atom { e }

pred_atom:
  | name = IDENT { mk_node (EVar name) $startpos $endpos }
  | name = SCALAR_IDENT { mk_node (EScalarVar name) $startpos $endpos }
  | n = INT_LIT { mk_node (EInt n) $startpos $endpos }
  | f = FLOAT_LIT { mk_node (EFloat f) $startpos $endpos }
  | TRUE { mk_node (EBool true) $startpos $endpos }
  | FALSE { mk_node (EBool false) $startpos $endpos }
  | n = SCALAR_INT_LIT {
      mk_node (EBroadcast (mk_node (EInt n) $startpos $endpos)) $startpos $endpos
    }
  | f = SCALAR_FLOAT_LIT {
      mk_node (EBroadcast (mk_node (EFloat f) $startpos $endpos)) $startpos $endpos
    }
  | e = pred_atom DOT name = IDENT { mk_node (EField (e, name)) $startpos $endpos }
  (* Broadcast with field access: <sphere.radius> *)
  | LT e = broadcast_inner GT { mk_node (EBroadcast e) $startpos $endpos }
  (* Parenthesized expressions for grouping arithmetic: (a * b) + c *)
  | LPAREN e = pred_expr RPAREN { e }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Broadcast inner expression (supports field access like <sphere.cx>) *)
(* ═══════════════════════════════════════════════════════════════════ *)

broadcast_inner:
  | name = IDENT { mk_node (EVar name) $startpos $endpos }
  | e = broadcast_inner DOT name = IDENT { mk_node (EField (e, name)) $startpos $endpos }
  | n = INT_LIT { mk_node (EInt n) $startpos $endpos }
  | f = FLOAT_LIT { mk_node (EFloat f) $startpos $endpos }
  | MINUS n = INT_LIT { mk_node (EInt (Int64.neg n)) $startpos $endpos }
  | MINUS f = FLOAT_LIT { mk_node (EFloat (-.f)) $startpos $endpos }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Through blocks                                                       *)
(*                                                                       *)
(* Through blocks execute computation under a tine mask.                 *)
(* The tine is referenced by #name:                                      *)
(*                                                                       *)
(*   through #maybe:                                                     *)
(*     let sqrt_disc = sqrt(disc)                                        *)
(*     sqrt_disc                                                         *)
(*   -> result                                                           *)
(*                                                                       *)
(* Optional else clause for passthru value:                              *)
(*   through #maybe else <0.0>: ... -> result                            *)
(* ═══════════════════════════════════════════════════════════════════ *)

canonical_through_block:
  | THROUGH tr = tine_ref ELSE pt = simple_expr INTO binding = IDENT COLON
    body = list(through_stmt) result = expr {
      {
        through_tine = tr;
        through_passthru = Some pt;
        through_body = body;
        through_result = result;
        through_binding = binding;
      }
    }

tine_ref:
  | name = TINE_REF { TRSingle name }
  | LPAREN p = predicate RPAREN { TRComposed p }

through_stmt:
  | LET b = binding { mk_node (SLet b) $startpos $endpos }
  | PIPE_CHAR name = IDENT annotation = option(type_annotation)
    FUSED_LEFT e = expr {
      mk_node (SFused {
        fused_name = name;
        fused_type = annotation;
        fused_expr = e;
      }) $startpos $endpos
    }

(* Simple expression for else clause (no ambiguity with through body) *)
simple_expr:
  | name = SCALAR_IDENT { mk_node (EScalarVar name) $startpos $endpos }
  | n = INT_LIT { mk_node (EInt n) $startpos $endpos }
  | f = FLOAT_LIT { mk_node (EFloat f) $startpos $endpos }
  | TRUE { mk_node (EBool true) $startpos $endpos }
  | FALSE { mk_node (EBool false) $startpos $endpos }
  | n = SCALAR_INT_LIT {
      mk_node (EBroadcast (mk_node (EInt n) $startpos $endpos)) $startpos $endpos
    }
  | f = SCALAR_FLOAT_LIT {
      mk_node (EBroadcast (mk_node (EFloat f) $startpos $endpos)) $startpos $endpos
    }
  | LT e = broadcast_inner GT { mk_node (EBroadcast e) $startpos $endpos }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Sweep blocks                                                         *)
(*                                                                       *)
(* Sweep collects results from through blocks based on which tine       *)
(* matched each lane.                                                    *)
(*                                                                       *)
(*   sweep:                                                              *)
(*     | #miss  -> miss_value                                            *)
(*     | #hit   -> hit_result                                            *)
(*   -> final_result                                                     *)
(* ═══════════════════════════════════════════════════════════════════ *)

canonical_sweep_arm:
  | PIPE_CHAR name = TINE_REF FAT_ARROW e = expr {
      { arm_tine = Some name; arm_value = e }
    }
  | PIPE_CHAR UNDERSCORE FAT_ARROW e = expr {
      { arm_tine = None; arm_value = e }
    }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Statements                                                           *)
(* ═══════════════════════════════════════════════════════════════════ *)

stmt:
  | LET b = binding { mk_node (SLet b) $startpos $endpos }
  | name = IDENT ASSIGN e = expr { mk_node (SAssign (name, e)) $startpos $endpos }
  (* Location binding: x := e (introduces mutable storage) *)
  | name = IDENT COLONEQ e = expr { mk_node (SLocBind { loc_name = name; loc_type = None; loc_expr = e }) $startpos $endpos }
  | name = IDENT COLON t = typ COLONEQ e = expr {
      mk_node (SLocBind { loc_name = name; loc_type = Some t; loc_expr = e }) $startpos $endpos
    }
  | LPAREN name = IDENT COLON t = typ RPAREN COLONEQ e = expr {
      mk_node (SLocBind { loc_name = name; loc_type = Some t; loc_expr = e }) $startpos $endpos
    }
  (* Fused binding: | x <| e (verified inlineable-SSA contract) *)
  | PIPE_CHAR name = IDENT FUSED_LEFT e = expr {
      mk_node (SFused { fused_name = name; fused_type = None; fused_expr = e }) $startpos $endpos
    }
  | PIPE_CHAR name = IDENT COLON t = typ FUSED_LEFT e = expr {
      mk_node (SFused { fused_name = name; fused_type = Some t; fused_expr = e }) $startpos $endpos
    }
  | e = expr { mk_node (SExpr e) $startpos $endpos }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Over loop: iterate over pack in stack-sized chunks                  *)
(*                                                                      *)
(*   over rays, count |> ray:                                           *)
(*     let t = intersect(ray.ox, ray.oy, ...)                           *)
(*     result[offset] <- t                                              *)
(*                                                                      *)
(* Each iteration processes one stack (lanes elements).                 *)
(* Tail iteration is automatically masked for count % lanes != 0.       *)
(* ═══════════════════════════════════════════════════════════════════ *)

canonical_traversal:
  | FOR chunk = IDENT IN pack = IDENT USING domain = rack_prim_type
    UP TO count = simple_expr COLON body = list(stmt) YIELD value = expr {
      mk_node (SOver {
        over_pack = pack;
        over_domain = domain;
        over_count = count;
        over_chunk = chunk;
        over_body = body @ [mk_node (SExpr value) $startpos(value) $endpos(value)];
      }) $startpos $endpos
    }

type_annotation:
  | COLON t = typ { t }

binding:
  | name = IDENT EQ e = expr {
      { bind_name = name; bind_type = None; bind_expr = e }
    }
  | name = IDENT COLON t = typ EQ e = expr {
      { bind_name = name; bind_type = Some t; bind_expr = e }
    }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Expressions                                                          *)
(* ═══════════════════════════════════════════════════════════════════ *)

expr:
  | e = expr_or { e }

expr_or:
  | l = expr_or OR r = expr_and {
      mk_node (EBinop (l, Or, r)) $startpos $endpos
    }
  | e = expr_and { e }

expr_and:
  | l = expr_and AND r = expr_cmp {
      mk_node (EBinop (l, And, r)) $startpos $endpos
    }
  | e = expr_cmp { e }

expr_cmp:
  | l = expr_cmp LT r = expr_add { mk_node (EBinop (l, Lt, r)) $startpos $endpos }
  | l = expr_cmp LE r = expr_add { mk_node (EBinop (l, Le, r)) $startpos $endpos }
  | l = expr_cmp GT r = expr_add { mk_node (EBinop (l, Gt, r)) $startpos $endpos }
  | l = expr_cmp GE r = expr_add { mk_node (EBinop (l, Ge, r)) $startpos $endpos }
  | l = expr_cmp EQ r = expr_add { mk_node (EBinop (l, Eq, r)) $startpos $endpos }
  | l = expr_cmp NE r = expr_add { mk_node (EBinop (l, Ne, r)) $startpos $endpos }
  | e = expr_add { e }

expr_add:
  | l = expr_add PLUS r = expr_mul { mk_node (EBinop (l, Add, r)) $startpos $endpos }
  | l = expr_add MINUS r = expr_mul { mk_node (EBinop (l, Sub, r)) $startpos $endpos }
  | e = expr_mul { e }

expr_mul:
  | l = expr_mul STAR r = expr_unary { mk_node (EBinop (l, Mul, r)) $startpos $endpos }
  | l = expr_mul SLASH r = expr_unary { mk_node (EBinop (l, Div, r)) $startpos $endpos }
  | l = expr_mul PERCENT r = expr_unary { mk_node (EBinop (l, Mod, r)) $startpos $endpos }
  | e = expr_unary { e }

expr_unary:
  | MINUS e = expr_unary { mk_node (EUnop (Neg, e)) $startpos $endpos }
  | NOT e = expr_unary { mk_node (EUnop (Not, e)) $startpos $endpos }
  | e = expr_postfix { e }

expr_postfix:
  | e = expr_postfix DOT name = IDENT { mk_node (EField (e, name)) $startpos $endpos }
  | e = expr_primary { e }

expr_primary:
  (* Literals *)
  | n = INT_LIT { mk_node (EInt n) $startpos $endpos }
  | f = FLOAT_LIT { mk_node (EFloat f) $startpos $endpos }
  | TRUE { mk_node (EBool true) $startpos $endpos }
  | FALSE { mk_node (EBool false) $startpos $endpos }
  | n = SCALAR_INT_LIT {
      mk_node (EBroadcast (mk_node (EInt n) $startpos $endpos)) $startpos $endpos
    }
  | f = SCALAR_FLOAT_LIT {
      mk_node (EBroadcast (mk_node (EFloat f) $startpos $endpos)) $startpos $endpos
    }

  (* Variables *)
  | name = IDENT { mk_node (EVar name) $startpos $endpos }
  | name = SCALAR_IDENT { mk_node (EScalarVar name) $startpos $endpos }

  (* Lane operations *)
  | AT { mk_node ELaneIndex $startpos $endpos }
  | LANES { mk_node ELanes $startpos $endpos }

  (* Gather: base[offsets] *)
  | base = expr_primary LBRACKET idx = expr RBRACKET {
      mk_node (EGather (base, idx)) $startpos $endpos
    }

  (* Function calls *)
  | name = IDENT LPAREN args = separated_list(COMMA, expr) RPAREN {
      mk_node (named_call name args) $startpos $endpos
    }

  (* Static shuffle lists remain syntax, not runtime values. *)
  | SHUFFLE_FN LPAREN value = expr COMMA LBRACKET
    indices = separated_nonempty_list(COMMA, int_lit) RBRACKET RPAREN {
      mk_node (EShuffle (value, indices)) $startpos $endpos
    }
  | SHIFT_LEFT_FN LPAREN value = expr COMMA amount = int_lit RPAREN {
      mk_node (EShift (value, amount, Left)) $startpos $endpos
    }
  | SHIFT_RIGHT_FN LPAREN value = expr COMMA amount = int_lit RPAREN {
      mk_node (EShift (value, amount, Right)) $startpos $endpos
    }
  | ROTATE_LEFT_FN LPAREN value = expr COMMA amount = int_lit RPAREN {
      mk_node (ERotate (value, amount, Left)) $startpos $endpos
    }
  | ROTATE_RIGHT_FN LPAREN value = expr COMMA amount = int_lit RPAREN {
      mk_node (ERotate (value, amount, Right)) $startpos $endpos
    }

  (* FMA *)
  | FMA LPAREN a = expr COMMA b = expr COMMA c = expr RPAREN {
      mk_node (EFma (a, b, c)) $startpos $endpos
    }

  (* Broadcast with field access: <sphere.cx> *)
  | LT e = broadcast_inner GT { mk_node (EBroadcast e) $startpos $endpos }
  | LPAREN e = expr RPAREN { e }

int_lit:
  | n = INT_LIT { Int64.to_int n }
