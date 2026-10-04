(** C locals derived from Rake identifiers. User identifiers gain a trailing
    underscore. Compiler identifiers replace [$] with [_rk]. *)
let local name =
  if String.contains name '$' then String.concat "_rk" (String.split_on_char '$' name)
  else name ^ "_"
