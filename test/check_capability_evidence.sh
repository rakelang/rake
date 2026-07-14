#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="${project_root}/test/capability_evidence.tsv"
rakec="${RAKEC:-${project_root}/_build/default/src/bin/main.exe}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  echo "capability evidence: $*" >&2
  exit 1
}

test -x "${rakec}" || fail "compiler not found at ${rakec}; run dune build"
test -f "${evidence}" || fail "missing ${evidence}"

expected_header=$'feature\tcompiler_status\trelease_state\tfrontend_evidence\tsemantic_evidence\tnative_ir_evidence\ttarget_evidence\tallocation_evidence\tobject_evidence\truntime_evidence'
test "$(head -n 1 "${evidence}")" = "${expected_header}" \
  || fail "unexpected evidence-table header"

"${rakec}" --print-capabilities >"${tmp}/capabilities.tsv"
awk -F '\t' 'NR > 2 { print $3 "\t" $2 }' "${tmp}/capabilities.tsv" \
  | sort >"${tmp}/compiler"
awk -F '\t' 'NR > 1 { print $1 "\t" $2 }' "${evidence}" \
  | sort >"${tmp}/evidence"

test "$(wc -l <"${tmp}/compiler")" -eq \
  "$(cut -f1 "${tmp}/compiler" | sort -u | wc -l)" \
  || fail "compiler capability output contains duplicate feature IDs"
test "$(wc -l <"${tmp}/evidence")" -eq \
  "$(cut -f1 "${tmp}/evidence" | sort -u | wc -l)" \
  || fail "evidence table contains duplicate feature IDs"
diff -u "${tmp}/compiler" "${tmp}/evidence" \
  || fail "compiler capability catalog and evidence table differ"

valid_evidence_id() {
  local feature="$1"
  local evidence_id="$2"
  local value="${evidence_id#*:}"

  case "${evidence_id}" in
    "capability:${feature}") return 0 ;;
    fixture:*) test -f "${project_root}/${value}" ;;
    dune:*) grep -Fq "(name ${value})" "${project_root}/test/dune" ;;
    runtime:add|runtime:select|runtime:scalar-broadcast|runtime:predication|runtime:reductions|runtime:scans)
      test -f "${project_root}/test/native_backend_test.sh" ;;
    verify:add|verify:select|verify:scalar-broadcast|verify:predication|verify:reductions|verify:scans)
      test -f "${project_root}/test/native_backend_test.sh" ;;
    docs:*) test -f "${project_root}/${value}" ;;
    *) return 1 ;;
  esac
}

while IFS=$'\t' read -r feature compiler_status release_state frontend \
    semantics native_ir target allocation object runtime; do
  test "${feature}" != feature || continue

  valid_evidence_id "${feature}" "${frontend}" \
    || fail "${feature}: invalid frontend evidence ID '${frontend}'"

  case "${compiler_status}:${release_state}" in
    unavailable:unavailable|reserved:reserved|checked:frontend-only|checked:verified-slice|checked:verified) ;;
    *) fail "${feature}: inconsistent compiler/release states ${compiler_status}/${release_state}" ;;
  esac

  stages=("${semantics}" "${native_ir}" "${target}" "${allocation}" "${object}" "${runtime}")
  case "${release_state}" in
    unavailable|reserved|frontend-only)
      for stage in "${stages[@]}"; do
        test "${stage}" = - \
          || fail "${feature}: ${release_state} capability has downstream evidence '${stage}'"
      done
      ;;
    verified-slice|verified)
      for stage in "${stages[@]}"; do
        test "${stage}" != - \
          || fail "${feature}: ${release_state} capability is missing a required evidence stage"
        valid_evidence_id "${feature}" "${stage}" \
          || fail "${feature}: invalid evidence ID '${stage}'"
      done
      ;;
  esac
done <"${evidence}"

echo "capability evidence: compiler catalog bijection and release-state chain passed"
