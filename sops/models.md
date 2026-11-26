# SOP: how a session's model and effort are chosen

Every session the team launches takes its model and its effort from one file, the team home's `models.toml`.
This SOP says what the file holds, how a launch reads it, what each launch logs, what is left out of it, how a line is changed, and how the Rust core keeps the same config.
`bin/team-models` is the file's one reader, and its `--help` is the exact reference for the line form, the categories and the precedence.

## The file

- `models.toml` sits at the team home's root, beside `projects.toml`, and is a records path (`bin/lib/records`), so it never reaches the code repository.
- It is TOML with top-level keys only: each key a quoted string naming a line, each value an inline table, one line per choice.
  ```toml
  # The model and effort of every session category: sops/models.md.
  "default" = { model = "opus", effort = "high" }
  "reviewer.rereview" = { model = "sonnet" }
  "builder path=small" = { model = "sonnet", effort = "high" }
  "planner" = { subagent_model = "haiku" }
  ```
  The last three lines are examples; the file ships as `tests/fixtures/models.toml`, its header comment and the one `default` line, Opus at `high`, today's choice for every session.
- A key is a category, then optionally ` project=<registry name>` and then ` path=<path>`, in that order, with single spaces between.
  A path is `team-open`'s: `feature`, `bug`, `small`, `research` or `retro`.
  A project is a name `team-project --list` gives.
- The key must be quoted: a bare dotted key (`reviewer.rereview = ...`) is TOML's nested table, which `team-models --check` refuses as "quote the key".
- A value's fields are each optional, and a line names at least one:
  - `model` and `subagent_model`: an alias `opus`, `sonnet`, `haiku` or `fable`, or a name `claude-` followed by lowercase letters, digits, dots and dashes, either optionally ending in `[1m]`; or `default`.
  - `effort` and `subagent_effort`: `low`, `medium`, `high`, `xhigh` or `max`, or `default`.
  - `default` means pass nothing, so the settings' word stands, as if no line named that field.
- `team-models --check` refuses a typo such as `sonet`, an unknown category, qualifier, field, project or path, a qualifier out of order, a value not of its form, a line naming no field, and a `project=` or `path=` on a category whose launches have neither, since it would never match.

## The categories

Each category falls back through its parent, the part before its last dot, to `default`.

| Category | Its launches |
| - | - |
| `coordinator` | `claude-coordinator` |
| `coordinator.compaction-drill` | `tests/compaction-drill`'s session |
| `assistant` | `claude-assistant` |
| `assistant.load-check` | `claude-assistant --load-check` |
| `planner` | a planner whose brief has no template |
| `planner.feature`, `planner.research`, `planner.interview`, `planner.walk` | the templates `planner-feature`, `planner-research`, `planner-interview`, `planner-walk` |
| `planner.retro` | the template `retro` |
| `planner.load-check` | a planner of T0, the load check |
| `builder` | a builder whose brief has no template |
| `builder.ticket`, `builder.deliver`, `builder.fix`, `builder.round`, `builder.merge-base` | the templates `builder-ticket`, `builder-deliver`, `builder-fix`, `builder-round`, `builder-merge-base` |
| `builder.load-check` | a builder of T0 |
| `reviewer` | a reviewer whose brief has no template |
| `reviewer.review` | the template `reviewer` |
| `reviewer.rereview` | the template `rereview` |
| `reviewer.verify` | the template `verify`, a notes-only round's re-review |
| `reviewer.load-check` | a reviewer of T0 |
| `ops` | the template `ops`, and an ops brief of no template |
| `ops.load-check` | ops of T0 |

- The table lives in `bin/team-models` alone, as data, and `team-models templates` prints its template map; `tests/team-models.bats` fails naming any template in `templates/briefs/` the table does not map, so a new template is not launched without a category.
- A brief's template is the one its record beside it names (`brief-<name>.json`, which `team-brief` writes); a hand-written brief has no record, so its launch takes its role's category.
- A `resume` or a `resume-crash` brief takes the category of the brief it resumes: `team-worker` reads the resume record's `values.brief`, that brief's own record and its template.
  A resumed brief with no record naming a template takes the role's category, with a warning on stderr, and so does a template of another role.
