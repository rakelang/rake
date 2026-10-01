(** Rake's layout tokens.

    Indentation is structural: a line ending in [:] opens an indented body.
    This filter sits between the lexer and the parser and turns the source's
    line structure into three tokens, as Python's tokenizer does: [NEWLINE]
    ends a logical line, [INDENT] opens a deeper body and [DEDENT] closes one.
    Lines inside parentheses, brackets or braces continue the logical line and
    produce no layout tokens, so parameter lists and stack bodies may span
    lines freely. {!Layout.validate} has already rejected tabs and
    indentation that matches no enclosing body. *)

type state = {
  mutable pending : (Parser.token * Lexing.position * Lexing.position) list;
  mutable indents : int list;
  mutable depth : int;
  mutable last_line : int;
  mutable started : bool;
}

let filter (lexer : Lexing.lexbuf -> Parser.token) : Lexing.lexbuf -> Parser.token =
  let state = { pending = []; indents = [ 0 ]; depth = 0; last_line = 0; started = false } in
  let emit (lexbuf : Lexing.lexbuf) (token, start, finish) =
    lexbuf.lex_start_p <- start;
    lexbuf.lex_curr_p <- finish;
    token
  in
  fun lexbuf ->
    match state.pending with
    | next :: rest ->
        state.pending <- rest;
        emit lexbuf next
    | [] ->
        let token = lexer lexbuf in
        let start = lexbuf.lex_start_p and finish = lexbuf.lex_curr_p in
        let queue = ref [] in
        let push token = queue := (token, start, start) :: !queue in
        (match token with
        | Parser.EOF ->
            if state.started then push Parser.NEWLINE;
            List.iter (fun indent -> if indent > 0 then push Parser.DEDENT) state.indents;
            state.indents <- [ 0 ];
            state.started <- false
        | _ ->
            if state.depth = 0 && start.pos_lnum <> state.last_line then (
              if state.started then push Parser.NEWLINE;
              let column = start.pos_cnum - start.pos_bol in
              match state.indents with
              | top :: _ when column > top ->
                  push Parser.INDENT;
                  state.indents <- column :: state.indents
              | _ ->
                  let rec close = function
                    | top :: (_ :: _ as rest) when column < top ->
                        push Parser.DEDENT;
                        close rest
                    | levels -> levels
                  in
                  state.indents <- close state.indents);
            state.started <- true;
            state.last_line <- start.pos_lnum;
            (match token with
            | Parser.LPAREN | Parser.LBRACKET | Parser.LBRACE -> state.depth <- state.depth + 1
            | Parser.RPAREN | Parser.RBRACKET | Parser.RBRACE -> state.depth <- max 0 (state.depth - 1)
            | _ -> ()));
        queue := (token, start, finish) :: !queue;
        (match List.rev !queue with
        | first :: rest ->
            state.pending <- rest;
            emit lexbuf first
        | [] -> assert false)
