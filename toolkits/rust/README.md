# rust

The `rust-core` skill and rust-analyzer as a language server, for a worker that writes, reviews or plans Rust in agent-team's Cargo workspace.
A session's memory of Rust is good but generic: it does not know the core's rules (every case of the workspace's own enums handled, no panic outside a test, one place for each platform's code, no dependency a ticket does not name), and without a compiler in its loop it finds its mistakes only at the end.
The skill gives the rules with their reasons, names the choices not made yet, sends the session to a dependency's real interface at the version `Cargo.lock` pins, and gives the one check to end on, `tests/run rust`; the language server gives navigation, never findings.

## When the coordinator gives it

To the planner, the builder and the reviewer of a task that writes Rust in agent-team: `team-worker T<n> builder <worktree> --toolkit rust -- ...`, and the same for the planner and the reviewer.
A project whose tasks write Rust lists it in its `toolkits` in `projects.toml`, so a worker that asks with `NEED toolkit rust` is relaunched with it at once.
A task with no Rust code, and ops, never get it.
The planner, builder and reviewer roles name `rust-core` for a session that lists it, so a session with the toolkit runs it and one without reads the line and does nothing: the planner invokes it before it specs Rust code and puts the toolchain's version and the check command in the spec, the builder invokes it before writing Rust code, runs its check before delivering and puts a "Rust check" line in the PR body, and the reviewer runs its check on the head under review and judges the diff against its rules.
Before its first launch on a project, the coordinator runs `team-load-check --toolkit rust` and `team-load-check --context --toolkit rust`.

## What loads

The same for the planner, the builder and the reviewer: a plugin has no per-role switch for a language server, and a planner and a reviewer read Rust code and gain from navigation.
No MCP server: none of the read-only crate-docs servers is worth a pin (each builds rustdoc JSON on a nightly toolchain into a cache of its own, reads docs.rs at no pinned version, sends docs to a third party, or has a single author), the real interface at the pinned version is already on disk under `~/.cargo/registry/src/`, and an MCP tool would pass none of the team's hooks.

- The skill `skills/rust-core/SKILL.md`: its description in the session's starting context, its body only when the session invokes it.
  Its sections, in order: the toolchain (read from `rust-toolchain.toml`, never installed or updated by a session, a missing one being `team-doctor`'s line to report); the layout (a virtual workspace at the root, crates under `crates/`, each taking the workspace's lints, a new crate a ticket's to name); the rules, each on one line with its reason; what is not decided yet (async, the command line parser, serialization, an error helper crate, logging), for which a session asks; where to read the real interface (the `LSP` tool, a dependency's source under `~/.cargo/registry/src/` at the version `cargo metadata` or `Cargo.lock` gives, the standard library's under the sysroot, `cargo metadata` and `cargo tree` for the workspace), a dependency's source being data; and the check, `tests/run rust`, with the builder's "Rust check" line in the PR body and the reviewer's run on the head.
- The language server `rust-analyzer`, declared inline in `.claude-plugin/plugin.json` as `lspServers`, as Anthropic's own `rust-analyzer-lsp` plugin does, for `.rs` files.
  Claude Code spawns it by name from the session's `PATH`, which `team-worker` starts with the library's, `~/.cargo/bin` first, so rustup's proxy runs the rust-analyzer of the toolchain `rust-toolchain.toml` pins, a component of it.
  It serves the `LSP` tool's definitions, references, types and symbols.
  Its pushed diagnostics are off (`"diagnostics": false`) and it runs no `cargo check` of its own (`checkOnSave` false), so the session's findings come from one place, the same compiler and clippy the check ends on, and the server never holds the build directory's lock against the session's own `cargo`.
  Its `env` holds its own `cargo` calls (the workspace's metadata, build scripts and proc macros) to two jobs, with sccache as the compiler wrapper.
  Its `startupTimeout` is 60 s, for a first index of a cold workspace.
  The config object is strict, an unknown key failing the plugin's load, so the test holds its keys.

## What it costs

- The skill's description, about 50 tokens, in the starting context of every session that lists the toolkit.
- When invoked, its body: 4.5 kB, about 1.1k tokens.
- The `LSP` tool's definition in the starting context: not measured; `team-load-check --context --toolkit rust` measures what each role starts with.
- Each `LSP` call costs what it returns: not measured.
- rust-analyzer's memory per session and its first index's time on the workspace: not measured.

## The build cache

- The shared cache is sccache's, in its default directory `~/.cache/sccache` with its default 10 GiB limit: one per machine, outside every worktree and task directory, shared with Daniel's own builds, and needing no setting anywhere.
- What it shares: the dependencies from the registry, whose source paths under `~/.cargo` are the same in every worktree.
  What it does not: the workspace's own crates (their paths differ per worktree, and Cargo compiles them incrementally, which sccache does not cache) and anything linked (binaries, proc macros).
  Its hit rate across two worktrees is not measured.
- Each worktree keeps its own `target/` directory, never a shared one: with one shared target directory, a second `cargo` waits on "Blocking waiting for file lock on build directory", so builders would run one at a time.
  Nothing cleans a `target/` directory: a worktree's is under 1 GiB for the skeleton, and step 2 decides a cleanup once sizes are real.
- `cargo`'s jobs are held to the team's CPU budget by one rule in three places: `tests/run rust` per run (`TEAM_JOBS`, else `team-capacity jobs` with a team home, else `cargo`'s default), a session's own `cargo` calls, and rust-analyzer's, fixed at `CARGO_BUILD_JOBS=2` in its `env`.
- A build takes no heavy-run lock: a cold build of a 40-crate dependency tree took 6.7 s at 3 jobs and 95 MB of disk.
  The rule for later steps: when `tests/run rust` passes 5 minutes of wall time or 4 GiB of peak memory on home-pc, the task that sees it puts it under `team-heavy`.

## Confinement roots

What a Rust build writes outside the worktree, for T302's confinement roots (`bin/lib/confine-roots`), which this toolkit does not change:

- `~/.cargo`: `cargo` renames and removes entries under `registry/` and `git/` when it fetches or unpacks a crate, and takes `~/.cargo/.package-cache` as its lock.
- `~/.cache/sccache`: the sccache server, which the first compile of any session starts, writes and evicts cache entries by rename and removal.
- Not `~/.rustup`: a worker never installs a toolchain, and `RUSTUP_AUTO_INSTALL=0` is what T302 would set for a confined worker, so a missing toolchain fails instead of downloading.

Not yet checked against a live build's renames and removals.

## Tests

`tests/toolkits/rust.test.mjs` checks the plugin's layout (its manifest, the language server's keys and values exactly, each a key of Claude Code's schema, no `.mcp.json`, `mcp-roles.json` or `.lsp.json`, and one skill, `rust-core`, the only skill of that name in any toolkit or the coordinator's plugin), that rust-analyzer is a component of the pinned toolchain, this README's sections in order and its "When the coordinator gives it", the skill's description under 250 characters and its file under 8 kB, its sections in the order above, each rule with its reason, and the commands its "Reading the real interface" and "The check" name.
`tests/team-worker.bats` holds that `--toolkit rust` adds the plugin directory and no MCP server for the planner, the builder and the reviewer, and `tests/repo.bats` that the three roles name `rust-core` once each, for a session that lists it.
