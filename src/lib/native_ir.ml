(** Target-independent, rack-preserving SSA for Rake's native backend.

    This IR deliberately stops before legalization.  A target profile decides
    lane counts, legal operations, register classes, and instruction forms. *)

type value = int

type source_location = { file : string; line : int; col : int; offset : int }

let unknown_location = { file = "<unknown>"; line = 0; col = 0; offset = 0 }

let format_source_location loc = Printf.sprintf "%s:%d:%d" loc.file loc.line loc.col

type element = I1 | I32 | I64 | F32 | F64

type typ = Scalar of element | Rack of element | Mask | Pointer

type literal =
  | Bool of bool
  | Int32 of int32
  | Int64 of int64
  | Float32_bits of int32
  | Float64_bits of int64

type binary = Add | Sub | Mul | Div | Min | Max | And | Or | Xor

type unary = Neg | Sqrt

type comparison = Eq | Ne | Lt | Le | Gt | Ge

type reduction = Reduce_add | Reduce_mul | Reduce_min | Reduce_max | Reduce_and | Reduce_or

type scan = Scan_add | Scan_mul | Scan_min | Scan_max

type call_effect = Pure | Read | Write | Read_write

type provenance = { fused : int option; through : value option }

let source = { fused = None; through = None }

type op =
  | Const of literal
  | Mask_const of bool
  | Rack_const of literal list
  | Rack_splat of literal
  | Broadcast of value
  | Unary of unary * value
  | Binary of binary * value * value
  | Fma of value * value * value
  | Compare of comparison * value * value
  | Select of { condition : value; if_true : value; if_false : value }
  | Sanitize of { mask : value; active : value; benign : value }
  | Load of { address : value; alignment : int }
  | Store of { address : value; stored : value; alignment : int }
  | Shuffle of { rack : value; indices : int list }
  | Reduce of reduction * value
  | Scan of scan * value
  | Extract of { rack : value; lane : value }
  | Insert of { rack : value; inserted : value; lane : value }
  | Gather of { base : value; indices : value; mask : value option }
  | Scatter of { base : value; indices : value; stored : value; mask : value option }
  | Mask_binary of binary * value * value
  | Mask_not of value
  | Call of {
      callee : string;
      arguments : value list;
      parameter_types : typ list;
      return_type : typ option;
      call_effect : call_effect;
    }
  | Loop of loop

and instruction = {
  result : (value * typ) option;
  op : op;
  provenance : provenance;
  loc : source_location;
}

and terminator = Return of value option | Yield

and block = { instructions : instruction list; terminators : terminator list }

and loop = {
  index : value * typ;
  start : value;
  stop : value;
  step : int64;
  body : block;
}

type parameter = { id : value; typ : typ; name : string option }

type func = {
  name : string;
  parameters : parameter list;
  result : typ option;
  body : block;
  loc : source_location;
}

type t = func list

type error = { function_name : string; context : string list; message : string }

let string_of_element = function
  | I1 -> "i1"
  | I32 -> "i32"
  | I64 -> "i64"
  | F32 -> "f32"
  | F64 -> "f64"

let string_of_typ = function
  | Scalar element -> "scalar<" ^ string_of_element element ^ ">"
  | Rack element -> "rack<" ^ string_of_element element ^ ">"
  | Mask -> "mask"
  | Pointer -> "ptr"

let format_error error =
  let context =
    match error.context with [] -> "" | items -> " [" ^ String.concat "/" items ^ "]"
  in
  error.function_name ^ context ^ ": " ^ error.message

module IntMap = Map.Make (Int)
module IntSet = Set.Make (Int)

type environment = typ IntMap.t

type verifier = { function_name : string; mutable errors : error list }

let complain (verifier : verifier) context message =
  verifier.errors <- { function_name = verifier.function_name; context; message } :: verifier.errors

let literal_element = function
  | Bool _ -> I1
  | Int32 _ -> I32
  | Int64 _ -> I64
  | Float32_bits _ -> F32
  | Float64_bits _ -> F64

