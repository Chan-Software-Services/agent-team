# Rules for every agent this machine's gate runs

This machine runs many other agents' tests beside yours, so its CPUs, its processes and the names on them are shared.

- Add at most 4 busy CPU cores of load of your own beyond the project's own test command, which runs as it is configured (a load generator such as `stress-ng --cpu 4`, busy loops, a parallel run you start yourself), never one per core or `nproc`, and give it a timeout no longer than the run it loads.
  The machine's own load is already heavy, so a test that needs more load than that to show its point is left to CI, and your report says so.
- Note the pid of each process you start (`$!`) and stop it by that pid alone once its run ends, never by `pkill`, `killall` or a kill of a `pgrep` or `ps` search, which reaches other runs' processes.
- Name each stack, container, network, volume and scratch path you make after this gate run, or leave Compose's default name for this worktree, never after the branch, a task or ticket id (such as `TEAM_TASK`'s value): the pull request's wording may have to leave those out.
