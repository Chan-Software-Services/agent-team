---
error: true
expect:
  ref: 9e4b7c21d0a35f68e2b1c4d7a9f03e5b6c8d1a27
  backup: 2026-11-09T081502Z
---

Rehearsal of 9e4b7c21 on ~/conventioner-backups/2026-11-09T081502Z: stopped at 2 of 2 migrations, nothing left running (4 min 51 s)
1. migrate_market_days.py --dry-run: exit 0 in 4 s, wrote nothing
   migrate_market_days.py: exit 0 in 5 s
   - market_days: 36 -> 36, 3 changed (stage: 3): 0f6b2d9e-4c1a-4e83-a7d5-91b3c6e2f048, 5d8e3a17-b29c-4f60-8e4d-2a7f1c9b3e65, c47a19f2-6e3b-4d58-9a1c-e8b5d2f30c71
2. migrate_to_one_stage.py --dry-run: exit 0 in 3 s
   - markets: 12 -> 12, 2 changed (phase: 2): 3f2c8d41-6b0e-4a7f-9c15-2d8e7b6a4f90, 8a91e5c3-27d4-4f1b-b6a0-5c3e9d2f7b18
Stopped: the dry run of migrate_to_one_stage.py wrote: markets: 12 -> 12, 2 changed (phase: 2).
Not run: migrate_to_one_stage.py.
Logs, for Daniel to read in a terminal (never quoted here): ~/conventioner-backups/2026-11-09T081502Z/rehearsals/2026-11-09T082944Z/ (1-migrate_market_days.py.dry-run.log, 2 lines; 1-migrate_market_days.py.run.log, 2 lines; 2-migrate_to_one_stage.py.dry-run.log, 3 lines)
