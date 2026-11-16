# T9 spec: touches

Two phases, the first two tickets of each building at once.

Parallel: 2, 1

```text
Parallel: 9
```

## Failure modes and assumptions

- Two tickets that share a path building at once: `team-tickets --check` names the pair; tested in `tests/team-tickets.bats`.
- Assumption, not verified: no ticket touches a path outside `scope.txt`.