let is_integer = function Scalar I32 | Scalar I64 -> true | _ -> false
let is_numeric_element = function I32 | I64 | F32 | F64 -> true | I1 -> false
let is_numeric = function Scalar element | Rack element -> is_numeric_element element | Mask | Pointer -> false
let is_float_rack = function Rack F32 | Rack F64 -> true | _ -> false

let operands = function
  | Const _ | Mask_const _ | Rack_const _ | Rack_splat _ -> []
  | Broadcast value | Unary (_, value) | Reduce (_, value) | Scan (_, value) | Mask_not value -> [ value ]
  | Binary (_, left, right)
  | Compare (_, left, right)
  | Mask_binary (_, left, right) -> [ left; right ]
  | Fma (a, b, c) -> [ a; b; c ]
  | Select { condition; if_true; if_false } -> [ condition; if_true; if_false ]
  | Sanitize { mask; active; benign } -> [ mask; active; benign ]
  | Load { address; _ } -> [ address ]
  | Store { address; stored; _ } -> [ address; stored ]
  | Shuffle { rack; _ } -> [ rack ]
  | Extract { rack; lane } -> [ rack; lane ]
  | Insert { rack; inserted; lane } -> [ rack; inserted; lane ]
  | Gather { base; indices; mask } -> base :: indices :: Option.to_list mask
  | Scatter { base; indices; stored; mask } -> base :: indices :: stored :: Option.to_list mask
  | Call { arguments; _ } -> arguments
  | Loop { start; stop; _ } -> [ start; stop ]

let require_type verifier context environment value expected =
  match IntMap.find_opt value environment with
  | None -> complain verifier context (Printf.sprintf "%%%d is used before it is defined" value)
  | Some actual when actual <> expected ->
      complain verifier context
        (Printf.sprintf "%%%d has type %s; expected %s" value (string_of_typ actual)
           (string_of_typ expected))
  | Some _ -> ()

let type_of verifier context environment value =
  match IntMap.find_opt value environment with
  | Some typ -> Some typ
  | None ->
      complain verifier context (Printf.sprintf "%%%d is used before it is defined" value);
      None

let require_same verifier context description types =
  match types with
  | [] | [ _ ] -> ()
  | first :: rest ->
      if List.exists (fun typ -> typ <> first) rest then
        complain verifier context (description ^ " operands must have the same type")

let check_result verifier context (instruction : instruction) expected =
  match (instruction.result, expected) with
  | None, None -> ()
  | Some (_, actual), Some expected when actual = expected -> ()
  | Some (_, actual), Some expected ->
      complain verifier context
        (Printf.sprintf "result has type %s; operation produces %s" (string_of_typ actual)
           (string_of_typ expected))
  | None, Some expected ->
      complain verifier context ("operation requires a " ^ string_of_typ expected ^ " result")
  | Some _, None -> complain verifier context "effect-only operation must not define a result"

let check_optional_mask verifier context environment = function
  | None -> ()
  | Some mask -> require_type verifier context environment mask Mask

let check_alignment verifier context alignment =
  if alignment <= 0 || alignment land (alignment - 1) <> 0 then
    complain verifier context "alignment must be a positive power of two"

let instruction_name = function
  | Const _ -> "const"
  | Mask_const _ -> "mask.const"
  | Rack_const _ -> "rack.const"
  | Rack_splat _ -> "rack.splat"
  | Broadcast _ -> "rack.broadcast"
  | Unary _ -> "unary"
  | Binary _ -> "binary"
  | Fma _ -> "rack.fma"
  | Compare _ -> "compare"
  | Select _ -> "select"
  | Sanitize _ -> "sanitize"
  | Load _ -> "load"
  | Store _ -> "store"
  | Shuffle _ -> "rack.shuffle"
  | Reduce _ -> "rack.reduce"
  | Scan _ -> "rack.scan"
  | Extract _ -> "rack.extract"
  | Insert _ -> "rack.insert"
  | Gather _ -> "rack.gather"
  | Scatter _ -> "rack.scatter"
  | Mask_binary _ -> "mask.binary"
  | Mask_not _ -> "mask.not"
  | Call _ -> "call"
  | Loop _ -> "loop"

