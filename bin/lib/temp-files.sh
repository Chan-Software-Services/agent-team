# Temporary files and directories that go when the shell that made them exits, however it ends:
# normally, on an error under set -e, by exit or die, or on a signal (TERM and HUP end a script
# through its EXIT trap, and so does INT once the command it waits on has ended by it). Sourced
# by bin/lib/team.sh, so every script that sources the library has it; a script with no library
# (bin/lib/confine-session) sources it alone:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/temp-files.sh"
#
# It provides:
#   team_mktemp <name> [<mktemp argument>...]
#                       runs mktemp with the arguments (-d for a directory, a template beside an
#                       atomic write's target), sets the variable <name> to its path, and has the
#                       path removed when this shell exits; fails as mktemp does, setting nothing.
#   team_tmp_add <path>...
#                       has each path removed when this shell exits too: a name built on one
#                       team_mktemp made (<path>.error).
#   team_tmp_rm <path>...
#                       removes each path now, recursively, and forgets it: the end of a file a
#                       function made for one call, in a script that runs on.
#   team_exit_trap <action> | team_exit_trap -
#                       sets this shell's own exit action, as trap <action> EXIT would, or clears
#                       it; the library's one EXIT trap runs it, then removes the paths. Every
#                       script that sources the library sets its exit action so, never with a
#                       trap of its own on EXIT, which would take the place of the removal.
# The EXIT trap runs the action as a trap of its own would run it: $? its exit status, under the
# script's errexit, and an exit in it (die's included) ends the shell with that status; the
# paths are removed after the action, or, when the action exits or a command in it fails under
# errexit, before the shell ends, so an action may read a file team_mktemp made. An EXIT trap a
# script set before its first team_mktemp or team_exit_trap (before sourcing the library, as
# hooks/denial-log does, or the library's team_guard_exit) is taken as its exit action.
# Each shell has its own paths and action: a subshell, a $(...) among them, that calls
# team_mktemp or team_exit_trap starts with none and gets its own EXIT trap, so its files go when
# it ends, and it never removes its parent's nor runs its parent's action.
# A script that ends by exec runs no EXIT trap, so it removes what it made before the exec.
# shellcheck shell=bash

# The shell (its BASHPID) the paths and the action below belong to, and they.
_team_tmp_shell='' _team_exit_action=''
_team_tmp_paths=()

team_mktemp() {
  local _tm_path
  _tm_path=$(mktemp "${@:2}") || return
  _team_tmp_claim
  _team_tmp_paths+=("$_tm_path")
  printf -v "$1" %s "$_tm_path"
}

team_tmp_add() {
  _team_tmp_claim
  _team_tmp_paths+=("$@")
}

team_tmp_rm() {
  local _tr_path _tr_keep=() _tr_gone
  (($#)) || return 0
  rm -rf -- "$@"
  [[ $_team_tmp_shell == "$BASHPID" ]] || return 0
  for _tr_path in "${_team_tmp_paths[@]}"; do
    for _tr_gone; do [[ $_tr_path != "$_tr_gone" ]] || continue 2; done
    _tr_keep+=("$_tr_path")
  done
  _team_tmp_paths=("${_tr_keep[@]}")
}

team_exit_trap() {
  _team_tmp_claim
  if [[ $1 == - ]]; then _team_exit_action=''; else _team_exit_action=$1; fi
}

# Make this shell the owner of the paths and the action, with the one EXIT trap: a subshell's
# first call starts with none of its parent's, and the script's own first call takes an EXIT
# trap already set as its action (trap -p, which in a subshell would name the parent's).
_team_tmp_claim() {
  local _tc_set
  [[ $_team_tmp_shell != "$BASHPID" ]] || return 0
  _team_tmp_paths=() _team_exit_action=''
  if [[ $BASHPID == "$$" ]]; then
    _tc_set=$(trap -p EXIT)
    # trap -p prints the command as trap would read it back: trap -- '<action>' EXIT.
    [[ -z $_tc_set ]] || eval "_team_tmp_adopt ${_tc_set#trap }"
  fi
  _team_tmp_shell=$BASHPID
  trap _team_exit EXIT
}

_team_tmp_adopt() {
  _team_exit_action=$2
}

# Remove this shell's paths, once; never fails.
_team_tmp_clean() {
  [[ $_team_tmp_shell == "$BASHPID" ]] || return 0
  ((${#_team_tmp_paths[@]})) || return 0
  local _tl_paths=("${_team_tmp_paths[@]}")
  _team_tmp_paths=()
  rm -rf -- "${_tl_paths[@]}" 2>/dev/null || true
}

_team_tmp_status() {
  return "$1"
}

# The one EXIT trap: the action, then the paths. While the action runs, exit is a function that
# removes them first, and a command failing under errexit removes them through the ERR trap
# (with errtrace, inside the functions the action calls too), since the shell ends there.
_team_exit() {
  local _te_status=$?
  if [[ $_team_tmp_shell == "$BASHPID" && -n $_team_exit_action ]]; then
    # shellcheck disable=SC2317,SC2329 # called by the action
    exit() {
      local _te_code=${1-$?}
      _team_tmp_clean
      builtin exit "$_te_code"
    }
    set -E
    trap '[[ $- != *e* ]] || _team_tmp_clean' ERR
    if ((_te_status)); then
      _team_tmp_status "$_te_status" || eval "$_team_exit_action"
    else
      :
      eval "$_team_exit_action"
    fi
  fi
  _team_tmp_clean
}
