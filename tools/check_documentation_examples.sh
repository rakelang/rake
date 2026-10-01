#!/usr/bin/env bash
# Every ```rake block in Rake's documentation is a complete program, checked
# here against the compiler. The documentation owns its examples: nothing is
# copied from fixtures. An HTML comment on the line before a block chooses the
# check, and a block without one must verify on wasm-simd128:
#
#   <!-- rake-check: verify x86-avx2 aarch64-neon wasm-simd128 -->
#                                          rakec --verify-native on each target
#   <!-- rake-check: frontend -->          parse and type-check only
#   <!-- rake-check: run 33 -->            verify on wasm-simd128, and
#                                          rakec --interpret prints 33
#   <!-- rake-check: trap "text" -->       verify on wasm-simd128, and
#                                          rakec --interpret traps, saying text
#   <!-- rake-check: reject "text" -->     rakec rejects it, saying text
#
# ```text blocks are syntax fragments and ```rake,proposal blocks designs that
# no compiler implements; neither is compiled.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
website_root="${RAKE_WEBSITE_DIR:-${project_root}/../rake-lang.org}"
rakec="${RAKEC:-${project_root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  echo "documentation examples: $*" >&2
  exit 1
}

test -x "${rakec}" || fail "compiler not found at ${rakec}; run dune build"

documents=()
while IFS= read -r document; do documents+=("${document}"); done < <(
  { find "${project_root}" -maxdepth 1 -name '*.md'
    find "${project_root}/docs" -name '*.md'
    if test -d "${website_root}/src"; then find "${website_root}/src" -name '*.md'; fi
  } | sort)

checked=0
for document in "${documents[@]}"; do
  # Split the document's rake blocks into numbered files, each with its check.
  rm -f "${tmp}"/block-*
  awk -v dir="${tmp}" '
    /^```rake$/ { inside = 1; count++; file = sprintf("%s/block-%03d.rk", dir, count)
                  printf "%s\n", (mode == "" ? "verify wasm-simd128" : mode) > (file ".check")
                  printf "%d\n", NR > (file ".line"); printf "" > file; next }
    inside && /^```$/ { inside = 0; mode = ""; next }
    inside { print > file; next }
    /^<!-- rake-check: .* -->$/ { mode = $0; sub(/^<!-- rake-check: /, "", mode); sub(/ -->$/, "", mode); next }
    /^[[:space:]]*$/ { next }
    { mode = "" }
  ' "${document}"
  for block in "${tmp}"/block-*.rk; do
    test -e "${block}" || continue
    line="$(cat "${block}.line")"
    where="${document#${project_root}/}:${line}"
    read -r kind arguments < "${block}.check" || true
    case "${kind}" in
      verify)
        for target in ${arguments}; do
          "${rakec}" --verify-native --target "${target}" -o "${tmp}/out.o" "${block}" > "${tmp}/log" 2>&1 \
            || { sed 's/^/  /' "${tmp}/log" >&2; fail "${where} does not verify on ${target}"; }
        done ;;
      frontend)
        "${rakec}" "${block}" > "${tmp}/log" 2>&1 \
          || { sed 's/^/  /' "${tmp}/log" >&2; fail "${where} does not type-check"; } ;;
      run)
        "${rakec}" --verify-native --target wasm-simd128 -o "${tmp}/out.o" "${block}" > "${tmp}/log" 2>&1 \
          || { sed 's/^/  /' "${tmp}/log" >&2; fail "${where} does not verify on wasm-simd128"; }
        result="$("${rakec}" --interpret "${block}" 2>&1)" || fail "${where} traps: ${result}"
        test "${result}" = "${arguments}" || fail "${where} returns ${result}, not ${arguments}" ;;
      trap)
        "${rakec}" --verify-native --target wasm-simd128 -o "${tmp}/out.o" "${block}" > "${tmp}/log" 2>&1 \
          || { sed 's/^/  /' "${tmp}/log" >&2; fail "${where} does not verify on wasm-simd128"; }
        expected="${arguments#\"}"; expected="${expected%\"}"
        if result="$("${rakec}" --interpret "${block}" 2>&1)"; then
          fail "${where} returns ${result}, but the page says it traps"
        fi
        grep -Fq -- "${expected}" <<< "${result}" || fail "${where} traps without saying: ${expected} (${result})" ;;
      reject)
        expected="${arguments#\"}"; expected="${expected%\"}"
        if "${rakec}" --emit-asm --target wasm-simd128 -o "${tmp}/out.c" "${block}" > "${tmp}/log" 2>&1; then
          fail "${where} compiles, but the page says it is rejected"
        fi
        grep -Fq -- "${expected}" "${tmp}/log" \
          || { sed 's/^/  /' "${tmp}/log" >&2; fail "${where} is rejected without saying: ${expected}"; } ;;
      *) fail "${where} has an unknown check '${kind}'" ;;
    esac
    checked=$((checked + 1))
  done
done

echo "documentation examples: ${checked} examples in ${#documents[@]} pages checked against the compiler"
