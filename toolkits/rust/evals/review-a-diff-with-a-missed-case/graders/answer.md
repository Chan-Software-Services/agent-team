---
type: llm
---

PASS if the review names the `_ => false` arm the diff adds to `is_terminal` as a finding: a wildcard that handles `Reopened` without naming it, so a variant added later compiles there unhandled, with the fix of an explicit `Kind::Reopened => false` arm.
Other findings do not change the verdict.
FAIL if the review approves the diff, misses that arm, or calls the wildcard acceptable.
