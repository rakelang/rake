(** Direct lowering from checked Rake AST to native, rack-preserving SSA.

    The executable slice covers straight-line [crunch] definitions and
    predicated [rake] definitions. Unsupported forms fail here rather than
    leaking into target legalization. *)

open Ast

module Ir = Native_ir
module StringMap = Map.Make (String)
module Int32Map = Map.Make (Int32)

let ( let* ) = Result.bind

type error = { loc : loc; message : string }

let format_error error =
  Printf.sprintf "%s:%d:%d: native lowering: %s" error.loc.file error.loc.line error.loc.col
    error.message

let error loc message = Error { loc; message }
let errorf loc format = Printf.ksprintf (fun message -> error loc message) format

let ir_location (loc : Ast.loc) : Ir.source_location =
  { file = loc.file; line = loc.line; col = loc.col; offset = loc.offset }

type binding = Ir.value * Ir.typ

type state = {
  mutable next_value : int;
  mutable next_fused_region : int;
  mutable instructions_rev : Ir.instruction list;
  mutable bindings : binding StringMap.t;
  mutable tines : binding StringMap.t;
  mutable rack_constants : binding Int32Map.t;
  mutable mask_constants : binding option * binding option;
}

let ir_typ_of_annotation typ =
  match typ.v with
  | TRack PFloat -> Ok (Ir.Rack Ir.F32)
  | TScalar PFloat -> Ok (Ir.Scalar Ir.F32)
  | TMask -> Ok Ir.Mask
  | _ ->
      error typ.loc
        "only 'float rack', scalar 'float', and mask annotations are supported by native crunch lowering"

let check_annotation annotation actual =
  match annotation with
  | None -> Ok ()
  | Some typ ->
      let* annotated = ir_typ_of_annotation typ in
      if annotated = actual then Ok ()
      else
        errorf typ.loc "annotation has type %s but expression has type %s"
          (Ir.string_of_typ annotated) (Ir.string_of_typ actual)

let find_binding state loc name =
  match StringMap.find_opt name state.bindings with
  | Some binding -> Ok binding
  | None -> errorf loc "undefined variable '%s'" name

let bind state loc name binding =
  if StringMap.mem name state.bindings then errorf loc "SSA name '%s' is already bound" name
  else (
    state.bindings <- StringMap.add name binding state.bindings;
    Ok ())

let emit state loc provenance typ op =
  let id = state.next_value in
  state.next_value <- id + 1;
  state.instructions_rev <-
    { Ir.result = Some (id, typ); op; provenance; loc = ir_location loc }
    :: state.instructions_rev;
  (id, typ)

let rack_constant state loc _provenance value =
  let bits = Int32.bits_of_float value in
  match Int32Map.find_opt bits state.rack_constants with
  | Some binding -> binding
  | None ->
      let binding =
        emit state loc Ir.source (Ir.Rack Ir.F32)
          (Ir.Rack_splat (Ir.Float32_bits bits))
      in
      state.rack_constants <- Int32Map.add bits binding state.rack_constants;
      binding

let mask_constant state loc value =
  let false_value, true_value = state.mask_constants in
  match if value then true_value else false_value with
  | Some binding -> binding
  | None ->
      let binding = emit state loc Ir.source Ir.Mask (Ir.Mask_const value) in
      state.mask_constants <-
        if value then (false_value, Some binding) else (Some binding, true_value);
      binding

let sanitize_operand state loc provenance benign ((value, typ) as operand) =
  match provenance.Ir.through with
  | None -> operand
  | Some mask ->
      let benign = rack_constant state loc provenance benign in
      emit state loc provenance typ
        (Ir.Sanitize { mask; active = value; benign = fst benign })

let expect_type loc description expected (_, actual) =
  if actual = expected then Ok ()
  else
    errorf loc "%s requires %s, got %s" description (Ir.string_of_typ expected)
      (Ir.string_of_typ actual)

let expect_same loc description ((_, left_type) as left) ((_, right_type) as right) =
  if left_type = right_type then Ok (left, right)
  else
    errorf loc "%s requires equal operands, got %s and %s" description
      (Ir.string_of_typ left_type) (Ir.string_of_typ right_type)

