{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Build tools
    clang
    llvmPackages.llvm
    mlir

    # Graphics
    SDL2
    vulkan-loader
    vulkan-headers
    shaderc

    # Utilities
    pkg-config
  ];

  shellHook = ''
    echo "Rake development environment"
    echo "  - LLVM/MLIR for compilation"
    echo "  - SDL2 for visualization"
    echo "  - Vulkan for GPU compute"
  '';
}
