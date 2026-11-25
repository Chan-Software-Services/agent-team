---
description: A builder asked to add a variant to the crate's own enum fires the skill, and handles it in every match with no catch-all.
tags: [rust]
model: claude-opus-5-5
max_turns: 15
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

Add a `Reopened` variant to the `Kind` enum of the Rust crate in this directory, and handle it everywhere the crate matches on `Kind`: a reopened task is not terminal, and its next state is `Opened`.
Show each file you would change, whole, in your reply; change no files.
