---
type: llm
---

PASS if the fix removes the `unwrap()` from `kind_of` by having it return a `Result` whose error is an enum of the crate (such as `Result<Kind, ParseKindError>`), or by handling the parse's failure without panicking, with no `unwrap` or `expect` left in it.
FAIL if the fix adds `#[allow(...)]` or `#[expect(...)]` for the lint, uses `expect`, `panic!` or another panicking call instead, or moves the line into a test.
