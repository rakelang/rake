(** Physical parameter placement. A traversal keeps its uniform arguments
    live across iterations, while an ordinary register kernel follows its
    platform's vector argument slots. *)

type parameter = { register : int; persistent : bool }

let resolve ~available ~argument_count ~parameter_count assigned =
  match assigned with
  | None when parameter_count > argument_count ->
      Error (Printf.sprintf
        "native calling convention requires %d vector arguments but provides %d register slots; stack arguments are forbidden"
        parameter_count argument_count)
  | _ ->
      let parameters = match assigned with
        | Some parameters -> parameters
        | None -> List.init parameter_count (fun register -> { register; persistent = false })
      in
      let registers = List.map (fun p -> p.register) parameters in
      if List.length parameters <> parameter_count then
        Error "native parameter assignment does not match the selected parameters"
      else if List.length (List.sort_uniq compare registers) <> parameter_count then
        Error "native parameters require distinct physical registers"
      else if not (List.for_all (fun register -> List.mem register available) registers) then
        Error "native parameter assignment uses an unavailable physical register"
      else if List.exists (fun p -> p.persistent && p.register = 0) parameters then
        Error "persistent parameters cannot occupy the result register"
      else Ok parameters

let preserve_uses ~instruction_count parameters values uses =
  List.fold_left2 (fun uses parameter value ->
    if parameter.persistent then Native_ir.IntMap.add value (instruction_count + 1) uses
    else uses) uses parameters values
