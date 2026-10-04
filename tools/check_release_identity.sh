#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tree_sitter_root="${TREE_SITTER_RAKE_DIR:-${project_root}/../tree-sitter-rake}"
website_root="${RAKE_WEBSITE_DIR:-${project_root}/../rake-lang.org}"
version_file="${project_root}/src/lib/version.ml"

check_website=true
case "$#:$*" in
  0:) ;;
  1:--compiler-only) check_website=false ;;
  *) echo 'usage: tools/check_release_identity.sh [--compiler-only]' >&2; exit 2 ;;
esac

fail() {
  echo "release identity: $*" >&2
  exit 1
}

test -f "${version_file}" || fail "canonical source is missing: ${version_file}"
version="$(sed -n 's/^let value = "\([^"]*\)"$/\1/p' "${version_file}")"
test -n "${version}" || fail "could not read 'let value = \"...\"' from ${version_file}"

expect_literal() {
  local file="$1"
  local literal="$2"
  test -f "${file}" || fail "required maintained file is missing: ${file}"
  grep -Fq -- "${literal}" "${file}" \
    || fail "${file} drifted; expected literal: ${literal}"
}

expect_absent_maintained() {
  local repo="$1"
  local pattern="$2"
  local matches
  matches="$(
    find "${repo}" \
      \( -path '*/.git' -o -path '*/_build' -o -path '*/node_modules' -o -path '*/target' \
         -o -path "${tree_sitter_root}/tree-sitter-rake" \) -prune -o \
      -type f \
      \( -name '*.md' -o -name '*.ml' -o -name '*.mli' -o -name '*.mll' \
         -o -name '*.mly' -o -name '*.sh' -o -name '*.json' -o -name '*.html' \
         -o -name '*.opam' -o -name '*.js' -o -name '*.scm' -o -name 'dune' \
         -o -name 'dune-project' -o -name 'Makefile' \) \
      -exec grep -nHIE -- "${pattern}" {} + || true
  )"
  if test -n "${matches}"; then
    sed 's/^/  /' <<<"${matches}" >&2
    fail "${repo} contains a stale maintained reference matching: ${pattern}"
  fi
}

expect_literal "${project_root}/dune-project" "(version ${version})"
expect_literal "${project_root}/rake.opam" "version: \"${version}\""
expect_literal "${project_root}/README.md" "Release: ${version}"
expect_literal "${project_root}/CHANGELOG.md" "## ${version}"
expect_literal "${project_root}/src/bin/main.ml" "Rake.Version.display"

# Registry releases are immutable. A grammar-only repair may add a numbered
# suffix without changing the compiler release whose language it parses.
grammar_version="$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' "${tree_sitter_root}/package.json")"
if test "${grammar_version}" != "${version}"; then
  case "${grammar_version}" in
    "${version}".*)
      grammar_patch="${grammar_version#"${version}".}"
      case "${grammar_patch}" in
        ''|*[!0-9]*) fail "invalid grammar patch version: ${grammar_version}" ;;
      esac
      ;;
    *) fail "grammar ${grammar_version} does not match compiler ${version}" ;;
  esac
fi
expect_literal "${tree_sitter_root}/package-lock.json" "\"version\": \"${grammar_version}\""
expect_literal "${tree_sitter_root}/tree-sitter.json" "\"version\": \"${grammar_version}\""
expect_literal "${tree_sitter_root}/Cargo.toml" "version = \"${grammar_version}\""
expect_literal "${tree_sitter_root}/pyproject.toml" "version = \"${grammar_version}\""
expect_literal "${tree_sitter_root}/CMakeLists.txt" "set(RAKE_PACKAGE_VERSION \"${grammar_version}\")"
expect_literal "${tree_sitter_root}/Makefile" "VERSION := ${grammar_version}"
expect_literal "${tree_sitter_root}/package.json" \
  "https://github.com/rakelang/tree-sitter-rake.git"
expect_literal "${tree_sitter_root}/tree-sitter.json" \
  "https://github.com/rakelang/tree-sitter-rake"

repositories=("${project_root}" "${tree_sitter_root}")
if "$check_website"; then
  expect_literal "${website_root}/public/index.html" "Rake ${version}."
  expect_literal "${website_root}/public/index.html" "https://github.com/rakelang/rake"
  repositories+=("${website_root}")
fi

for repo in "${repositories[@]}"; do
  git -C "${repo}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "expected a Git working tree at ${repo}"
  expect_absent_maintained "${repo}" \
    'github\.com/(KaiStarkk|kaistarkk|overyonderstudios|over-yonder-tech)/(rake|tree-sitter-rake|rake-lang\.org)'
done

if test -x "${project_root}/_build/default/src/bin/main.exe"; then
  actual="$(${project_root}/_build/default/src/bin/main.exe --version)"
  test "${actual}" = "rake ${version}" \
    || fail "compiled rakec drifted; expected 'rake ${version}', got '${actual}' (run dune build)"
fi

echo "release identity compiler ${version}, grammar ${grammar_version}: consistent"