let ir_binary = function
  | Ast.Add -> Some Ir.Add
  | Ast.Sub -> Some Ir.Sub
  | Ast.Mul -> Some Ir.Mul
  | Ast.Div -> Some Ir.Div
  | Ast.Mod | Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge | Ast.Eq | Ast.Ne | Ast.And | Ast.Or
  | Ast.Pipe | Ast.Shl | Ast.Shr | Ast.Rol | Ast.Ror | Ast.Interleave -> None

let ir_comparison = function
  | Ast.Lt -> Some Ir.Lt
  | Ast.Le -> Some Ir.Le
  | Ast.Gt -> Some Ir.Gt
  | Ast.Ge -> Some Ir.Ge
  | Ast.Eq -> Some Ir.Eq
  | Ast.Ne -> Some Ir.Ne
  | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod | Ast.And | Ast.Or | Ast.Pipe
  | Ast.Shl | Ast.Shr | Ast.Rol | Ast.Ror | Ast.Interleave -> None

let ir_reduction = function
  | Ast.RAdd -> Some Ir.Reduce_add
  | Ast.RMul -> Some Ir.Reduce_mul
  | Ast.RMin -> Some Ir.Reduce_min
  | Ast.RMax -> Some Ir.Reduce_max
  | Ast.RAnd | Ast.ROr -> None

let ir_scan = function
  | Ast.RAdd -> Some Ir.Scan_add
  | Ast.RMul -> Some Ir.Scan_mul
  | Ast.RMin -> Some Ir.Scan_min
  | Ast.RMax -> Some Ir.Scan_max
  | Ast.RAnd | Ast.ROr -> None

