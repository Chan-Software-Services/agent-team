# confine       Whether this machine's workers can have the kernel layer under the text guard:
#               passes with the kernel's Landlock ABI (bin/lib/confine.py --abi) when it is 2 or
#               more and the real pair runs: bin/lib/confine-session write makes a session
#               directory under the doctor's own scratch (its --home there too, so nothing is
#               made under ~/.config or /tmp), and that directory's program bash runs true in
#               both forms, as a session's prefix (bash true) and as its shell (bash -c true),
#               after which the directory is removed; the line names the projects
#               whose registry entry says confine = "on", whose workers alone run confined, or
#               that none does; warns, with no fix, on
#               macOS or an ABI below 2, where the workers run on the text guard alone; fails
#               when confine-session or the program cannot run where Landlock is (no bash or
#               python3 where they look, a domain that cannot be entered), with the last
#               stderr line.
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
    "bin/lib/confine-session's, bin/lib/confine-shell's and bin/lib/confine.py's own --help say what each needs"
elif ((confine_abi < 2)); then
  report confine WARN "this machine has no Landlock (ABI $confine_abi), so its workers run on the text guard alone (sops/platform-gotchas.md)"
else
  # The real pair on a session directory of the doctor's own: confine-session writes it under the
  # scratch, with a home there too, so the run makes nothing under ~/.config or /tmp, and its
  # program runs true as a session's prefix and as its shell, the two forms a session's commands
  # reach it by, with the interpreter and the shell they get.
  confine_home=$scratch/confine-home
  mkdir -p "$confine_home/worktree" "$confine_home/git"
  confine_program=$("$TEAM_LIB/confine-session" write --dir "$confine_home/.config/agent-team/confine/doctor/doctor" \
    --task doctor --worktree "$confine_home/worktree" --git-dir "$confine_home/git" --team-home "$TEAM_HOME" \
    --home "$confine_home" --session-tmp "$confine_home/tmp" 2>"$err") || confine_rc=$?
  if ((confine_rc == 0)); then
    "$confine_program" true >/dev/null 2>"$err" || confine_rc=$?
  fi
  if ((confine_rc == 0)); then
    "$confine_program" -c true >/dev/null 2>"$err" || confine_rc=$?
  fi
  rm -rf -- "${confine_home:?}"
  if ((confine_rc == 0)); then
    # What ran proves the layer works here, never that a worker has it: only the projects whose
    # registry entry says confine = "on" do, so the line names them.
    if confine_on=$(team_project --find confine on 2>/dev/null </dev/null); then
      confine_on=${confine_on//$'\n'/, }
      confine_on=${confine_on:+confine is on for $confine_on}
      confine_on=${confine_on:-no project has confine on, so every worker runs on the text guard alone}
    else
      confine_on="the registry does not say which projects have confine on"
    fi
    report confine PASS "Landlock ABI $confine_abi; a worker's shell commands can run confined (a session's shell and prefix ran true in a sandbox worktree); $confine_on"
  else
    confine_line=$(grep . "$err" | tail -n 1 || true)
    [[ -n $confine_line ]] || confine_line="a session's shell and prefix could not run true (exit $confine_rc)"
    report confine FAIL "$confine_line" \
      "bin/lib/confine-session's, bin/lib/confine-shell's and bin/lib/confine.py's own --help say what each needs"
  fi
fi
