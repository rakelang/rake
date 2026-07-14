{ pkgs ? import <nixpkgs> { } }:

let
  aarch64Cross = pkgs.pkgsCross.aarch64-multiplatform;
in

pkgs.mkShell {
  buildInputs =
    (with pkgs.ocamlPackages; [
      ocaml
      dune_3
      findlib
      menhir
      ppx_deriving
      cmdliner
      ocaml-lsp
      ocamlformat
    ])
    ++ (with pkgs; [
      # Native object assembly, C harnesses, and object verification
      binutils
      gcc
      qemu

      # Differential parser workflow
      tree-sitter
    ])
    ++ [
      aarch64Cross.buildPackages.binutils
      aarch64Cross.stdenv.cc
    ];

  RAKE_AARCH64_LIBC = "${aarch64Cross.glibc}";
  RAKE_AARCH64_LIBC_DEV = "${aarch64Cross.glibc.dev}";
  RAKE_AARCH64_LIBC_STATIC = "${aarch64Cross.glibc.static}";

  shellHook = ''
    echo "Rake development environment"
    echo "  - OCaml/Menhir compiler frontend"
    echo "  - Rake-owned native backend with GNU assembler and objdump"
  '';
}
