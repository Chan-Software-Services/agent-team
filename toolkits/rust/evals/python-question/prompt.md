---
description: A Python list comprehension question, with no Rust in sight, leaves the skill alone.
tags: [rust]
model: claude-opus-5-5
max_turns: 15
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

In Python 3.13, what does the list comprehension `[x * x for row in grid for x in row if x % 2]` give for `grid = [[1, 2], [3, 4]]`, and in which order do its two `for` clauses run? Answer in a few lines, no code changes.