let rec lower_expr state provenance (expr : expr) =
  match expr.v with
  | EVar name -> find_binding state expr.loc name
  | EScalarVar name ->
      let* scalar = find_binding state expr.loc name in
      let* () = expect_type expr.loc "uniform scalar use" (Ir.Scalar Ir.F32) scalar in
      Ok
        (emit state expr.loc provenance (Ir.Rack Ir.F32)
           (Ir.Broadcast (fst scalar)))
  | EBroadcast ({ v = EScalarVar name; _ } as scalar_expr) ->
      let* scalar = find_binding state scalar_expr.loc name in
      let* () = expect_type expr.loc "broadcast" (Ir.Scalar Ir.F32) scalar in
      Ok
        (emit state expr.loc provenance (Ir.Rack Ir.F32)
           (Ir.Broadcast (fst scalar)))
  | EBroadcast { v = EFloat value; _ } ->
      Ok (rack_constant state expr.loc provenance value)
  | EFloat value ->
      Ok (rack_constant state expr.loc provenance value)
  | EBinop (left, ((Add | Sub | Mul | Div) as operation), right) ->
      let* left = lower_expr state provenance left in
      let* right = lower_expr state provenance right in
      let* left, right = expect_same expr.loc "arithmetic" left right in
      let* () = expect_type expr.loc "arithmetic" (Ir.Rack Ir.F32) left in
      let left_benign, right_benign =
        (Masked_safety.binop_operand operation 0,
         Masked_safety.binop_operand operation 1)
      in
      let operation = Option.get (ir_binary operation) in
      let left = sanitize_operand state expr.loc provenance left_benign left in
      let right = sanitize_operand state expr.loc provenance right_benign right in
      Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Binary (operation, fst left, fst right)))
  | EBinop (left, ((Lt | Le | Gt | Ge | Eq | Ne) as comparison), right) ->
      let* left = lower_expr state provenance left in
      let* right = lower_expr state provenance right in
      let* left, right = expect_same expr.loc "comparison" left right in
      let* () = expect_type expr.loc "comparison" (Ir.Rack Ir.F32) left in
      let comparison = Option.get (ir_comparison comparison) in
      let left = sanitize_operand state expr.loc provenance 0.0 left in
      let right = sanitize_operand state expr.loc provenance 0.0 right in
      Ok (emit state expr.loc provenance Ir.Mask (Ir.Compare (comparison, fst left, fst right)))
  | EBinop (left, ((And | Or) as operation), right) ->
      let* left = lower_expr state provenance left in
      let* right = lower_expr state provenance right in
      let* () = expect_type expr.loc "mask operation" Ir.Mask left in
      let* () = expect_type expr.loc "mask operation" Ir.Mask right in
      let operation = match operation with And -> Ir.And | Or -> Ir.Or | _ -> assert false in
      Ok (emit state expr.loc provenance Ir.Mask (Ir.Mask_binary (operation, fst left, fst right)))
  | EBinop (_, operation, _) ->
      errorf expr.loc "binary operator %s is not supported by native crunch lowering"
        (show_binop operation)
  | EUnop ((Neg | FNeg), operand) ->
      let* operand = lower_expr state provenance operand in
      let* () = expect_type expr.loc "negation" (Ir.Rack Ir.F32) operand in
      Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Unary (Ir.Neg, fst operand)))
  | EUnop (Not, operand) ->
      let* operand = lower_expr state provenance operand in
      let* () = expect_type expr.loc "mask not" Ir.Mask operand in
      Ok (emit state expr.loc provenance Ir.Mask (Ir.Mask_not (fst operand)))
  | ECall ("sqrt", [ operand ]) ->
      let* operand = lower_expr state provenance operand in
      let* () = expect_type expr.loc "sqrt" (Ir.Rack Ir.F32) operand in
      let operand = sanitize_operand state expr.loc provenance 1.0 operand in
      Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Unary (Ir.Sqrt, fst operand)))
  | ECall ("sqrt", arguments) ->
      errorf expr.loc "sqrt expects one argument, got %d" (List.length arguments)
  | ECall ("select", [ condition; if_true; if_false ]) ->
      let* condition = lower_expr state provenance condition in
      let* if_true = lower_expr state provenance if_true in
      let* if_false = lower_expr state provenance if_false in
      let* () = expect_type expr.loc "select condition" Ir.Mask condition in
      let* if_true, if_false = expect_same expr.loc "select" if_true if_false in
      let* () = expect_type expr.loc "select arms" (Ir.Rack Ir.F32) if_true in
      Ok
        (emit state expr.loc provenance (Ir.Rack Ir.F32)
           (Ir.Select
              { condition = fst condition; if_true = fst if_true; if_false = fst if_false }))
  | ECall ("select", arguments) ->
      errorf expr.loc "select expects three arguments, got %d" (List.length arguments)
  | ECall (name, _) -> errorf expr.loc "call to '%s' is not supported by native crunch lowering" name
  | EFma (a, b, c) ->
      let* a = lower_expr state provenance a in
      let* b = lower_expr state provenance b in
      let* c = lower_expr state provenance c in
      let* a, b = expect_same expr.loc "fma" a b in
      let* a, c = expect_same expr.loc "fma" a c in
      let* () = expect_type expr.loc "fma" (Ir.Rack Ir.F32) a in
      let a = sanitize_operand state expr.loc provenance (Masked_safety.fma_operand 0) a in
      let b = sanitize_operand state expr.loc provenance (Masked_safety.fma_operand 1) b in
      let c = sanitize_operand state expr.loc provenance (Masked_safety.fma_operand 2) c in
      Ok (emit state expr.loc provenance (Ir.Rack Ir.F32) (Ir.Fma (fst a, fst b, fst c)))
  | EInt _ -> error expr.loc "integer rack literals are not supported by native crunch lowering"
  | EBool _ -> error expr.loc "boolean literals are not supported by native crunch lowering"
  | ELambda _ -> error expr.loc "lambdas are not supported by native crunch lowering"
  | EPipe _ -> error expr.loc "pipelines are not supported by native crunch lowering"
  | EFusedPipe _ -> error expr.loc "fused pipelines are not supported by native crunch lowering"
  | ELet _ -> error expr.loc "expression-local let is not supported by native crunch lowering"
  | EField _ -> error expr.loc "field access is not supported by native crunch lowering"
  | ERecord _ -> error expr.loc "record construction is not supported by native crunch lowering"
  | EWith _ -> error expr.loc "record updates are not supported by native crunch lowering"
  | ELaneIndex -> error expr.loc "lane indices are not supported by native crunch lowering"
  | ELanes -> error expr.loc "lane counts are not supported by native crunch lowering"
  | EExtract _ -> error expr.loc "lane extraction is not supported by native crunch lowering"
  | EInsert _ -> error expr.loc "lane insertion is not supported by native crunch lowering"
  | EReduce (operation, operand) ->
      if provenance.Ir.through <> None then
        error expr.loc "reductions are forbidden in predicated regions"
      else
        let* operand = lower_expr state provenance operand in
        let* () = expect_type expr.loc "f32 reduction" (Ir.Rack Ir.F32) operand in
        (match ir_reduction operation with
        | Some operation ->
            Ok
              (emit state expr.loc provenance (Ir.Scalar Ir.F32)
                 (Ir.Reduce (operation, fst operand)))
        | None -> error expr.loc "logical mask reductions are not implemented")
  | EScan (operation, operand) ->
      if provenance.Ir.through <> None then
        error expr.loc "prefix scans are forbidden in predicated regions"
      else
        let* operand = lower_expr state provenance operand in
        let* () = expect_type expr.loc "f32 prefix scan" (Ir.Rack Ir.F32) operand in
        (match ir_scan operation with
        | Some operation ->
            Ok
              (emit state expr.loc provenance (Ir.Rack Ir.F32)
                 (Ir.Scan (operation, fst operand)))
        | None -> error expr.loc "logical prefix scans are not defined")
  | EShuffle _ -> error expr.loc "shuffles are not supported by native crunch lowering"
  | EShift _ -> error expr.loc "lane shifts are not supported by native crunch lowering"
  | ERotate _ -> error expr.loc "lane rotates are not supported by native crunch lowering"
  | EGather _ -> error expr.loc "gather is not supported by native crunch lowering"
  | EScatter _ -> error expr.loc "scatter is not supported by native crunch lowering"
  | ECompress _ -> error expr.loc "compression is not supported by native crunch lowering"
  | EExpand _ -> error expr.loc "expansion is not supported by native crunch lowering"
  | ETines _ -> error expr.loc "inline tines are not supported by native crunch lowering"
  | EOuter _ -> error expr.loc "outer products are not supported by native crunch lowering"
  | ETuple _ -> error expr.loc "tuples are not supported by native crunch lowering"
  | EBroadcast _ ->
      error expr.loc
        "native crunch lowering currently supports broadcasts of literal f32 values"
  | EUnit -> error expr.loc "unit expressions are not supported by native crunch lowering"

