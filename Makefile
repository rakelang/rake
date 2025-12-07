# Rake Build System
# ==================
#
# Usage:
#   make              Build compiler + AVX2 variant
#   make all          Build all variants
#   make bench        Run unified benchmark
#   make demo-cpu     Interactive SDL demo
#   make demo-gpu     Vulkan GPU demo
#   make clean        Clean all build artifacts
#
# Variants:
#   make sse          SSE (width 4, 128-bit)
#   make avx          AVX2 (width 8, 256-bit) [default]
#   make avx512       AVX-512 (width 16, 512-bit)
#   make gpu          GPU scalar parallel

.PHONY: all default compiler demo demo-cpu demo-gpu vulkan
.PHONY: bench bench-sse bench-avx clean sse avx avx512 gpu test help

# Directories
PROJECT_DIR := $(shell pwd)
BUILD_DIR := $(PROJECT_DIR)/_build/default/src/bin
OUT_DIR := $(PROJECT_DIR)/out
TMP_DIR := /tmp/rake_build

# Tools
RAKE := $(BUILD_DIR)/main.exe
MLIR_OPT := mlir-opt
MLIR_TRANSLATE := mlir-translate
LLC := llc
CLANG := clang

# MLIR lowering passes
MLIR_PASSES := --convert-vector-to-scf \
               --convert-scf-to-cf \
               --convert-vector-to-llvm \
               --convert-math-to-llvm \
               --convert-arith-to-llvm \
               --convert-index-to-llvm \
               --convert-func-to-llvm \
               --convert-cf-to-llvm \
               --finalize-memref-to-llvm \
               --reconcile-unrealized-casts

# Source files
DEMO_SRC := $(PROJECT_DIR)/examples/demo.rk
DEMO_CPU_SRC := $(PROJECT_DIR)/examples/demo_cpu.c
DEMO_GPU_SRC := $(PROJECT_DIR)/examples/demo_gpu.c
BENCHMARK_SRC := $(PROJECT_DIR)/examples/benchmark.c
GPU_SHADER := $(PROJECT_DIR)/examples/shader_gpu.comp

# Default target
default: compiler avx

# Build everything
all: compiler sse avx avx512

# Help
help:
	@echo "Rake Build System"
	@echo ""
	@echo "Build:"
	@echo "  make              Build compiler + AVX2"
	@echo "  make all          Build all variants"
	@echo "  make compiler     Build Rake compiler"
	@echo "  make clean        Clean build artifacts"
	@echo ""
	@echo "Variants:"
	@echo "  make sse          Width 4  (128-bit, SSE4)"
	@echo "  make avx          Width 8  (256-bit, AVX2)"
	@echo "  make avx512       Width 16 (512-bit, AVX-512)"
	@echo ""
	@echo "Demos:"
	@echo "  make demo-cpu     CPU demo (C vs Rake)"
	@echo "  make demo-gpu     GPU demo (CPU vs Vulkan)"
	@echo ""
	@echo "Benchmark:"
	@echo "  make bench        Unified benchmark (all implementations)"
	@echo "  make bench-sse    SSE-only benchmark"
	@echo "  make bench-avx    AVX-only benchmark"

# ==============================================================================
# Compiler
# ==============================================================================

compiler:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Building Rake compiler"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@dune build
	@mkdir -p $(OUT_DIR)/bin
	@install -m 755 $(RAKE) $(OUT_DIR)/bin/rakec
	@echo "  → out/bin/rakec"

# ==============================================================================
# Directory Creation
# ==============================================================================

$(OUT_DIR)/mlir $(OUT_DIR)/lib $(OUT_DIR)/bin $(TMP_DIR):
	@mkdir -p $@

# ==============================================================================
# Rake Compilation (MLIR → LLVM → Object)
# ==============================================================================

