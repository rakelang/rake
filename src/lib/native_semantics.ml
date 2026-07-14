(** Public executable-semantics interface.

    The implementation remains in [Native_reference] while downstream code
    migrates from the old name.  This module is the language's scalar semantic
    model; it is independent of every machine-code backend. *)

include Native_reference
