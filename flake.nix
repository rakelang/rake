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
      wasiCross = pkgs.pkgsCross.wasi32;
      # Intel SDE runs the AVX-512 runtime checks on hosts without AVX-512F.
      # It is the release the CI workflow downloads.
      intelSde = pkgs.stdenvNoCC.mkDerivation {
        pname = "intel-sde";
        version = "10.13.1-2026-07-28";
        src = pkgs.fetchurl {
          url = "https://downloadmirror.intel.com/924984/sde-external-10.13.1-2026-07-28-lin.tar.xz";
          sha256 = "94e97d623fec54385686e1e7ba65ebc9941748c05ee451423948334892bf2b50";
        };
        nativeBuildInputs = [pkgs.autoPatchelfHook];
        buildInputs = [pkgs.stdenv.cc.cc.lib];
        autoPatchelfIgnoreMissingDeps = true;
        dontStrip = true;
        installPhase = "cp -r . $out";
      };
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

            # Browser build of the compiler used by rake-lang.org/playground.
            js_of_ocaml
            js_of_ocaml-compiler
            js_of_ocaml-ppx

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

            # wasm-simd128: Clang compiles the emitted C, llvm-objdump verifies it.
            # Unwrapped, so gcc stays the C compiler for native harnesses.
            llvmPackages.clang-unwrapped
            llvmPackages.llvm
            # Runtime tests link freestanding wasm32 modules and run them.
            llvmPackages.lld
            wasmtime

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
        RAKE_SDE = pkgs.lib.optionalString (system == "x86_64-linux") "${intelSde}/sde64";
        RAKE_AARCH64_LIBC = "${aarch64Cross.glibc}";
        RAKE_AARCH64_LIBC_DEV = "${aarch64Cross.glibc.dev}";
        RAKE_AARCH64_LIBC_STATIC = "${aarch64Cross.glibc.static}";
        RAKE_WASI_LIBC = "${wasiCross.wasilibc}";
        RAKE_WASI_LIBC_DEV = "${wasiCross.wasilibc.dev}";
        RAKE_WASM_CFLAGS = "-isystem ${wasiCross.wasilibc.dev}/include";
      };
    });
}