let lower_binding state provenance loc name annotation expression =
  let* value = lower_expr state provenance expression in
  let* () = check_annotation annotation (snd value) in
  let* () = bind state loc name value in
  Ok value

let lower_statement state active_fused (statement : stmt) =
  match statement.v with
  | SFused binding ->
      let region =
        match active_fused with
        | Some region -> region
        | None ->
            let region = state.next_fused_region in
            state.next_fused_region <- region + 1;
            region
      in
      let provenance = { Ir.fused = Some region; through = None } in
      let* _ =
        lower_binding state provenance statement.loc binding.fused_name binding.fused_type
          binding.fused_expr
      in
      Ok (Some region)
  | SLet binding ->
      let* _ =
        lower_binding state Ir.source statement.loc binding.bind_name binding.bind_type
          binding.bind_expr
      in
      Ok None
  | SExpr expression ->
      let* _ = lower_expr state Ir.source expression in
      Ok None
  | SLocBind _ -> error statement.loc "mutable location bindings are not supported by native crunch lowering"
  | SAssign _ -> error statement.loc "assignment is not supported by native crunch lowering"
  | SOver _ -> error statement.loc "over loops are not supported by native crunch lowering"

let add_parameter state function_loc index = function
  | PRack (name, annotation) ->
      let* () =
        match annotation with
        | None -> Ok ()
        | Some typ ->
            let* typ = ir_typ_of_annotation typ in
            if typ = Ir.Rack Ir.F32 then Ok ()
            else error function_loc "native crunch parameters must be float racks"
      in
      let parameter = { Ir.id = index; typ = Ir.Rack Ir.F32; name = Some name } in
      let* () = bind state function_loc name (index, Ir.Rack Ir.F32) in
      Ok parameter
  | PScalar (name, annotation) ->
      let* () =
        match annotation with
        | None -> Ok ()
        | Some typ ->
            let* typ = ir_typ_of_annotation typ in
            if typ = Ir.Scalar Ir.F32 then Ok ()
            else error function_loc "native scalar crunch parameters must be f32"
      in
      let parameter = { Ir.id = index; typ = Ir.Scalar Ir.F32; name = Some name } in
      let* () = bind state function_loc name (index, Ir.Scalar Ir.F32) in
      Ok parameter
  | PSpread _ -> error function_loc "spread crunch parameters are not supported by native lowering"

