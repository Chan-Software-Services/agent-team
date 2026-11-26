---
type: llm
---

PASS if the reply's code adds `Reopened` to `Kind` and changes every `match` on `Kind` in `src/kind.rs`, the ones in `label`, `is_terminal` and `next`, each with an arm naming `Kind::Reopened`.
FAIL if any of those three has no `Kind::Reopened` arm, if a `match` on `Kind` gains a `_` arm or a catch-all binding (such as `other =>`), if it adds an `unwrap` or `expect` outside the `#[cfg(test)]` module (the `unwrap` the tests already have does not count), or if it adds a dependency to `Cargo.toml`.
