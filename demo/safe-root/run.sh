#!/usr/bin/env bash
# A bounded native comparison. Run inside the pinned development shell.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
output="${root}/.build/safe-root"
mkdir -p "${output}"
"${rakec}" --emit-asm --target x86-avx2 -o "${output}/safe_root.generated.c" "${root}/demo/safe-root/safe_root.rk"
"${rakec}" --verify-native --target x86-avx2 -o "${output}/safe_root.o" "${root}/demo/safe-root/safe_root.rk"
"${rakec}" --verify-native --target x86-avx2 -o "${output}/paired.o" "${root}/test/abi/native_streams.rk"
gcc "${output}/paired.o" -lm -o "${output}/paired"
expected="$("${rakec}" --interpret --target x86-avx2 "${root}/test/abi/native_streams.rk")"
actual=0
"${output}/paired" || actual=$?
test "${actual}" = "${expected}" && test "${actual}" = 14
flags=(-std=gnu11 -O3 -mavx2 -ffp-contract=off -fno-fast-math -fno-math-errno -Wall -Wextra -Werror)
gcc "${flags[@]}" -c "${root}/demo/safe-root/safe_root.c" -o "${output}/c.o"
gcc "${flags[@]}" "${root}/demo/safe-root/compare.c" "${output}/c.o" "${output}/safe_root.o" -lm -o "${output}/compare"
objdump -d -M intel "${output}/safe_root.o" > "${output}/rake.disassembly"
objdump -d -M intel "${output}/c.o" > "${output}/c.disassembly"
printf 'compiler\t%s\n' "$(git -C "${root}" rev-parse HEAD)"
printf 'c_compiler\t%s\n' "$(gcc --version | head -1)"
printf 'c_flags\t%s\n' "${flags[*]}"
printf 'cpu\t%s\n' "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
printf 'baseline\toptimized C (automatic vectorization enabled)\n'
"${output}/compare"
gcc "${flags[@]}" -fno-tree-vectorize -c "${root}/demo/safe-root/safe_root.c" -o "${output}/c-scalar.o"
gcc "${flags[@]}" "${root}/demo/safe-root/compare.c" "${output}/c-scalar.o" "${output}/safe_root.o" -lm -o "${output}/compare-scalar"
printf 'baseline\tscalar C (-fno-tree-vectorize added)\n'
"${output}/compare-scalar"
