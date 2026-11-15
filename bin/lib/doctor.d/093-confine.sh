# confine       Whether this machine's workers have the kernel layer under the text guard:
#               passes with the kernel's Landlock ABI (bin/lib/confine.py --abi) when it is 2 or
#               more and confine.py --session runs true in a worktree of the doctor's own, with
#               no task and no session named, so no session tmp is made; warns, with no fix, on
#               macOS or an ABI below 2, where the workers run on the text guard alone; fails
#               when the wrapper cannot run where Landlock is, with its last stderr line.
# reads state from: 010-os.sh
# shellcheck shell=bash
# shellcheck disable=SC2154 # os, scratch, err and TEAM_LIB, the doctor's

# macOS has no Landlock, and the os line's verdict stands for the kernel there, as confine.py reads
# it off Linux.
confine_abi=0 confine_rc=0
if [[ $os != macos ]]; then
  confine_abi=$(python3 -I "$TEAM_LIB/confine.py" --abi 2>"$err") || confine_rc=$?
fi
if ((confine_rc != 0)) || [[ ! $confine_abi =~ ^[0-9]+$ ]]; then
  confine_line=$(grep . "$err" | tail -n 1 || true)
  report confine FAIL "confine.py --abi exited $confine_rc${confine_line:+: $confine_line}" \
    "bin/lib/confine.py's own --help says what it needs"
elif ((confine_abi < 2)); then
  report confine WARN "this machine has no Landlock (ABI $confine_abi), so its workers run on the text guard alone (sops/platform-gotchas.md)"
else
  # A session's roots on a worktree of the doctor's own: with no task and no session id there is
  # no session tmp, so the run leaves nothing in /tmp.
  mkdir -p "$scratch/confine-worktree"
  env -u AGENT_TEAM_TASK -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR -u CLAUDE_JOB_DIR \
    AGENT_TEAM_WORKTREE="$scratch/confine-worktree" TEAM_HOME="$TEAM_HOME" \
    python3 -I "$TEAM_LIB/confine.py" --session -- true >/dev/null 2>"$err" || confine_rc=$?
  if ((confine_rc == 0)); then
    report confine PASS "Landlock ABI $confine_abi; a worker's shell commands run confined (confine.py --session ran in a sandbox worktree)"
  else
    confine_line=$(grep . "$err" | tail -n 1 || true)
    report confine FAIL "${confine_line:-confine.py --session -- true exited $confine_rc}" \
      "bin/lib/confine.py's own --help says what it needs"
  fi
fi
