# Rake build system
# =================
#
# The production backend owns lowering, instruction selection, register
# allocation, and textual assembly. GNU as encodes the text, and GNU objdump
# verifies the resulting object.

.PHONY: default all compiler avx test parser-test demo-check release-check clean help

PROJECT_DIR := $(shell pwd)
BUILD_DIR := $(PROJECT_DIR)/_build/default/src/bin
OUT_DIR := $(PROJECT_DIR)/out

RAKE := $(BUILD_DIR)/main.exe
AVX2_SRC := $(PROJECT_DIR)/test/native/identity.rk
AVX2_OBJ := $(OUT_DIR)/lib/native-identity-avx2.o

default: compiler avx

all: compiler avx

help:
	@echo "Rake build system"
	@echo ""
	@echo "Build:"
	@echo "  make              Build the compiler and verified AVX2 object"
	@echo "  make all          Build the compiler and verified AVX2 object"
	@echo "  make compiler     Build and install rakec under out/bin"
	@echo "  make avx          Build the Rake-owned x86-avx2 object"
	@echo "  make test         Run the default conformance suite"
	@echo "  make parser-test  Compare compiler and Tree-sitter parsers"
	@echo "  make demo-check   Run the C/Rust/Rake SoA proof harness"
	@echo "  make release-check Run the complete release gate"
	@echo "  make clean        Remove build artifacts"

compiler:
	@echo "Building Rake compiler"
	@dune build
	@mkdir -p $(OUT_DIR)/bin
	@install -m 755 $(RAKE) $(OUT_DIR)/bin/rakec
	@echo "  -> out/bin/rakec"

avx: compiler
	@echo "Building and verifying Rake-owned AVX2 object"
	@mkdir -p $(OUT_DIR)/lib
	@$(RAKE) --verify-native --target x86-avx2 \
	  -o $(AVX2_OBJ) $(AVX2_SRC)
	@echo "  -> out/lib/native-identity-avx2.o"

test: compiler
	@echo "Running default conformance suite"
	@RAKEC=$(RAKE) bash test/run_tests.sh

parser-test: compiler
	@bash test/parser_differential.sh

demo-check:
	@bash demo/soa-proof/run_demo.sh

release-check:
	@bash tools/release_gate.sh

clean:
	@rm -rf $(OUT_DIR)
	@dune clean
