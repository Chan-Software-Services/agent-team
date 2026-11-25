---
description: A builder asked to fix clippy's unwrap_used warning fires the skill, and returns a Result instead of silencing the lint.
tags: [rust]
model: claude-opus-5-5
max_turns: 15
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

`cargo clippy` on the Rust crate in this directory warns on the line `parse(field.trim()).unwrap()` of `kind_of` in `src/lib.rs`:

```text
warning: used `unwrap()` on a `Result` value
  --> src/lib.rs:10:5
   |
10 |     parse(field.trim()).unwrap()
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   |
   = note: if this value is an `Err`, it will panic
   = note: requested on the command line with `-W clippy::unwrap-used`
```

Fix it, and show the changed function and anything that must change with it in your reply; change no files.