let lower_crunch definition_loc name parameters result body =
  let state =
    {
      next_value = List.length parameters;
      next_fused_region = 0;
      instructions_rev = [];
      bindings = StringMap.empty;
      tines = StringMap.empty;
      rack_constants = Int32Map.empty;
      mask_constants = (None, None);
    }
  in
  let rec add_parameters index reversed = function
    | [] -> Ok (List.rev reversed)
    | parameter :: rest ->
        let* parameter = add_parameter state definition_loc index parameter in
        add_parameters (index + 1) (parameter :: reversed) rest
  in
  let* parameters = add_parameters 0 [] parameters in
  let* () =
    match result.result_type with
    | None -> Ok ()
    | Some annotation ->
        let* typ = ir_typ_of_annotation annotation in
        if typ = Ir.Rack Ir.F32 || typ = Ir.Scalar Ir.F32 then Ok ()
        else error annotation.loc "native crunch results must be float rack or scalar float"
  in
  let rec lower_body active_fused = function
    | [] -> Ok ()
    | statement :: rest ->
        let* active_fused = lower_statement state active_fused statement in
        lower_body active_fused rest
  in
  let* () = lower_body None body in
  let* return_value = find_binding state definition_loc result.result_name in
  let* () =
    match result.result_type with
    | Some annotation -> check_annotation (Some annotation) (snd return_value)
    | None -> expect_type definition_loc "implicit crunch result" (Ir.Rack Ir.F32) return_value
  in
  let func =
    {
      Ir.name;
      parameters;
      result = Some (snd return_value);
      body =
        {
          instructions = List.rev state.instructions_rev;
          terminators = [ Ir.Return (Some (fst return_value)) ];
        };
      loc = ir_location definition_loc;
    }
  in
  match Ir.verify_function func with
  | Ok () -> Ok func
  | Error errors ->
      errorf definition_loc "generated invalid native IR: %s"
        (String.concat "; " (List.map Ir.format_error errors))

let rec lower_predicate state (predicate : predicate) =
  match predicate.v with
  | PExpr expression ->
      let* value = lower_expr state Ir.source expression in
      let* () = expect_type predicate.loc "predicate" Ir.Mask value in
      Ok value
  | PCmp (left, comparison, right) ->
      let operation =
        match comparison with
        | CLt -> Lt | CLe -> Le | CGt -> Gt | CGe -> Ge | CEq -> Eq | CNe -> Ne
      in
      lower_expr state Ir.source (node (EBinop (left, operation, right)) predicate.loc)
  | PIs (left, right) ->
      lower_expr state Ir.source (node (EBinop (left, Eq, right)) predicate.loc)
  | PIsNot (left, right) ->
      lower_expr state Ir.source (node (EBinop (left, Ne, right)) predicate.loc)
  | PAnd (left, right) | POr (left, right) ->
      let* left = lower_predicate state left in
      let* right = lower_predicate state right in
      let operation = match predicate.v with PAnd _ -> Ir.And | _ -> Ir.Or in
      Ok
        (emit state predicate.loc Ir.source Ir.Mask
           (Ir.Mask_binary (operation, fst left, fst right)))
  | PNot inner ->
      let* inner = lower_predicate state inner in
      Ok (emit state predicate.loc Ir.source Ir.Mask (Ir.Mask_not (fst inner)))
  | PTineRef name -> (
      match StringMap.find_opt name state.tines with
      | Some value -> Ok value
      | None -> errorf predicate.loc "undefined or forward tine reference '#%s'" name)

let lower_tine_ref state loc = function
  | TRSingle name -> (
      match StringMap.find_opt name state.tines with
      | Some value -> Ok value
      | None -> errorf loc "undefined tine '#%s'" name)
  | TRComposed predicate -> lower_predicate state predicate

