# SOP: fanning a read-only sweep out to forks

How a planner splits a large read-only sweep (research, an audit, a triage of many files or questions) across forks of its own session, and puts their answers back together without losing or doubling an item.
It is the team's map-reduce: the planner picks and shards the work, each fork maps its shard to fixed blocks, a script reduces them, and the planner checks what matters before the summary.
The paths below are in the task directory, `.scratch/task/`, whose `work/` the task's archive keeps (the planner brief says its bounds).

Use it when one session cannot read everything and still answer with paths and lines, as with 50 questions over 30,000 lines of code, or 173 queued files.
A sweep a single session can hold needs none of it.

## 1. Write the manifest first

Before any fork starts, write `work/manifest.tsv`: one line per input, its id, then a tab and what it is (a path, a question's title).
Its first lines are comments, each starting with `#`:

- `# Selector: <the command that produced the list>`, such as a `git ls-files` pattern, an `ls` of a directory or a `jq` over the ledger.
- `# Left out: <each kind of source the selector does not reach, and why it may stay out>`, or `# Left out: none`.

The selector makes coverage checkable: anyone can run it again and compare.
A fork reads only what its inputs and charge name, so what the selector leaves out is never read unless the planner adds it.
Example: T240's spec-review readers missed both questions a project's ADRs answer outright (ADRs 0015 and 0007), since no ticket named the ADRs and neither reader opened them; a `# Left out: docs/adr/` line would have put the gap in front of the planner before the run.

## 2. Shard the manifest

- Split by size, so the shards take about as long, as T304 split 173 queued files into six bins of about 52 KB each.
- Or split by shared code, so one fork reads a module once for every question it touches, as T244 grouped its 40 questions into twelve forks.
- Write each shard's input ids to `work/shard-<n>.txt`, and check that the shards together hold each manifest id exactly once.
- Give each shard a short, specific charge: what to answer for each input, how to choose each block's key (below), and what belongs to another shard.
  Vague charges are where duplicated work and gaps come from.
- Run at most as many forks at once as `~/agent-team/bin/team-capacity jobs` prints, the level's job count, and let only one fork run a stack (`team-stack up`) or a heavy run, named in its charge.
- Keep the highest-stakes group, such as the security questions, for the planner's own session.

## 3. A fixed block per item

Every fork answers in the same blocks, each headed `### <input id>` and holding these lines:

```markdown
### <input id>

- Key: <what the item is about, by the charge's rule: a code site as path:line, a record, a question's number>
- Answer: <the answer, a sentence or a short paragraph>
- Evidence: <each claim's paths and lines, each marked (run), (read) or (inferred)>
- Confidence: high | medium | low
```

The fork's reply ends with one line naming every input it was handed, whether it wrote a block for it or not:

```markdown
Accounted for: <input id>, <input id>, ...
```

An input with nothing to say still gets a block, its answer saying why.
The marks say how each claim was known: (run) for a command the fork ran, (read) for a line it read, (inferred) for anything else.
The key is what lets the reduce see two forks talking about the same thing, so the charge fixes how it is spelled, such as `bin/team-sweep:352` and never `team-sweep line 352`.
Notes that belong to no item go under a `## Notes` heading before the first block, which the reduce keeps instead of dropping.

## 4. Run the forks

- Launch the forks early, while the planner's context is still small: a fork inherits the session, so its prompt names only its shard file, its charge, the block format and the rules it keeps.
- Those rules: return the findings as text in its final message, write only its own probe scripts and their outputs under `work/`, send nothing to `coordinator`, read or print no secret, and run no heavy run its charge does not give it.
- A fork never writes its report: the harness refuses a subagent's Write of a findings file ("Subagents should return findings as text"), and asking for one wastes a call per fork.
- Save each fork's reply as it lands, from the output file the Agent call printed, never by reading that file, which is the fork's whole transcript:

  ```bash
  jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last' <output file> > .scratch/task/work/result-<n>.md
  ```

## 5. Reduce with a script

Write `work/reduce.py` (or any script under `work/`), run it, and build the report from what it prints.
It reads the manifest, every `work/result-<n>.md` and `work/overrides.tsv`, and:

- refuses, naming each, a manifest id that no `Accounted for:` line names, one that two name, and one accounted for with no block;
- refuses a block or an `Accounted for:` id that the manifest does not hold;
- groups the blocks by key, so two blocks about the same thing from different forks, a duplicate or a conflict, print side by side for the planner's call;
- applies `work/overrides.tsv`, one line per call of the planner's: the input id, the verdict, and a note saying why, tab-separated, and refuses a line whose id has no block.

The overrides file is where the planner's judgment lives, so the report can be rebuilt from the results at any time.
Example: T304's `overrides.tsv` holds 7 calls, among them three queued files marked duplicates of files in other bins, each citing the code line both name (`bin/team-sweep:352` for two of them, `bin/team-log:336` for the third), which no single fork could see.
Where two forks measured the same thing and differ, the report says so where they meet, rather than keeping one.

## 6. Check what matters yourself

Before a claim goes in the summary, the planner re-checks it itself when it is a headline, a security or a correctness claim: it runs the command or reads the cited line again, and marks the claim (run) or (read) as its own.
Every other claim keeps the fork's mark, and the report says it is the fork's.
A claim that does not hold up goes in `work/overrides.tsv` with what the check found, and the reduce runs again.
