(** Rake 0.2.0 Parser

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
%}

(* Tokens: Types *)
%token FLOAT DOUBLE INT INT8 INT16 INT64 UINT UINT8 UINT16 UINT64 BOOL
%token VEC2 VEC3 VEC4 MAT3 MAT4
%token RACK MASK STACK SINGLE PACK TYPE

(* Tokens: Functions *)
%token CRUNCH RAKE RUN

(* Tokens: Tines and control *)
%token <string> TINE_REF
%token THROUGH SWEEP ELSE RESULTS IN

(* Tokens: Iteration *)
%token OVER REPEAT TIMES UNTIL

(* Tokens: Bindings *)
%token LET FUN WITH AS

(* Tokens: Lane operations *)
%token LANES FMA OUTER COMPRESS EXPAND BROADCAST

(* Tokens: Boolean *)
%token TRUE FALSE IS NOT AND OR

(* Tokens: Operators *)
%token PLUS MINUS STAR SLASH PERCENT
%token LT LE GT GE EQ NE
%token AMPAMP PIPEPIPE BANG
%token PIPE FUSED_LEFT ARROW ASSIGN COLONEQ
%token SHUFFLE INTERLEAVE
%token SHL SHR ROL ROR
%token COMPRESS_STORE EXPAND_LOAD

(* Tokens: Reduction ligatures *)
%token REDUCE_ADD REDUCE_MUL REDUCE_MIN REDUCE_MAX REDUCE_OR REDUCE_AND

(* Tokens: Scan ligatures *)
%token SCAN_ADD SCAN_MUL SCAN_MIN SCAN_MAX

(* Tokens: Delimiters *)
%token LPAREN RPAREN LBRACE RBRACE LBRACKET RBRACKET
%token COMMA COLON SEMICOLON PIPE_CHAR AT DOT UNDERSCORE

(* Tokens: Literals *)
%token <int64> INT_LIT
%token <float> FLOAT_LIT
%token <string> STRING_LIT
%token <string> IDENT
%token <string> SCALAR_IDENT

%token EOF

(* Precedence: lowest to highest *)
%right ARROW
%left PIPE FUSED_LEFT
%left PIPEPIPE OR
%left AMPAMP AND
%left EQ NE
%left LT LE GT GE IS
%left PLUS MINUS
%left STAR SLASH PERCENT
%left SHL SHR ROL ROR
%left INTERLEAVE
%right SHUFFLE
%nonassoc BANG NOT
%nonassoc REDUCE_ADD REDUCE_MUL REDUCE_MIN REDUCE_MAX REDUCE_OR REDUCE_AND
%nonassoc SCAN_ADD SCAN_MUL SCAN_MIN SCAN_MAX
%left DOT AT

%start <Ast.program> program

%%

(* ═══════════════════════════════════════════════════════════════════ *)
(* Program structure                                                    *)
(* ═══════════════════════════════════════════════════════════════════ *)

program:
  | ms = list(module_) EOF { ms }

module_:
  | ds = nonempty_list(definition) {
      { mod_name = "main"; mod_defs = ds }
    }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Definitions                                                          *)
(* ═══════════════════════════════════════════════════════════════════ *)

definition:
  | d = stack_def { d }
  | d = single_def { d }
  | d = type_def { d }
  | d = crunch_def { d }
  | d = rake_def { d }
  | d = run_def { d }

(* stack Particle { pos: vec3 rack, vel: vec3 rack } *)
stack_def:
  | STACK name = IDENT LBRACE fs = separated_list(COMMA, field) RBRACE {
      mk_node (DStack (name, fs)) $startpos $endpos
    }

(* single Config { dt: float, gravity: float } *)
single_def:
  | SINGLE name = IDENT LBRACE fs = separated_list(COMMA, field) RBRACE {
      mk_node (DSingle (name, fs)) $startpos $endpos
    }

(* type alias = existing_type *)
type_def:
  | TYPE name = IDENT EQ t = typ {
      mk_node (DType (name, t)) $startpos $endpos
    }

field:
  | name = IDENT COLON t = typ {
      { field_name = name; field_type = t }
    }