- A T0 launch takes `<role>.load-check` whatever template of its role its brief has, so the load check runs on its role's line unless a line of its own says otherwise.

## Precedence

- Each axis, the model, the effort, the subagent model and the subagent effort, is resolved on its own: the most specific matching line that names that axis wins it.
  So `"reviewer.rereview" = { model = "sonnet" }` gives a re-review Sonnet at the effort of `"default"`.
- A line matches a launch when its category is the launch's or an ancestor of it, `default` included, and each qualifier it has equals the launch's project or task path.
  A worker of a real task is resolved with its worktree's project and its task's path (the `opened` event's); the coordinator, the assistant and T0 have neither, and match only lines with no qualifier.
- Specificity is compared in order: the category's depth (`default` is 0), then having `project=`, then having `path=`.
  So `"reviewer.rereview"` beats `"reviewer project=conventioner"`, which beats `"reviewer"`, which beats `"default"`, and no two lines tie.
- `team-models resolve --role <r> [--template <t>] [--load-check] [--project <p>] [--path <p>]` (or `--category <c>`) prints the choice for one launch, each axis with the key of the line that chose it; `team-models list` prints every category's, for a project and path when given.

## The overrides

- A worker's model, first that applies:
  1. `team-worker --model <m>` names that launch's model (`model_from` `launch`); `--model default` means the config's word for this launch.
  2. A task's builder launches on its task's builder model (`task`): the `builder_model` `team-open --builder-model` put on its `opened` event, or the model of a later builder launch on `--model` or on the task's model (or of one from before 2026-11-17 that logged a model); any other builder launch, one on the config included, and `--model default` leave the task none from then on.
     An `opened` `builder_model` of `default`, which a task opened from 2026-11-17 to 2026-11-24 with neither a builder model named nor a registry builder line carries, is no task model.
  3. Its category's line in the config (`config`).
  4. The settings' word, passing no `--model` (`settings`, or `default` with none).
- A planner's or reviewer's `--model` is that launch's alone, as a paired review's is (`sops/model-trials.md`); a builder's becomes its task's builder model.
- Ops takes the `ops` line, and `team-worker` still refuses `--model` for ops, so only a change of that line, on Daniel's word, moves it.
- No option names an effort: the config is the one place an effort is chosen, and a trial changes a line.
- The settings' word is read as written, each key in the session's generated settings and then in the user settings (`${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`) before the next key: the model from `env.ANTHROPIC_MODEL`, then `model`; the effort from `env.CLAUDE_CODE_EFFORT_LEVEL`, then `modelSettings[<the model>].effortLevel`, then `effortLevel`.
  An `ANTHROPIC_MODEL` in the launching process's environment or in managed settings is not read.
- A missing `models.toml` names no axis, so a launch nothing else names a model or effort for runs on the settings' word, as before the config (logged `settings`, or `default` with none), and the doctor's `models` line WARNs.
- A `models.toml` that does not read refuses a worker launch, exit 1, before the lease or anything is started or logged: "models.toml does not read: <its first problem>; fix it, then team-models --check".
  The coordinator and the assistant launch anyway, warning "models.toml does not read: ...; launching on the settings' model", since the coordinator is the session that fixes the file; `team-open` opens the task with a warning and prints `default` as its builder model.

## What a launch passes and logs

- The chosen model goes to `claude` as `--model <m>` and the chosen effort as `--effort <e>`, each only when a line names it and not `default`.
- A line's `subagent_model` and `subagent_effort` go into the session's generated settings' `env` as `CLAUDE_CODE_SUBAGENT_MODEL` and `CLAUDE_CODE_SUBAGENT_EFFORT`, only when a line names them; never `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`, so an Agent call's own `model` or an agent definition's model still wins over them.
- A worker's launch logs, on its ledger `launch` event, `category`, `model`, `model_from` (`launch`, `task`, `config`, `settings` or `default`), `effort`, `effort_from` (`config`, `settings` or `default`), and `subagent_model` and `subagent_effort` when a line sets them; `bin/lib/ledger-contract.json` holds the fields, and keeps `registry` in `model_from` for the launches made on the registry's retired `models` table before 2026-11-24.
  T0 logs nothing, as before.
- The coordinator's and the assistant's launches each append one line to the team home's `sessions.jsonl` once `claude --bg` succeeds, `{ts, machine, name, category, model, model_from, effort, effort_from}`, with the session's `id` when the launch printed one and the subagent fields when set (`launch_log` in `bin/lib/launch.sh`); `team-checkpoint` commits it with the ledger.
  A failed write is a warning, and the session runs on; `claude-assistant --load-check` writes no line.
- `tests/compaction-drill` records what its session ran on in its `drills.jsonl` detail, `model=<m> effort=<e>`.
- A logged model or effort that came from no line is the settings' word as read, an alias such as `opus` as much as a model id, so the record says what the session was asked to run on; the models its replies ran on are `team-tokens`' `reply_models`.

## What is left out, and where those models are set

- The gate's agent: Daniel's `~/.no-mistakes/config.yaml` sets it, every step on `claude-haiku-5-5` (`agent_config.claude.model`) and its reviewer and fixer on `claude-opus-5-5` (`review_agents`).
  Its Claude starts with `--setting-sources project,local --strict-mcp-config --settings bin/lib/gate-claude-settings.json` (the doctor's `gate-agent` line checks those flags), so it reads neither the user settings nor `models.toml`; a change of it is a change of that file, never a line here.
- The toolkits' evals: each case's `model`, in its `prompt.md` frontmatter, or in its `case.yaml` for a `spec-review` case, under `toolkits/<name>/evals/`.
- The `spec-review` toolkit's three reader agents: each is pinned to `model: opus` in its frontmatter under `toolkits/spec-review/agents/`, since each one's reading is a judgment.
  That field wins over a line's `subagent_model`, as above, while an Agent call's own `model`, such as the one the `spec-review` skill's `--model` passes, wins over it; a change of the pin is a change of those files, never a line here.
- Auto mode's classifier, which Claude Code chooses itself.
- The doctor's and `team-quota`'s probes, which make no model request.
- Daniel's own sessions, which run on the user settings, the team home's `machine/claude/settings.json` that `team-config apply` puts on each machine; that file is also the settings' word a launch falls back to.

## Changing a line

1. Daniel says which category, project or path takes which model or effort; ops's line, like every other, changes only on their word.
2. The coordinator edits `models.toml` in the team home and runs `~/agent-team/bin/team-models --check`, which must exit 0.
3. `team-models resolve` or `team-models list` shows which line now decides each category it meant to change.
4. The coordinator commits it as a records commit; the records `pre-commit` hook runs `team-models --check` on the staged file and refuses a broken one, and no PR is needed.
5. The next launch of that category takes the line, an open task's included, and its `launch` event or `sessions.jsonl` line shows it; a running session keeps what it launched on.

Two live checks prove what no worker can, since no worker starts a real session:

- That `--effort` outranks the settings' `effortLevel` and `modelSettings` effort: run one `team-load-check` with a temporary `"reviewer.load-check" = { effort = "medium" }` line, read the effort the reviewer's transcript's assistant messages ran at, one count per value, `jq -r 'select(.type == "assistant") | .effort' <transcript> | sort | uniq -c`, which must say `medium`, then remove the line.
- That a settings file's `env` reaches Claude Code's reading of `CLAUDE_CODE_SUBAGENT_MODEL` and `CLAUDE_CODE_SUBAGENT_EFFORT`: the first subagent line written is checked the same way, in a subagent transcript of a session launched on it, before any trial counts on it.

## In the Rust core

The Rust port is not in this repository yet; this is the design it keeps for the model choice.

- The core keeps `models.toml` as it is: its format is the contract, as `ledger-contract.json` is for the ledger's events, so the same file reads the same before and after the port.
- `team-model` holds the categories as a closed enum, each brief template mapped to its category by an exhaustive match, so a new template does not compile without a category, and the precedence as a pure function over the parsed lines.
- `team-core` resolves a launch's choice and logs it on the launch event with the same fields: `category`, `model`, `model_from`, `effort`, `effort_from`, `subagent_model` and `subagent_effort`.
- The `Platform` trait's session spawn takes the resolved model, effort and subagent fields and turns them into Claude Code's flags and environment, so no platform crate decides a model.
- `bin/team-models` stays the reader until the port replaces it, and its bats tests are ported with it.