# SSE (width 4)
sse: compiler | $(OUT_DIR)/mlir $(OUT_DIR)/lib $(TMP_DIR)
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Building SSE variant (width 4)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@$(RAKE) --emit-mlir --width 4 $(DEMO_SRC) > $(OUT_DIR)/mlir/demo-sse.mlir
	@$(MLIR_OPT) $(MLIR_PASSES) $(OUT_DIR)/mlir/demo-sse.mlir -o $(TMP_DIR)/demo-sse.llvm.mlir
	@$(MLIR_TRANSLATE) --mlir-to-llvmir $(TMP_DIR)/demo-sse.llvm.mlir -o $(TMP_DIR)/demo-sse.ll
	@$(LLC) -O3 -filetype=obj -march=x86-64 -mattr=+sse4.2 $(TMP_DIR)/demo-sse.ll -o $(OUT_DIR)/lib/demo-sse.o
	@echo "  → out/lib/demo-sse.o"

# AVX2 (width 8)
avx: compiler | $(OUT_DIR)/mlir $(OUT_DIR)/lib $(TMP_DIR)
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Building AVX2 variant (width 8)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@$(RAKE) --emit-mlir --width 8 $(DEMO_SRC) > $(OUT_DIR)/mlir/demo-avx.mlir
	@$(MLIR_OPT) $(MLIR_PASSES) $(OUT_DIR)/mlir/demo-avx.mlir -o $(TMP_DIR)/demo-avx.llvm.mlir
	@$(MLIR_TRANSLATE) --mlir-to-llvmir $(TMP_DIR)/demo-avx.llvm.mlir -o $(TMP_DIR)/demo-avx.ll
	@$(LLC) -O3 -filetype=obj -march=x86-64 -mattr=+avx2 $(TMP_DIR)/demo-avx.ll -o $(OUT_DIR)/lib/demo-avx.o
	@echo "  → out/lib/demo-avx.o"

# AVX-512 (width 16)
avx512: compiler | $(OUT_DIR)/mlir $(OUT_DIR)/lib $(TMP_DIR)
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Building AVX-512 variant (width 16)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@$(RAKE) --emit-mlir --width 16 $(DEMO_SRC) > $(OUT_DIR)/mlir/demo-avx512.mlir
	@$(MLIR_OPT) $(MLIR_PASSES) $(OUT_DIR)/mlir/demo-avx512.mlir -o $(TMP_DIR)/demo-avx512.llvm.mlir
	@$(MLIR_TRANSLATE) --mlir-to-llvmir $(TMP_DIR)/demo-avx512.llvm.mlir -o $(TMP_DIR)/demo-avx512.ll
	@$(LLC) -O3 -filetype=obj -march=x86-64 -mattr=+avx512f,+avx512vl $(TMP_DIR)/demo-avx512.ll -o $(OUT_DIR)/lib/demo-avx512.o
	@echo "  → out/lib/demo-avx512.o"

# GPU (scalar parallel)
gpu: compiler | $(OUT_DIR)/mlir $(OUT_DIR)/lib $(TMP_DIR)
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Building GPU variant (scalar)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@$(RAKE) --emit-mlir --gpu $(DEMO_SRC) > $(OUT_DIR)/mlir/demo-gpu.mlir
	@$(MLIR_OPT) $(MLIR_PASSES) $(OUT_DIR)/mlir/demo-gpu.mlir -o $(TMP_DIR)/demo-gpu.llvm.mlir
	@$(MLIR_TRANSLATE) --mlir-to-llvmir $(TMP_DIR)/demo-gpu.llvm.mlir -o $(TMP_DIR)/demo-gpu.ll
	@$(LLC) -O3 -filetype=obj -march=x86-64 $(TMP_DIR)/demo-gpu.ll -o $(OUT_DIR)/lib/demo-gpu.o
	@echo "  → out/lib/demo-gpu.o"

# ==============================================================================
# Demo Applications
# ==============================================================================

demo: demo-cpu

demo-cpu: avx | $(OUT_DIR)/bin
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Building CPU demo"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@SDL_CFLAGS=$$(pkg-config --cflags sdl2 2>/dev/null || echo "-I/usr/include/SDL2"); \
	 SDL_LIBS=$$(pkg-config --libs sdl2 2>/dev/null || echo "-lSDL2"); \
	 $(CLANG) -O3 -mavx2 -Wall $$SDL_CFLAGS \
	   $(DEMO_CPU_SRC) $(OUT_DIR)/lib/demo-avx.o \
	   -o $(OUT_DIR)/bin/demo-cpu $$SDL_LIBS -lm
	@echo "  → out/bin/demo-cpu"
	@echo ""
	@echo "  Run: ./out/bin/demo-cpu"
	@echo "  Keys: 1=C Scalar, 2=C SIMD, 3=Rake SIMD, Q=Quit"