let effectful = function
  | Load _ | Store _ | Gather _ | Scatter _ | Call _ | Loop _ -> true
  | Const _ | Mask_const _ | Rack_const _ | Rack_splat _ | Broadcast _ | Unary _ | Binary _ | Fma _ | Compare _ | Select _ | Sanitize _ | Shuffle _
  | Reduce _ | Scan _ | Extract _ | Insert _ | Mask_binary _ | Mask_not _ -> false

let check_provenance verifier context environment (instruction : instruction) =
  Option.iter (fun tine -> require_type verifier context environment tine Mask) instruction.provenance.through;
  match instruction.provenance.fused with
  | None -> ()
  | Some _ ->
      if effectful instruction.op then
        complain verifier context (instruction_name instruction.op ^ " is not permitted in a fused region");
      (match instruction.result with
      | Some (_, (Rack _ | Mask)) -> ()
      | Some (_, typ) ->
          complain verifier context
            ("fused regions must retain rack identity; found " ^ string_of_typ typ ^ " result")
      | None -> complain verifier context "a fused instruction must define a rack or mask result")

let check_fused_contiguity verifier context (instructions : instruction list) =
  let _, closed =
    List.fold_left
      (fun (active, closed) instruction ->
        match instruction.provenance.fused with
        | None -> (None, Option.fold ~none:closed ~some:(fun id -> IntSet.add id closed) active)
        | Some id when Some id = active -> (active, closed)
        | Some id ->
            if IntSet.mem id closed then
              complain verifier context (Printf.sprintf "fused region %d is not contiguous" id);
            let closed = Option.fold ~none:closed ~some:(fun old -> IntSet.add old closed) active in
            (Some id, closed))
      (None, IntSet.empty) instructions
  in
  ignore closed

