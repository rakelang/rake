#!/usr/bin/env bash

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

extract_source() {
  local id="$1"
  local source="$2"
  awk -v start="~~ docs:start ${id}" -v finish="~~ docs:end ${id}" '
    $0 == start { inside = 1; next }
    $0 == finish { inside = 0; found = 1; next }
    inside { print }
    END { if (!found) exit 1 }
  ' "${source}"
}

extract_markdown() {
  local id="$1"
  local document="$2"
  awk -v start="<!-- rake-example:${id}:start -->" \
      -v finish="<!-- rake-example:${id}:end -->" '
    $0 == start { inside = 1; next }
    $0 == finish { inside = 0; found = 1; next }
    inside && $0 !~ /^```rake$/ && $0 !~ /^```$/ { print }
    END { if (!found) exit 1 }
  ' "${document}"
}

extract_html() {
  local id="$1"
  local document="$2"
  awk -v start="<!-- rake-example:${id}:start -->" \
      -v finish="<!-- rake-example:${id}:end -->" '
    $0 == start { inside = 1; next }
    $0 == finish { inside = 0; found = 1; next }
    inside && $0 !~ /^<pre data-rake-example=/ && $0 !~ /^<\/pre>$/ { print }
    END { if (!found) exit 1 }
  ' "${document}"
}

escape_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

check_copy() {
  local id="$1"
  local source="$2"
  local format="$3"
  local document="$4"
  local expected="${tmp}/${id}.expected"
  local actual="${tmp}/${id}.$(basename "${document}").actual"

  extract_source "${id}" "${source}" > "${expected}" \
    || fail "missing source region '${id}' in ${source}"
  case "${format}" in
    markdown) extract_markdown "${id}" "${document}" > "${actual}" ;;
    html)
      extract_html "${id}" "${document}" > "${actual}"
      escape_html < "${expected}" > "${expected}.escaped"
      expected="${expected}.escaped"
      ;;
    *) fail "unknown copy format: ${format}" ;;
  esac
  diff -u "${expected}" "${actual}" \
    || fail "${document} drifted from checked region '${id}'"
}

check_copy_if_present() {
  local id="$1"
  local source="$2"
  local format="$3"
  local document="$4"

  if grep -Fqx -- "<!-- rake-example:${id}:start -->" "${document}"; then
    check_copy "${id}" "${source}" "${format}" "${document}"
  fi
}

manifest_fixture() {
  local id="$1"
  local manifest="${project_root}/test/manifest.tsv"
  local relative

  while IFS=$'\t' read -r path _; do
    test "${path}" = "path" && continue
    if test -f "${project_root}/${path}" \
      && grep -Fqx -- "~~ docs:start ${id}" "${project_root}/${path}"; then
      relative="${path}"
      break
    fi
  done < "${manifest}"
  test -n "${relative:-}" || fail "${manifest} does not list the '${id}' documentation fixture"
  test -f "${project_root}/${relative}" \
    || fail "manifest fixture does not exist: ${relative}"
  printf '%s\n' "${project_root}/${relative}"
}

assert_manifest_contract() {
  local source="$1"
  local expected_category="$2"
  local expected_stage="$3"
  local relative="${source#${project_root}/}"
  local actual

  actual="$(awk -F '\t' -v path="${relative}" '$1 == path { print $2 "\t" $5 }' \
    "${project_root}/test/manifest.tsv")"
  test "${actual}" = "${expected_category}"$'\t'"${expected_stage}" \
    || fail "${relative} must be classified ${expected_category}/${expected_stage}, found ${actual:-no manifest row}"
}

test -x "${rakec}" || fail "compiler not found at ${rakec}; run dune build"
test -f "${website_root}/index.html" || fail "website checkout not found at ${website_root}"

# A plain `rake` fence means executable current syntax. Every such fence must
# sit in a named checked region. Syntax fragments use `text`; design sketches
# use `rake,proposal`.
while IFS= read -r document; do
  rake_fences="$(grep -Ec '^```rake$' "${document}" || true)"
  named_regions="$(grep -Ec '^<!-- rake-example:[a-z-]+:start -->$' "${document}" || true)"
  test "${rake_fences}" -eq "${named_regions}" \
    || fail "${document} has an untracked current-language Rake block"
done < <(find "${project_root}" -path '*/_build' -prune -o \
  -path '*/docs/RECOMMENDED_WORK_PACKAGES.md' -prune -o \
  -type f -name '*.md' -print)

crunch="$(manifest_fixture crunch)"
safe_through="$(manifest_fixture safe-through)"
pack_over="$(manifest_fixture pack-over)"

check_copy crunch "${crunch}" markdown "${project_root}/README.md"
check_copy safe-through "${safe_through}" markdown "${project_root}/README.md"
check_copy pack-over "${pack_over}" markdown "${project_root}/README.md"
check_copy_if_present crunch "${crunch}" markdown "${project_root}/docs/spec/04_fused_bindings.md"
check_copy_if_present safe-through "${safe_through}" markdown "${project_root}/docs/spec/03_tines_and_through.md"
check_copy_if_present pack-over "${pack_over}" markdown "${project_root}/docs/spec/01_racks_targets_and_abi.md"
check_copy crunch "${crunch}" html "${website_root}/index.html"
check_copy safe-through "${safe_through}" html "${website_root}/index.html"
check_copy pack-over "${pack_over}" html "${website_root}/index.html"

assert_manifest_contract "${crunch}" native native-object
assert_manifest_contract "${safe_through}" frontend frontend
assert_manifest_contract "${pack_over}" frontend frontend

"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/docs-crunch.o" \
  "${crunch}"
"${rakec}" --verify-native --target x86-avx2 -o "${tmp}/docs-safe-through.o" \
  "${safe_through}"
"${rakec}" "${pack_over}" > /dev/null

echo "documentation examples: synchronized, frontend-checked, and native-verified where supported"