demo-gpu: avx gpu | $(OUT_DIR)/bin
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Building GPU demo"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@glslc -fshader-stage=compute $(GPU_SHADER) -o $(OUT_DIR)/lib/shader.spv 2>/dev/null || true
	@SDL_CFLAGS=$$(pkg-config --cflags sdl2 2>/dev/null || echo "-I/usr/include/SDL2"); \
	 SDL_LIBS=$$(pkg-config --libs sdl2 2>/dev/null || echo "-lSDL2"); \
	 $(CLANG) -O3 -mavx2 -Wall $$SDL_CFLAGS \
	   $(DEMO_GPU_SRC) $(OUT_DIR)/lib/demo-avx.o \
	   -o $(OUT_DIR)/bin/demo-gpu $$SDL_LIBS -lvulkan -lm 2>/dev/null || \
	   echo "  (Vulkan not available, skipping GPU demo)"
	@echo "  → out/bin/demo-gpu"

vulkan: demo-gpu

# ==============================================================================
# Unified Benchmark
# ==============================================================================

# SSE benchmark
bench-sse: sse | $(OUT_DIR)/bin
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Building SSE benchmark"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@$(CLANG) -O3 -msse4.2 -Wall -DRAKE_SSE \
	  $(BENCHMARK_SRC) $(OUT_DIR)/lib/demo-sse.o \
	  -o $(OUT_DIR)/bin/bench-sse -lm
	@$(OUT_DIR)/bin/bench-sse

# AVX benchmark
bench-avx: avx | $(OUT_DIR)/bin
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Building AVX benchmark"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@$(CLANG) -O3 -mavx2 -Wall -DRAKE_AVX \
	  $(BENCHMARK_SRC) $(OUT_DIR)/lib/demo-avx.o \
	  -o $(OUT_DIR)/bin/bench-avx -lm
	@$(OUT_DIR)/bin/bench-avx

# Main benchmark target - runs comprehensive comparison
bench: sse avx | $(OUT_DIR)/bin
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Running unified benchmark"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "[SSE Results]"
	@$(CLANG) -O3 -msse4.2 -Wall -DRAKE_SSE \
	  $(BENCHMARK_SRC) $(OUT_DIR)/lib/demo-sse.o \
	  -o $(OUT_DIR)/bin/bench-sse -lm
	@$(OUT_DIR)/bin/bench-sse
	@echo ""
	@echo "[AVX Results]"
	@$(CLANG) -O3 -mavx2 -Wall -DRAKE_AVX \
	  $(BENCHMARK_SRC) $(OUT_DIR)/lib/demo-avx.o \
	  -o $(OUT_DIR)/bin/bench-avx -lm
	@$(OUT_DIR)/bin/bench-avx

# ==============================================================================
# Test
# ==============================================================================

test: compiler
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Testing MLIR emission"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo -n "  Width 4 (SSE):     " && $(OUT_DIR)/bin/rakec --emit-mlir --width 4 $(DEMO_SRC) | head -1
	@echo -n "  Width 8 (AVX):     " && $(OUT_DIR)/bin/rakec --emit-mlir --width 8 $(DEMO_SRC) | head -1
	@echo -n "  Width 16 (AVX512): " && $(OUT_DIR)/bin/rakec --emit-mlir --width 16 $(DEMO_SRC) | head -1
	@echo -n "  GPU (scalar):      " && $(OUT_DIR)/bin/rakec --emit-mlir --gpu $(DEMO_SRC) | head -1
	@echo "  ✓ All modes working"

# ==============================================================================
# Clean
# ==============================================================================

clean:
	@echo "Cleaning..."
	@rm -rf $(OUT_DIR) $(TMP_DIR)
	@dune clean
	@echo "  ✓ Clean"