(* crunch name params -> result: body
   Supports three forms:
   1. Bare params:    crunch dot ax ay az -> d:
   2. Parenthesized:  crunch dot (ax, ay, az) -> d:
   3. Type spreading: crunch dot (Vec3 as ax ay az) -> d:
*)
crunch_def:
  (* Original: bare space-separated params *)
  | CRUNCH name = IDENT ps = list(param) ARROW r = result_spec COLON
    body = stmt_list {
      mk_node (DCrunch (name, ps, r, body)) $startpos $endpos
    }
  (* New: comma-separated params in parens, with optional type spreading *)
  | CRUNCH name = IDENT LPAREN ps = separated_nonempty_list(COMMA, crunch_param) RPAREN ARROW r = result_spec COLON
    body = stmt_list {
      mk_node (DCrunch (name, List.concat ps, r, body)) $startpos $endpos
    }

(* Parameters inside parenthesized crunch definition *)
crunch_param:
  (* Single untyped rack param: ax *)
  | name = IDENT { [PRack (name, None)] }
  (* Single typed param: ax : float rack *)
  | name = IDENT COLON t = typ { [PRack (name, Some t)] }
  (* Single scalar param: <x> *)
  | name = SCALAR_IDENT { [PScalar (name, None)] }
  (* Single typed scalar: <x> : float *)
  | name = SCALAR_IDENT COLON t = typ { [PScalar (name, Some t)] }
  (* Type spreading: Vec3 as ax ay az *)
  | tname = IDENT AS names = nonempty_list(IDENT) { [PSpread (names, tname)] }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Rake definition with tine/through/sweep                              *)
