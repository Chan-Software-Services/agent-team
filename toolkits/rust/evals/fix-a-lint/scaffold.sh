#!/usr/bin/env bash
# The fix-a-lint case's workspace: a copy of the rust toolkit's fixture crate, with one function
# added to src/lib.rs whose unwrap() is the line clippy's warning in the prompt quotes. The fixture
# itself stays clean under the workspace's lints, so the case adds the finding here. It writes files
# only and runs no cargo, so the case needs no toolchain and no network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)
cp -R "$root/tests/toolkits/fixtures/rust-crate/." .

cat >>src/lib.rs <<'EOF'

/// The state a ledger line's `kind` field names.
pub fn kind_of(field: &str) -> Kind {
    parse(field.trim()).unwrap()
}
EOF
