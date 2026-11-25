---
name: walk
description: Walk Daniel through every item waiting on them, one at a time, routing each answer as they give it. Use when Daniel writes /walk, or asks in plain words to go through what waits on them, as "walk me through what's waiting".
---

# Walk

A walk takes Daniel through every item waiting on them, one message per item, and routes each answer as they give it; it is no manual QC walk of a task's UI (`team-ui --walk`).
Its rules are `roles/assistant.md`'s, which this skill restates none of: "Daniel's words" for what never relays and how a decision is handed on, "Hand-offs" for the `decision` kind and `COORDINATOR ANSWER H<n>`, "Your list" for the walk's items, and "Discord" for its thread and where to answer.

1. **Sync.** The ledger is the truth, and `waiting.md` lags it.
   Run `team-snapshot --json` and take its `pending_asks` ({task, id, text, ts}): the open tasks' asks that no later event settles, read from the ledger now.
   Run `team-current reconcile`, so that an item of your list whose condition holds is closed.
   Before each item of step 4, check it again: for a task's ask, `team-state T<n> --json`, the item standing while its `pending_asks` holds the ask's id; for a PR to merge, while its `pr.state` is `open` and `pr.merge_approved` is false; for an item of your list, `team-current list`.
   Drop an item that no longer stands, and say in the thread that it was answered meanwhile.
2. **Collect.** Every item waiting on Daniel, in three groups.
   The coordinator's: each of `pending_asks`, and each `pr` item of the team home's `waiting.json` (a PR ready to merge) that `team-state` still shows open; an ask and a `pr` item of the same PR are one item.
   Yours: each `ask` item of `team-current list` but a walk's own (step 6); your `owe`, `next` and `watch` items wait on you, not on Daniel, and stay out.
   The due manual steps: each open step (`- [ ]`) of the team home's `manual-steps.md` whose day has come (a date today or earlier, UTC) or whose trigger the records show has happened (a PR merged, a task's plan approved), and each with neither; one whose day or trigger is still ahead waits.
3. **Order.** The coordinator's items by the total of their `unblocks` in `waiting.json`, more first, ties oldest first, as `waiting.md` ranks them.
   An ask `waiting.json` does not hold yet (logged since it was last written) goes after those with the same total, by its `ts`.
   With no readable `waiting.json`, the coordinator's items go oldest first.
   Then your asks, then the due manual steps, each in the order their file lists them.
4. **Present.** Open the walk's thread in `#assistant` with `team-assistant thread "Walk: <n> items waiting on you" --from <Daniel's message id>`; when Daniel wrote in a thread of `#assistant`, walk in that thread and open none.
   Post a first message listing the items, one per line, each a bullet with its number in bold (`- **3** T586 q1: ...`), since Discord renumbers an ordered list.
   Then post one message per item, under 2000 characters: what it is; the facts read from the task's own records (`tasks/T<n>/scratch/questions-<round>.md`, `tasks/T<n>/scratch/report.md`, `tasks/T<n>/plan.md`, the ask's text), linking a file too long to quote; a recommendation, the records' own when they give one; and the exact reply form.
   Wait for Daniel's answer before the next item, unless they skip it ("skip", "later"), which moves it to the end once.
5. **Route.** Route each answer as it comes, before the next item.
   For a word "Daniel's words" keeps first-hand (the merge word, a plan approval, a script's yes, "hand off"), relay nothing: the item names the words, the ask's own (`T<n> yes` for a plan, `merge it` for a PR), and links the task's thread, `team-state`'s `thread`.
   When Daniel says such a word in the walk's thread anyway, point them again at the thread where it counts.
   Hand on any other decision at once: write a body naming each item the message answers (the task and the ask's id, as `T586 q1`) and the answer's place in it.
   Then run `team-assistant send decision --task T<n> --file <body> --daniel <their message id> --channel <the walk's thread id>`, and send `coordinator` the line `ASSISTANT H<n> decision`.
   Make one hand-off per message of Daniel's: a message answering items of two tasks is one hand-off, with `--task` of the first and the body naming both.
   When `team-assistant send` refuses, tell Daniel what it named and ask them to answer again, handing on no summary of your own.
   An answer to your own ask is acted on as that ask's work says, and its item done.
   A done manual step is removed from `manual-steps.md`.
6. **Track.** At the walk's start, run `team-current add ask - Daniel: walk of <n> waiting items (<their short names>) --where <the walk's thread id> --review`.
   For each hand-off, run `team-current add owe T<n> Tell Daniel what H<n> (<item>) became --where <the walk's thread id> --until handoff H<n> answered`.
   On `COORDINATOR ANSWER H<n>`, run `team-assistant show H<n>`, then tell Daniel in the walk's thread what it became; the owed item closes by its condition at the next `team-current reconcile`.
   When the last item is answered or skipped twice, post the summary (each item: decided and handed on as H<n>, said where it counts, skipped, or answered meanwhile), and run `team-current done <the walk's id>`.
   Once every owed report of the walk is told, close its topic with `team-assistant thread --close <thread id>`.

## Starting again

- A new `/walk` while one is open ends the old one first: `team-current done` its ask item, post a last message in its thread pointing at the new one, and start from step 1.
- A walk found open at a start (your digest shows its ask item): read its thread back with the Discord plugin's `fetch_messages`, sync (step 1), and go on from the first item Daniel has not answered.

## Remote Control and an empty walk

- A `/walk` over Remote Control gets the answer to say it in `#assistant`, since every answer a walk hands on needs a Discord message of Daniel's.
- With no item, reply where Daniel wrote that nothing waits on them, opening no thread and adding no item.