let lower_through state (through : through) =
  let* mask = lower_tine_ref state through.through_result.loc through.through_tine in
  let outer_bindings = state.bindings in
  let provenance = { Ir.source with through = Some (fst mask) } in
  let rec lower_body = function
    | [] -> Ok ()
    | statement :: rest -> (
        match statement.v with
        | SLet binding ->
            let* _ =
              lower_binding state provenance statement.loc binding.bind_name
                binding.bind_type binding.bind_expr
            in
            lower_body rest
        | SExpr expression ->
            let* _ = lower_expr state provenance expression in
            lower_body rest
        | SFused binding ->
            let* _ =
              lower_binding state provenance statement.loc binding.fused_name None
                binding.fused_expr
            in
            lower_body rest
        | SLocBind _ | SAssign _ | SOver _ ->
            error statement.loc "effectful statements are forbidden in native through blocks")
  in
  let* () = lower_body through.through_body in
  let* computed = lower_expr state provenance through.through_result in
  state.bindings <- outer_bindings;
  let* passthrough =
    match through.through_passthru with
    | Some expression -> lower_expr state Ir.source expression
    | None -> Ok (rack_constant state through.through_result.loc Ir.source 0.0)
  in
  let* computed, passthrough =
    expect_same through.through_result.loc "through result" computed passthrough
  in
  let selected =
    emit state through.through_result.loc Ir.source (snd computed)
      (Ir.Select
         { condition = fst mask; if_true = fst computed; if_false = fst passthrough })
  in
  bind state through.through_result.loc through.through_binding selected

let rec expression_needs_inactive_guard (expression : expr) =
  match expression.v with
  | EBinop (_, (Add | Sub | Mul | Div | Lt | Le | Gt | Ge | Eq | Ne), _) -> true
  | EFma _ | ECall ("sqrt", _) -> true
  | EBinop (left, (And | Or), right)
  | EPipe (left, right) | EFusedPipe (left, right) ->
      expression_needs_inactive_guard left || expression_needs_inactive_guard right
  | EUnop (_, inner) | EBroadcast inner | EField (inner, _) ->
      expression_needs_inactive_guard inner
  | ECall ("select", arguments) -> List.exists expression_needs_inactive_guard arguments
  | ELet (binding, body) ->
      expression_needs_inactive_guard binding.bind_expr
      || expression_needs_inactive_guard body
  | EInt _ | EFloat _ | EBool _ | EVar _ | EScalarVar _ | ELaneIndex
  | ELanes | EUnit -> false
  | _ -> true

let lower_sweep state definition_loc (sweep : sweep) =
  let needs_effective_masks =
    List.exists (fun arm -> expression_needs_inactive_guard arm.arm_value)
      sweep.sweep_arms
  in
  let claimed =
    ref
      (if needs_effective_masks then mask_constant state definition_loc false
       else (-1, Ir.Mask))
  in
  let named_rev = ref [] in
  let catchall = ref None in
  let rec lower_arms = function
    | [] -> Ok ()
    | arm :: rest -> (
        match arm.arm_tine with
        | Some name ->
            let* tine =
              match StringMap.find_opt name state.tines with
              | Some value -> Ok value
              | None -> errorf arm.arm_value.loc "undefined sweep tine '#%s'" name
            in
            let provenance =
              if not needs_effective_masks then Ir.source
              else
                let not_claimed =
                  emit state arm.arm_value.loc Ir.source Ir.Mask
                    (Ir.Mask_not (fst !claimed))
                in
                let effective =
                  emit state arm.arm_value.loc Ir.source Ir.Mask
                    (Ir.Mask_binary (Ir.And, fst tine, fst not_claimed))
                in
                { Ir.source with through = Some (fst effective) }
            in
            let* candidate = lower_expr state provenance arm.arm_value in
            named_rev := (tine, candidate, arm.arm_value.loc) :: !named_rev;
            if needs_effective_masks then
              claimed :=
                emit state arm.arm_value.loc Ir.source Ir.Mask
                  (Ir.Mask_binary (Ir.Or, fst !claimed, fst tine));
            lower_arms rest
        | None ->
            let provenance =
              if not needs_effective_masks then Ir.source
              else
                let effective =
                  emit state arm.arm_value.loc Ir.source Ir.Mask
                    (Ir.Mask_not (fst !claimed))
                in
                { Ir.source with through = Some (fst effective) }
            in
            let* candidate = lower_expr state provenance arm.arm_value in
            catchall := Some candidate;
            lower_arms rest)
  in
  let* () = lower_arms sweep.sweep_arms in
  let* seed =
    match !catchall with
    | Some value -> Ok value
    | None -> error definition_loc "native sweep requires a final catch-all arm"
  in
  let result =
    List.fold_left
      (fun accumulator (tine, candidate, loc) ->
        emit state loc Ir.source (snd accumulator)
          (Ir.Select
             { condition = fst tine; if_true = fst candidate; if_false = fst accumulator }))
      seed !named_rev
  in
  let* () = bind state definition_loc sweep.sweep_binding result in
  Ok result

