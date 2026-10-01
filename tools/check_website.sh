#!/usr/bin/env bash
# The website in the sibling rake-lang.org checkout is built from this
# repository's documentation. Its own tool checks that the committed build is
# current and that every page passes the search and link rules, and the
# documentation checker compiles the Rake on its pages.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
website_root="${RAKE_WEBSITE_DIR:-${project_root}/../rake-lang.org}"

test -x "${website_root}/tools/build.sh" || {
  echo "website check: no site build at ${website_root}/tools/build.sh" >&2
  exit 1
}
RAKE_DIR="${project_root}" bash "${website_root}/tools/build.sh" check
bash "${project_root}/tools/check_documentation_examples.sh"
