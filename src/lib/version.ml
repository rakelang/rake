(** Canonical Rake release identity.

    Release tooling checks every public metadata copy against [value]. Keep the
    value here so the compiled executable does not need a source checkout at
    runtime. *)

let value = "0.3.0-alpha.1"
let display = "rake " ^ value