let rec verify_instruction verifier context environment (instruction : instruction) =
  List.iter
    (fun operand ->
      if not (IntMap.mem operand environment) then
        complain verifier context (Printf.sprintf "%%%d is used before it is defined" operand))
    (operands instruction.op);
  check_provenance verifier context environment instruction;
  let lookup value = IntMap.find_opt value environment in
  (match instruction.op with
  | Const literal -> check_result verifier context instruction (Some (Scalar (literal_element literal)))
  | Mask_const _ -> check_result verifier context instruction (Some Mask)
  | Rack_const [] ->
      complain verifier context "rack constant must contain at least one lane"
  | Rack_const (first :: rest) ->
      let element = literal_element first in
      if List.exists (fun literal -> literal_element literal <> element) rest then
        complain verifier context "rack constant lanes must have one element type";
      check_result verifier context instruction (Some (Rack element))
  | Rack_splat literal ->
      check_result verifier context instruction (Some (Rack (literal_element literal)))
  | Broadcast value ->
      let expected =
        match lookup value with Some (Scalar element) when element <> I1 -> Some (Rack element) | _ -> None
      in
      if expected = None then complain verifier context "broadcast requires a numeric scalar";
      Option.iter (fun typ -> check_result verifier context instruction (Some typ)) expected
  | Unary (Neg, value) ->
      (match lookup value with
      | Some (Rack (F32 | F64) as typ) -> check_result verifier context instruction (Some typ)
      | _ -> complain verifier context "neg requires a floating-point rack")
  | Unary (Sqrt, value) ->
      (match lookup value with
      | Some (Rack (F32 | F64) as typ) -> check_result verifier context instruction (Some typ)
      | _ -> complain verifier context "sqrt requires a floating-point rack")
  | Binary (_, left, right) ->
      let types = List.filter_map lookup [ left; right ] in
      require_same verifier context "binary" types;
      (match types with
      | typ :: _ when is_numeric typ -> check_result verifier context instruction (Some typ)
      | _ -> complain verifier context "binary arithmetic requires numeric scalar or rack operands")
  | Fma (a, b, c) ->
      let types = List.filter_map lookup [ a; b; c ] in
      require_same verifier context "fma" types;
      (match types with
      | typ :: _ when is_float_rack typ -> check_result verifier context instruction (Some typ)
      | _ -> complain verifier context "fma requires three equal floating-point racks")
  | Compare (_, left, right) ->
      let types = List.filter_map lookup [ left; right ] in
      require_same verifier context "compare" types;
      (match types with
      | Rack element :: _ when is_numeric_element element -> check_result verifier context instruction (Some Mask)
      | Scalar element :: _ when is_numeric_element element ->
          check_result verifier context instruction (Some (Scalar I1))
      | _ -> complain verifier context "compare requires equal numeric operands")
  | Select { condition; if_true; if_false } ->
      let arm_types = List.filter_map lookup [ if_true; if_false ] in
      require_same verifier context "select" arm_types;
      (match arm_types with
      | (Rack _ as typ) :: _ ->
          require_type verifier context environment condition Mask;
          check_result verifier context instruction (Some typ)
      | (Scalar _ as typ) :: _ ->
          require_type verifier context environment condition (Scalar I1);
          check_result verifier context instruction (Some typ)
      | _ -> complain verifier context "select arms must be equal scalar or rack values")
  | Sanitize { mask; active; benign } ->
      require_type verifier context environment mask Mask;
      let arm_types = List.filter_map lookup [ active; benign ] in
      require_same verifier context "sanitize" arm_types;
      (match arm_types with
      | (Rack _ as typ) :: _ -> check_result verifier context instruction (Some typ)
      | _ -> complain verifier context "sanitize operands must be equal rack values")
  | Load { address; alignment } ->
      require_type verifier context environment address Pointer;
      check_alignment verifier context alignment;
      (match instruction.result with
      | Some (_, (Scalar _ | Rack _)) -> ()
      | _ -> complain verifier context "load must define a scalar or rack result")
  | Store { address; stored = _; alignment } ->
      require_type verifier context environment address Pointer;
      check_alignment verifier context alignment;
      check_result verifier context instruction None
  | Shuffle { rack; indices } ->
      if indices = [] || List.exists (fun index -> index < 0) indices then
        complain verifier context "shuffle indices must be non-negative and non-empty";
      (match lookup rack with
      | Some (Rack _ as typ) -> check_result verifier context instruction (Some typ)
      | _ -> complain verifier context "shuffle requires a rack")
  | Reduce ((Reduce_add | Reduce_mul | Reduce_min | Reduce_max), rack) ->
      require_type verifier context environment rack (Rack F32);
      check_result verifier context instruction (Some (Scalar F32))
  | Reduce ((Reduce_and | Reduce_or), rack) ->
      require_type verifier context environment rack Mask;
      check_result verifier context instruction (Some (Scalar I1))
  | Scan (_, rack) ->
      require_type verifier context environment rack (Rack F32);
      check_result verifier context instruction (Some (Rack F32))
  | Extract { rack; lane } ->
      if Option.fold ~none:false ~some:is_integer (lookup lane) |> not then
        complain verifier context "extract lane must be an integer scalar";
      (match lookup rack with
      | Some (Rack element) -> check_result verifier context instruction (Some (Scalar element))
      | _ -> complain verifier context "extract requires a rack")
  | Insert { rack; inserted; lane } ->
      if Option.fold ~none:false ~some:is_integer (lookup lane) |> not then
        complain verifier context "insert lane must be an integer scalar";
      (match lookup rack with
      | Some (Rack element as typ) ->
          require_type verifier context environment inserted (Scalar element);
          check_result verifier context instruction (Some typ)
      | _ -> complain verifier context "insert requires a rack")
  | Gather { base; indices; mask } ->
      require_type verifier context environment base Pointer;
      check_optional_mask verifier context environment mask;
      (match lookup indices with
      | Some (Rack (I32 | I64)) -> ()
      | _ -> complain verifier context "gather indices must be an integer rack");
      (match instruction.result with
      | Some (_, Rack _) -> ()
      | _ -> complain verifier context "gather must define a rack result")
  | Scatter { base; indices; stored; mask } ->
      require_type verifier context environment base Pointer;
      check_optional_mask verifier context environment mask;
      (match lookup indices with
      | Some (Rack (I32 | I64)) -> ()
      | _ -> complain verifier context "scatter indices must be an integer rack");
      (match lookup stored with
      | Some (Rack _) -> ()
      | _ -> complain verifier context "scatter value must be a rack");
      check_result verifier context instruction None
  | Mask_binary ((And | Or | Xor), left, right) ->
      require_type verifier context environment left Mask;
      require_type verifier context environment right Mask;
      check_result verifier context instruction (Some Mask)
  | Mask_binary _ -> complain verifier context "mask binary operation must be and, or, or xor"
  | Mask_not mask ->
      require_type verifier context environment mask Mask;
      check_result verifier context instruction (Some Mask)
  | Call { callee; arguments; parameter_types; return_type; _ } ->
      if String.trim callee = "" then complain verifier context "call target must not be empty";
      if List.length arguments <> List.length parameter_types then
        complain verifier context "call argument and parameter type counts differ"
      else
        List.iter2
          (fun argument parameter_type ->
            require_type verifier context environment argument parameter_type)
          arguments parameter_types;
      check_result verifier context instruction return_type
  | Loop loop ->
      let start_type = lookup loop.start and stop_type = lookup loop.stop in
      require_same verifier context "loop bounds" (List.filter_map Fun.id [ start_type; stop_type ]);
      if Option.fold ~none:false ~some:is_integer start_type |> not then
        complain verifier context "loop bounds must be integer scalars";
      if loop.step = 0L then complain verifier context "loop step must not be zero";
      check_result verifier context instruction None;
      let index_id, index_type = loop.index in
      if not (is_integer index_type) then complain verifier context "loop index must be an integer scalar";
      (match start_type with
      | Some typ when typ <> index_type ->
          complain verifier context "loop index type must match the loop bound type"
      | _ -> ());
      let loop_environment =
        if IntMap.mem index_id environment then (
          complain verifier context (Printf.sprintf "loop index %%%d is already defined" index_id);
          environment)
        else IntMap.add index_id index_type environment
      in
      ignore (verify_block verifier (context @ [ "loop" ]) ~expected_result:None ~yielding:true loop_environment loop.body));
  match instruction.result with
  | None -> environment
  | Some (id, typ) ->
      if IntMap.mem id environment then (
        complain verifier context (Printf.sprintf "%%%d is defined more than once" id);
        environment)
      else IntMap.add id typ environment

