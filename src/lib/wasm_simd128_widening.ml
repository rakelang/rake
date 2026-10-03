(** Source-derived alternatives for widened integer expressions.

    Clang may compare compact lanes before extending their masks, or combine two
    extensions with a multiply. A 32-bit operation alone authorizes neither
    form: both operands must fit the narrower signed or unsigned domain. Bounds
    come from typed compact columns and integer literals. Arithmetic with an
    unproved result drops the bounds. *)

module N = Native_ir

type range = { minimum : int64; maximum : int64 }

let integer_range minimum maximum = { minimum; maximum }

let compact_column_range = function
  | Types.SInt8 -> Some (integer_range (-128L) 127L)
  | SUint8 -> Some (integer_range 0L 255L)
  | SInt16 -> Some (integer_range (-32768L) 32767L)
  | SUint16 -> Some (integer_range 0L 65535L)
  | _ -> None

let literal_range = function
  | N.Int32 value ->
      Some (integer_range (Int64.of_int32 value) (Int64.of_int32 value))
  | N.Uint32 value ->
      let value = Int64.logand (Int64.of_int32 value) 0xffffffffL in
      Some (integer_range value value)
  | N.Int16 value | N.Uint8 value ->
      Some (integer_range (Int64.of_int value) (Int64.of_int value))
  | _ -> None

let fits bounds minimum maximum =
  bounds.minimum >= minimum && bounds.maximum <= maximum

let union left right =
  match (left, right) with
  | Some left, Some right ->
      Some
        (integer_range
           (min left.minimum right.minimum)
           (max left.maximum right.maximum))
  | _ -> None

let reinterpreted_range element = function
  | Some bounds when element = N.I32 && fits bounds (-2147483648L) 2147483647L
    ->
      Some bounds
  | Some bounds when element = N.U32 && fits bounds 0L 4294967295L ->
      Some bounds
  | _ -> None

(** The result's bounds and additional packed instructions justified by this
    expression, with parameter bounds inherited from its column or prior
    immutable binding. These are alternatives, never scalar-lane permissions. *)
let expression_alternatives ~parameters (func : N.func) =
  let ranges = Hashtbl.create 16 and types = Hashtbl.create 16 in
  List.iter
    (fun (parameter : N.parameter) ->
      Hashtbl.replace types parameter.id parameter.typ;
      Option.iter
        (fun bounds -> Hashtbl.replace ranges parameter.id bounds)
        (List.assoc_opt parameter.id parameters |> Option.join))
    func.parameters;
  let range value = Hashtbl.find_opt ranges value in
  let word value =
    match Hashtbl.find_opt types value with
    | Some (N.Rack (N.I32 | N.U32)) -> true
    | _ -> false
  in
  let alternatives = ref [] in
  let add instructions = alternatives := instructions @ !alternatives in
  let narrow_domains =
    [
      (8, "s", -128L, 127L);
      (8, "u", 0L, 255L);
      (16, "s", -32768L, 32767L);
      (16, "u", 0L, 65535L);
    ]
  in
  let comparison_names comparison left right minimum maximum =
    let singleton_adjustment bounds direction =
      bounds.minimum = bounds.maximum
      && fits
           (integer_range
              (Int64.add bounds.minimum direction)
              (Int64.add bounds.maximum direction))
           minimum maximum
    in
    match comparison with
    | N.Eq -> [ "eq" ]
    | N.Ne -> [ "ne" ]
    | N.Lt | N.Gt -> [ "lt"; "gt" ]
    | N.Le ->
        [ "le"; "ge" ]
        @
        if singleton_adjustment right 1L || singleton_adjustment left (-1L) then
          [ "lt"; "gt" ]
        else []
    | N.Ge ->
        [ "ge"; "le" ]
        @
        if singleton_adjustment right (-1L) || singleton_adjustment left 1L then
          [ "gt"; "lt" ]
        else []
  in
  List.iter
    (fun (instruction : N.instruction) ->
      (match instruction.op with
      | N.Compare (comparison, left, right) when word left && word right -> (
          match (range left, range right) with
          | Some left, Some right ->
              List.iter
                (fun (bits, signedness, minimum, maximum) ->
                  if fits left minimum maximum && fits right minimum maximum
                  then (
                    let shape = Printf.sprintf "i%dx%d" bits (128 / bits) in
                    add
                      (List.map
                         (fun comparison ->
                           shape ^ "." ^ comparison
                           ^
                           if comparison = "eq" || comparison = "ne" then ""
                           else "_" ^ signedness)
                         (comparison_names comparison left right minimum maximum));
                    (* A Boolean lane is all ones or zero. Sign extension
                     preserves it when the compact comparison moves first. *)
                    add
                      (if bits = 8 then
                         [
                           "i16x8.extend_low_i8x16_s";
                           "i32x4.extend_low_i16x8_s";
                         ]
                       else [ "i32x4.extend_low_i16x8_s" ])))
                narrow_domains
          | _ -> ())
      | N.Binary (N.Mul, left, right) when word left && word right -> (
          match (range left, range right) with
          | Some left, Some right ->
              List.iter
                (fun (signedness, minimum, maximum) ->
                  if fits left minimum maximum && fits right minimum maximum
                  then add [ "i32x4.extmul_low_i16x8_" ^ signedness ])
                [ ("s", -32768L, 32767L); ("u", 0L, 65535L) ]
          | _ -> ())
      | _ -> ());
      match instruction.result with
      | None -> ()
      | Some (value, typ) ->
          Hashtbl.replace types value typ;
          let bounds =
            match instruction.op with
            | N.Const literal | N.Rack_splat literal -> literal_range literal
            | N.Broadcast scalar -> range scalar
            | N.Reinterpret { operand; element } ->
                reinterpreted_range element (range operand)
            | N.Select { if_true; if_false; _ } ->
                union (range if_true) (range if_false)
            | N.Sanitize { active; benign; _ } ->
                union (range active) (range benign)
            | _ -> None
          in
          Option.iter (fun bounds -> Hashtbl.replace ranges value bounds) bounds)
    func.body.instructions;
  let result =
    match func.body.terminators with
    | [ N.Return (Some value) ] -> range value
    | _ -> None
  in
  (result, List.sort_uniq compare !alternatives)
