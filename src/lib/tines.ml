open Ast
(** Global predicates and lane-definedness. Mask coverage is propositional:
    comparisons are independent atoms, including ordered floating comparisons.
    In particular, [not (x >= 0)] must not become [x < 0] in the presence of
    NaN. *)

exception Error of loc * string

let fail loc fmt =
  Printf.ksprintf (fun message -> raise (Error (loc, message))) fmt

let find_definition definitions name loc =
  match
    List.find_opt
      (fun definition ->
        match definition.v with
        | DTine (candidate, _, _) -> candidate = name
        | _ -> false)
      definitions
  with
  | Some { v = DTine (_, parameters, predicate); _ } -> (parameters, predicate)
  | _ -> fail loc "Undefined global tine: #%s" name

let rec substitute_expression bindings expression =
  let substitute = substitute_expression bindings in
  let value =
    match expression.v with
    | EVar name -> (
        match List.assoc_opt name bindings with
        | Some argument -> argument.v
        | None -> expression.v)
    | EScalarVar name -> (
        match List.assoc_opt name bindings with
        | Some argument -> EBroadcast argument
        | None -> expression.v)
    | EBinop (left, operator, right) ->
        EBinop (substitute left, operator, substitute right)
    | EUnop (operator, operand) -> EUnop (operator, substitute operand)
    | EBroadcast operand -> EBroadcast (substitute operand)
    | EField (base, field) -> EField (substitute base, field)
    | EInt _ | EFloat _ | EBool _ -> expression.v
    | _ ->
        fail expression.loc
          "Global tine arguments must be pure lane expressions"
  in
  { expression with v = value }

let rec substitute_predicate bindings predicate =
  let expression = substitute_expression bindings in
  let substitute = substitute_predicate bindings in
  let value =
    match predicate.v with
    | PCmp (left, operator, right) ->
        PCmp (expression left, operator, expression right)
    | PExpr operand -> PExpr (expression operand)
    | PIs (left, right) -> PIs (expression left, expression right)
    | PIsNot (left, right) -> PIsNot (expression left, expression right)
    | PAnd (left, right) -> PAnd (substitute left, substitute right)
    | POr (left, right) -> POr (substitute left, substitute right)
    | PNot operand -> PNot (substitute operand)
    | PTineCall (name, arguments) ->
        PTineCall (name, List.map expression arguments)
    | PTineRef _ -> predicate.v
  in
  { predicate with v = value }

let expand_calls definitions predicate =
  let rec expand visiting predicate =
    let value =
      match predicate.v with
      | PTineCall (name, arguments) ->
          if List.mem name visiting then
            fail predicate.loc "Recursive global tine: #%s" name;
          let parameters, body =
            find_definition definitions name predicate.loc
          in
          if List.length parameters <> List.length arguments then
            fail predicate.loc "Global tine #%s expects %d arguments, got %d"
              name (List.length parameters) (List.length arguments);
          let bindings =
            List.map2
              (fun parameter argument ->
                match parameter with
                | PRack (name, Some _) -> (name, argument)
                | PScalar (name, Some _) ->
                    let scalar =
                      match argument.v with
                      | EBroadcast scalar -> scalar
                      | EScalarVar name -> { argument with v = EVar name }
                      | _ ->
                          fail argument.loc
                            "A global tine's uniform argument must use angle \
                             brackets"
                    in
                    (name, scalar)
                | _ ->
                    fail predicate.loc
                      "Global tine parameters require explicit rack or uniform \
                       types")
              parameters arguments
          in
          (expand (name :: visiting) (substitute_predicate bindings body)).v
      | PAnd (left, right) -> PAnd (expand visiting left, expand visiting right)
      | POr (left, right) -> POr (expand visiting left, expand visiting right)
      | PNot operand -> PNot (expand visiting operand)
      | PCmp _ | PExpr _ | PIs _ | PIsNot _ | PTineRef _ -> predicate.v
    in
    { predicate with v = value }
  in
  expand [] predicate

type mask_proof = {
  nodes : (int, string * int * int) Hashtbl.t;
  interned : (string * int * int, int) Hashtbl.t;
  conjunctions : (int * int, int) Hashtbl.t;
  complements : (int, int) Hashtbl.t;
  mutable next_node : int;
  location : loc;
}
(** A reduced ordered Boolean decision diagram. Terminals 0 and 1 are false and
    true; the remaining nodes are interned by atom and child identities. *)