and verify_block verifier context ~expected_result ~yielding environment block =
  check_fused_contiguity verifier context block.instructions;
  let definitions =
    List.fold_left
      (fun definitions (instruction : instruction) ->
        match instruction.result with
        | Some (id, _) -> IntMap.add id instruction.op definitions
        | None -> definitions)
      IntMap.empty block.instructions
  in
  let require_sanitized mask expected_bits operand =
    match IntMap.find_opt operand definitions with
    | Some (Sanitize { mask = operand_mask; benign; _ }) when operand_mask = mask ->
        (match IntMap.find_opt benign definitions with
        | Some (Rack_splat (Float32_bits bits)) when bits = expected_bits -> ()
        | _ ->
            complain verifier context
              (Printf.sprintf
                 "masked operand %%%d does not use required benign f32 bits 0x%08lx"
                 operand expected_bits))
    | _ ->
        complain verifier context
          (Printf.sprintf
             "masked exception-capable operand %%%d is not produced by sanitize for mask %%%d"
             operand mask)
  in
  List.iter
    (fun (instruction : instruction) ->
      match instruction.provenance.through with
      | None -> ()
      | Some mask ->
          (match instruction.op with
          | Unary (Sqrt, operand) -> require_sanitized mask 0x3f800000l operand
          | Binary ((Add | Sub | Min | Max), left, right)
          | Compare (_, left, right) ->
              require_sanitized mask 0x00000000l left;
              require_sanitized mask 0x00000000l right
          | Binary (Mul, left, right) ->
              require_sanitized mask 0x3f800000l left;
              require_sanitized mask 0x3f800000l right
          | Binary (Div, left, right) ->
              require_sanitized mask 0x00000000l left;
              require_sanitized mask 0x3f800000l right
          | Fma (a, b, c) ->
              require_sanitized mask 0x00000000l a;
              require_sanitized mask 0x00000000l b;
              require_sanitized mask 0x00000000l c
          | Load _ | Store _ ->
              complain verifier context "unmasked memory operation is forbidden in a through region"
          | Gather { mask = Some memory_mask; _ }
          | Scatter { mask = Some memory_mask; _ } when memory_mask = mask -> ()
          | Gather _ | Scatter _ ->
              complain verifier context "through memory mask must match through provenance"
          | _ -> ()))
    block.instructions;
  let environment =
    List.fold_left
      (fun environment instruction -> verify_instruction verifier context environment instruction)
      environment block.instructions
  in
  (match block.terminators with
  | [ Return value ] when not yielding ->
      (match (value, expected_result) with
      | None, None -> ()
      | Some id, Some typ -> require_type verifier context environment id typ
      | None, Some typ -> complain verifier context ("return requires a " ^ string_of_typ typ ^ " value")
      | Some _, None -> complain verifier context "void function must return without a value")
  | [ Yield ] when yielding -> ()
  | [ Yield ] -> complain verifier context "function body must end in return, not yield"
  | [ Return _ ] -> complain verifier context "loop body must end in yield, not return"
  | [] -> complain verifier context "block has no terminator"
  | _ -> complain verifier context "block has more than one terminator");
  environment

