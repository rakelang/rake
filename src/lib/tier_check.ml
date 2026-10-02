(** The checker for the slow tier and general runs.

    Slow code is scalar orchestration: records, arrays, views, module state,
    embedded data, control flow and calls. It can't name or hold a rack type.
    A run's lexical slow blocks capture scalars and views, never live racks.
    Slow code reaches vector work only by calling a run, or a crunch whose parameters
    are all uniform, and marks every scalar argument that becomes a rack at
    that boundary with angle brackets.

    A run is vector code over memory: views, packs and uniform scalars in,
    stores out, with counted loops, unrolled [repeat], uniform [if] and
    traversals. Its statements are put in A-normal form ({!Tier_ir.rstmt}):
    each load, gather and pure rack computation binds a name, and the pure
    computations are typed by the crunch checker ({!Typecheck}) so that a
    rack operation means the same in a run as in a crunch. *)

open Tier_ir
module SM = Map.Make (String)

exception Error of Ast.loc * string

let fail loc fmt = Printf.ksprintf (fun message -> raise (Error (loc, message))) fmt

let format_error (loc : Ast.loc) message =
  Printf.sprintf "%s:%d:%d: Type error: %s" loc.file loc.line loc.col message

type vector_sig =
  | Sig_run of run_param list * scalar option
  | Sig_crunch of (string * ty * bool) list * ty  (** name, type, uniform; result *)

type ctx = {
  records : (string, record) Hashtbl.t;
  stacks : (string, stack) Hashtbl.t;
  slows : (string, param list * ty) Hashtbl.t;
  externs : (string, extern_func) Hashtbl.t;
  vectors : (string, vector_sig) Hashtbl.t;
  globals : (string, ty * bool) Hashtbl.t;  (** state and embedded data, writable *)
  consts : (string, expr) Hashtbl.t;
  tc : Typecheck.env;
  base_dir : string;
  block_functions : slow_func list ref;
}

type binding = {
  bty : ty;
  bmut : bool;  (** may be assigned *)
  buniform : bool;  (** a uniform scalar of vector code, written <name> *)
  bconst : int64 option;  (** an unrolled repeat index *)
}

type mode = Slow_mode | Vector_mode

type env = {
  ctx : ctx;
  vars : binding SM.t;
  mode : mode;
  loops : int;
  result : ty;
  fresh : int ref;
  return_allowed : bool;
}

let lookup env loc name =
  match SM.find_opt name env.vars with
  | Some binding -> binding
  | None -> fail loc "undefined name '%s'" name

let fresh env prefix =
  incr env.fresh;
  Printf.sprintf "%s$%d" prefix !(env.fresh)

let mk k ty loc = { k; ty; loc }

(* ─── Types ─────────────────────────────────────────────────────────── *)

let rec ty_of ctx (t : Ast.typ) =
  match t.v with
  | TScalar p -> Sc (scalar_of_prim p)
  | TRack p -> Rack (scalar_of_prim p)
  | TMask -> Mask Types.SInt
  | TArray (n, inner) -> (
      if n <= 0 then fail t.loc "an array needs at least one element";
      match inner.v with
      | TRack p -> Rack_array (n, scalar_of_prim p)
      | _ -> Array (n, storable ctx inner))
  | TView inner -> View (storable ctx inner, false)
  | TMut { v = TView inner; _ } -> View (storable ctx inner, true)
  | TMut { v = TPack name; _ } ->
      if not (Hashtbl.mem ctx.stacks name) then fail t.loc "unknown stack '%s'" name;
      Pack (name, true)
  | TPack name ->
      if not (Hashtbl.mem ctx.stacks name) then fail t.loc "unknown stack '%s'" name;
      Pack (name, false)
  | TPtr inner -> Ptr (pointee ctx inner)
  | TNamed name ->
      if Hashtbl.mem ctx.records name then Record name
      else if Hashtbl.mem ctx.stacks name then
        fail t.loc "'%s' is a stack: write pack %s for its columns" name name
      else fail t.loc "unknown record '%s'" name
  | TMut _ -> fail t.loc "mut marks a writable parameter: mut []T, mut pack S, or a mut record or array"
  | TStack _ -> fail t.loc "a stack is a column schema: write pack S"
  | TCompoundRack _ | TCompoundScalar _ | TSingle _ | TFun _ | TTuple _ | TUnit ->
      fail t.loc "this type has no published contract"

and storable ctx (t : Ast.typ) =
  match ty_of ctx t with
  | (Sc _ | Array _ | Record _ | Ptr _) as ty -> ty
  | ty -> fail t.loc "%s can't be stored in memory" (string_of_ty ty)

and pointee ctx (t : Ast.typ) =
  match t.v with
  | TNamed name when Hashtbl.mem ctx.records name -> Record name
  | _ -> ty_of ctx t

let rec equal_ty a b =
  match (a, b) with
  | Sc x, Sc y | Rack x, Rack y -> x = y
  | Mask _, Mask _ -> true
  | Rack_array (n, x), Rack_array (m, y) -> n = m && x = y
  | Array (n, x), Array (m, y) -> n = m && equal_ty x y
  | View (x, w), View (y, v) -> w = v && equal_ty x y
  | Ptr x, Ptr y -> equal_ty x y
  | Record x, Record y -> x = y
  | Pack (x, w), Pack (y, v) -> x = y && w = v
  | Str, Str | Void, Void -> true
  | _ -> false

let is_aggregate = function Array _ | Record _ -> true | _ -> false

let require loc expected actual what =
  if not (equal_ty expected actual) then
    fail loc "%s has type %s; expected %s" what (string_of_ty actual) (string_of_ty expected)

let integer_scalar loc what = function
  | Sc s when is_integer s -> s
  | ty -> fail loc "%s must be an integer, got %s" what (string_of_ty ty)

let fits s value =
  let open Int64 in
  match s with
  | Types.SInt8 -> value >= -128L && value <= 127L
  | SUint8 -> value >= 0L && value <= 255L
  | SInt16 -> value >= -32768L && value <= 32767L
  | SUint16 -> value >= 0L && value <= 65535L
  | SInt -> value >= of_int32 Int32.min_int && value <= of_int32 Int32.max_int
  | SUint -> value >= 0L && value <= 0xFFFFFFFFL
  | SInt64 | SUint64 -> true
  | SFloat | SDouble -> true
  | SBool -> false

let bind env loc name binding =
  if SM.mem name env.vars then fail loc "'%s' is already bound; names are not reused" name;
  if Hashtbl.mem env.ctx.consts name || Hashtbl.mem env.ctx.globals name then
    fail loc "'%s' names a module definition" name;
  { env with vars = SM.add name binding env.vars }

let rec definitely_returns = function
  | [] -> false
  | stmts -> (
      match (List.rev stmts |> List.hd).s with
      | Return _ -> true
      | If (_, a, b) -> definitely_returns a && definitely_returns b
      | Eval { k = Block (body, _); _ } -> definitely_returns body
      | _ -> false)

(* ─── Uniform scalar expressions ────────────────────────────────────── *)

let math_unary = [ "sqrt"; "exp"; "log"; "log2"; "tanh"; "floor"; "ceil" ]

let bit_binary =
  [ ("bit_and", Bit_and); ("bit_or", Bit_or); ("bit_xor", Bit_xor); ("bit_andnot", Bit_andnot);
    ("shift_bits_left", Shl); ("shift_bits_right", Shr); ("shift_bits_right_signed", Shr_signed);
    ("rotate_bits_left", Rotl); ("rotate_bits_right", Rotr); ("wrap_add", Wrap_add);
    ("wrap_sub", Wrap_sub); ("wrap_mul", Wrap_mul) ]

let comparison_of = function
  | Ast.Eq -> Eq | Ne -> Ne | Lt -> Lt | Le -> Le | Gt -> Gt | Ge -> Ge
  | _ -> invalid_arg "comparison_of"

(** Whether a vector-mode expression involves racks, masks or a traversal
    chunk, and so belongs to the rack pipeline rather than the uniform one. *)
let rec mentions_racks env (e : Ast.expr) =
  let any = List.exists (mentions_racks env) in
  match e.v with
  | EVar name -> (
      match SM.find_opt name env.vars with
      | Some { bty = Rack _ | Mask _ | Rack_array _ | Pack _; _ } -> true
      | Some { bty = View _; _ } -> true
      | _ -> false)
  | EScalarVar _ | EInt _ | EFloat _ | EBool _ | EString _ | ELanes -> false
  | ESlow _ -> false
  | EBroadcast _ -> false
  | ELaneIndex -> true
  | EBinop (a, _, b) -> any [ a; b ]
  | EConvert (_, { v = TRack _ | TMask; _ }, _) -> true
  | EUnop (_, a) | EField (a, _) | EConvert (_, _, a) -> mentions_racks env a
  | EIndex (a, i, _) -> mentions_racks env a || mentions_racks env i
  | ECall (name, args) -> (
      match Hashtbl.find_opt env.ctx.vectors name with
      | Some _ -> true
      | None ->
          List.mem name [ "dot"; "narrow"; "widen"; "widen_low"; "widen_high"; "to_f32"; "to_i32";
            "bitmask"; "select"; "exp_approximate" ] || any args)
  | EIf (c, a, b) -> any [ c; a; b ]
  | EReduce _ | EScan _ | EShuffle _ | EFma _ | EExtract _ | EInsert _ -> true
  | EArray es -> any es
  | _ -> true