let lower_rake definition_loc name parameters result setup tines throughs sweep =
  let state =
    {
      next_value = List.length parameters;
      next_fused_region = 0;
      instructions_rev = [];
      bindings = StringMap.empty;
      tines = StringMap.empty;
      rack_constants = Int32Map.empty;
      mask_constants = (None, None);
    }
  in
  let rec add_parameters index reversed = function
    | [] -> Ok (List.rev reversed)
    | parameter :: rest ->
        let* parameter = add_parameter state definition_loc index parameter in
        add_parameters (index + 1) (parameter :: reversed) rest
  in
  let* parameters = add_parameters 0 [] parameters in
  let rec lower_setup active_fused = function
    | [] -> Ok ()
    | statement :: rest ->
        let* active_fused = lower_statement state active_fused statement in
        lower_setup active_fused rest
  in
  let* () = lower_setup None setup in
  let rec lower_tines = function
    | [] -> Ok ()
    | tine :: rest ->
        if StringMap.mem tine.tine_name state.tines then
          errorf tine.tine_pred.loc "duplicate tine '#%s'" tine.tine_name
        else
          let* value = lower_predicate state tine.tine_pred in
          state.tines <- StringMap.add tine.tine_name value state.tines;
          lower_tines rest
  in
  let* () = lower_tines tines in
  let rec lower_throughs = function
    | [] -> Ok ()
    | through :: rest ->
        let* () = lower_through state through in
        lower_throughs rest
  in
  let* () = lower_throughs throughs in
  let* sweep_value = lower_sweep state definition_loc sweep in
  let* return_value =
    match StringMap.find_opt result.result_name state.bindings with
    | Some value -> Ok value
    | None when result.result_name = sweep.sweep_binding -> Ok sweep_value
    | None ->
        errorf definition_loc
          "rake result '%s' must name the total sweep binding '%s'"
          result.result_name sweep.sweep_binding
  in
  let* () = expect_type definition_loc "rake result" (Ir.Rack Ir.F32) return_value in
  let func =
    {
      Ir.name;
      parameters;
      result = Some (Ir.Rack Ir.F32);
      body =
        {
          instructions = List.rev state.instructions_rev;
          terminators = [ Ir.Return (Some (fst return_value)) ];
        };
      loc = ir_location definition_loc;
    }
  in
  match Ir.verify_function func with
  | Ok () -> Ok func
  | Error errors ->
      errorf definition_loc "generated invalid native rake IR: %s"
        (String.concat "; " (List.map Ir.format_error errors))

let lower_definition (definition : def) =
  match definition.v with
  | DCrunch (name, parameters, result, body) ->
      lower_crunch definition.loc name parameters result body
  | DStack _ -> error definition.loc "stack definitions are not supported by native lowering"
  | DSingle _ -> error definition.loc "single definitions are not supported by native lowering"
  | DType _ -> error definition.loc "type aliases are not supported by native lowering"
  | DRake (name, parameters, result, setup, tines, throughs, sweep) ->
      lower_rake definition.loc name parameters result setup tines throughs sweep
  | DRun _ -> error definition.loc "run definitions are not supported by native lowering"

let lower_module module_ =
  let rec lower reversed = function
    | [] -> Ok (List.rev reversed)
    | ({ v = (DStack _ | DSingle _ | DType _); _ } : def) :: rest ->
        lower reversed rest
    | definition :: rest ->
        let* func = lower_definition definition in
        lower (func :: reversed) rest
  in
  lower [] module_.mod_defs

let lower_program program =
  let rec lower reversed = function
    | [] ->
        let functions = List.rev reversed in
        (match Ir.verify functions with
        | Ok () -> Ok functions
        | Error errors ->
            error Ast.dummy_loc
              ("generated invalid native module: "
              ^ String.concat "; " (List.map Ir.format_error errors)))
    | module_ :: rest ->
        let* functions = lower_module module_ in
        lower (List.rev_append functions reversed) rest
  in
  lower [] program
