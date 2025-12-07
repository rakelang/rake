(** Rake 0.2.0 Lexer

    Tokenizes rake source with:
    - Tine references: #name (grid-line evokes SIMD lanes)
    - Tine declarations: | #name := (predicate)
    - Through blocks: through #tine ... -> binding
    - Sweep blocks: sweep: | #tine -> value
    - Reduction ligatures: \+/ \*/ \min/ \max/ \|/ \&/
    - Scan ligatures: \+\ \*\ \min\ \max\
    - Shuffle: ~>
    - Interleave: ><
    - Lane access: @
    - Scalar markers: <name> or <expr.field>
    - Comments: ~~ (evokes rake marks in sand)
*)

{
open Parser

exception LexError of string * Lexing.position

(** Keywords table *)
let keywords = Hashtbl.create 64
let () = List.iter (fun (k, v) -> Hashtbl.add keywords k v) [
  (* Types *)
  ("float", FLOAT); ("double", DOUBLE);
  ("int", INT); ("int8", INT8); ("int16", INT16); ("int64", INT64);
  ("uint", UINT); ("uint8", UINT8); ("uint16", UINT16); ("uint64", UINT64);
  ("bool", BOOL);
  ("vec2", VEC2); ("vec3", VEC3); ("vec4", VEC4);
  ("mat3", MAT3); ("mat4", MAT4);
  ("rack", RACK); ("mask", MASK);

  (* Type constructors *)
  ("stack", STACK); ("single", SINGLE); ("pack", PACK);
  ("type", TYPE);

  (* Functions *)
  ("crunch", CRUNCH); ("rake", RAKE); ("run", RUN);

  (* Tines and control *)
  ("through", THROUGH); ("sweep", SWEEP);
  ("else", ELSE); ("results", RESULTS); ("in", IN);

  (* Iteration *)
  ("over", OVER); ("repeat", REPEAT); ("times", TIMES); ("until", UNTIL);

  (* Bindings *)
  ("let", LET); ("fun", FUN); ("with", WITH); ("as", AS);

  (* Lane operations *)
  ("lanes", LANES);
  ("fma", FMA); ("outer", OUTER);
  ("compress", COMPRESS); ("expand", EXPAND);
  ("broadcast", BROADCAST);

  (* Boolean *)
  ("true", TRUE); ("false", FALSE);
  ("is", IS); ("not", NOT); ("and", AND); ("or", OR);
]

(** Update lexer position on newline *)
let newline lexbuf =
  let pos = lexbuf.Lexing.lex_curr_p in
  lexbuf.Lexing.lex_curr_p <- {
    pos with
    Lexing.pos_lnum = pos.Lexing.pos_lnum + 1;
    Lexing.pos_bol = pos.Lexing.pos_cnum;
  }

(** Get current position *)
let get_pos lexbuf = lexbuf.Lexing.lex_curr_p
}

(* Character classes *)
let digit = ['0'-'9']
let hex = ['0'-'9' 'a'-'f' 'A'-'F']
let alpha = ['a'-'z' 'A'-'Z']
let alphanum = alpha | digit | '_'
let ident = (alpha | '_') alphanum*
let whitespace = [' ' '\t']+
let newline = '\r'? '\n'

(* Number literals *)
let int_lit = '-'? digit+
let hex_lit = "0x" hex+
let float_lit = '-'? digit+ '.' digit* (['e' 'E'] ['+' '-']? digit+)?
              | '-'? digit+ ['e' 'E'] ['+' '-']? digit+

