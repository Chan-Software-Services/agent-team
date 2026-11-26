# The one Bash reader of bin/lib/context-mark, the builders' context mark, for team-worker and
# team-next (team-tokens, in Python, reads it by the same rule).
# Sourced after team.sh: source "$TEAM_LIB/context-mark.sh"
#
# context_mark: prints the mark in tokens from this checkout's bin/lib/context-mark, whose lines
# but comments (#) and empty ones are one tokens=<n> line, <n> a whole number of tokens of six to
# nine digits, a multiple of 1000 (so at least 100000). Fails, printing nothing, on anything else,
# and on a file that is missing or cannot be read, with one line on stderr for all of them: that the
# file is malformed, and what it needs (the line leaves the nine-digit cap unsaid).

# shellcheck shell=bash
context_mark() {
  local file=$TEAM_LIB/context-mark line marks=()
  if [[ -f $file && -r $file ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -z $line || $line == '#'* ]] || marks+=("$line")
    done <"$file"
  fi
  # At most nine digits, so the arithmetic cannot overflow, and no leading zero, which it would
  # read as octal.
  if ((${#marks[@]} == 1)) && [[ ${marks[0]} =~ ^tokens=([1-9][0-9]{5,8})$ ]] && ((BASH_REMATCH[1] % 1000 == 0)); then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  echo "${0##*/}: $file is malformed: it needs one tokens=<n> line, a whole number of tokens that is a multiple of 1000 and at least 100000" >&2
  return 1
}