let rec check_uniform env ?expected (e : Ast.expr) : expr =
  let loc = e.loc in
  let literal_int value =
    match expected with
    | Some (Sc s) when is_integer s ->
        if not (fits s value) then fail loc "integer literal %Ld does not fit %s" value (string_of_ty (Sc s));
        mk (Int value) (Sc s) loc
    | Some (Sc ((SFloat | SDouble) as s)) -> mk (Float (Int64.to_float value)) (Sc s) loc
    | _ ->
        if not (fits Types.SInt value) then fail loc "integer literal %Ld needs a declared type wider than i32" value;
        mk (Int value) (Sc Types.SInt) loc
  in
  let literal_float value =
    match expected with
    | Some (Sc Types.SDouble) -> mk (Float value) (Sc SDouble) loc
    | _ -> mk (Float value) (Sc SFloat) loc
  in
  let name_use name =
    match Hashtbl.find_opt env.ctx.consts name with
    | Some value when not (SM.mem name env.vars) -> { value with loc }
    | _ -> (
        match SM.find_opt name env.vars with
        | Some { bconst = Some value; bty; _ } -> mk (Int value) bty loc
        | Some { bty; buniform; _ } ->
            (match bty with
             | Rack _ | Mask _ | Rack_array _ when env.mode = Slow_mode ->
                 fail loc "slow code can't hold rack or mask '%s'; reduce or extract it before the slow block" name
             | Pack _ when env.mode = Slow_mode ->
                 fail loc "slow code can't use traversal chunk or pack '%s'; pass its memory to a run" name
             | _ -> ());
            if env.mode = Vector_mode && not buniform then
              fail loc "'%s' is not a uniform scalar" name;
            mk (Var name) bty loc
        | None -> (
            match Hashtbl.find_opt env.ctx.globals name with
            | Some (ty, _) ->
                if env.mode = Vector_mode then
                  fail loc "vector code can't read module state '%s'; pass it as a parameter" name;
                mk (Global name) ty loc
            | None -> fail loc "undefined name '%s'" name))
  in
  match e.v with
  | EInt value -> literal_int value
  | EFloat value -> literal_float value
  | EBool value -> mk (Bool value) (Sc SBool) loc
  | EString text -> mk (Str_lit text) Str loc
  | EVar name ->
      if env.mode = Vector_mode && not (Hashtbl.mem env.ctx.consts name) then
        (match SM.find_opt name env.vars with
         | Some { buniform = true; _ } ->
             fail loc "uniform scalar '%s' is written <%s> where it is used" name name
         | _ -> ());
      name_use name
  | EScalarVar name ->
      if env.mode = Slow_mode then
        fail loc "<%s> marks a uniform scalar for vector code; every slow value is scalar, so write %s"
          name name;
      name_use name
  | EBroadcast inner -> (
      if env.mode = Slow_mode then
        fail loc "angle brackets mark scalars that become racks, at a vector call; slow values are written bare";
      match inner.v with
      | EInt value -> literal_int value
      | EFloat value -> literal_float value
      | EVar name -> name_use name
      | EIndex (view, index, unchecked) -> element env loc view index unchecked
      | _ -> fail loc "a uniform scalar is written <name>, <literal> or <view[index]>")
  | EUnop (Neg, a) ->
      let a = check_uniform env ?expected a in
      (match a.ty with
       | Sc s when s <> SBool -> mk (Unary (Neg, a)) a.ty loc
       | ty -> fail loc "negation needs a number, got %s" (string_of_ty ty))
  | EUnop (FNeg, a) -> check_uniform env ?expected { e with v = EUnop (Neg, a) }
  | EUnop (Not, a) ->
      let a = check_uniform env ~expected:(Sc SBool) a in
      require loc (Sc SBool) a.ty "the operand of not";
      mk (Unary (Not, a)) a.ty loc
  | EBinop (a, ((Add | Sub | Mul | Div | Mod) as op), b) ->
      let a, b = same_numeric env ?expected a b in
      let s = match a.ty with Sc s -> s | _ -> assert false in
      if s = SBool then fail loc "arithmetic needs numbers, got bool";
      if op = Mod && is_float s then fail loc "%% is integer remainder; floats have no remainder operator";
      let op = match op with Add -> Add | Sub -> Sub | Mul -> Mul | Div -> Div | _ -> Rem in
      mk (Binary (op, a, b)) a.ty loc
  | EBinop (a, ((Lt | Le | Gt | Ge | Eq | Ne) as op), b) ->
      let a, b = same_numeric env a b in
      (match (op, a.ty) with
       | (Lt | Le | Gt | Ge), Sc SBool -> fail loc "booleans are ordered by = and != only"
       | _ -> ());
      mk (Compare (comparison_of op, a, b)) (Sc SBool) loc
  | EBinop (a, ((And | Or) as op), b) ->
      let a = check_uniform env ~expected:(Sc SBool) a and b = check_uniform env ~expected:(Sc SBool) b in
      require a.loc (Sc SBool) a.ty "the left operand";
      require b.loc (Sc SBool) b.ty "the right operand";
      mk (Logic (op = And, a, b)) (Sc SBool) loc
  | EBinop (_, op, _) -> fail loc "operator %s has no scalar meaning" (Ast.show_binop op)
  | EIf (c, a, b) ->
      let c = check_uniform env ~expected:(Sc SBool) c in
      require c.loc (Sc SBool) c.ty "an if condition";
      let a, b = same_type env ?expected a b in
      mk (Cond (c, a, b)) a.ty loc
  | EConvert (kind, target, value) -> (
      let target_s =
        match ty_of env.ctx target with Sc s -> s | ty -> fail loc "conversion targets a scalar type, got %s" (string_of_ty ty)
      in
      let expected =
        match (kind, value.v) with
        | Ast.Convert_bitcast, (EInt _ | EBroadcast { v = EInt _; _ }) ->
            Some (Sc (match bits target_s with 8 -> Types.SUint8 | 16 -> SUint16 | 64 -> SUint64 | _ -> SUint))
        | (Ast.Convert_checked | Convert_wrap), (EInt value | EBroadcast { v = EInt value; _ }) when is_integer target_s ->
            (* A literal converted to an integer type is read as one, as wide as it needs. *)
            if fits target_s value then Some (Sc target_s) else Some (Sc (if value < 0L then Types.SInt64 else SUint64))
        | _ -> None
      in
      let value = check_uniform env ?expected value in
      match value.ty with
      | Sc source ->
          (match kind with
           | Ast.Convert_wrap ->
               if not (is_integer source && is_integer target_s) then
                 fail loc "wrap converts between integer types"
           | Convert_bitcast ->
               if bits source <> bits target_s || source = SBool || target_s = SBool then
                 fail loc "bitcast needs two numeric types of one width"
           | Convert_checked ->
               if (source = SBool) <> (target_s = SBool) then fail loc "bool converts only to bool");
          mk (Convert (kind, target_s, value)) (Sc target_s) loc
      | ty -> fail loc "conversion needs a scalar, got %s" (string_of_ty ty))
  | EIndex (base, index, unchecked) ->
      if env.mode = Vector_mode then
        fail loc "in vector code a view's element is read as <view[index]>; view[index] loads a rack";
      element env loc base index unchecked
  | EField (base, field) -> (
      let base = check_uniform env base in
      let record =
        match base.ty with
        | Record name | Ptr (Record name) -> Hashtbl.find env.ctx.records name
        | ty -> fail loc "%s has no fields" (string_of_ty ty)
      in
      match List.assoc_opt field record.rfields with
      | Some ty -> mk (Field (base, field)) ty loc
      | None -> fail loc "record %s has no field '%s'" record.rname field)
  | ERecord (name, inits) -> record_literal env loc name inits
  | EArray items -> (
      match expected with
      | Some (Array (n, element)) ->
          if List.length items <> n then fail loc "array literal has %d elements; %s needs %d" (List.length items) (string_of_ty (Array (n, element))) n;
          let items = List.map (fun item -> let v = check_uniform env ~expected:element item in require item.loc element v.ty "an array element"; v) items in
          mk (Array_lit items) (Array (n, element)) loc
      | _ ->
          let first = check_uniform env (List.hd items) in
          let items = first :: List.map (fun item -> let v = check_uniform env ~expected:first.ty item in require item.loc first.ty v.ty "an array element"; v) (List.tl items) in
          mk (Array_lit items) (Array (List.length items, first.ty)) loc)
  | ECall (name, args) -> call env ?expected loc name args
  | ESlow (body, tail) -> slow_expression env ?expected loc body tail
  | _ ->
      if env.mode = Vector_mode then fail loc "this expression is a rack computation, not a uniform scalar"
      else fail loc "this expression is vector code; slow code reaches it by calling a run"

and element env loc base index unchecked =
  (* The base is memory, named bare even in vector code. *)
  let base = check_uniform { env with mode = Slow_mode } base in
  let index = check_uniform env index in
  ignore (integer_scalar index.loc "an index" index.ty);
  match base.ty with
  | Array (_, element) | View (element, _) -> mk (Elem (base, index, not unchecked)) element loc
  | Ptr element ->
      if not unchecked then fail loc "a pointer carries no bounds; write p[unchecked i]";
      mk (Elem (base, index, false)) element loc
  | ty -> fail loc "%s can't be indexed" (string_of_ty ty)

and same_numeric env ?expected a b =
  (* A literal takes the type of the operand beside it. *)
  let is_literal (e : Ast.expr) =
    match e.v with EInt _ | EFloat _ | EBroadcast { v = EInt _ | EFloat _; _ } -> true | EUnop (Neg, { v = EInt _ | EFloat _; _ }) -> true | _ -> false
  in
  let expected = match expected with Some (Sc SBool) -> None | other -> other in
  let a, b =
    if is_literal a && not (is_literal b) then
      let b = check_uniform env ?expected b in
      (check_uniform env ~expected:b.ty a, b)
    else
      let a = check_uniform env ?expected a in
      (a, check_uniform env ~expected:a.ty b)
  in
  (match (a.ty, b.ty) with
   | Sc x, Sc y when x = y -> ()
   | Sc _, Sc _ ->
       fail b.loc "operands have types %s and %s; convert one explicitly" (string_of_ty a.ty) (string_of_ty b.ty)
   | _ -> fail a.loc "operands must be scalars, got %s and %s" (string_of_ty a.ty) (string_of_ty b.ty));
  (a, b)

and same_type env ?expected a b =
  let a = check_uniform env ?expected a in
  let b = check_uniform env ~expected:a.ty b in
  require b.loc a.ty b.ty "this branch";
  (a, b)

