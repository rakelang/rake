{
  description = "Rake - a vector-first programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      ocamlPackages = pkgs.ocamlPackages;
      aarch64Cross = pkgs.pkgsCross.aarch64-multiplatform;
    in {
      devShells.default = pkgs.mkShell {
        buildInputs = with ocamlPackages;
          [
            # Core OCaml
            ocaml
            dune_3
            findlib

            # Rake compiler deps
            menhir
            ppx_deriving

            # Eval arena deps
            yojson
            cmdliner

            # Dev tools
            ocaml-lsp
            ocamlformat
          ]
          ++ (with pkgs; [
            # Native object assembly, C harnesses, and object verification
            binutils
            gcc
            qemu

            # Differential parser workflow
            tree-sitter

            # Benchmarking tools
            hyperfine
            time

            # Competitor compilers (optional, for eval arena)
            rustc
            cargo
            zig
            # mojo  # Not in nixpkgs yet
            # bend  # Not in nixpkgs yet
            odin
          ])
          ++ [
            aarch64Cross.buildPackages.binutils
            aarch64Cross.stdenv.cc
          ];
        RAKE_AARCH64_LIBC = "${aarch64Cross.glibc}";
        RAKE_AARCH64_LIBC_DEV = "${aarch64Cross.glibc.dev}";
        RAKE_AARCH64_LIBC_STATIC = "${aarch64Cross.glibc.static}";
      };
    });
}