let create_proof location =
  {
    nodes = Hashtbl.create 32;
    interned = Hashtbl.create 32;
    conjunctions = Hashtbl.create 32;
    complements = Hashtbl.create 32;
    next_node = 2;
    location;
  }

let make_node proof atom low high =
  if low = high then low
  else
    match Hashtbl.find_opt proof.interned (atom, low, high) with
    | Some node -> node
    | None ->
        if proof.next_node >= 10000 then
          fail proof.location
            "Mask coverage proof is too complex; use simpler explicit tines";
        let node = proof.next_node in
        proof.next_node <- node + 1;
        Hashtbl.add proof.nodes node (atom, low, high);
        Hashtbl.add proof.interned (atom, low, high) node;
        node

let rec complement proof mask =
  if mask < 2 then 1 - mask
  else
    match Hashtbl.find_opt proof.complements mask with
    | Some result -> result
    | None ->
        let atom, low, high = Hashtbl.find proof.nodes mask in
        let result =
          make_node proof atom (complement proof low) (complement proof high)
        in
        Hashtbl.add proof.complements mask result;
        result

let rec conjunction proof left right =
  if left = 0 || right = 0 then 0
  else if left = 1 then right
  else if right = 1 || left = right then left
  else
    let left, right = if left < right then (left, right) else (right, left) in
    match Hashtbl.find_opt proof.conjunctions (left, right) with
    | Some result -> result
    | None ->
        let left_atom, left_low, left_high = Hashtbl.find proof.nodes left in
        let right_atom, right_low, right_high =
          Hashtbl.find proof.nodes right
        in
        let atom = min left_atom right_atom in
        let left_low, left_high =
          if left_atom = atom then (left_low, left_high) else (left, left)
        in
        let right_low, right_high =
          if right_atom = atom then (right_low, right_high) else (right, right)
        in
        let result =
          make_node proof atom
            (conjunction proof left_low right_low)
            (conjunction proof left_high right_high)
        in
        Hashtbl.add proof.conjunctions (left, right) result;
        result

let disjunction proof left right =
  complement proof
    (conjunction proof (complement proof left) (complement proof right))

let rec expression_key expression =
  match expression.v with
  | EVar name -> Printf.sprintf "variable:%S" name
  | EScalarVar name -> Printf.sprintf "broadcast(variable:%S)" name
  | EInt value -> "integer:" ^ Int64.to_string value
  | EFloat value -> "float:" ^ Int64.to_string (Int64.bits_of_float value)
  | EBool value -> string_of_bool value
  | EBroadcast operand -> "broadcast(" ^ expression_key operand ^ ")"
  | EUnop (operator, operand) ->
      show_unop operator ^ "(" ^ expression_key operand ^ ")"
  | EBinop (left, operator, right) ->
      show_binop operator ^ "(" ^ expression_key left ^ ","
      ^ expression_key right ^ ")"
  | EField (base, field) ->
      Printf.sprintf "field(%s,%S)" (expression_key base) field
  | _ ->
      fail expression.loc
        "This expression cannot participate in a mask coverage proof"

