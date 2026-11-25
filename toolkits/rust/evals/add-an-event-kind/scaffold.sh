#!/usr/bin/env bash
# The add-an-event-kind case's workspace: a copy of the rust toolkit's fixture crate, whose Kind the
# prompt has the session add a variant to. It copies files only and runs no cargo, so the case
# needs no toolchain and no network.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)
cp -R "$root/tests/toolkits/fixtures/rust-crate/." .
