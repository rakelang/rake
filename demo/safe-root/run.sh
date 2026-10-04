#!/usr/bin/env bash
# A bounded native comparison. Run inside the pinned development shell.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
output="${root}/.build/safe-root"
mkdir -p "${output}"
"${rakec}" --emit-c --target x86-avx2 -o "${output}/safe_root.generated.c" "${root}/demo/safe-root/safe_root.rk"
"${rakec}" --verify-native --target x86-avx2 -o "${output}/safe_root.o" "${root}/demo/safe-root/safe_root.rk"
"${rakec}" --verify-native --target x86-avx2 -o "${output}/paired.o" "${root}/test/abi/native_streams.rk"
gcc "${output}/paired.o" -lm -o "${output}/paired"
expected="$("${rakec}" --interpret --target x86-avx2 "${root}/test/abi/native_streams.rk")"
actual=0
"${output}/paired" || actual=$?
if [[ "${actual}" != "${expected}" ]]; then
  printf 'safe-root composed program: native returned %s, interpreter returned %s\n' "${actual}" "${expected}" >&2
  exit 1
fi
flags=(-std=gnu11 -O3 -mavx2 -ffp-contract=off -fno-fast-math -fno-math-errno -Wall -Wextra -Werror)
gcc "${flags[@]}" -c "${root}/demo/safe-root/safe_root.c" -o "${output}/c.o"
gcc "${flags[@]}" -fno-tree-vectorize -Dsafe_root_c=safe_root_c_scalar \
  -c "${root}/demo/safe-root/safe_root.c" -o "${output}/c-scalar.o"
gcc "${flags[@]}" -c "${root}/demo/safe-root/safe_root_avx2.c" -o "${output}/c-intrinsics.o"
gcc "${flags[@]}" -fopt-info-vec-missed="${output}/sine.vectorization.txt" \
  -c "${root}/demo/soa-proof/c/reject_sin.c" -o "${output}/sine.o"
if "${rakec}" --verify-native --target x86-avx2 -o "${output}/sine-rake.o" \
  "${root}/demo/soa-proof/rake/reject_sin.rk" > "${output}/sine.rake.txt" 2>&1; then
  printf 'native sine unexpectedly compiled\n' >&2
  exit 1
fi
grep -F "call to 'sin' is not supported by native scratch lowering" "${output}/sine.rake.txt"
"${rakec}" --verify-native --target x86-avx2 -o "${output}/bounded-sine.o" \
  "${root}/demo/safe-root/bounded_sine.rk"
gcc "${flags[@]}" "${root}/demo/safe-root/bounded_sine.c" \
  "${output}/bounded-sine.o" -lm -o "${output}/bounded-sine"
"${output}/bounded-sine" | tee "${output}/bounded-sine.tsv"
gcc "${flags[@]}" -DSAFE_ROOT_FOUR_WAY "${root}/demo/safe-root/compare.c" \
  "${output}/c.o" "${output}/c-scalar.o" "${output}/c-intrinsics.o" \
  "${output}/safe_root.o" -lm -o "${output}/compare"
objdump -d -M intel "${output}/safe_root.o" > "${output}/rake.disassembly"
objdump -d -M intel "${output}/c.o" > "${output}/c.disassembly"
objdump -d -M intel "${output}/c-scalar.o" > "${output}/c-scalar.disassembly"
objdump -d -M intel "${output}/c-intrinsics.o" > "${output}/c-intrinsics.disassembly"
objdump -dr -M intel "${output}/sine.o" > "${output}/sine.disassembly"
objdump -d -M intel "${output}/bounded-sine" > "${output}/bounded-sine.disassembly"
{
  printf 'source_parent\t%s\n' "$(git -C "${root}" rev-parse HEAD)"
  sha256sum "${rakec}" "${root}/demo/safe-root/compare.c" \
    "${root}/demo/safe-root/safe_root.c" "${root}/demo/safe-root/safe_root_avx2.c" \
    "${root}/demo/safe-root/safe_root.rk" "${root}/demo/safe-root/run.sh"
  sha256sum "${output}/compare" "${output}/c.o" "${output}/c-scalar.o" \
    "${output}/c-intrinsics.o" "${output}/safe_root.o"
  printf 'c_compiler\t%s\n' "$(gcc --version | head -1)"
  printf 'c_flags\t%s\n' "${flags[*]}"
  printf 'scalar_extra_flags\t-fno-tree-vectorize -Dsafe_root_c=safe_root_c_scalar\n'
  printf 'cpu\t%s\n' "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
  printf 'elements\t1000000\n'
  "${output}/compare"
} | tee "${output}/timings.tsv"