(*                                                                       *)
(* rake name params -> result:                                           *)
(*   let disc = ...           ~~ optional setup                          *)
(*                                                                       *)
(*   | #miss  := (disc < <0.0>)                                          *)
(*   | #maybe := (!#miss)                                                *)
(*   | #hit   := (#maybe && t > <epsilon>)                               *)
(*                                                                       *)
(*   through #maybe: ...computation... -> t_value                        *)
(*   through #hit:   ...computation... -> hit_result                     *)
(*                                                                       *)
(*   sweep:                                                              *)
(*     | #miss -> miss_value                                             *)
(*     | #hit  -> hit_result                                             *)
(*   -> result                                                           *)
(* ═══════════════════════════════════════════════════════════════════ *)

rake_def:
  | RAKE name = IDENT ps = list(param) ARROW r = result_spec COLON
    setup = rake_setup
    ts = nonempty_list(tine_decl)
    ths = nonempty_list(through_block)
    sw = sweep_block {
      mk_node (DRake (name, ps, r, setup, ts, ths, sw)) $startpos $endpos
    }

(* Setup statements before tines (let bindings for computation shared by all tines) *)
rake_setup:
  | ss = list(rake_setup_stmt) { ss }

rake_setup_stmt:
  | LET b = binding { mk_node (SLet b) $startpos $endpos }

(* run name params -> result: body *)
run_def:
  | RUN name = IDENT ps = list(param) ARROW r = result_spec COLON
    body = stmt_list {
      mk_node (DRun (name, ps, r, body)) $startpos $endpos
    }

result_spec:
  | name = IDENT { { result_name = name; result_type = None } }
  | LPAREN name = IDENT COLON t = typ RPAREN {
      { result_name = name; result_type = Some t }
    }
  | LPAREN names = separated_nonempty_list(COMMA, IDENT) RPAREN {
      (* Tuple result - use first name, type inferred *)
      { result_name = List.hd names; result_type = None }
    }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Parameters                                                           *)
(* ═══════════════════════════════════════════════════════════════════ *)

param:
  | name = IDENT { PRack (name, None) }
  | LPAREN name = IDENT COLON t = typ RPAREN { PRack (name, Some t) }
  | name = SCALAR_IDENT { PScalar (name, None) }
  | LPAREN name = SCALAR_IDENT COLON t = typ RPAREN { PScalar (name, Some t) }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Types                                                                *)
(* ═══════════════════════════════════════════════════════════════════ *)

typ:
  | t = prim_type RACK { mk_node (TRack t) $startpos $endpos }
  | t = compound_type RACK { mk_node (TCompoundRack t) $startpos $endpos }
  | t = prim_type { mk_node (TScalar t) $startpos $endpos }
  | t = compound_type { mk_node (TCompoundScalar t) $startpos $endpos }
  | name = IDENT STACK { mk_node (TStack name) $startpos $endpos }
  | name = IDENT PACK { mk_node (TPack name) $startpos $endpos }
  | name = IDENT SINGLE { mk_node (TSingle name) $startpos $endpos }
  | MASK { mk_node TMask $startpos $endpos }
  | LPAREN ts = separated_list(COMMA, typ) RPAREN ARROW r = typ {
      mk_node (TFun (ts, r)) $startpos $endpos
    }
  | LPAREN ts = separated_nonempty_list(COMMA, typ) RPAREN {
      mk_node (TTuple ts) $startpos $endpos
    }
  | LPAREN RPAREN { mk_node TUnit $startpos $endpos }

prim_type:
  | FLOAT { PFloat }
  | DOUBLE { PDouble }
  | INT { PInt }
  | INT8 { PInt8 }
  | INT16 { PInt16 }
  | INT64 { PInt64 }
  | UINT { PUint }
  | UINT8 { PUint8 }
  | UINT16 { PUint16 }
  | UINT64 { PUint64 }
  | BOOL { PBool }

compound_type:
  | VEC2 { CVec2 }
  | VEC3 { CVec3 }
  | VEC4 { CVec4 }
  | MAT3 { CMat3 }
  | MAT4 { CMat4 }

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

tine_decl:
  | PIPE_CHAR name = TINE_REF COLONEQ LPAREN p = predicate RPAREN {
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
  | l = pred_or PIPEPIPE r = pred_and {
      mk_node (POr (l, r)) $startpos $endpos
    }
  | l = pred_or OR r = pred_and {
      mk_node (POr (l, r)) $startpos $endpos
    }
  | p = pred_and { p }

pred_and:
  | l = pred_and AMPAMP r = pred_not {
      mk_node (PAnd (l, r)) $startpos $endpos
    }
  | l = pred_and AND r = pred_not {
      mk_node (PAnd (l, r)) $startpos $endpos
    }
  | p = pred_not { p }

pred_not:
  | BANG p = pred_not { mk_node (PNot p) $startpos $endpos }
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
  | l = pred_expr IS r = pred_expr { mk_node (PIs (l, r)) $startpos $endpos }
  | l = pred_expr IS NOT r = pred_expr { mk_node (PIsNot (l, r)) $startpos $endpos }
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

through_block:
  | THROUGH tr = tine_ref pt = option(else_clause) COLON
    body = through_body
    result = expr ARROW binding = IDENT {
      {
        through_tine = tr;
        through_passthru = pt;
        through_body = body;
        through_result = result;
        through_binding = binding;
      }
    }

tine_ref:
  | name = TINE_REF { TRSingle name }
  | LPAREN p = predicate RPAREN { TRComposed p }

else_clause:
  | ELSE e = simple_expr { e }

(* Through body: sequence of let bindings *)
through_body:
  | ss = list(through_stmt) { ss }

through_stmt:
  | LET b = binding { mk_node (SLet b) $startpos $endpos }

(* Simple expression for else clause (no ambiguity with through body) *)
simple_expr:
  | name = SCALAR_IDENT { mk_node (EScalarVar name) $startpos $endpos }
  | n = INT_LIT { mk_node (EInt n) $startpos $endpos }
  | f = FLOAT_LIT { mk_node (EFloat f) $startpos $endpos }
  | TRUE { mk_node (EBool true) $startpos $endpos }
  | FALSE { mk_node (EBool false) $startpos $endpos }
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

sweep_block:
  | SWEEP COLON arms = nonempty_list(sweep_arm) ARROW binding = IDENT {
      { sweep_arms = arms; sweep_binding = binding }
    }

sweep_arm:
  | PIPE_CHAR name = TINE_REF ARROW e = expr {
      { arm_tine = Some name; arm_value = e }
    }
  | PIPE_CHAR UNDERSCORE ARROW e = expr {
      { arm_tine = None; arm_value = e }
    }

(* ═══════════════════════════════════════════════════════════════════ *)
(* Statements                                                           *)
(* ═══════════════════════════════════════════════════════════════════ *)

stmt_list:
  | ss = list(stmt) { ss }

stmt:
  | LET b = binding { mk_node (SLet b) $startpos $endpos }
  | name = IDENT ASSIGN e = expr { mk_node (SAssign (name, e)) $startpos $endpos }
  (* Location binding: x := e (introduces mutable storage) *)
  | name = IDENT COLONEQ e = expr { mk_node (SLocBind { loc_name = name; loc_type = None; loc_expr = e }) $startpos $endpos }
  | LPAREN name = IDENT COLON t = typ RPAREN COLONEQ e = expr {
      mk_node (SLocBind { loc_name = name; loc_type = Some t; loc_expr = e }) $startpos $endpos
    }
  (* Fused binding: | x <| e (must fuse, no intermediate storage) *)
  | PIPE_CHAR name = IDENT FUSED_LEFT e = expr {
      mk_node (SFused { fused_name = name; fused_expr = e }) $startpos $endpos
    }
  | o = over_stmt { o }
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

over_stmt:
  | OVER pack = IDENT COMMA count = over_count_expr PIPE chunk = IDENT COLON
    body = over_body {
      mk_node (SOver {
        over_pack = pack;
        over_count = count;
        over_chunk = chunk;
        over_body = body;
      }) $startpos $endpos
    }

over_count_expr:
  | name = IDENT { mk_node (EVar name) $startpos $endpos }
  | name = SCALAR_IDENT { mk_node (EScalarVar name) $startpos $endpos }
  | n = INT_LIT { mk_node (EInt n) $startpos $endpos }

over_body:
  | ss = nonempty_list(over_body_stmt) { ss }

over_body_stmt:
  | LET b = binding { mk_node (SLet b) $startpos $endpos }
  | name = IDENT ASSIGN e = expr { mk_node (SAssign (name, e)) $startpos $endpos }
  | e = expr { mk_node (SExpr e) $startpos $endpos }

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
  | e = expr_pipe { e }

expr_pipe:
  | l = expr_pipe PIPE r = expr_or {
      mk_node (EPipe (l, r)) $startpos $endpos
    }
  | l = expr_pipe FUSED_LEFT r = expr_or {
      mk_node (EFusedPipe (l, r)) $startpos $endpos
    }
  | e = expr_or { e }

expr_or:
  | l = expr_or PIPEPIPE r = expr_and {
      mk_node (EBinop (l, Or, r)) $startpos $endpos
    }
  | e = expr_and { e }

expr_and:
  | l = expr_and AMPAMP r = expr_cmp {
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
  | l = expr_mul STAR r = expr_shift { mk_node (EBinop (l, Mul, r)) $startpos $endpos }
  | l = expr_mul SLASH r = expr_shift { mk_node (EBinop (l, Div, r)) $startpos $endpos }
  | l = expr_mul PERCENT r = expr_shift { mk_node (EBinop (l, Mod, r)) $startpos $endpos }
  | e = expr_shift { e }

expr_shift:
  | l = expr_shift SHL r = expr_interleave { mk_node (EBinop (l, Shl, r)) $startpos $endpos }
  | l = expr_shift SHR r = expr_interleave { mk_node (EBinop (l, Shr, r)) $startpos $endpos }
  | l = expr_shift ROL r = expr_interleave { mk_node (EBinop (l, Rol, r)) $startpos $endpos }
  | l = expr_shift ROR r = expr_interleave { mk_node (EBinop (l, Ror, r)) $startpos $endpos }
  | e = expr_interleave { e }

expr_interleave:
  | l = expr_interleave INTERLEAVE r = expr_unary {
      mk_node (EBinop (l, Interleave, r)) $startpos $endpos
    }
  | e = expr_unary { e }

expr_unary:
  | MINUS e = expr_unary { mk_node (EUnop (Neg, e)) $startpos $endpos }
  | BANG e = expr_unary { mk_node (EUnop (Not, e)) $startpos $endpos }
  | NOT e = expr_unary { mk_node (EUnop (Not, e)) $startpos $endpos }
  | e = expr_reduce { e }

expr_reduce:
  | e = expr_postfix REDUCE_ADD { mk_node (EReduce (RAdd, e)) $startpos $endpos }
  | e = expr_postfix REDUCE_MUL { mk_node (EReduce (RMul, e)) $startpos $endpos }
  | e = expr_postfix REDUCE_MIN { mk_node (EReduce (RMin, e)) $startpos $endpos }
  | e = expr_postfix REDUCE_MAX { mk_node (EReduce (RMax, e)) $startpos $endpos }
  | e = expr_postfix REDUCE_OR { mk_node (EReduce (ROr, e)) $startpos $endpos }
  | e = expr_postfix REDUCE_AND { mk_node (EReduce (RAnd, e)) $startpos $endpos }
  | e = expr_postfix SCAN_ADD { mk_node (EScan (RAdd, e)) $startpos $endpos }
  | e = expr_postfix SCAN_MUL { mk_node (EScan (RMul, e)) $startpos $endpos }
  | e = expr_postfix SCAN_MIN { mk_node (EScan (RMin, e)) $startpos $endpos }
  | e = expr_postfix SCAN_MAX { mk_node (EScan (RMax, e)) $startpos $endpos }
  | e = expr_postfix { e }

expr_postfix:
  | e = expr_postfix DOT name = IDENT { mk_node (EField (e, name)) $startpos $endpos }
  | e = expr_postfix AT i = expr_primary { mk_node (EExtract (e, i)) $startpos $endpos }
  | e = expr_postfix SHUFFLE LBRACKET is = separated_list(COMMA, int_lit) RBRACKET {
      mk_node (EShuffle (e, is)) $startpos $endpos
    }
  | e = expr_primary { e }

expr_primary:
  (* Literals *)
  | n = INT_LIT { mk_node (EInt n) $startpos $endpos }
  | f = FLOAT_LIT { mk_node (EFloat f) $startpos $endpos }
  | TRUE { mk_node (EBool true) $startpos $endpos }
  | FALSE { mk_node (EBool false) $startpos $endpos }

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
      mk_node (ECall (name, args)) $startpos $endpos
    }

  (* FMA *)
  | FMA LPAREN a = expr COMMA b = expr COMMA c = expr RPAREN {
      mk_node (EFma (a, b, c)) $startpos $endpos
    }

  (* Outer product *)
  | a = expr_primary OUTER b = expr_primary {
      mk_node (EOuter (a, b)) $startpos $endpos
    }

  (* Broadcast with field access: <sphere.cx> *)
  | LT e = broadcast_inner GT { mk_node (EBroadcast e) $startpos $endpos }
  | BROADCAST e = expr_primary { mk_node (EBroadcast e) $startpos $endpos }

  (* Record construction *)
  | name = IDENT LBRACE fs = separated_list(COMMA, field_init) RBRACE {
      mk_node (ERecord (name, fs)) $startpos $endpos
    }

  (* Record update *)
  | LBRACE e = expr WITH fs = separated_nonempty_list(COMMA, field_init) RBRACE {
      mk_node (EWith (e, fs)) $startpos $endpos
    }

  (* Tuple *)
  | LPAREN es = separated_nonempty_list(COMMA, expr) RPAREN {
      if List.length es = 1 then List.hd es
      else mk_node (ETuple es) $startpos $endpos
    }

  (* Unit *)
  | LPAREN RPAREN { mk_node EUnit $startpos $endpos }

  (* Lambda *)
  | FUN ps = nonempty_list(param) ARROW body = expr {
      mk_node (ELambda (ps, body)) $startpos $endpos
    }

  (* Let expression *)
  | LET b = binding IN body = expr {
      mk_node (ELet (b, body)) $startpos $endpos
    }

field_init:
  | name = IDENT COLONEQ e = expr {
      { init_field = name; init_value = e }
    }

int_lit:
  | n = INT_LIT { Int64.to_int n }