let verify_function (func : func) =
  let verifier = { function_name = func.name; errors = [] } in
  if String.trim func.name = "" then complain verifier [] "function name must not be empty";
  let environment =
    List.fold_left
      (fun environment parameter ->
        if IntMap.mem parameter.id environment then (
          complain verifier [] (Printf.sprintf "parameter %%%d is defined more than once" parameter.id);
          environment)
        else IntMap.add parameter.id parameter.typ environment)
      IntMap.empty func.parameters
  in
  ignore (verify_block verifier [ "entry" ] ~expected_result:func.result ~yielding:false environment func.body);
  match List.rev verifier.errors with [] -> Ok () | errors -> Error errors

let verify module_ =
  let _, errors =
    List.fold_left
      (fun (names, errors) (func : func) ->
        let duplicate = String.trim func.name <> "" && List.mem func.name names in
        let errors =
          if duplicate then
            { function_name = func.name; context = []; message = "function is defined more than once" } :: errors
          else errors
        in
        let errors = match verify_function func with Ok () -> errors | Error found -> List.rev_append found errors in
        (func.name :: names, errors))
      ([], []) module_
  in
  match List.rev errors with [] -> Ok () | found -> Error found

let string_of_literal = function
  | Bool value -> string_of_bool value
  | Int32 value -> Int32.to_string value
  | Int64 value -> Int64.to_string value
  | Float32_bits bits -> Printf.sprintf "f32:0x%08lx" bits
  | Float64_bits bits -> Printf.sprintf "f64:0x%016Lx" bits

let string_of_binary = function
  | Add -> "add"
  | Sub -> "sub"
  | Mul -> "mul"
  | Div -> "div"
  | Min -> "min"
  | Max -> "max"
  | And -> "and"
  | Or -> "or"
  | Xor -> "xor"

let string_of_unary = function Neg -> "neg" | Sqrt -> "sqrt"

let string_of_comparison = function Eq -> "eq" | Ne -> "ne" | Lt -> "lt" | Le -> "le" | Gt -> "gt" | Ge -> "ge"

let string_of_reduction = function
  | Reduce_add -> "add"
  | Reduce_mul -> "mul"
  | Reduce_min -> "min"
  | Reduce_max -> "max"
  | Reduce_and -> "and"
  | Reduce_or -> "or"

let string_of_scan = function Scan_add -> "add" | Scan_mul -> "mul" | Scan_min -> "min" | Scan_max -> "max"

let value id = Printf.sprintf "%%%d" id
let values ids = String.concat ", " (List.map value ids)

let string_of_provenance provenance =
  let items =
    Option.fold ~none:[] ~some:(fun id -> [ "fused=" ^ string_of_int id ]) provenance.fused
    @ Option.fold ~none:[] ~some:(fun id -> [ "through=" ^ value id ]) provenance.through
  in
  match items with [] -> "" | _ -> " {" ^ String.concat ", " items ^ "}"

