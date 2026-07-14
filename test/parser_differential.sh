#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tree_sitter_root="${TREE_SITTER_RAKE_DIR:-$(cd "${project_root}/../tree-sitter-rake" 2>/dev/null && pwd)}"
rakec="${RAKEC:-${project_root}/_build/default/src/bin/main.exe}"
tree_sitter="${TREE_SITTER_BIN:-tree-sitter}"
main_manifest="${project_root}/test/manifest.tsv"
parser_manifest="${project_root}/test/parser/manifest.tsv"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  echo "parser differential: $*" >&2
  exit 1
}

test -x "${rakec}" || fail "compiler not found at ${rakec}; run dune build"
test -f "${tree_sitter_root}/grammar.js" \
  || fail "Tree-sitter grammar not found at ${tree_sitter_root}"
command -v "${tree_sitter}" >/dev/null \
  || fail "${tree_sitter} is unavailable; enter the Tree-sitter Nix shell"

compiler_parse() {
  "${rakec}" --emit-ast "$1"
}

tree_sitter_parse() {
  (cd "${tree_sitter_root}" && "${tree_sitter}" parse --quiet "$1")
}

case_number=0
check_source() {
  local source="$1"
  local expected="$2"
  local label="$3"
  local compiler_status=0
  local tree_status=0
  local compiler_output
  local tree_output

  case_number=$((case_number + 1))
  compiler_output="${tmp}/${case_number}.compiler"
  tree_output="${tmp}/${case_number}.tree-sitter"
  compiler_parse "${source}" >"${compiler_output}" 2>&1 || compiler_status=$?
  tree_sitter_parse "${source}" >"${tree_output}" 2>&1 || tree_status=$?

  if test "${compiler_status}" -eq 0; then compiler_result=accept; else compiler_result=reject; fi
  if test "${tree_status}" -eq 0; then tree_result=accept; else tree_result=reject; fi

  if test "${compiler_result}" != "${tree_result}" \
      || test "${compiler_result}" != "${expected}"; then
    echo "parser differential mismatch: ${label}" >&2
    echo "  source: ${source}" >&2
    echo "  expected: ${expected}" >&2
    echo "  compiler: ${compiler_result} (exit ${compiler_status})" >&2
    if test "${compiler_status}" -ne 0; then
      sed 's/^/    /' "${compiler_output}" >&2
    fi
    echo "  tree-sitter: ${tree_result} (exit ${tree_status})" >&2
    if test "${tree_status}" -ne 0; then
      sed 's/^/    /' "${tree_output}" >&2
    fi
    return 1
  fi
}

# The WP-07 manifest remains the one copy of every executable and proposed
# example. Design-only future examples are deliberately outside the canonical
# source grammar until their contracts are promoted.
while IFS=$'\t' read -r path category _; do
  test "${path}" != path || continue
  case "${category}" in
    future) continue ;;
    frontend|native|reject) expected=accept; class=supported ;;
    *) fail "unknown conformance category ${category} for ${path}" ;;
  esac
  check_source "${project_root}/${path}" "${expected}" "${class}: ${path}"
done < "${main_manifest}"

cut -f1 "${parser_manifest}" | tail -n +2 | sort >"${tmp}/parser-manifest-paths"
if test "$(wc -l <"${tmp}/parser-manifest-paths")" -ne \
    "$(sort -u "${tmp}/parser-manifest-paths" | wc -l)"; then
  fail "parser manifest contains duplicate fixture paths"
fi
(cd "${project_root}" && find test/parser/malformed -type f -name '*.rk.invalid' -print | sort) \
  >"${tmp}/malformed-paths"
diff -u "${tmp}/parser-manifest-paths" "${tmp}/malformed-paths" \
  || fail "parser manifest and malformed fixture tree differ"

while IFS=$'\t' read -r path class construct; do
  test "${path}" != path || continue
  test "${class}" = malformed || fail "${path}: expected malformed class"
  check_source "${project_root}/${path}" reject "malformed ${construct}: ${path}"
done < "${parser_manifest}"

# Additional paths let documentation and website extraction feed their
# canonical examples through the same two real parsers.
for source in "$@"; do
  check_source "$(realpath "${source}")" accept "external supported source: ${source}"
done

echo "parser differential passed (${case_number} sources)"
