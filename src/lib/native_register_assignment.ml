(** Physical parameter placement. A traversal keeps its uniform arguments
    live across iterations, while an ordinary register kernel follows its
    platform's vector argument slots. *)

type parameter = { register : int; persistent : bool }
type argument_class = Vector | Integer32 | Boolean
type integer_transfer = { argument : int; register : int }

let resolve ~available ~argument_count ~integer_argument_count ~classes assigned =
  let parameter_count = List.length classes in
  let vector_count = List.fold_left (fun count -> function Vector -> count + 1 | Integer32 | Boolean -> count) 0 classes in
  let integer_count = parameter_count - vector_count in
  match assigned with
  | None when vector_count > argument_count ->
      Error (Printf.sprintf
        "native calling convention requires %d vector arguments but provides %d register slots; stack arguments are forbidden"
        vector_count argument_count)
  | None when integer_count > integer_argument_count ->
      Error (Printf.sprintf
        "native calling convention requires %d integer arguments but provides %d register slots; stack arguments are forbidden"
        integer_count integer_argument_count)
  | None when parameter_count > List.length available ->
      Error "native parameters exceed the no-spill vector register capacity"
  | _ ->
      let parameters, transfers = match assigned with
        | Some parameters -> parameters, []
        | None ->
            (* Integer and SIMD arguments advance independent ABI counters.
               Import integer bits after the occupied SIMD argument slots. *)
            let vector_slot = ref 0 and integer_slot = ref 0 in
            let remaining = List.filter (fun register -> register >= vector_count) available in
            let transfers = ref [] in
            let parameters = List.map (function
              | Vector ->
                  let register = !vector_slot in
                  incr vector_slot;
                  { register; persistent = false }
              | Integer32 | Boolean ->
                  let argument = !integer_slot in
                  let register = List.nth remaining argument in
                  incr integer_slot;
                  transfers := { argument; register } :: !transfers;
                  { register; persistent = false }) classes in
            parameters, List.rev !transfers
      in
      let registers = List.map (fun (p : parameter) -> p.register) parameters in
      if List.length parameters <> parameter_count then
        Error "native parameter assignment does not match the selected parameters"
      else if List.length (List.sort_uniq compare registers) <> parameter_count then
        Error "native parameters require distinct physical registers"
      else if not (List.for_all (fun register -> List.mem register available) registers) then
        Error "native parameter assignment uses an unavailable physical register"
      else if List.exists (fun p -> p.persistent && p.register = 0) parameters then
        Error "persistent parameters cannot occupy the result register"
      else Ok (parameters, transfers)

let preserve_uses ~instruction_count parameters values uses =
  List.fold_left2 (fun uses parameter value ->
    if parameter.persistent then Native_ir.IntMap.add value (instruction_count + 1) uses
    else uses) uses parameters values
