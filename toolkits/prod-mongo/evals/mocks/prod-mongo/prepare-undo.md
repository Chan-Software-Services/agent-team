---
expect:
  backup: 2026-11-08T091233Z
  collection: markets
  id: 3f2c8d41-6b0e-4a7f-9c15-2d8e7b6a4f90
---

Undo of one document of markets from ~/conventioner-backups/2026-11-08T091233Z, prepared for you to run; nothing was written to production:
3f2c8d41-6b0e-4a7f-9c15-2d8e7b6a4f90: changed in production since the dump, in phase, status_note. The command puts the dump's version back in its place (mongoimport --mode upsert).
The file it imports: ~/conventioner-backups/2026-11-08T091233Z/undo/2026-11-09T101544Z/markets.json
Run it in a terminal of your own, pasting the connection string of a user that may write (the read user cannot) at the read -rs prompt; <(...) is a pipe, so the string is never in an argument list or a file:
```bash
read -rs PROD_URI
mongoimport --config=<(printf 'uri: %s\n' "$PROD_URI") --db conventioner --collection markets --mode upsert --file ~/conventioner-backups/2026-11-08T091233Z/undo/2026-11-09T101544Z/markets.json
unset PROD_URI
```
