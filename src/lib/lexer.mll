(** Rake lexer

    Tokenizes rake source with:
    - Tine references: #name (grid-line evokes SIMD lanes)
    - Tine declarations: tine #name when predicate
    - Through blocks: through #tine else <value> into binding:
    - Sweep blocks: return sweep: | #tine => value
    - Named reductions, scans, shuffles, shifts, and rotations
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
  ("bool", BOOL);
  ("f32", F32); ("f64", F64);
  ("i32", I32); ("i8", I8); ("i16", I16); ("i64", I64);
  ("u32", U32); ("u8", U8); ("u16", U16); ("u64", U64);
  ("f32s", F32S); ("f64s", F64S);
  ("i32s", I32S); ("i8s", I8S); ("i16s", I16S); ("i64s", I64S);
  ("u32s", U32S); ("u8s", U8S); ("u16s", U16S); ("u64s", U64S);
  ("bools", BOOLS);
  ("mask", MASK);

  (* Type constructors *)
  ("stack", STACK); ("pack", PACK);

  (* Functions *)
  ("crunch", CRUNCH); ("rake", RAKE); ("run", RUN);

  (* Tines and control *)
  ("tine", TINE); ("when", WHEN);
  ("through", THROUGH); ("sweep", SWEEP);
  ("else", ELSE); ("into", INTO); ("return", RETURN); ("yield", YIELD);
  ("in", IN);

  (* Iteration *)
  ("for", FOR); ("using", USING);
  ("up", UP); ("to", TO);

  (* Bindings *)
  ("let", LET);

  (* Lane operations *)
  ("lanes", LANES);
  ("fma", FMA); ("shuffle", SHUFFLE_FN);
  ("shift_left", SHIFT_LEFT_FN); ("shift_right", SHIFT_RIGHT_FN);
  ("rotate_left", ROTATE_LEFT_FN); ("rotate_right", ROTATE_RIGHT_FN);

  (* Boolean *)
  ("true", TRUE); ("false", FALSE);
  ("not", NOT); ("and", AND); ("or", OR);
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
let type_ident = ['A'-'Z'] alphanum*
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

  (* Numeric scalar markers are single lexical units. This keeps <-1.0>
     distinct from the location-assignment operator <-. *)
  | '<' (float_lit as f) '>' { SCALAR_FLOAT_LIT (float_of_string f) }
  | '<' (int_lit as i) '>' { SCALAR_INT_LIT (Int64.of_string i) }

  (* Multi-character operators *)
  | "<|" { FUSED_LEFT }
  | "=>" { FAT_ARROW }
  | "->" { ARROW }
  | "<-" { ASSIGN }
  | ":=" { COLONEQ }
  | ">=" { GE }
  | "<=" { LE }
  | "!=" { NE }

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
  | '>' { GT }
  | '<' { LT }
  | '_' { UNDERSCORE }

  (* Number literals *)
  | float_lit as f { FLOAT_LIT (float_of_string f) }
  | hex_lit as h { INT_LIT (Int64.of_string h) }
  | int_lit as i { INT_LIT (Int64.of_string i) }

  (* Identifiers and keywords *)
  | type_ident as id { TYPE_IDENT id }
  | ident as id {
      try Hashtbl.find keywords id
      with Not_found -> IDENT id
    }

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

{
let show_token = function
  | BOOL -> "BOOL" | F32 -> "F32" | F64 -> "F64" | I32 -> "I32" | I8 -> "I8"
  | I16 -> "I16" | I64 -> "I64" | U32 -> "U32" | U8 -> "U8"
  | U16 -> "U16" | U64 -> "U64"
  | F32S -> "F32S" | F64S -> "F64S" | I32S -> "I32S" | I8S -> "I8S"
  | I16S -> "I16S" | I64S -> "I64S" | U32S -> "U32S" | U8S -> "U8S"
  | U16S -> "U16S" | U64S -> "U64S" | BOOLS -> "BOOLS"
  | MASK -> "MASK" | STACK -> "STACK" | PACK -> "PACK"
  | CRUNCH -> "CRUNCH" | RAKE -> "RAKE" | RUN -> "RUN"
  | TINE_REF s -> Printf.sprintf "TINE_REF(%s)" s
  | TINE -> "TINE" | WHEN -> "WHEN"
  | THROUGH -> "THROUGH" | SWEEP -> "SWEEP" | ELSE -> "ELSE" | INTO -> "INTO"
  | RETURN -> "RETURN" | YIELD -> "YIELD"
  | IN -> "IN" | FOR -> "FOR" | USING -> "USING"
  | UP -> "UP" | TO -> "TO"
  | LET -> "LET"
  | LANES -> "LANES" | FMA -> "FMA" | SHUFFLE_FN -> "SHUFFLE_FN"
  | SHIFT_LEFT_FN -> "SHIFT_LEFT_FN" | SHIFT_RIGHT_FN -> "SHIFT_RIGHT_FN"
  | ROTATE_LEFT_FN -> "ROTATE_LEFT_FN" | ROTATE_RIGHT_FN -> "ROTATE_RIGHT_FN"
  | TRUE -> "TRUE" | FALSE -> "FALSE"
  | NOT -> "NOT" | AND -> "AND" | OR -> "OR"
  | PLUS -> "PLUS" | MINUS -> "MINUS" | STAR -> "STAR" | SLASH -> "SLASH"
  | PERCENT -> "PERCENT" | LT -> "LT" | LE -> "LE" | GT -> "GT" | GE -> "GE"
  | EQ -> "EQ" | NE -> "NE" | FUSED_LEFT -> "FUSED_LEFT"
  | ARROW -> "ARROW" | FAT_ARROW -> "FAT_ARROW" | ASSIGN -> "ASSIGN"
  | COLONEQ -> "COLONEQ"
  | LPAREN -> "LPAREN" | RPAREN -> "RPAREN" | LBRACE -> "LBRACE"
  | RBRACE -> "RBRACE" | LBRACKET -> "LBRACKET" | RBRACKET -> "RBRACKET"
  | COMMA -> "COMMA" | COLON -> "COLON" | SEMICOLON -> "SEMICOLON"
  | PIPE_CHAR -> "PIPE_CHAR" | AT -> "AT" | DOT -> "DOT"
  | UNDERSCORE -> "UNDERSCORE"
  | INT_LIT n -> Printf.sprintf "INT_LIT(%Ld)" n
  | FLOAT_LIT f -> Printf.sprintf "FLOAT_LIT(%g)" f
  | SCALAR_FLOAT_LIT f -> Printf.sprintf "SCALAR_FLOAT_LIT(%g)" f
  | SCALAR_INT_LIT n -> Printf.sprintf "SCALAR_INT_LIT(%Ld)" n
  | IDENT s -> Printf.sprintf "IDENT(%s)" s
  | TYPE_IDENT s -> Printf.sprintf "TYPE_IDENT(%s)" s
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
