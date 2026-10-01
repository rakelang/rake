(** Reading Rake source: layout validation, layout tokens and parsing, with
    one diagnostic format for every caller. *)

let read_file filename = In_channel.with_open_bin filename In_channel.input_all

let parse_string ~filename source =
  match Layout.validate ~filename source with
  | Error _ as failure -> failure
  | Ok () -> (
      let lexbuf = Lexing.from_string source in
      lexbuf.Lexing.lex_curr_p <- { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = filename };
      let position (p : Lexing.position) = (p.pos_fname, p.pos_lnum, p.pos_cnum - p.pos_bol) in
      try Ok (Parser.program (Layout_tokens.filter Lexer.token) lexbuf) with
      | Lexer.LexError (message, p) ->
          let file, line, col = position p in
          Error (Printf.sprintf "%s:%d:%d: Lexical error: %s" file line col message)
      | Ast.Static_syntax (loc, message) ->
          Error (Printf.sprintf "%s:%d:%d: Syntax error: %s" loc.file loc.line loc.col message)
      | Parser.Error ->
          let file, line, col = position lexbuf.Lexing.lex_start_p in
          Error (Printf.sprintf "%s:%d:%d: Syntax error" file line col))

let parse_file filename = parse_string ~filename (read_file filename)