let check_defined_rake definitions tines throughs sweep location =
  let proof = create_proof location in
  let local_masks = Hashtbl.create 16 in
  let partial_values = Hashtbl.create 16 in
  let rec check_expression context expression =
    let check = check_expression context and check_all = check_expression 1 in
    let check_variable name =
      match Hashtbl.find_opt partial_values name with
      | Some domain
        when conjunction proof context (complement proof domain) <> 0 ->
          fail expression.loc
            "Value '%s' is undefined outside its through mask; select it under \
             that mask or supply an else fallback"
            name
      | _ -> ()
    in
    match expression.v with
    | EVar name | EScalarVar name -> check_variable name
    | EBinop (left, _, right) | EPipe (left, right) | EFusedPipe (left, right)
      ->
        check left;
        check right
    | EUnop (_, operand)
    | EBroadcast operand
    | EField (operand, _)
    | EConvert (_, _, operand) ->
        check operand
    | EFma (a, b, c) | EIf (a, b, c) ->
        check a;
        check b;
        check c
    | ELet (binding, body) ->
        check binding.bind_expr;
        check body
    | ERecord (_, fields) | EStack (_, fields) ->
        List.iter (fun field -> check field.init_value) fields
    | EWith (base, fields) ->
        check base;
        List.iter (fun field -> check field.init_value) fields
    | ECall (name, arguments) ->
        let check =
          match Masked_safety.classify_builtin name with
          | Masked_safety.Sanitized -> check
          | Masked_safety.Unsupported -> check_all
        in
        List.iter check arguments
    | EShuffle (operand, _)
    | EShift (operand, _, _)
    | ERotate (operand, _, _)
    | EReduce (_, operand)
    | EScan (_, operand) ->
        check_all operand
    | EExtract (operand, index) ->
        check_all operand;
        check index
    | EInsert (operand, index, value) ->
        check_all operand;
        check index;
        check value
    | EGather (base, indices) | ECompress (base, indices) ->
        check_all base;
        check_all indices
    | EScatter (base, indices, values) | EExpand (base, indices, values) ->
        check_all base;
        check_all indices;
        check_all values
    | EOuter (left, right) ->
        check_all left;
        check_all right
    | ETuple operands | EArray operands -> List.iter check operands
    | EIndex (base, index, _) ->
        check_all base;
        check index
    | ELambda (_, body) -> check_all body
    | ETines _ | ESlow _ ->
        fail expression.loc
          "Nested masked or slow blocks are unavailable in a rake"
    | EInt _ | EFloat _ | EBool _ | ELaneIndex | ELanes | EUnit | EString _ ->
        ()
  in
  let rec mask predicate =
    match (expand_calls definitions predicate).v with
    | PTineRef name -> (
        match Hashtbl.find_opt local_masks name with
        | Some value -> value
        | None -> fail predicate.loc "Undefined local tine: #%s" name)
    | PNot operand -> complement proof (mask operand)
    | PAnd (left, right) -> conjunction proof (mask left) (mask right)
    | POr (left, right) -> disjunction proof (mask left) (mask right)
    | PCmp (left, operator, right) ->
        check_expression 1 left;
        check_expression 1 right;
        make_node proof
          (show_cmp_op operator ^ "(" ^ expression_key left ^ ","
         ^ expression_key right ^ ")")
          0 1
    | PExpr operand ->
        check_expression 1 operand;
        make_node proof (expression_key operand) 0 1
    | PIs _ | PIsNot _ | PTineCall _ ->
        fail predicate.loc "Unsupported predicate in mask coverage proof"
  in
  List.iter
    (fun tine -> Hashtbl.add local_masks tine.tine_name (mask tine.tine_pred))
    tines;
  List.iter
    (fun through ->
      let predicate =
        match through.through_tine with
        | TRSingle name -> node (PTineRef name) through.through_result.loc
        | TRComposed predicate -> predicate
      in
      let context = mask predicate in
      let saved_values = Hashtbl.copy partial_values in
      List.iter
        (fun statement ->
          match statement.v with
          | SLet binding | SUniform binding ->
              check_expression context binding.bind_expr;
              Hashtbl.replace partial_values binding.bind_name context
          | SFused binding ->
              check_expression context binding.fused_expr;
              Hashtbl.replace partial_values binding.fused_name context
          | SExpr expression -> check_expression context expression
          | _ ->
              fail statement.loc
                "Only immutable lane expressions are permitted in a through \
                 block")
        through.through_body;
      check_expression context through.through_result;
      Hashtbl.reset partial_values;
      Hashtbl.iter (Hashtbl.add partial_values) saved_values;
      Option.iter (check_expression 1) through.through_passthru;
      let domain =
        match through.through_passthru with Some _ -> 1 | None -> context
      in
      Hashtbl.replace partial_values through.through_binding domain)
    throughs;
  let claimed = ref 0 in
  List.iter
    (fun arm ->
      let selector =
        match arm.arm_tine with None -> 1 | Some predicate -> mask predicate
      in
      let context = conjunction proof selector (complement proof !claimed) in
      if context = 0 then fail arm.arm_value.loc "Unreachable sweep arm";
      check_expression context arm.arm_value;
      claimed := disjunction proof !claimed selector)
    sweep.sweep_arms;
  if !claimed <> 1 then
    fail location
      "Sweep does not provably cover every lane; add gaps or a final (_) arm"
