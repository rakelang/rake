#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${project_root}/test/manifest.tsv"
parser_manifest="${project_root}/test/parser/manifest.tsv"
rakec="${RAKEC:-${project_root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  echo "conformance: $*" >&2
  exit 1
}

test -x "${rakec}" || fail "compiler not found at ${rakec}; run dune build"

# The manifest owns classification. Every .rk source under test/ and examples/
# occurs exactly once. Frontend acceptance and production executability are
# deliberately distinct stages: a checker pass never stands in for native code.
cut -f1 "${manifest}" | tail -n +2 | sort > "${tmp}/manifest-paths"
if test "$(wc -l < "${tmp}/manifest-paths")" -ne \
    "$(sort -u "${tmp}/manifest-paths" | wc -l)"; then
  fail "manifest contains duplicate fixture paths"
fi
(cd "${project_root}" && find test examples -type f -name '*.rk' -print) \
  | sort > "${tmp}/actual-paths"
diff -u "${tmp}/manifest-paths" "${tmp}/actual-paths" \
  || fail "manifest and fixture tree differ"

while IFS=$'\t' read -r path category targets widths stage outcome diagnostic; do
  test "${path}" != "path" || continue
  case "${category}:${path}" in
    frontend:test/frontend/*.rk|native:test/native/*.rk|reject:test/reject/*.rk|future:examples/future/*.rk) ;;
    *) fail "${path}: category ${category} disagrees with directory" ;;
  esac
  case "${category}:${stage}:${outcome}" in
    frontend:frontend:pass|native:native-object:pass|reject:frontend:reject|future:design:excluded) ;;
    *) fail "${path}: inconsistent stage/outcome metadata" ;;
  esac
  test -n "${targets}" && test -n "${widths}" \
    || fail "${path}: target/width metadata is empty"
done < "${manifest}"

while IFS=$'\t' read -r path category target width stage outcome diagnostic; do
  test "${path}" != "path" || continue
  source="${project_root}/${path}"
  case "${category}" in
    frontend)
      "${rakec}" --target "${target}" --width "${width}" "${source}" > /dev/null
      ;;
    reject)
      output="${tmp}/$(basename "${path}").reject"
      if "${rakec}" --target "${target}" --width "${width}" "${source}" \
          > "${output}" 2>&1; then
        fail "${path}: expected frontend rejection"
      fi
      grep -Fq -- "${diagnostic}" "${output}" \
        || fail "${path}: missing diagnostic substring: ${diagnostic}"
      if grep -Eq 'Fatal error|Internal error|emission failed' "${output}"; then
        fail "${path}: failure escaped the parser/typechecker stage"
      fi
      ;;
    native)
      stem="$(basename "${path}" .rk)"
      native_ir="${tmp}/${stem}.native"
      object="${tmp}/${stem}.o"
      "${rakec}" --emit-native-ir --target "${target}" --width "${width}" \
        "${source}" > "${native_ir}"
      test -s "${native_ir}" || fail "${path}: native SSA emission was empty"
      "${rakec}" --verify-native --target "${target}" --width "${width}" \
        -o "${object}" "${source}"
      test -s "${object}" || fail "${path}: verified native object was empty"
      ;;
    future) ;;
    *) fail "${path}: unknown category ${category}" ;;
  esac
done < "${manifest}"

# Menhir must reject every deliberately malformed language construct. The
# optional differential suite additionally compares these results to the
# Tree-sitter grammar.
while IFS=$'\t' read -r path class construct; do
  test "${path}" != "path" || continue
  test "${class}" = malformed || fail "${path}: expected malformed parser class"
  output="${tmp}/$(basename "${path}").parser"
  if "${rakec}" --emit-ast "${project_root}/${path}" > "${output}" 2>&1; then
    fail "${path}: malformed ${construct} unexpectedly parsed"
  fi
  grep -Eq 'Lexical error|Syntax error' "${output}" \
    || fail "${path}: rejection was not a lexer/parser diagnostic"
done < "${parser_manifest}"

echo "frontend and verified-native conformance suite passed"
