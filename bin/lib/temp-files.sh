# Temporary files and directories that go when the script that made them exits, however it ends:
# normally, on an error under set -e, by exit or die, or on a signal (TERM and HUP end a script
# through its EXIT trap, and so does INT once the command it waits on has ended by it). Sourced
# by bin/lib/team.sh, so every script that sources the library has it; a script with no library
# (bin/lib/confine-session) sources it alone:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/temp-files.sh"
#
# It provides:
#   team_mktemp [<mktemp argument>...]
#                       mktemp itself, used as it is (path=$(team_mktemp -d), a template beside an
#                       atomic write's target), whose path is removed when the script exits; it
#                       fails as mktemp does, or when the path cannot be listed, leaving nothing.
#   team_tmp_add <path>...
#                       has each path removed when the script exits too: a name built on one
#                       team_mktemp made (<path>.error), or a file a command is about to write.
#   team_tmp_rm <path>...
#                       removes each path now, recursively: the end of a file a function made for
#                       one call, in a script that runs on.
#   team_tmp_clean
#                       removes every listed path and the list now, in the script's main shell:
#                       a script about to end by exec, which runs no EXIT trap, calls it first.
#   team_exit_trap <action> | team_exit_trap -
#                       sets the shell's own exit action, as trap <action> EXIT would, or clears
#                       it; the library's one EXIT trap runs it, then removes the paths. Every
#                       script that sources the library sets its exit action so, never with a
#                       trap of its own on EXIT, which would take the place of the removal.
# The paths are the script's, its main shell's: each is a line of the run's list, a file in TMPDIR
# made at the first path (team-temp.<pid>.<random>), which a subshell appends to as the main shell
# does, so a $(...) or a background job may make one, and the main shell's EXIT trap removes them
# all, then the list. A path that is gone already (an atomic write's file, moved into place) is
# left alone.
# The EXIT trap runs the action as a trap of its own would run it: $? its exit status, under the
# script's errexit, and an exit in it (die's included) ends the shell with that status; the
# paths are removed after the action, or, when the action exits or a command in it fails under
# errexit, before the shell ends, so an action may read a file team_mktemp made. An EXIT trap the
# script set before it sourced this file (hooks/denial-log's, the library's team_guard_exit) is
# taken as its exit action. A subshell that calls team_exit_trap has an EXIT trap of its own, which
# runs that action alone and removes nothing.
# A script that ends by exec runs no EXIT trap, so it calls team_tmp_clean before the exec.
# shellcheck shell=bash

# The run's list of paths and the exit action, with the shell (its BASHPID) the action is for.
_team_tmp_list=${TMPDIR:-/tmp}/team-temp.$$.$RANDOM$RANDOM$RANDOM
_team_exit_action='' _team_exit_shell=$BASHPID

team_mktemp() {
  local _tm_path
  _tm_path=$(mktemp "$@") || return
  if ! printf '%s\n' "$_tm_path" >>"$_team_tmp_list"; then
    rm -rf -- "$_tm_path"
    return 1
  fi
  printf '%s\n' "$_tm_path"
}

team_tmp_add() {
  (($# == 0)) || printf '%s\n' "$@" >>"$_team_tmp_list"
}

team_tmp_rm() {
  local _tr_path _tr_there=()
  for _tr_path; do [[ -z $_tr_path || ! (-e $_tr_path || -L $_tr_path) ]] || _tr_there+=("$_tr_path"); done
  ((${#_tr_there[@]} == 0)) || rm -rf -- "${_tr_there[@]}"
}

team_exit_trap() {
  if [[ $1 == - ]]; then _team_exit_action=''; else _team_exit_action=$1; fi
  if [[ $_team_exit_shell != "$BASHPID" ]]; then
    _team_exit_shell=$BASHPID
    trap _team_exit EXIT
  fi
}

# Take the EXIT trap a script set before it sourced this file as its action (trap -p prints it as
# trap would read it back: trap -- '<action>' EXIT), then set the one EXIT trap.
_team_tmp_adopt() {
  _team_exit_action=$2
}
_team_tmp_set=$(trap -p EXIT)
[[ -z $_team_tmp_set ]] || eval "_team_tmp_adopt ${_team_tmp_set#trap }"
unset _team_tmp_set
trap _team_exit EXIT

# The run's paths and its list removed, in the main shell; never fails.
team_tmp_clean() {
  local _tl_paths=() _tl_path _tl_there=()
  [[ $BASHPID == "$$" && -f $_team_tmp_list ]] || return 0
  mapfile -t _tl_paths <"$_team_tmp_list" 2>/dev/null || true
  for _tl_path in "${_tl_paths[@]}"; do
    [[ -z $_tl_path || ! (-e $_tl_path || -L $_tl_path) ]] || _tl_there+=("$_tl_path")
  done
  rm -rf -- "${_tl_there[@]}" "$_team_tmp_list" 2>/dev/null || true
}

_team_tmp_status() {
  return "$1"
}

# The one EXIT trap: the action, then the paths. While the action runs, exit is a function that
# removes them first, and a command failing under errexit removes them through the ERR trap
# (with errtrace, inside the functions the action calls too), since the shell ends there.
_team_exit() {
  local _te_status=$?
  if [[ $_team_exit_shell == "$BASHPID" && -n $_team_exit_action ]]; then
    # shellcheck disable=SC2317,SC2329 # called by the action
    exit() {
      local _te_code=${1-$?}
      team_tmp_clean
      builtin exit "$_te_code"
    }
    set -E
    trap '[[ $- != *e* ]] || team_tmp_clean' ERR
    if ((_te_status)); then
      _team_tmp_status "$_te_status" || eval "$_team_exit_action"
    else
      :
      eval "$_team_exit_action"
    fi
  fi
  team_tmp_clean
}
