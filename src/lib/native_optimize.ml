(** Cost-directed rewrites over target-independent native SSA.

    Fused-flow names are source-level names for nodes in one data-flow graph;
    they are not evaluation or rounding boundaries.  This pass therefore sees
    through those names before instruction selection and selects cheaper graph
    shapes supported by the chosen profile. *)

module N = Native_ir
module IntMap = Map.Make (Int)
module IntSet = Set.Make (Int)

type error = N.error list

let format_error errors = String.concat "; " (List.map N.format_error errors)

type operation_costs = { add : int; multiply : int; fma : int option }

let operation_costs = function
  | Target.X86_avx2 | Target.Aarch64_neon ->
      Some { add = 1; multiply = 1; fma = Some 1 }
  | Target.Scalar | Target.X86_sse2 | Target.X86_avx512 | Target.Wasm_simd128 | Target.Wasm_simd128_relaxed -> None

let fma_is_cheaper costs =
  match costs.fma with
  | Some fma -> fma < costs.multiply + costs.add
  | None -> false

let definitions instructions =
  List.fold_left
    (fun definitions (instruction : N.instruction) ->
      match instruction.result with
      | Some (value, _) -> IntMap.add value instruction definitions
      | None -> definitions)
    IntMap.empty instructions

let same_fused_region left right =
  match (left.N.fused, right.N.fused) with
  | Some left, Some right -> left = right
  | None, _ | _, None -> false

let contract_fma definitions (instruction : N.instruction) =
  let multiplied value =
    match IntMap.find_opt value definitions with
    | Some
        { N.op = N.Binary (N.Mul, multiplicand, multiplier);
          provenance;
          result = Some (_, N.Rack N.F32);
          _ }
      when same_fused_region provenance instruction.provenance ->
        Some (multiplicand, multiplier)
    | _ -> None
  in
  match instruction.op with
  | N.Binary (N.Add, left, right) -> (
      match multiplied left with
      | Some (multiplicand, multiplier) ->
          { instruction with op = N.Fma (multiplicand, multiplier, right) }
      | None -> (
          match multiplied right with
          | Some (multiplicand, multiplier) ->
              { instruction with op = N.Fma (multiplicand, multiplier, left) }
          | None -> instruction))
  | _ -> instruction

let use_counts (func : N.func) =
  let count counts value =
    IntMap.update value
      (function None -> Some 1 | Some previous -> Some (previous + 1))
      counts
  in
  let counts =
    List.fold_left
      (fun counts (instruction : N.instruction) ->
        List.fold_left count counts (N.operands instruction.op))
      IntMap.empty func.body.instructions
  in
  List.fold_left
    (fun counts -> function N.Return value -> Option.fold ~none:counts ~some:(count counts) value | N.Yield -> counts)
    counts func.body.terminators

let dead_multiply_values definitions original rewritten =
  List.fold_left2
    (fun values (before : N.instruction) (after : N.instruction) ->
      match (before.op, after.op) with
      | N.Binary (N.Add, left, right), N.Fma _ ->
          let add_if_multiply values value =
            match IntMap.find_opt value definitions with
            | Some { N.op = N.Binary (N.Mul, _, _); _ } -> IntSet.add value values
            | _ -> values
          in
          add_if_multiply (add_if_multiply values left) right
      | _ -> values)
    IntSet.empty original rewritten

let optimize_function ~profile (func : N.func) =
  match operation_costs profile with
  | None -> func
  | Some costs when not (fma_is_cheaper costs) -> func
  | Some _ ->
    let original = func.body.instructions in
    let definitions = definitions original in
    let rewritten = List.map (contract_fma definitions) original in
    let provisional = { func with body = { func.body with instructions = rewritten } } in
    let uses = use_counts provisional in
    let contracted_multiplications =
      dead_multiply_values definitions original rewritten
    in
    let instructions =
      List.filter
        (fun (instruction : N.instruction) ->
          match instruction.result with
          | Some (value, _) when IntSet.mem value contracted_multiplications ->
              Option.value ~default:0 (IntMap.find_opt value uses) <> 0
          | _ -> true)
        rewritten
    in
    { func with body = { func.body with instructions } }

(** A select whose arm is another select on the same condition takes that
    select's arm directly: select(c, select(c, a, b), d) is select(c, a, d),
    and select(c, a, select(c, b, d)) is select(c, a, d). A rake's through
    block and its sweep each select on a tine, so this removes the second. *)
let simplify_selects (func : N.func) =
  let definitions = definitions func.body.instructions in
  let arm condition value pick =
    match IntMap.find_opt value definitions with
    | Some { N.op = N.Select { condition = inner; if_true; if_false }; _ } when inner = condition ->
        pick if_true if_false
    | _ -> value
  in
  let instructions =
    List.map
      (fun (instruction : N.instruction) ->
        match instruction.op with
        | N.Select { condition; if_true; if_false } ->
            let if_true = arm condition if_true (fun inner_true _ -> inner_true) in
            let if_false = arm condition if_false (fun _ inner_false -> inner_false) in
            { instruction with op = N.Select { condition; if_true; if_false } }
        | _ -> instruction)
      func.body.instructions
  in
  { func with body = { func.body with instructions } }

(** Dead-code elimination: drop pure instructions whose results nothing uses,
    until none is left. An unrolled [repeat] binds its index in every copy,
    and a copy that never reads it would otherwise leave a scalar constant
    that a rack-only backend can't hold. *)
let rec remove_dead (func : N.func) =
  (* A loop's body uses values its operands don't list, so leave such a function. *)
  if List.exists (fun (i : N.instruction) -> match i.op with N.Loop _ -> true | _ -> false) func.body.instructions
  then func
  else
  (* A mask is used by its operations and by the instructions it predicates. *)
  let uses =
    List.fold_left
      (fun uses (instruction : N.instruction) ->
        List.fold_left (fun uses value -> IntMap.add value () uses) uses
          (Option.to_list instruction.provenance.through))
      (IntMap.map (fun _ -> ()) (use_counts func)) func.body.instructions
  in
  let live (instruction : N.instruction) =
    N.effectful instruction.op
    || match instruction.result with
       | Some (value, _) -> IntMap.mem value uses
       | None -> true
  in
  let instructions = List.filter live func.body.instructions in
  if List.length instructions = List.length func.body.instructions then func
  else remove_dead { func with body = { func.body with instructions } }

let optimize ~profile module_ =
  let optimized = List.map (fun func -> remove_dead (simplify_selects (optimize_function ~profile func))) module_ in
  match N.verify optimized with Ok () -> Ok optimized | Error errors -> Error errors