rule token = parse
  (* Whitespace and newlines *)
  | whitespace { token lexbuf }
  | newline { newline lexbuf; token lexbuf }

  (* Comments: ~~ rake marks in sand *)
  | "~~" { line_comment lexbuf }
  | "(*" { block_comment 1 lexbuf }

  (* Reduction ligatures: \+/ \*/ \min/ \max/ \|/ \&/ *)
  | "\\+/" { REDUCE_ADD }
  | "\\*/" { REDUCE_MUL }
  | "\\min/" { REDUCE_MIN }
  | "\\max/" { REDUCE_MAX }
  | "\\|/" { REDUCE_OR }
  | "\\&/" { REDUCE_AND }

  (* Scan ligatures: \+\ \*\ \min\ \max\ *)
  | "\\+\\" { SCAN_ADD }
  | "\\*\\" { SCAN_MUL }
  | "\\min\\" { SCAN_MIN }
  | "\\max\\" { SCAN_MAX }

  (* Multi-character operators *)
  | "|>" { PIPE }
  | "<|" { FUSED_LEFT }
  | "->" { ARROW }
  | "<-" { ASSIGN }
  | ":=" { COLONEQ }
  | "~>" { SHUFFLE }
  | "><" { INTERLEAVE }
  | "<-|" { COMPRESS_STORE }
  | "|->" { EXPAND_LOAD }
  | ">>" { SHR }
  | "<<" { SHL }
  | ">>>" { ROR }
  | "<<<" { ROL }
  | ">=" { GE }
  | "<=" { LE }
  | "!=" { NE }
  | "&&" { AMPAMP }
  | "||" { PIPEPIPE }

  (* Tine reference: #name (grid-line evokes SIMD lanes) *)
  | '#' (ident as id) { TINE_REF id }

  (* Scalar variable: <name> *)
  | '<' (ident as id) '>' { SCALAR_IDENT id }

  (* Single-character operators and delimiters *)
  | '(' { LPAREN }
  | ')' { RPAREN }
  | '{' { LBRACE }
  | '}' { RBRACE }
  | '[' { LBRACKET }
  | ']' { RBRACKET }
  | ',' { COMMA }
  | ':' { COLON }
  | ';' { SEMICOLON }
  | '|' { PIPE_CHAR }
  | '@' { AT }
  | '.' { DOT }
  | '+' { PLUS }
  | '-' { MINUS }
  | '*' { STAR }
  | '/' { SLASH }
  | '%' { PERCENT }
  | '=' { EQ }
  | '!' { BANG }
  | '>' { GT }
  | '<' { LT }
  | '_' { UNDERSCORE }

  (* Number literals *)
  | float_lit as f { FLOAT_LIT (float_of_string f) }
  | hex_lit as h { INT_LIT (Int64.of_string h) }
  | int_lit as i { INT_LIT (Int64.of_string i) }

  (* Identifiers and keywords *)
  | ident as id {
      try Hashtbl.find keywords id
      with Not_found -> IDENT id
    }

  (* String literals *)
  | '"' { string_lit (Buffer.create 32) lexbuf }

  (* End of file *)
  | eof { EOF }

  (* Unknown character *)
  | _ as c {
      raise (LexError (Printf.sprintf "Unexpected character: %c" c, get_pos lexbuf))
    }

(* Nested block comments: (* ... (* ... *) ... *) *)
and block_comment depth = parse
  | "*)" {
      if depth = 1 then token lexbuf
      else block_comment (depth - 1) lexbuf
    }
  | "(*" { block_comment (depth + 1) lexbuf }
  | newline { newline lexbuf; block_comment depth lexbuf }
  | eof { raise (LexError ("Unterminated comment", get_pos lexbuf)) }
  | _ { block_comment depth lexbuf }

(* Line comments: ~~ rake marks in sand *)
and line_comment = parse
  | newline { newline lexbuf; token lexbuf }
  | eof { EOF }
  | _ { line_comment lexbuf }

(* String literals: "..." *)
and string_lit buf = parse
  | '"' { STRING_LIT (Buffer.contents buf) }
  | "\\n" { Buffer.add_char buf '\n'; string_lit buf lexbuf }
  | "\\t" { Buffer.add_char buf '\t'; string_lit buf lexbuf }
  | "\\r" { Buffer.add_char buf '\r'; string_lit buf lexbuf }
  | "\\\\" { Buffer.add_char buf '\\'; string_lit buf lexbuf }
  | "\\\"" { Buffer.add_char buf '"'; string_lit buf lexbuf }
  | newline { raise (LexError ("Newline in string literal", get_pos lexbuf)) }
  | eof { raise (LexError ("Unterminated string", get_pos lexbuf)) }
  | _ as c { Buffer.add_char buf c; string_lit buf lexbuf }

{
let show_token = function
  | FLOAT -> "FLOAT" | DOUBLE -> "DOUBLE" | INT -> "INT" | INT8 -> "INT8"
  | INT16 -> "INT16" | INT64 -> "INT64" | UINT -> "UINT" | UINT8 -> "UINT8"
  | UINT16 -> "UINT16" | UINT64 -> "UINT64" | BOOL -> "BOOL"
  | VEC2 -> "VEC2" | VEC3 -> "VEC3" | VEC4 -> "VEC4"
  | MAT3 -> "MAT3" | MAT4 -> "MAT4"
  | RACK -> "RACK" | MASK -> "MASK" | STACK -> "STACK" | SINGLE -> "SINGLE"
  | PACK -> "PACK" | TYPE -> "TYPE"
  | CRUNCH -> "CRUNCH" | RAKE -> "RAKE" | RUN -> "RUN"
  | TINE_REF s -> Printf.sprintf "TINE_REF(%s)" s
  | THROUGH -> "THROUGH" | SWEEP -> "SWEEP" | ELSE -> "ELSE"
  | RESULTS -> "RESULTS" | IN -> "IN"
  | OVER -> "OVER" | REPEAT -> "REPEAT" | TIMES -> "TIMES" | UNTIL -> "UNTIL"
  | LET -> "LET" | FUN -> "FUN" | WITH -> "WITH" | AS -> "AS"
  | LANES -> "LANES" | FMA -> "FMA" | OUTER -> "OUTER"
  | COMPRESS -> "COMPRESS" | EXPAND -> "EXPAND" | BROADCAST -> "BROADCAST"
  | TRUE -> "TRUE" | FALSE -> "FALSE"
  | IS -> "IS" | NOT -> "NOT" | AND -> "AND" | OR -> "OR"
  | PLUS -> "PLUS" | MINUS -> "MINUS" | STAR -> "STAR" | SLASH -> "SLASH"
  | PERCENT -> "PERCENT" | LT -> "LT" | LE -> "LE" | GT -> "GT" | GE -> "GE"
  | EQ -> "EQ" | NE -> "NE" | AMPAMP -> "AMPAMP" | PIPEPIPE -> "PIPEPIPE"
  | BANG -> "BANG" | PIPE -> "PIPE" | FUSED_LEFT -> "FUSED_LEFT"
  | ARROW -> "ARROW" | ASSIGN -> "ASSIGN"
  | COLONEQ -> "COLONEQ" | SHUFFLE -> "SHUFFLE" | INTERLEAVE -> "INTERLEAVE"
  | SHL -> "SHL" | SHR -> "SHR" | ROL -> "ROL" | ROR -> "ROR"
  | COMPRESS_STORE -> "COMPRESS_STORE" | EXPAND_LOAD -> "EXPAND_LOAD"
  | REDUCE_ADD -> "REDUCE_ADD" | REDUCE_MUL -> "REDUCE_MUL"
  | REDUCE_MIN -> "REDUCE_MIN" | REDUCE_MAX -> "REDUCE_MAX"
  | REDUCE_OR -> "REDUCE_OR" | REDUCE_AND -> "REDUCE_AND"
  | SCAN_ADD -> "SCAN_ADD" | SCAN_MUL -> "SCAN_MUL"
  | SCAN_MIN -> "SCAN_MIN" | SCAN_MAX -> "SCAN_MAX"
  | LPAREN -> "LPAREN" | RPAREN -> "RPAREN" | LBRACE -> "LBRACE"
  | RBRACE -> "RBRACE" | LBRACKET -> "LBRACKET" | RBRACKET -> "RBRACKET"
  | COMMA -> "COMMA" | COLON -> "COLON" | SEMICOLON -> "SEMICOLON"
  | PIPE_CHAR -> "PIPE_CHAR" | AT -> "AT" | DOT -> "DOT"
  | UNDERSCORE -> "UNDERSCORE"
  | INT_LIT n -> Printf.sprintf "INT_LIT(%Ld)" n
  | FLOAT_LIT f -> Printf.sprintf "FLOAT_LIT(%g)" f
  | STRING_LIT s -> Printf.sprintf "STRING_LIT(%S)" s
  | IDENT s -> Printf.sprintf "IDENT(%s)" s
  | SCALAR_IDENT s -> Printf.sprintf "SCALAR_IDENT(%s)" s
  | EOF -> "EOF"

let emit lexbuf =
  let buf = Buffer.create 256 in
  let rec loop () =
    let tok = token lexbuf in
    let pos = lexbuf.Lexing.lex_curr_p in
    Buffer.add_string buf (Printf.sprintf "%d:%d %s\n"
      pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol) (show_token tok));
    if tok <> EOF then loop ()
  in
  loop ();
  Buffer.contents buf
}
