#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${test_dir}/../tools/check_release_identity.sh"
bash "${test_dir}/conformance_test.sh"
bash "${test_dir}/../tools/check_documentation_examples.sh"
