(** Lightweight validation for Rake's indentation-sensitive source layout.

    Menhir can delimit canonical bodies from their leading and terminating
    keywords, so indentation does not need to become part of the semantic AST.
    It is nevertheless part of the accepted source language. This pass rejects
    inconsistent indentation before lexing, while ignoring blank lines and
    indentation inside parenthesized or bracketed continuations. *)

type state = {
  indents : int list;
  pending_block : (int * int) option;
  delimiter_depth : int;
  block_comment_depth : int;
}

let initial = {
  indents = [ 0 ];
  pending_block = None;
  delimiter_depth = 0;
  block_comment_depth = 0;
}

let error filename line column message =
  Error (Printf.sprintf "%s:%d:%d: Layout error: %s" filename line column message)

let indentation line =
  let rec count index =
    if index >= String.length line then Ok index
    else
      match line.[index] with
      | ' ' -> count (index + 1)
      | '\t' -> Error index
      | _ -> Ok index
  in
  count 0

let scan_content ~comment_depth ~delimiter_depth text =
  let buffer = Buffer.create (String.length text) in
  let rec loop index depth delimiters =
    if index >= String.length text then
      (String.trim (Buffer.contents buffer), depth, delimiters)
    else if depth > 0 then
      if index + 1 < String.length text && text.[index] = '(' && text.[index + 1] = '*'
      then loop (index + 2) (depth + 1) delimiters
      else if index + 1 < String.length text && text.[index] = '*' && text.[index + 1] = ')'
      then loop (index + 2) (depth - 1) delimiters
      else loop (index + 1) depth delimiters
    else if index + 1 < String.length text && text.[index] = '~' && text.[index + 1] = '~'
    then (String.trim (Buffer.contents buffer), depth, delimiters)
    else if index + 1 < String.length text && text.[index] = '(' && text.[index + 1] = '*'
    then loop (index + 2) 1 delimiters
    else (
      let char = text.[index] in
      Buffer.add_char buffer char;
      let delimiters =
        match char with
        | '(' | '[' -> delimiters + 1
        | ')' | ']' -> max 0 (delimiters - 1)
        | _ -> delimiters
      in
      loop (index + 1) depth delimiters)
  in
  loop 0 comment_depth delimiter_depth

let rec pop_to indent = function
  | [] -> None
  | current :: _ as levels when current = indent -> Some levels
  | current :: rest when current > indent -> pop_to indent rest
  | _ -> None

let validate_line filename number state line =
  match indentation line with
  | Error column -> error filename number column "tabs are not allowed in indentation"
  | Ok indent ->
      let content, block_comment_depth, delimiter_depth =
        scan_content ~comment_depth:state.block_comment_depth
          ~delimiter_depth:state.delimiter_depth line
      in
      if content = "" then Ok { state with block_comment_depth }
      else
        let depth_before = state.delimiter_depth in
        if depth_before > 0 then
          let pending_block =
            if delimiter_depth = 0 && String.ends_with ~suffix:":" content
            then Some (List.hd state.indents, number)
            else state.pending_block
          in
          Ok { state with pending_block; delimiter_depth; block_comment_depth }
        else
          match state.pending_block with
          | Some (parent, opener_line) when indent <= parent ->
              error filename number indent
                (Printf.sprintf "expected an indented body after line %d" opener_line)
          | Some (_, _) ->
              let opens_block =
                String.ends_with ~suffix:":" content || String.ends_with ~suffix:"{" content
              in
              Ok {
                indents = indent :: state.indents;
                pending_block = if opens_block then Some (indent, number) else None;
                delimiter_depth;
                block_comment_depth;
              }
          | None -> (
              match pop_to indent state.indents with
              | None ->
                  error filename number indent
                    "indentation does not match any enclosing body"
              | Some indents ->
                  let opens_block =
                    String.ends_with ~suffix:":" content || String.ends_with ~suffix:"{" content
                  in
                  Ok {
                    indents;
                    pending_block = if opens_block then Some (indent, number) else None;
                    delimiter_depth;
                    block_comment_depth;
                  })

let validate ~filename source =
  let lines = String.split_on_char '\n' source in
  let rec loop number state = function
    | [] -> (
        match state.pending_block with
        | None -> Ok ()
        | Some (_, opener_line) ->
            error filename opener_line 0 "block header has no indented body")
    | line :: rest -> (
        match validate_line filename number state line with
        | Ok state -> loop (number + 1) state rest
        | Error _ as failure -> failure)
  in
  loop 1 initial lines