and record_literal env loc name inits =
  match Hashtbl.find_opt env.ctx.records name with
  | Some record ->
      let given = List.map (fun (i : Ast.field_init) -> i.init_field) inits in
      List.iter (fun (field, _) -> if not (List.mem field given) then fail loc "record %s literal lacks field '%s'" name field) record.rfields;
      let fields =
        List.map
          (fun (i : Ast.field_init) ->
            match List.assoc_opt i.init_field record.rfields with
            | None -> fail i.init_value.loc "record %s has no field '%s'" name i.init_field
            | Some ty ->
                let v = check_uniform env ~expected:ty i.init_value in
                require i.init_value.loc ty v.ty ("field " ^ i.init_field);
                (i.init_field, v))
          inits
      in
      mk (Record_lit (name, fields)) (Record name) loc
  | None -> (
      match Hashtbl.find_opt env.ctx.stacks name with
      | Some stack ->
          (* A pack: each column a view of the stack's stored element. *)
          let fields =
            List.map
              (fun (field, element) ->
                match List.find_opt (fun (i : Ast.field_init) -> i.init_field = field) inits with
                | None -> fail loc "pack %s literal lacks column '%s'" name field
                | Some i ->
                    let v = as_view env (check_uniform env i.init_value) in
                    (match v.ty with
                     | View (Sc s, _) when s = element -> ()
                     | ty -> fail i.init_value.loc "column %s holds %s; got %s" field (string_of_ty (Sc element)) (string_of_ty ty));
                    (field, v))
              stack.sfields
          in
          let writable = List.for_all (fun (_, v) -> match v.ty with View (_, w) -> w | _ -> false) fields in
          mk (Pack_lit (name, fields)) (Pack (name, writable)) loc
      | None -> fail loc "unknown record or stack '%s'" name)

(** An array passed where a view is expected is a borrow of all its elements. *)
and as_view env (e : expr) =
  match e.ty with
  | Array (n, element) ->
      let writable = is_writable_place env e in
      let zero = mk (Int 0L) (Sc SInt) e.loc and count = mk (Int (Int64.of_int n)) (Sc SInt) e.loc in
      mk (Slice (e, zero, count)) (View (element, writable)) e.loc
  | _ -> e

and is_writable_place env (e : expr) =
  match e.k with
  | Var name -> (match SM.find_opt name env.vars with Some b -> b.bmut | None -> false)
  | Global name -> (match Hashtbl.find_opt env.ctx.globals name with Some (_, w) -> w | None -> false)
  | Field (base, _) -> (match base.ty with Ptr _ -> true | _ -> is_writable_place env base)
  | Elem (base, _, _) -> (
      match base.ty with View (_, w) -> w | Ptr _ -> true | _ -> is_writable_place env base)
  | _ -> false

and call env ?expected loc name args =
  let arg ?expected a = check_uniform env ?expected a in
  let unary_float f =
    match args with
    | [ a ] ->
        let a = arg ~expected:(Sc SFloat) a in
        (match a.ty with Sc (SFloat | SDouble) -> mk (Math (f, [ a ])) a.ty loc | ty -> fail loc "%s needs a float, got %s" f (string_of_ty ty))
    | _ -> fail loc "%s takes one argument" f
  in
  match (name, args) with
  | f, _ when List.mem f math_unary -> unary_float f
  | "abs", [ a ] ->
      let a = arg ?expected a in
      (match a.ty with Sc s when s <> SBool -> mk (Math ("abs", [ a ])) a.ty loc | ty -> fail loc "abs needs a number, got %s" (string_of_ty ty))
  | (("min" | "max") as f), [ a; b ] ->
      let a, b = same_numeric env ?expected a b in
      mk (Binary ((if f = "min" then Min else Max), a, b)) a.ty loc
  | "bit_not", [ a ] ->
      let a = arg ?expected a in
      ignore (integer_scalar loc "bit_not's operand" a.ty);
      mk (Unary (Bit_not, a)) a.ty loc
  | f, [ a; b ] when List.mem_assoc f bit_binary ->
      let op = List.assoc f bit_binary in
      (match op with
       | Shl | Shr | Shr_signed | Rotl | Rotr ->
           let a = arg ?expected a in
           ignore (integer_scalar loc (f ^ "'s operand") a.ty);
           let b = arg ~expected:(Sc SUint) b in
           ignore (integer_scalar loc (f ^ "'s count") b.ty);
           mk (Binary (op, a, b)) a.ty loc
       | _ ->
           let a, b = same_numeric env ?expected a b in
           ignore (integer_scalar loc (f ^ "'s operands") a.ty);
           mk (Binary (op, a, b)) a.ty loc)
  | (("count_leading_zeros" | "count_trailing_zeros" | "popcount") as f), [ a ] ->
      let a = arg a in
      ignore (integer_scalar loc (f ^ "'s operand") a.ty);
      let kind = match f with "count_leading_zeros" -> Clz | "count_trailing_zeros" -> Ctz | _ -> Popcnt in
      mk (Count_bits (kind, a)) a.ty loc
  | "count", [ a ] -> (
      let a = arg a in
      match a.ty with
      | View _ | Array _ -> mk (Length a) (Sc SInt) loc
      | ty -> fail loc "count takes a view or array, got %s" (string_of_ty ty))
  | "slice", [ a; start; count ] -> (
      let a = arg a in
      let start = arg ~expected:(Sc SInt) start and count = arg ~expected:(Sc SInt) count in
      require start.loc (Sc SInt) start.ty "a slice's start";
      require count.loc (Sc SInt) count.ty "a slice's count";
      match a.ty with
      | View (element, w) -> mk (Slice (a, start, count)) (View (element, w)) loc
      | Array (_, element) -> mk (Slice (a, start, count)) (View (element, is_writable_place env a)) loc
      | ty -> fail loc "slice takes a view or array, got %s" (string_of_ty ty))
  | "unchecked_view", [ p; count ] -> (
      let p = arg p and count = arg ~expected:(Sc SInt) count in
      require count.loc (Sc SInt) count.ty "a view's count";
      match p.ty with
      | Ptr element -> mk (Ptr_view (p, count)) (View (element, true)) loc
      | ty -> fail loc "unchecked_view takes a pointer, got %s" (string_of_ty ty))
  | "addr", [ place ] ->
      let place = arg place in
      (match place.k with
       | Var _ | Global _ | Field _ | Elem _ -> ()
       | _ -> fail loc "addr takes a location");
      mk (Addr place) (Ptr place.ty) loc
  | "is_null", [ p ] ->
      let p = arg p in
      (match p.ty with Ptr _ -> () | ty -> fail loc "is_null takes a pointer, got %s" (string_of_ty ty));
      mk (Is_null p) (Sc SBool) loc
  | _ when env.mode = Vector_mode -> fail loc "vector code can't call '%s' as a uniform scalar function" name
  | _ -> (
      match Hashtbl.find_opt env.ctx.slows name with
      | Some (params, result) ->
          if List.length params <> List.length args then
            fail loc "%s takes %d arguments, got %d" name (List.length params) (List.length args);
          let args = List.map2 (fun p a -> pass_argument env p a) params args in
          mk (Call (name, args)) result loc
      | None -> (
          match Hashtbl.find_opt env.ctx.externs name with
          | Some ext ->
              if List.length ext.eparams <> List.length args then
                fail loc "%s takes %d arguments, got %d" name (List.length ext.eparams) (List.length args);
              let args =
                List.map2
                  (fun p (a : Ast.expr) ->
                    let v = check_uniform env ~expected:p.pty a in
                    (match (p.pty, v.ty) with
                     | Ptr (Sc (SUint8 | SInt8)), Str -> ()
                     | expected, actual -> require a.loc expected actual ("argument " ^ p.pname));
                    v)
                  ext.eparams args
              in
              mk (Extern_call (name, args)) ext.eresult loc
          | None -> (
              match Hashtbl.find_opt env.ctx.vectors name with
              | Some signature -> vector_call env loc name signature args
              | None -> fail loc "unknown function '%s'" name)))

and pass_argument env (p : param) (a : Ast.expr) =
  let v = check_uniform env ~expected:p.pty a in
  let v = match p.pty with View _ -> as_view env v | _ -> v in
  (match (p.pty, v.ty) with
   | View (e, true), View (f, w) ->
       if not w then fail a.loc "argument %s must be writable" p.pname;
       require a.loc (View (e, true)) (View (f, true)) ("argument " ^ p.pname)
   | View (e, false), View (f, _) -> require a.loc (View (e, false)) (View (f, false)) ("argument " ^ p.pname)
   | expected, actual -> require a.loc expected actual ("argument " ^ p.pname));
  if p.pass = Borrow_mut && not (is_writable_place env v) then
    fail a.loc "argument %s is mut: pass a location the caller may write" p.pname;
  if p.pass <> By_value then (
    match v.k with
    | Var _ | Global _ | Field _ | Elem _ -> ()
    | _ when p.pass = Borrow -> ()
    | _ -> fail a.loc "argument %s is borrowed: pass a location" p.pname);
  v

(** A slow call into vector code: views and packs pass unmarked, and every
    uniform scalar is marked <x> at the call, where it becomes a rack. *)
and vector_call env loc name signature args =
  let uniform_arg s (a : Ast.expr) =
    let inner =
      match a.v with
      | EBroadcast inner -> inner
      | EScalarVar name -> { a with v = EVar name }
      | _ -> fail a.loc "a scalar passed to vector code becomes a rack there: mark it <...> at the call"
    in
    let v = check_uniform { env with mode = Slow_mode } ~expected:(Sc s) inner in
    require a.loc (Sc s) v.ty "a uniform argument";
    Arg_uniform v
  in
  let memory_arg expected (a : Ast.expr) =
    (match a.v with EBroadcast _ | EScalarVar _ -> fail a.loc "memory arguments are not uniform scalars; pass them bare" | _ -> ());
    let v = as_view env (check_uniform env a) in
    (match (expected, v.ty) with
     | View (e, true), View (f, w) ->
         if not w then fail a.loc "this run writes the argument: pass a writable view";
         require a.loc (View (e, true)) (View (f, true)) "a view argument"
     | View (e, false), View (f, _) -> require a.loc (View (e, false)) (View (f, false)) "a view argument"
     | Pack (s, true), Pack (t, w) ->
         if not w then fail a.loc "this run writes the pack: pass writable columns";
         if s <> t then fail a.loc "a pack of %s is expected, got %s" s t
     | Pack (s, false), Pack (t, _) -> if s <> t then fail a.loc "a pack of %s is expected, got %s" s t
     | expected, actual -> require a.loc expected actual "a memory argument");
    Arg_memory v
  in
  match signature with
  | Sig_run (params, stream) ->
      let expected = List.length params + (if stream = None then 0 else 1) in
      if List.length args <> expected then
        fail loc "run %s takes %d arguments%s, got %d" name expected
          (if stream = None then "" else " (its last the output view)") (List.length args);
      let rec go params args =
        match (params, args) with
        | [], [] -> []
        | [], [ out ] -> (
            match stream with Some s -> [ memory_arg (View (Sc s, true)) out ] | None -> assert false)
        | p :: ps, a :: rest ->
            let v =
              match p with
              | Run_uniform (_, s) -> uniform_arg s a
              | Run_view (_, s, w) -> memory_arg (View (Sc s, w)) a
              | Run_pack (_, stack, w) -> memory_arg (Pack (stack, w)) a
              | Run_rack (pname, _) ->
                  fail a.loc "run %s takes rack %s, which slow code can't hold" name pname
            in
            v :: go ps rest
        | _ -> fail loc "argument count mismatch"
      in
      mk (Vector_call (name, go params args)) Void loc
  | Sig_crunch (params, result) ->
      if List.length params <> List.length args then
        fail loc "%s takes %d arguments, got %d" name (List.length params) (List.length args);
      (match result with
       | Sc _ -> ()
       | ty -> fail loc "%s returns %s, which slow code can't hold" name (string_of_ty ty));
      let args =
        List.map2
          (fun (pname, ty, uniform) a ->
            match ty with
            | Sc s when uniform -> uniform_arg s a
            | ty -> fail a.loc "%s takes %s %s, which slow code can't make" name (string_of_ty ty) pname)
          params args
      in
      mk (Vector_call (name, args)) result loc

(* Blocks in a run become a non-inlined scalar helper. Its captures are scalar
   values and memory views only, so a vector value never crosses the boundary.
   Blocks already in scalar code remain lexical scopes, sharing outer locations. *)
and slow_expression env ?expected loc body tail =
  let inner = { env with mode = Slow_mode; loops = (if env.mode = Vector_mode then 0 else env.loops) } in
  let checked_env, body = check_slow_statements inner body in
  let tail = Option.map (check_uniform checked_env ?expected) tail in
  let ty = match tail with None -> Void | Some value -> value.ty in
  (match ty with Sc _ | Void -> () | _ -> fail loc "a slow block produces a scalar value or nothing");
  if env.mode = Slow_mode then mk (Block (body, tail)) ty loc
  else (
    let captures =
      SM.bindings env.vars
      |> List.filter_map (fun (name, b) ->
             match b.bty with
             | Sc _ | View (Sc _, _) ->
                 Some ({ pname = name; pty = b.bty; pass = By_value },
                       (match b.bconst with Some value -> mk (Int value) b.bty loc | None -> mk (Var name) b.bty loc))
             | _ -> None)
    in
    let name = fresh env "slow_block" in
    let body = body @ (match tail with
      | Some value when value.ty = Void -> [ { s = Eval value; sloc = loc }; { s = Return None; sloc = loc } ]
      | _ -> [ { s = Return tail; sloc = loc } ]) in
    env.ctx.block_functions :=
      { fname = name; fparams = List.map fst captures; fresult = ty; fbody = body; floc = loc; fblock = true }
      :: !(env.ctx.block_functions);
    mk (Call (name, List.map snd captures)) ty loc)

and check_slow_statements env (stmts : Ast.stmt list) =
  let env, out =
    List.fold_left
      (fun (env, acc) stmt ->
        let env, s = check_slow_stmt env stmt in
        (env, s :: acc))
      (env, []) stmts
  in
  (env, List.rev out)

and check_slow_block env stmts = snd (check_slow_statements env stmts)

and check_slow_stmt env (stmt : Ast.stmt) =
  let loc = stmt.loc in
  let st s = { s; sloc = loc } in
  let declare name annotation value mutable_ =
    let expected = Option.map (ty_of env.ctx) annotation in
    let v = check_uniform env ?expected value in
    let ty = match expected with Some t -> require value.loc t v.ty ("'" ^ name ^ "'"); t | None -> v.ty in
    (match ty with
     | Void -> fail loc "'%s' would hold nothing" name
     | Str -> fail loc "a string literal is passed to an extern, not stored"
     | Pack _ -> fail loc "a pack is built at the run call it is passed to"
     | _ -> ());
    let env = bind env loc name { bty = ty; bmut = mutable_; buniform = false; bconst = None } in
    (env, st (Decl (name, ty, Some v, mutable_)))
  in
  match stmt.v with
  | SLet b -> declare b.bind_name b.bind_type b.bind_expr false
  | SLocBind l -> declare l.loc_name l.loc_type l.loc_expr true
  | SAssign (name, value) ->
      let target = check_uniform env { stmt with v = EVar name } in
      assign env loc target value
  | SStore (target, value) -> assign env loc (check_uniform env target) value
  | SExpr e -> (env, st (Eval (check_uniform env e)))
  | SIf (c, a, b) ->
      let c = check_uniform env ~expected:(Sc SBool) c in
      require c.loc (Sc SBool) c.ty "an if condition";
      (env, st (If (c, check_slow_block env a, check_slow_block env b)))
  | SWhile (c, body) ->
      let c = check_uniform env ~expected:(Sc SBool) c in
      require c.loc (Sc SBool) c.ty "a while condition";
      (env, st (While (c, check_slow_block { env with loops = env.loops + 1 } body)))
  | SLoop l ->
      if l.loop_repeat then fail loc "repeat is the unrolled vector loop; slow code counts with for";
      if l.loop_uniform then fail loc "slow loop indices are plain scalars: for i from a up to b";
      let ty = match l.loop_type with Some t -> ty_of env.ctx t | None -> Sc SInt in
      let s = integer_scalar loc "a loop index" ty in
      let from = check_uniform env ~expected:ty l.loop_from and upto = check_uniform env ~expected:ty l.loop_to in
      require from.loc ty from.ty "the loop start";
      require upto.loc ty upto.ty "the loop bound";
      let by = Option.map (fun e -> let v = check_uniform env ~expected:ty e in require e.loc ty v.ty "the loop step"; v) l.loop_by in
      let inner = bind { env with loops = env.loops + 1 } loc l.loop_var { bty = ty; bmut = false; buniform = false; bconst = None } in
      (env, st (For (l.loop_var, s, from, upto, by, check_slow_block inner l.loop_body)))
  | SBreak -> if env.loops = 0 then fail loc "break outside a loop"; (env, st Break)
  | SContinue -> if env.loops = 0 then fail loc "continue outside a loop"; (env, st Continue)
  | SReturn None ->
      if not env.return_allowed then fail loc "a run has no return; a slow block produces its value with its final expression";
      if env.result <> Void then fail loc "this function returns %s" (string_of_ty env.result);
      (env, st (Return None))
  | SReturn (Some e) ->
      if not env.return_allowed then fail loc "a run has no return; a slow block produces its value with its final expression";
      if env.result = Void then fail loc "this function returns nothing";
      let v = check_uniform env ~expected:env.result e in
      require e.loc env.result v.ty "the returned value";
      (env, st (Return (Some v)))
  | SFused _ -> fail loc "fused bindings are vector code"
  | SUniform _ -> fail loc "every slow value is scalar: write let name: T = value"
  | SOver _ | SYield _ -> fail loc "traversals are run code"

and assign env loc (target : expr) value =
  if not (is_writable_place env target) then fail loc "this location can't be assigned";
  (match target.k with Var _ | Global _ | Field _ | Elem _ -> () | _ -> fail loc "only a location can be assigned");
  let v = check_uniform env ~expected:target.ty value in
  require value.loc target.ty v.ty "the assigned value";
  (env, { s = Assign (target, v); sloc = loc })

(* ─── Definitions ───────────────────────────────────────────────────── *)

let slow_params ctx loc (params : Ast.param list) =
  List.map
    (function
      | Ast.PRack (name, Some t) -> (
          match t.v with
          | TMut ({ v = TView _; _ }) -> { pname = name; pty = ty_of ctx t; pass = By_value }
          | TMut inner -> (
              match () with
              | () -> (
                  match ty_of ctx inner with
                  | (Array _ | Record _) as ty -> { pname = name; pty = ty; pass = Borrow_mut }
                  | ty -> fail loc "%s can't be mut: only views, packs, records and arrays are written through a parameter" (string_of_ty ty)))
          | _ -> (
              match ty_of ctx t with
              | (Array _ | Record _) as ty -> { pname = name; pty = ty; pass = Borrow }
              | (Sc _ | View _ | Ptr _) as ty -> { pname = name; pty = ty; pass = By_value }
              | ty -> fail loc "slow code can't take %s %s" (string_of_ty ty) name))
      | PScalar (name, _) -> fail loc "every slow value is scalar: write %s: T" name
      | _ -> fail loc "slow parameters are written name: T")
    params

let run_params ctx loc (params : Ast.param list) =
  List.map
    (function
      | Ast.PScalar (name, Some t) -> (
          match ty_of ctx t with
          | Sc s -> Run_uniform (name, s)
          | ty -> fail loc "<%s> must be a scalar, got %s" name (string_of_ty ty))
      | PRack (name, Some t) -> (
          match ty_of ctx t with
          | Pack (stack, w) -> Run_pack (name, stack, w)
          | View (Sc s, w) -> Run_view (name, s, w)
          | Rack s -> Run_rack (name, s)
          | ty -> fail loc "a run takes packs, views of scalars, racks and <uniform> scalars, not %s" (string_of_ty ty))
      | _ -> fail loc "run parameters are typed")
    params

let constant_value ctx (e : expr) =
  let rec ok (e : expr) =
    match e.k with
    | Int _ | Float _ | Bool _ -> true
    | Unary (_, a) | Convert (_, _, a) -> ok a
    | Binary (_, a, b) | Compare (_, a, b) -> ok a && ok b
    | Array_lit items -> List.for_all ok items
    | Record_lit (_, fields) -> List.for_all (fun (_, v) -> ok v) fields
    | _ -> false
  in
  ignore ctx;
  ok e

(* ─── Runs ──────────────────────────────────────────────────────────── *)

(** Names a statement's normalisation has bound so far (see [bound] below). *)
let bound_names : binding SM.t ref = ref SM.empty

(** The traversal a run statement sits in: chunk name, stack, domain. *)
type traversal_scope = { chunk : string; chunk_stack : stack; domain : scalar; outer : traversal_scope option }

type run_env = { env : env; scope : traversal_scope option; emit : rstmt list ref }

let emit renv loc r = renv.emit := { r; rloc = loc } :: !(renv.emit)

let types_of_ty = function
  | Rack s -> Some (Types.Rack s)
  | Mask _ -> Some Types.Mask
  | Sc s -> Some (Types.Scalar s)
  | _ -> None

let ty_of_types loc = function
  | Types.Rack s -> Rack s
  | Types.Mask -> Mask Types.SInt
  | Types.Scalar s -> Sc s
  | Types.StorageSlice (stored, domain) ->
      fail loc "a column stored as %s is a %s storage slice; call widen(column) explicitly"
        (string_of_ty (Sc stored)) (string_of_ty (Rack domain))
  | t -> fail loc "%s is not a rack value" (Types.show_concise t)

(** Type a pure rack expression with the crunch checker, so a rack operation
    means the same in a run as in a crunch. *)
let infer_pure renv (e : Ast.expr) =
  let tc = Typecheck.copy_env renv.env.ctx.tc in
  SM.iter
    (fun name b ->
      match (b.bty, b.buniform) with
      | (Rack _ | Mask _), _ | Sc _, true -> (
          match types_of_ty b.bty with Some t -> Hashtbl.replace tc.vars name t | None -> ())
      | _ -> ())
    renv.env.vars;
  SM.iter
    (fun name b ->
      match types_of_ty b.bty with Some t -> Hashtbl.replace tc.vars name t | None -> ())
    !bound_names;
  ty_of_types e.loc (Typecheck.infer_expr tc e)

let rec mask_element renv (e : Ast.expr) =
  match e.v with
  | EBinop (l, (Lt | Le | Gt | Ge | Eq | Ne), r) -> (
      let side (x : Ast.expr) = try (match infer_pure renv x with Rack s -> Some s | _ -> None) with _ -> None in
      match side l with Some s -> s | None -> Option.value (side r) ~default:Types.SInt)
  | EBinop (l, (And | Or), _) | EUnop (Not, l) -> mask_element renv l
  | EVar name -> (match SM.find_opt name renv.env.vars with Some { bty = Mask s; _ } -> s | _ -> Types.SInt)
  | EIf (_, a, _) -> mask_element renv a
  | _ -> Types.SInt

(** The value of a uniform integer expression of literals and unrolled indices. *)
let rec fold (e : expr) =
  match e.k with
  | Int value -> Some value
  | Unary (Neg, a) -> Option.map Int64.neg (fold a)
  | Binary (op, a, b) -> (
      match (fold a, fold b) with
      | Some x, Some y -> (
          match op with
          | Add -> Some (Int64.add x y)
          | Sub -> Some (Int64.sub x y)
          | Mul -> Some (Int64.mul x y)
          | Div when y <> 0L -> Some (Int64.div x y)
          | Rem when y <> 0L -> Some (Int64.rem x y)
          | _ -> None)
      | _ -> None)
  | _ -> None

let constant_int renv (e : Ast.expr) what =
  match fold (check_uniform renv.env e) with
  | Some value -> value
  | None -> fail e.loc "%s must be a constant integer" what

(** A-normal form: hoist every load, gather, scalar read and chunk column
    out of a rack expression, leaving a pure expression over named racks,
    masks and uniform scalars. *)
(** Inside an if's branches, where a hoisted read would happen for lanes and
    cases the branch doesn't take. *)
let in_branch = ref 0

let refuse_branch_read loc =
  if !in_branch > 0 then
    fail loc "an if's branches compute on values: read memory before the if, with let, so the read is visibly unconditional"

let rec normalise renv (e : Ast.expr) : Ast.expr =
  let open Ast in
  let loc = e.loc in
  let re v = { e with v } in
  let var name = re (EVar name) in
  let hoist_uniform (value : Tier_ir.expr) =
    let name = fresh renv.env "u" in
    emit renv loc (R_uniform (name, value));
    renv_bind_uniform renv name value.ty;
    re (EScalarVar name)
  in
  let not_state name =
    if Hashtbl.mem renv.env.ctx.globals name && not (SM.mem name renv.env.vars) then
      fail loc "vector code can't read module state '%s'; pass it as a parameter" name
  in
  match e.v with
  | EInt _ | EFloat _ | EBool _ -> e
  | EVar name -> (
      not_state name;
      if Hashtbl.mem renv.env.ctx.consts name && not (SM.mem name renv.env.vars) then
        let v = Hashtbl.find renv.env.ctx.consts name in
        match v.k with
        | Int n -> re (EInt n)
        | Float f -> re (EFloat f)
        | _ -> fail loc "constant %s is not a rack literal" name
      else
        match (lookup renv.env loc name).bty with
        | Rack _ | Mask _ -> e
        | Rack_array _ -> fail loc "rack array %s is used one element at a time: %s[<k>]" name name
        | View _ -> fail loc "%s is memory: load a rack with %s[<index>]" name name
        | Pack _ -> fail loc "%s is a pack: use a traversal over it" name
        | Sc _ -> fail loc "uniform scalar %s is written <%s>" name name
        | ty -> fail loc "%s holds %s, which is not a rack" name (string_of_ty ty))
  | EScalarVar name -> (
      not_state name;
      match (lookup renv.env loc name) with
      | { bconst = Some value; _ } -> re (EBroadcast (re (EInt value)))
      | { buniform = true; _ } -> e
      | _ -> fail loc "<%s> must name a uniform scalar" name)
  | EBroadcast inner -> (
      match inner.v with
      | EInt _ | EFloat _ -> e
      | EVar name -> normalise renv (re (EScalarVar name))
      | EIndex _ -> refuse_branch_read loc; hoist_uniform (check_uniform renv.env e)
      | _ -> fail loc "a uniform scalar is written <name>, <literal> or <view[index]>")
  | EIndex ({ v = EVar base; _ }, index, unchecked) -> (
      (match (lookup renv.env loc base).bty with View _ -> refuse_branch_read loc | _ -> ());
      match (lookup renv.env loc base).bty with
      | Rack_array (n, _) ->
          let k = constant_int renv index "a rack array index" in
          if k < 0L || k >= Int64.of_int n then fail index.loc "index %Ld is outside rack array %s of %d" k base n;
          var (Printf.sprintf "%s$e%Ld" base k)
      | View (Sc element, _) ->
          let view = check_uniform { renv.env with mode = Slow_mode } (re (EVar base)) in
          if mentions_racks renv.env index then (
            let indices = normalise renv index in
            let index_name = fresh renv.env "g" in
            (match infer_pure renv indices with
             | Rack (Types.SInt | SUint) -> ()
             | ty -> fail index.loc "a gather's indices are an i32s rack, got %s" (string_of_ty ty));
            emit renv loc (R_pure (index_name, Rack SInt, indices, false));
            renv_bind_rack renv index_name (Rack SInt);
            (match element with
             | SInt | SUint | SFloat -> ()
             | s -> fail loc "wasm-simd128 gathers 32-bit elements; %s has %d-bit elements" base (bits s));
            (match renv.scope with
             | Some { domain; _ } when bits domain <> 32 ->
                 fail loc "a gather in a traversal takes the traversal's lanes: traverse with a 32-bit domain such as f32s or i32s"
             | _ -> ());
            let name = fresh renv.env "gather" in
            emit renv loc (R_gather (name, element, view, index_name, not unchecked));
            renv_bind_rack renv name (Rack element);
            var name)
          else
            let index = check_uniform renv.env index in
            ignore (integer_scalar index.loc "an element index" index.ty);
            let name = fresh renv.env "load" in
            emit renv loc (R_load (name, element, view, index, not unchecked));
            renv_bind_rack renv name (Rack element);
            var name
      | ty -> fail loc "%s holds %s and can't be indexed in vector code" base (string_of_ty ty))
  | EIndex _ -> fail loc "vector code indexes a named view or rack array"
  | EField ({ v = EVar chunk; _ }, field) -> chunk_column renv loc chunk field false
  | ECall ("widen", [ { v = EField ({ v = EVar chunk; _ }, field); loc = floc } ]) -> chunk_column renv floc chunk field true
  | EField _ -> fail loc "vector code reads fields of a traversal chunk only"
  | ECall (name, args) -> re (ECall (name, List.map (normalise renv) args))
  | EBinop (a, op, b) -> re (EBinop (normalise renv a, op, normalise renv b))
  | EUnop (op, a) -> re (EUnop (op, normalise renv a))
  | EIf (c, a, b) ->
      (* A uniform condition stays a scalar; a mask condition is a rack. *)
      let c = if mentions_racks renv.env c then normalise renv c else hoist_uniform (check_uniform renv.env c) in
      incr in_branch;
      let branches = try Ok (normalise renv a, normalise renv b) with error -> Error error in
      decr in_branch;
      (match branches with Ok (a, b) -> re (EIf (c, a, b)) | Error error -> raise error)
  | EConvert (kind, t, a) -> re (EConvert (kind, t, normalise renv a))
  | EFma (a, b, c) -> re (EFma (normalise renv a, normalise renv b, normalise renv c))
  | EReduce (op, a) -> re (EReduce (op, normalise renv a))
  | EScan (op, a) -> re (EScan (op, normalise renv a))
  | EShuffle ({ v = ETuple racks; _ } as pair, indices) ->
      re (EShuffle ({ pair with v = ETuple (List.map (normalise renv) racks) }, indices))
  | EShuffle (a, indices) -> re (EShuffle (normalise renv a, indices))
  | EExtract (a, lane) -> re (EExtract (normalise renv a, lane))
  | EInsert (a, lane, x) -> re (EInsert (normalise renv a, lane, normalise renv x))
  | EString _ -> fail loc "a string is not a rack value"
  | _ -> fail loc "this expression has no vector meaning in a run"

and chunk_column renv loc chunk field widened =
  match renv.scope with
  | Some scope when scope.chunk = chunk -> (
      match List.assoc_opt field scope.chunk_stack.sfields with
      | None -> fail loc "stack %s has no column '%s'" scope.chunk_stack.sname field
      | Some stored ->
          let element =
            if bits stored = bits scope.domain then (
              if widened then fail loc "widen requires a stored element narrower than the traversal domain";
              stored)
            else if bits stored > bits scope.domain then
              fail loc "column %s is wider than the %s traversal domain" field (string_of_ty (Rack scope.domain))
            else if not widened then
              fail loc "column %s stored as %s is a storage slice; call widen(column) explicitly" field (string_of_ty (Sc stored))
            else
              match (stored, bits scope.domain) with
              | (SInt8 | SInt16), 32 -> SInt
              | (SUint8 | SUint16), 32 -> SUint
              | (SInt8 | SInt16 | SInt), 64 -> SInt64
              | (SUint8 | SUint16 | SUint), 64 -> SUint64
              | SFloat, 64 -> SDouble
              | _ -> fail loc "no value-preserving widening of %s to %s lanes" (string_of_ty (Sc stored)) (string_of_ty (Rack scope.domain))
          in
          let name = fresh renv.env "column" in
          emit renv loc (R_chunk_load (name, element, field, stored));
          renv_bind_rack renv name (Rack element);
          { Ast.v = Ast.EVar name; loc })
  | Some scope when (let rec outer = function Some s -> s.chunk = chunk || outer s.outer | None -> false in outer scope.outer) ->
      fail loc "%s is an outer traversal's chunk: bind %s.%s with let before the nested traversal" chunk chunk field
  | _ -> fail loc "%s is not a traversal chunk here" chunk

and renv_bind_rack renv name ty =
  renv.env.vars |> ignore;
  bound := SM.add name { bty = ty; bmut = false; buniform = false; bconst = None } !bound

and renv_bind_uniform renv name ty =
  ignore renv;
  bound := SM.add name { bty = ty; bmut = false; buniform = true; bconst = None } !bound

(* Names bound while one statement is normalised; the statement's checker
   folds them into its environment. *)
and bound : binding SM.t ref = bound_names

let with_bound renv =
  let env = { renv.env with vars = SM.union (fun _ a _ -> Some a) !bound renv.env.vars } in
  bound := SM.empty;
  { renv with env }

(** Normalise and type one rack expression; hoisted names are visible to the
    pure expression's checker. *)
let rack_value renv (e : Ast.expr) =
  bound := SM.empty;
  let pure = normalise renv e in
  let renv = with_bound renv in
  let ty = infer_pure renv pure in
  let ty = match ty with Mask _ -> Mask (mask_element renv pure) | ty -> ty in
  (* A marked uniform where a rack is expected is an explicit broadcast. *)
  let ty = match (ty, pure.v) with Sc s, (EScalarVar _ | EBroadcast _) -> Rack s | _ -> ty in
  (renv, pure, ty)

let statement_count stmts =
  let rec count (s : Ast.stmt) =
    match s.v with
    | SIf (_, a, b) -> 1 + List.fold_left (fun n s -> n + count s) 0 (a @ b)
    | SLoop l -> 1 + List.fold_left (fun n s -> n + count s) 0 l.loop_body
    | SOver o -> 1 + List.fold_left (fun n s -> n + count s) 0 o.over_body
    | _ -> 1
  in
  List.fold_left (fun n s -> n + count s) 0 stmts

(** The wasm-simd128 unrolling budget, in source statements after unrolling.
    Points meter executed instructions, so unrolling a fixed-count loop is
    never slower; this bounds code size and compile time. *)
let unroll_budget = 4096

let rec check_run_block renv (stmts : Ast.stmt list) ~yield_last : run_env * rstmt list =
  let outer = renv.emit in
  renv.emit |> ignore;
  let collected = ref [] in
  let renv = { renv with emit = collected } in
  let count = List.length stmts in
  let renv =
    List.fold_left
      (fun (renv, index) stmt -> (check_run_stmt renv stmt ~last:(yield_last && index = count - 1), index + 1))
      (renv, 0) stmts
    |> fst
  in
  ignore outer;
  (renv, List.rev !collected)

and check_run_stmt renv (stmt : Ast.stmt) ~last : run_env =
  let loc = stmt.loc in
  let bind_name renv name binding = { renv with env = bind renv.env loc name binding } in
  match stmt.v with
  | SUniform b ->
      let ty = match b.bind_type with Some t -> ty_of renv.env.ctx t | None -> fail loc "a uniform binding declares its type" in
      (match ty with Sc _ -> () | _ -> fail loc "let <%s: T> binds a scalar" b.bind_name);
      (* Scalar arithmetic on what racks produce, as in maximum(x) - minimum(x):
         each operand computed from racks becomes a uniform of its own, and
         the arithmetic is scalar work on those uniforms. *)
      let rec hoist renv (e : Ast.expr) =
        match e.v with
        | Ast.EBinop (left, operation, right) ->
            let renv, left = hoist renv left in
            let renv, right = hoist renv right in
            (renv, { e with v = Ast.EBinop (left, operation, right) })
        | Ast.EUnop (operation, operand) ->
            let renv, operand = hoist renv operand in
            (renv, { e with v = Ast.EUnop (operation, operand) })
        | _ when mentions_racks renv.env e ->
            let name = fresh renv.env "uniform" in
            let renv, pure, produced = rack_value renv e in
            (match produced with Sc _ -> () | _ -> fail e.loc "this operand of a uniform's arithmetic is not a scalar");
            emit renv e.loc (R_pure (name, produced, pure, false));
            (bind_name renv name { bty = produced; bmut = false; buniform = true; bconst = None },
             { e with v = Ast.EScalarVar name })
        | _ -> (renv, e)
      in
      let renv, b =
        match b.bind_expr.v with
        | (Ast.EBinop _ | Ast.EUnop _) when mentions_racks renv.env b.bind_expr ->
            let renv, hoisted = hoist renv b.bind_expr in
            if mentions_racks renv.env hoisted then (renv, b) else (renv, { b with bind_expr = hoisted })
        | _ -> (renv, b)
      in
      if mentions_racks renv.env b.bind_expr then (
        let renv, pure, actual = rack_value renv b.bind_expr in
        require loc ty actual ("<" ^ b.bind_name ^ ">");
        emit renv loc (R_pure (b.bind_name, ty, pure, false));
        bind_name renv b.bind_name { bty = ty; bmut = false; buniform = true; bconst = None })
      else
        let value = check_uniform renv.env ~expected:ty b.bind_expr in
        require loc ty value.ty ("<" ^ b.bind_name ^ ">");
        emit renv loc (R_uniform (b.bind_name, value));
        bind_name renv b.bind_name { bty = ty; bmut = false; buniform = true; bconst = None }
  | SLet { bind_name = name; bind_type = annotation; bind_expr = value }
  | SFused { fused_name = name; fused_type = annotation; fused_expr = value } ->
      let fused = match stmt.v with SFused _ -> true | _ -> false in
      if fused then (
        match Typecheck.fused_contract_rejection value with
        | Some reason -> fail loc "Fused binding contract for '%s' rejected: %s" name reason
        | None -> ());
      if not (mentions_racks renv.env value || (match value.v with EScalarVar _ | EBroadcast _ -> true | _ -> false)) then
        fail loc "'%s' would be a uniform scalar: declare it let <%s: T> = ..." name name;
      let renv, pure, ty = rack_value renv value in
      (match ty with Sc _ -> fail loc "'%s' would be a uniform scalar: declare it let <%s: T> = ..." name name | _ -> ());
      Option.iter (fun t -> require loc (ty_of renv.env.ctx t) ty ("'" ^ name ^ "'")) annotation;
      emit renv loc (R_pure (name, ty, pure, fused));
      bind_name renv name { bty = ty; bmut = false; buniform = false; bconst = None }
  | SLocBind { loc_name; loc_type; loc_expr } ->
      let declared = Option.map (ty_of renv.env.ctx) loc_type in
      let renv, pure, ty = rack_value renv loc_expr in
      let first = fresh renv.env "init" in
      (match (declared, ty) with
       | Some (Rack_array (n, s)), Rack s' ->
           if s <> s' then fail loc "rack array %s holds %s, got %s" loc_name (string_of_ty (Rack s)) (string_of_ty ty);
           emit renv loc (R_pure (first, ty, pure, false));
           let renv = ref renv in
           for k = 0 to n - 1 do
             let element = Printf.sprintf "%s$e%d" loc_name k in
             emit !renv loc (R_location (element, Rack s, first));
             renv := bind_name !renv element { bty = Rack s; bmut = true; buniform = false; bconst = None }
           done;
           bind_name !renv loc_name { bty = Rack_array (n, s); bmut = true; buniform = false; bconst = None }
       | _, (Rack _ | Mask _) ->
           Option.iter (fun t -> require loc t ty ("'" ^ loc_name ^ "'")) declared;
           emit renv loc (R_pure (first, ty, pure, false));
           emit renv loc (R_location (loc_name, ty, first));
           bind_name renv loc_name { bty = ty; bmut = true; buniform = false; bconst = None }
       | _ -> fail loc "vector code's mutable locations hold racks; uniform scalars are immutable")
  | SAssign (name, value) -> assign_rack renv loc name value
  | SStore (target, value) -> (
      match target.v with
      | EIndex ({ v = EVar base; _ }, index, unchecked) -> (
          match (lookup renv.env loc base).bty with
          | Rack_array (n, _) ->
              let k = constant_int renv index "a rack array index" in
              if k < 0L || k >= Int64.of_int n then fail index.loc "index %Ld is outside rack array %s of %d" k base n;
              assign_rack renv loc (Printf.sprintf "%s$e%Ld" base k) value
          | View (Sc element, writable) ->
              if not writable then fail loc "view %s is read-only: declare it mut []%s" base (string_of_ty (Sc element));
              if mentions_racks renv.env index then fail loc "wasm-simd128 has no scatter: a store takes a uniform index";
              let view = check_uniform { renv.env with mode = Slow_mode } { target with v = Ast.EVar base } in
              let index = check_uniform renv.env index in
              ignore (integer_scalar index.loc "an element index" index.ty);
              let renv, pure, ty = rack_value renv value in
              require loc (Rack element) ty "the stored rack";
              let name = fresh renv.env "stored" in
              emit renv loc (R_pure (name, ty, pure, false));
              emit renv loc (R_store (view, index, name, not unchecked));
              renv
          | ty -> fail loc "%s holds %s and can't be stored to" base (string_of_ty ty))
      | EField ({ v = EVar output; _ }, field) -> (
          match ((lookup renv.env loc output).bty, renv.scope) with
          | Pack (stack, true), Some scope ->
              let stack = Hashtbl.find renv.env.ctx.stacks stack in
              let element = match List.assoc_opt field stack.sfields with Some e -> e | None -> fail loc "stack %s has no column %s" stack.sname field in
              if bits element <> bits scope.domain then
                fail loc "output column %s must have the traversal domain's lane width" field;
              let renv, pure, ty = rack_value renv value in
              require loc (Rack element) ty "the stored rack";
              let name = fresh renv.env "output" in
              emit renv loc (R_pure (name, ty, pure, false));
              emit renv loc (R_output (output, field, name));
              renv
          | Pack (_, false), _ -> fail loc "pack %s is read-only: declare it mut pack" output
          | _ -> fail loc "%s.%s is stored only inside a traversal over the same records" output field)
      | _ -> fail loc "vector code stores to view[<index>], rack array elements and output columns")
  | SExpr ({ v = ESlow _; _ } as value) ->
      emit renv loc (R_slow (check_uniform renv.env value));
      renv
  | SExpr value when last -> (
      match renv.scope with
      | Some _ ->
          let renv, pure, ty = rack_value renv value in
          (match ty with Rack _ -> () | _ -> fail loc "a traversal yields a rack");
          let name = fresh renv.env "yield" in
          emit renv loc (R_pure (name, ty, pure, false));
          emit renv loc (R_yield name);
          renv
      | None -> fail loc "an expression statement has no effect in vector code")
  | SExpr _ -> fail loc "an expression statement has no effect in vector code"
  | SYield _ -> fail loc "yield ends a traversal"
  | SLoop l when l.loop_repeat ->
      if not l.loop_uniform then fail loc "repeat's index is uniform: repeat <i: i32> from <a> up to <b>";
      let ty = match l.loop_type with Some t -> ty_of renv.env.ctx t | None -> Sc SInt in
      ignore (integer_scalar loc "repeat's index" ty);
      let first = constant_int renv l.loop_from "repeat's start" and stop = constant_int renv l.loop_to "repeat's bound" in
      let trips = Int64.to_int (Int64.sub stop first) in
      if trips * statement_count l.loop_body <= unroll_budget then (
        for k = 0 to trips - 1 do
          let copy = { renv with env = bind renv.env loc l.loop_var { bty = ty; bmut = false; buniform = true; bconst = Some (Int64.add first (Int64.of_int k)) } } in
          let _, body = check_run_block copy l.loop_body ~yield_last:false in
          emit renv loc (R_block body)
        done;
        renv)
      else
        let inner = { renv with env = bind renv.env loc l.loop_var { bty = ty; bmut = false; buniform = true; bconst = None } } in
        let _, body = check_run_block inner l.loop_body ~yield_last:false in
        emit renv loc (R_for (l.loop_var, mk (Int first) ty loc, mk (Int stop) ty loc, None, body));
        renv
  | SLoop l ->
      if not l.loop_uniform then fail loc "a vector loop's index is uniform: for <i: i32> from <a> up to <b>";
      let ty = match l.loop_type with Some t -> ty_of renv.env.ctx t | None -> Sc SInt in
      ignore (integer_scalar loc "a loop index" ty);
      let from = check_uniform renv.env ~expected:ty l.loop_from and upto = check_uniform renv.env ~expected:ty l.loop_to in
      require from.loc ty from.ty "the loop start";
      require upto.loc ty upto.ty "the loop bound";
      let by = Option.map (fun e -> let v = check_uniform renv.env ~expected:ty e in require e.loc ty v.ty "the loop step"; v) l.loop_by in
      (match by with Some { k = Int n; _ } when n <= 0L -> fail loc "a loop steps forward" | _ -> ());
      let inner = { renv with env = bind renv.env loc l.loop_var { bty = ty; bmut = false; buniform = true; bconst = None } } in
      let _, body = check_run_block inner l.loop_body ~yield_last:false in
      emit renv loc (R_for (l.loop_var, from, upto, by, body));
      renv
  | SIf (c, a, b) ->
      if mentions_racks renv.env c then
        fail loc "a statement if takes a uniform condition; choose lanes with if mask then a else b";
      let c = check_uniform renv.env ~expected:(Sc SBool) c in
      require c.loc (Sc SBool) c.ty "an if condition";
      let _, a = check_run_block renv a ~yield_last:false in
      let _, b = check_run_block renv b ~yield_last:false in
      emit renv loc (R_if (c, a, b));
      renv
  | SOver o -> (
      match (lookup renv.env loc o.over_pack).bty with
      | Pack (stack_name, _) ->
          let stack = Hashtbl.find renv.env.ctx.stacks stack_name in
          let domain = scalar_of_prim o.over_domain in
          (* A nested traversal's lanes are its outer traversal's, so their
             tails combine into one prefix mask. *)
          (match renv.scope with
           | Some outer when lanes outer.domain <> lanes domain ->
               fail loc "a nested traversal takes its outer traversal's lane count: %s has %d lanes, %s %d"
                 (string_of_ty (Rack domain)) (lanes domain) (string_of_ty (Rack outer.domain)) (lanes outer.domain)
           | _ -> ());
          let count = check_uniform renv.env o.over_count in
          (match count.ty with
           | Sc (SInt | SInt64) -> ()
           | ty -> fail o.over_count.loc "Over loop count must be scalar int/int64, got %s" (string_of_ty ty));
          let inner =
            { renv with scope = Some { chunk = o.over_chunk; chunk_stack = stack; domain; outer = renv.scope };
              env = bind renv.env loc o.over_chunk { bty = Pack (stack_name, false); bmut = false; buniform = false; bconst = None } }
          in
          let _, body = check_run_block inner o.over_body ~yield_last:true in
          (* Its stores would be bounded by both traversals at once: it
             accumulates into locations, which the outer traversal stores. *)
          if renv.scope <> None then (
            let rec stores stmts = List.exists (fun s -> match s.r with R_yield _ | R_output _ | R_store _ -> true | R_for (_, _, _, _, b) | R_block b -> stores b | R_if (_, a, b) -> stores a || stores b | R_traverse t -> stores t.t_body | _ -> false) stmts in
            if stores body then
              fail loc "a nested traversal can't yield or store: accumulate into a location and store it in the outer traversal");
          emit renv loc (R_traverse { t_pack = o.over_pack; t_stack = stack_name; t_domain = domain; t_count = count; t_body = body });
          renv
      | ty -> fail loc "Expected pack type, got %s" (string_of_ty ty))
  | SWhile _ -> fail loc "vector code loops are counted: for <i: i32> from <a> up to <b>"
  | SBreak | SContinue -> fail loc "vector loops run every iteration; there is no break"
  | SReturn _ -> fail loc "a run ends after its last statement"

and assign_rack renv loc name value =
  if Hashtbl.mem renv.env.ctx.globals name && not (SM.mem name renv.env.vars) then
    fail loc "vector code can't write module state '%s'; use a slow block" name;
  let binding = lookup renv.env loc name in
  if not binding.bmut then fail loc "'%s' is not a mutable location" name;
  let renv, pure, ty = rack_value renv value in
  require loc binding.bty ty ("the value assigned to " ^ name);
  let fresh_name = fresh renv.env "next" in
  emit renv loc (R_pure (fresh_name, ty, pure, false));
  emit renv loc (R_set (name, fresh_name));
  renv

let check_run_body env params stream body loc =
  let env =
    List.fold_left
      (fun env -> function
        | Run_pack (name, stack, w) -> bind env loc name { bty = Pack (stack, w); bmut = false; buniform = false; bconst = None }
        | Run_view (name, s, w) -> bind env loc name { bty = View (Sc s, w); bmut = false; buniform = false; bconst = None }
        | Run_uniform (name, s) -> bind env loc name { bty = Sc s; bmut = false; buniform = true; bconst = None }
        | Run_rack (name, s) -> bind env loc name { bty = Rack s; bmut = false; buniform = false; bconst = None })
      env params
  in
  let renv = { env; scope = None; emit = ref [] } in
  let _, stmts = check_run_block renv body ~yield_last:false in
  (match stream with
   | Some element -> (
       match List.rev stmts with
       | { r = R_traverse t; _ } :: _ ->
           if bits element <> bits t.t_domain then
             fail loc "a run yielding %s racks stores elements of their width" (string_of_ty (Rack t.t_domain));
           let rec yields = function
             | [] -> false
             | { r = R_yield _; _ } :: _ -> true
             | _ :: rest -> yields rest
           in
           if not (yields t.t_body) then fail loc "Run result is not produced; the traversal must end in yield"
       | _ -> fail loc "Run result is not produced; the body must end in an over loop")
   | None ->
       let rec yields stmts = List.exists (fun s -> match s.r with R_yield _ -> true | R_traverse t -> yields t.t_body | R_for (_, _, _, _, b) | R_block b -> yields b | R_if (_, a, b) -> yields a || yields b | _ -> false) stmts in
       if yields stmts then fail loc "only a run declared -> T yields; this run stores to its views");
  stmts

let check_program ?(base_dir = ".") (program : Ast.program) : program =
  let tc = Typecheck.check_program program in
  let ctx =
    {
      records = Hashtbl.create 16; stacks = Hashtbl.create 16; slows = Hashtbl.create 32;
      externs = Hashtbl.create 32; vectors = Hashtbl.create 32; globals = Hashtbl.create 16;
      consts = Hashtbl.create 16; tc; base_dir; block_functions = ref [];
    }
  in
  let defs = List.concat_map (fun (m : Ast.module_) -> m.mod_defs) program in
  (* Names first: records and stacks may refer to each other in any order. *)
  List.iter
    (fun (d : Ast.def) ->
      match d.v with
      | DRecord (name, header, _) ->
          if Hashtbl.mem ctx.records name then fail d.loc "record %s is declared twice" name;
          Hashtbl.replace ctx.records name { rname = name; rheader = header; rfields = []; rloc = d.loc }
      | DStack (name, fields) ->
          let fields =
            List.map (fun (f : Ast.field) -> match f.field_type.v with TScalar p -> (f.field_name, scalar_of_prim p) | _ -> fail d.loc "stack columns are scalars") fields
          in
          Hashtbl.replace ctx.stacks name { sname = name; sfields = fields }
      | _ -> ())
    defs;
  let records =
    List.filter_map
      (fun (d : Ast.def) ->
        match d.v with
        | DRecord (name, header, fields) ->
            let rfields =
              List.map
                (fun (f : Ast.field) ->
                  let ty = storable ctx f.field_type in
                  (match ty with
                   | Record inner when inner = name -> fail f.field_type.loc "record %s can't contain itself" name
                   | _ -> ());
                  (f.field_name, ty))
                fields
            in
            let names = List.map fst rfields in
            if List.length (List.sort_uniq compare names) <> List.length names then
              fail d.loc "record %s repeats a field" name;
            let record = { rname = name; rheader = header; rfields; rloc = d.loc } in
            Hashtbl.replace ctx.records name record;
            Some record
        | _ -> None)
      defs
  in
  (* Records in an order where each follows the records its fields hold. *)
  let records =
    let placed = Hashtbl.create 16 in
    let rec holds = function Record name -> [ name ] | Array (_, t) -> holds t | _ -> [] in
    let rec place visiting acc (r : record) =
      if Hashtbl.mem placed r.rname then acc
      else if List.mem r.rname visiting then fail r.rloc "records %s hold each other" r.rname
      else
        let acc =
          List.fold_left
            (fun acc (_, ty) -> List.fold_left (fun acc name -> place (r.rname :: visiting) acc (Hashtbl.find ctx.records name)) acc (holds ty))
            acc r.rfields
        in
        Hashtbl.replace placed r.rname ();
        r :: acc
    in
    List.rev (List.fold_left (place []) [] records)
  in
  let fresh = ref 0 in
  let top_env = { ctx; vars = SM.empty; mode = Slow_mode; loops = 0; result = Void; fresh; return_allowed = true } in
  let consts = ref [] and states = ref [] and embeds = ref [] and externs = ref [] in
  List.iter
    (fun (d : Ast.def) ->
      match d.v with
      | DConst (name, t, value) ->
          let ty = ty_of ctx t in
          let v = check_uniform top_env ~expected:ty value in
          require value.loc ty v.ty ("constant " ^ name);
          if not (constant_value ctx v) then fail value.loc "a constant's value is computed from literals";
          Hashtbl.replace ctx.consts name v;
          consts := (name, ty, v) :: !consts
      | DEmbed (name, file) ->
          let path = if Filename.is_relative file then Filename.concat base_dir file else file in
          let contents = try In_channel.with_open_bin path In_channel.input_all with Sys_error message -> fail d.loc "can't embed %s: %s" file message in
          Hashtbl.replace ctx.globals name (View (Sc SUint8, false), false);
          embeds := (name, contents) :: !embeds
      | DSlow (name, params, result, _) ->
          let result = match result with Some t -> ty_of ctx t | None -> Void in
          (match result with Array _ -> fail d.loc "a slow function returns arrays through a mut parameter" | View _ | Pack _ | Rack _ | Mask _ | Rack_array _ -> fail d.loc "%s can't be returned by slow code" (string_of_ty result) | _ -> ());
          if name = "main" && (params <> [] || result <> Sc SInt) then fail d.loc "main is slow main() -> i32";
          Hashtbl.replace ctx.slows name (slow_params ctx d.loc params, result)
      | DExtern (name, params, result, header) ->
          let eparams =
            List.map
              (function
                | Ast.PRack (pname, Some t) -> (
                    match ty_of ctx t with
                    | (Sc _ | Ptr _ | Record _) as ty -> { pname; pty = ty; pass = By_value }
                    | ty -> fail d.loc "extern %s can't take %s: C has scalars, pointers and structs" name (string_of_ty ty))
                | _ -> fail d.loc "extern parameters are written name: T")
              params
          in
          let eresult = match result with Some t -> ty_of ctx t | None -> Void in
          let ext = { ename = name; eheader = header; eparams; eresult } in
          Hashtbl.replace ctx.externs name ext;
          externs := ext :: !externs
      | DRun (name, params, result, _) ->
          let stream = Option.map (fun (t : Ast.typ) -> match ty_of ctx t with Sc s -> s | ty -> fail t.loc "a stream run stores scalars, got %s" (string_of_ty ty)) result.result_type in
          Hashtbl.replace ctx.vectors name (Sig_run (run_params ctx d.loc params, stream))
      | DCrunch (name, params, result, _) | DRake (name, params, result, _, _, _, _) -> (
          try
            let params =
              List.map
                (function
                  | Ast.PScalar (p, Some t) -> (p, ty_of ctx t, true)
                  | PRack (p, Some t) -> (p, ty_of ctx t, false)
                  | _ -> raise Exit)
                params
            in
            let result = match result.result_type with Some t -> ty_of ctx t | None -> Rack SFloat in
            Hashtbl.replace ctx.vectors name (Sig_crunch (params, result))
          with Exit -> ())
      | _ -> ())
    defs;
  (* State initialisers may name constants. *)
  List.iter
    (fun (d : Ast.def) ->
      match d.v with
      | DState (name, t, init) ->
          let ty = ty_of ctx t in
          (match ty with Sc _ | Array _ | Record _ | Ptr _ -> () | _ -> fail d.loc "module state holds scalars, arrays, records and pointers");
          let init =
            Option.map
              (fun value ->
                let v = check_uniform top_env ~expected:ty value in
                require value.loc ty v.ty ("state " ^ name);
                if not (constant_value ctx v) then fail value.loc "state starts from a constant value";
                v)
              init
          in
          Hashtbl.replace ctx.globals name (ty, true);
          states := (name, ty, init) :: !states
      | _ -> ())
    defs;
  let slows =
    List.filter_map
      (fun (d : Ast.def) ->
        match d.v with
        | DSlow (name, _, _, body) ->
            let params, result = Hashtbl.find ctx.slows name in
            let env =
              List.fold_left
                (fun env p ->
                  bind env d.loc p.pname
                    { bty = p.pty; bmut = (p.pass = Borrow_mut || (match p.pty with View (_, w) -> w | _ -> false)); buniform = false; bconst = None })
                { top_env with result } params
            in
            (* Views passed by value are writable through, not reassignable. *)
            let env = { env with vars = SM.mapi (fun n b -> if List.exists (fun p -> p.pname = n && p.pass = By_value) params then { b with bmut = false } else b) env.vars } in
            let body = check_slow_block env body in
            if result <> Void && not (definitely_returns body) then
              fail d.loc "slow function %s may end without returning %s" name (string_of_ty result);
            Some { fname = name; fparams = params; fresult = result; fbody = body; floc = d.loc; fblock = false }
        | _ -> None)
      defs
  in
  let runs =
    List.filter_map
      (fun (d : Ast.def) ->
        match d.v with
        | DRun (name, _, _, body) -> (
            match Hashtbl.find ctx.vectors name with
            | Sig_run (params, stream) ->
                let env = { top_env with mode = Vector_mode; return_allowed = false } in
                let body = check_run_body env params stream body d.loc in
                Some { run_name = name; run_params = params; run_stream = stream; run_body = body; run_loc = d.loc }
            | Sig_crunch _ -> None)
        | _ -> None)
      defs
  in
  {
    source = program;
    stacks = Hashtbl.fold (fun _ s acc -> s :: acc) ctx.stacks [] |> List.sort compare;
    records;
    externs = List.rev !externs;
    states = List.rev !states;
    embeds = List.rev !embeds;
    consts = List.rev !consts;
    slows = slows @ List.rev !(ctx.block_functions);
    runs;
    vector_defs = List.filter (fun (d : Ast.def) -> match d.v with DCrunch _ | DRake _ -> true | _ -> false) defs;
  }

let check ?base_dir program =
  try Ok (check_program ?base_dir program) with
  | Error (loc, message) -> Error (format_error loc message)
  | Typecheck.TypeError (message, loc) -> Error (format_error loc message)
