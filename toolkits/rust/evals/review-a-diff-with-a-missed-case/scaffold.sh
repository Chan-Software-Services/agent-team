#!/usr/bin/env bash
# The review-a-diff-with-a-missed-case case's workspace: a copy of the rust toolkit's fixture crate,
# which the prompt's diff applies to as it is. It copies files only and runs no cargo, so the case
# needs no toolchain and no network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)
cp -R "$root/tests/toolkits/fixtures/rust-crate/." .