let rec string_of_instruction indent (instruction : instruction) =
  let result =
    match instruction.result with
    | None -> ""
    | Some (id, typ) -> value id ^ " : " ^ string_of_typ typ ^ " = "
  in
  let op =
    match instruction.op with
    | Const literal -> "const " ^ string_of_literal literal
    | Mask_const value -> "mask.const " ^ string_of_bool value
    | Rack_const literals -> "rack.const [" ^ String.concat ", " (List.map string_of_literal literals) ^ "]"
    | Rack_splat literal -> "rack.splat " ^ string_of_literal literal
    | Broadcast operand -> "rack.broadcast " ^ value operand
    | Unary (op, operand) -> string_of_unary op ^ " " ^ value operand
    | Binary (op, left, right) -> string_of_binary op ^ " " ^ values [ left; right ]
    | Fma (a, b, c) -> "rack.fma " ^ values [ a; b; c ]
    | Compare (comparison, left, right) -> "compare." ^ string_of_comparison comparison ^ " " ^ values [ left; right ]
    | Select { condition; if_true; if_false } -> "select " ^ values [ condition; if_true; if_false ]
    | Sanitize { mask; active; benign } ->
        "sanitize " ^ values [ mask; active; benign ]
    | Load { address; alignment } -> Printf.sprintf "load %s align %d" (value address) alignment
    | Store { address; stored; alignment } -> Printf.sprintf "store %s, %s align %d" (value stored) (value address) alignment
    | Shuffle { rack; indices } -> "rack.shuffle " ^ value rack ^ " [" ^ String.concat ", " (List.map string_of_int indices) ^ "]"
    | Reduce (kind, rack) -> "rack.reduce." ^ string_of_reduction kind ^ " " ^ value rack
    | Scan (kind, rack) -> "rack.scan." ^ string_of_scan kind ^ " " ^ value rack
    | Extract { rack; lane } -> "rack.extract " ^ values [ rack; lane ]
    | Insert { rack; inserted; lane } -> "rack.insert " ^ values [ rack; inserted; lane ]
    | Gather { base; indices; mask } -> "rack.gather " ^ values ([ base; indices ] @ Option.to_list mask)
    | Scatter { base; indices; stored; mask } -> "rack.scatter " ^ values ([ base; indices; stored ] @ Option.to_list mask)
    | Mask_binary (op, left, right) -> "mask." ^ string_of_binary op ^ " " ^ values [ left; right ]
    | Mask_not operand -> "mask.not " ^ value operand
    | Call { callee; arguments; parameter_types; call_effect; _ } ->
        let effect_name = match call_effect with Pure -> "pure" | Read -> "read" | Write -> "write" | Read_write -> "read_write" in
        let arguments =
          if List.length arguments = List.length parameter_types then
            List.map2
              (fun argument typ -> value argument ^ " : " ^ string_of_typ typ)
              arguments parameter_types
          else List.map value arguments
        in
        "call @" ^ callee ^ "(" ^ String.concat ", " arguments ^ ") effect " ^ effect_name
    | Loop loop ->
        let index, typ = loop.index in
        Printf.sprintf "loop %s : %s = %s to %s step %Ld {\n%s\n%s}"
          (value index) (string_of_typ typ) (value loop.start) (value loop.stop) loop.step
          (string_of_block (indent ^ "  ") loop.body) indent
  in
  indent ^ result ^ op ^ string_of_provenance instruction.provenance

and string_of_terminator indent = function
  | Return None -> indent ^ "return"
  | Return (Some result) -> indent ^ "return " ^ value result
  | Yield -> indent ^ "yield"

and string_of_block indent block =
  String.concat "\n"
    (List.map (string_of_instruction indent) block.instructions
    @ List.map (string_of_terminator indent) block.terminators)

let string_of_parameter (parameter : parameter) =
  let name = Option.fold ~none:"" ~some:(fun name -> " " ^ name) parameter.name in
  value parameter.id ^ " : " ^ string_of_typ parameter.typ ^ name

let string_of_function (func : func) =
  let result = Option.fold ~none:"" ~some:(fun typ -> " -> " ^ string_of_typ typ) func.result in
  "func @" ^ func.name ^ "(" ^ String.concat ", " (List.map string_of_parameter func.parameters)
  ^ ")" ^ result ^ " {\n" ^ string_of_block "  " func.body ^ "\n}"

let dump module_ = String.concat "\n\n" (List.map string_of_function module_) ^ "\n"
