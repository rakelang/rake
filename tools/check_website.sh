#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
website_root="${RAKE_WEBSITE_DIR:-${project_root}/../rake-lang.org}"
page="${website_root}/index.html"

fail() {
  echo "website check: $*" >&2
  exit 1
}

test -f "${page}" || fail "missing ${page}"
test -f "${website_root}/wallpaper.png" || fail "missing hero image"
test "$(tr -d '\r\n' < "${website_root}/CNAME")" = "rake-lang.org" \
  || fail "CNAME must contain rake-lang.org"

for literal in \
  '<!DOCTYPE html>' \
  'name="viewport"' \
  'src="wallpaper.png"' \
  'href="#contract"' \
  'href="#gpu"' \
  'href="#comparisons"' \
  'href="#landscape"' \
  'href="#principles"' \
  'href="#fusion"' \
  'href="#syntax"' \
  'href="#status"' \
  'id="contract"' \
  'id="gpu"' \
  'id="comparisons"' \
  'id="landscape"' \
  'id="principles"' \
  'id="fusion"' \
  'id="syntax"' \
  'id="status"' \
  'https://github.com/rakelang/rake' \
  'git clone https://github.com/rakelang/rake' \
  'Rake-owned x86-64 AVX2 and AArch64 NEON backends' \
  'One rack, one register' \
  'Rake calls one target-sized vector of' \
  'Fusion turns bindings into a verified dataflow region' \
  'data-language="rake"' \
  'font-variant-ligatures: common-ligatures contextual' \
  'const highlightRake = source =>' \
  'No silent scalar fallback' \
  'The contract C, Rust, and SIMD crates do not provide' \
  'SPIR-V defines the portable boundary' \
  'A GPU rack maps to a subgroup' \
  'What Rake could guarantee before the driver' \
  'What portable SPIR-V cannot guarantee' \
  'A stronger device-certified mode' \
  'Why use Rake for GPU kernels?' \
  'Proposed GPU contract.' \
  'two approaches to explicit lane-parallel code' \
  'ISPC: imperative SPMD' \
  'Rake: expression-oriented dataflow' \
  'A substantial shared foundation' \
  'Deliberate differences' \
  'Choose ISPC today' \
  'https://ispc.github.io/ispc.html' \
  'call to '\''sin'\'' is not supported by native crunch lowering' \
  '400-particle traversal' \
  'demo/soa-proof' \
  'Language contract' \
  'nix develop --command dune exec rakec -- --verify-native --target x86-avx2'; do
  grep -Fq -- "${literal}" "${page}" || fail "missing literal: ${literal}"
done

if grep -Eqi \
    'split it across|scalarize it|automatically fused|both branches unconditionally|github\.com/(KaiStarkk|kaistarkk|overyonderstudios)' \
    "${page}"; then
  fail "stale capability or repository claim remains in index.html"
fi

for id in contract gpu comparisons landscape principles fusion syntax status; do
  test "$(grep -Fc "id=\"${id}\"" "${page}")" -eq 1 \
    || fail "expected one section id: ${id}"
done

bash "${project_root}/tools/check_release_identity.sh" > /dev/null
bash "${project_root}/tools/check_documentation_examples.sh" > /dev/null

echo "website check: HTML references, assets, release identity, and examples passed"
