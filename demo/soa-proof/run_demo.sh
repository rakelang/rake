#!/usr/bin/env bash

set -euo pipefail

demo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${demo_dir}/../.." && pwd)"
rakec="${root}/_build/default/src/bin/main.exe"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

dune build --root "${root}"

"${rakec}" "${demo_dir}/rake/particles_400_run.rk" >"${tmp}/run.check"
"${rakec}" --verify-native --target x86-avx2 \
  -o "${tmp}/advance-rack.o" "${demo_dir}/rake/advance_rack.rk"

for rejected in reject_sin reject_register_pressure; do
  if "${rakec}" --verify-native --target x86-avx2 \
      -o "${tmp}/${rejected}.o" "${demo_dir}/rake/${rejected}.rk" \
      >"${tmp}/${rejected}.stdout" 2>"${tmp}/${rejected}.stderr"; then
    echo "Rake unexpectedly accepted ${rejected}.rk" >&2
    exit 1
  fi
  test ! -e "${tmp}/${rejected}.o"
done
grep -Fq "call to 'sin' is not supported" "${tmp}/reject_sin.stderr"
grep -Fq "no spill fallback is permitted" "${tmp}/reject_register_pressure.stderr"

"${demo_dir}/c/check.sh"
cargo run --quiet --release --manifest-path "${demo_dir}/rust/Cargo.toml" -- 400
cargo run --quiet --release --manifest-path "${demo_dir}/rust/Cargo.toml" -- 403

"${demo_dir}/tools/run.sh" --manifest "${demo_dir}/cases.tsv" \
  --out "${demo_dir}/out" "$@"
