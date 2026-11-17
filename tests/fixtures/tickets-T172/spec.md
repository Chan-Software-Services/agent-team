# T172 spec: team-next's hand-offs and the strict ticket lines

The tickets beside this spec are T172's as planned; this spec is a stand-in that holds only the section `team-tickets --check` requires.

## Failure modes and assumptions

### Failure modes

- A ticket line written loosely (`Blocked by: None. Do it next`): `team-tickets --check` names its file and line; tested in `tests/team-tickets.bats`.

### Assumptions

none
