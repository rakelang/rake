#!/usr/bin/env bash
# The capability report's profile decisions must agree with what the fixtures
# compile. Every fixture is compiled for every production profile: as a
# verified object, or as a platform object when it is slow code only.
#   - A feature the report marks unavailable on a profile must appear in no
#     fixture that compiles there.
#   - A feature the report marks compiled, in full or as a slice, on a profile
#     must appear in at least one fixture that compiles there.
# Fixtures that fail are simply not evidence; rejections are checked elsewhere.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rakec="${RAKEC:-${root}/_build/default/src/bin/main.exe}"
features="${root}/_build/default/test/capability_features.exe"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
cd "${root}"

profiles=(x86-sse2 x86-avx2 x86-avx512 aarch64-neon wasm-simd128 wasm-simd128-relaxed)
mapfile -t fixtures < <(find test/native test/program test/abi test/frontend demo -name '*.rk' | sort)

"${features}" "${fixtures[@]}" >"${tmp}/features.tsv"

compiles() {
  local profile="$1" fixture="$2"
  if "${rakec}" --verify-native --no-report --target "${profile}" -o "${tmp}/object.o" "${fixture}" \
      >"${tmp}/compile.log" 2>&1; then
    return 0
  fi
  grep -q 'native slow-only code has no vector functions' "${tmp}/compile.log" \
    && "${rakec}" --emit-obj --no-report --target "${profile}" -o "${tmp}/object.o" "${fixture}" \
      >/dev/null 2>&1
}

# One line per feature that a compiling fixture uses: profile, feature.
while IFS=$'\t' read -r fixture used; do
  for profile in "${profiles[@]}"; do
    if compiles "${profile}" "${fixture}"; then
      tr ',' '\n' <<<"${used}" | sed "s/^/${profile}\t/"
    fi
  done
done <"${tmp}/features.tsv" | sort -u >"${tmp}/observed.tsv"

"${rakec}" --print-capabilities >"${tmp}/report.tsv"
awk -F '\t' 'NR > 2 && $1 != "frontend" && $1 != "scalar" && $2 != "unavailable" { print $1 "\t" $3 }' \
  "${tmp}/report.tsv" | sort >"${tmp}/compiled.tsv"
awk -F '\t' 'NR > 2 && $1 != "frontend" && $1 != "scalar" && $2 == "unavailable" { print $1 "\t" $3 }' \
  "${tmp}/report.tsv" | sort >"${tmp}/unavailable.tsv"

failed=false
contradicted="$(comm -12 "${tmp}/observed.tsv" "${tmp}/unavailable.tsv")"
if [[ -n "${contradicted}" ]]; then
  echo "capability profiles: reported unavailable, yet a fixture using it compiles:" >&2
  echo "${contradicted}" >&2
  failed=true
fi
unevidenced="$(comm -23 "${tmp}/compiled.tsv" "${tmp}/observed.tsv")"
if [[ -n "${unevidenced}" ]]; then
  echo "capability profiles: reported compiled, but no compiling fixture uses it:" >&2
  echo "${unevidenced}" >&2
  failed=true
fi
"${failed}" && exit 1
echo "capability profiles: $(wc -l <"${tmp}/compiled.tsv") compiled decisions agree with ${#fixtures[@]} fixtures"
