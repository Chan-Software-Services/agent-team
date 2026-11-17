# The GitHub logins, the one place that knows where each lives, sourced by bin/lib/team.sh, so
# every script has it:
#
#   # shellcheck source=bin/lib/github-login.sh
#   source "$TEAM_LIB/github-login.sh"
#
# The worker login is the GitHub account the team's sessions run on, one that pushes branches and
# opens pull requests, named by this checkout's bin/lib/worker-login, a committed constant of
# exactly one login=<name> line, never a registry key, since the registry is a record. With no
# such file the worker login is off and every session runs on the machine's own GitHub login, as
# before. On a machine it is gh's own login file, hosts.yml, in a gh configuration directory of
# its own, ~/.config/agent-team/gh-worker (mode 700, the file mode 600), which team-secrets
# restores as the secret worker-github-login. The owner login is the machine's own gh login, which
# team-merge runs on. It provides:
#   worker_login           prints the constant's login, or nothing, succeeding, when there is no
#                          bin/lib/worker-login (off); fails, printing nothing and naming the file
#                          on stderr, when the file is anything but one login=<a GitHub login>
#                          line.
#   worker_login_dir       prints the worker login's gh configuration directory.
#   worker_login_problem   prints why the worker login is not usable on this machine (its
#                          directory or hosts.yml missing, hosts.yml not a file, empty or not mode
#                          600), with ~ for the home directory, reading no byte of the file;
#                          fails, printing nothing, when it is usable.
#   worker_login_env       prints the environment a session gets, one NAME=value per line:
#                          GH_CONFIG_DIR=<worker_login_dir>, GH_TOKEN= and GITHUB_TOKEN= (both
#                          empty, which gh reads as unset, so a token in the launching environment
#                          never wins over the directory); nothing when off; fails as
#                          worker_login does.
#   worker_login_settings_env <login>
#                          prints the env object of a session's settings for <login>,
#                          worker_login's output: {} when it is empty (off), else
#                          worker_login_env's variables; fails, printing nothing, with the
#                          launchers' one refusal on stderr, naming the reason and the fix, when
#                          the login is not usable on this machine.
#   with_worker_login <command>...
#                          runs <command> with worker_login_env's environment, in a subshell, so
#                          the caller's own is unchanged; <command> may be a function, as bounded
#                          is, which timeout alone could not run.
#   worker_gh <arg>...     runs gh with worker_login_env's environment.
#   owner_login_env        prints the names to unset for the owner login, one per line.
#   with_owner_login <command>...
#                          runs <command> with those names unset, in a subshell.
#   owner_gh <arg>...      runs gh with those names unset.
#   use_owner_login        unsets them in the calling shell, for a script that is the owner's
#                          throughout (team-merge).
#   owner_git_helpers <gh> prints the two values of credential.https://github.com.helper that
#                          put a checkout's git traffic to github.com on the owner login, one per
#                          line: an empty one, which drops every helper set before it, then gh
#                          <gh>'s git-credential with those names unset (the team home's, which
#                          team-bootstrap sets and the doctor's team home login line holds).
#   WORKER_TOKEN_SCOPES    an array of the scopes the worker login's token may hold.
#   WORKER_LOGIN_RESTORE   the doctor's worker login fix while the login's file is not usable
#                          here, by which team-bootstrap puts that line in Daniel's secrets step.
#   LOGIN_VARIABLES        an array of the names that choose a session's GitHub login, which
#                          command-guard's login rows list too.
# shellcheck shell=bash

# shellcheck disable=SC2034 # read by the scripts that source the library
WORKER_TOKEN_SCOPES=(repo workflow)
WORKER_LOGIN_RESTORE="Daniel's own terminal: team-secrets restore"
LOGIN_VARIABLES=(GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN)

# The worker login's account, from this checkout's bin/lib/worker-login: worker_login
worker_login() {
  local login_file=$TEAM_LIB/worker-login login_lines=()
  [[ -e $login_file ]] || return 0
  if [[ -f $login_file ]]; then mapfile -t login_lines <"$login_file"; fi
  # A GitHub login: letters, digits and single dashes, neither first nor last, at most 39.
  if ((${#login_lines[@]} != 1)) || [[ ! ${login_lines[0]} =~ ^login=[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]] ||
    ((${#login_lines[0]} > 6 + 39)); then
    echo "${0##*/}: $login_file is not one login=<a GitHub login> line" >&2
    return 1
  fi
  printf '%s\n' "${login_lines[0]#login=}"
}

# The worker login's gh configuration directory: worker_login_dir
worker_login_dir() {
  printf '%s\n' "$HOME/.config/agent-team/gh-worker"
}

# Why the worker login is not usable on this machine, from the file's type, size and mode alone:
# worker_login_problem
worker_login_problem() {
  local login_dir login_file login_shown login_mode
  login_dir=$(worker_login_dir)
  login_file=$login_dir/hosts.yml
  login_shown=$login_dir
  [[ $login_shown != "$HOME"/* ]] || login_shown=\~/${login_shown#"$HOME"/}
  if [[ ! -e $login_dir && ! -L $login_dir ]]; then
    echo "$login_shown is missing"
  elif [[ ! -d $login_dir ]]; then
    echo "$login_shown is not a directory"
  elif [[ ! -e $login_file && ! -L $login_file ]]; then
    echo "$login_shown/hosts.yml is missing"
  elif [[ ! -f $login_file ]]; then
    echo "$login_shown/hosts.yml is not a file"
  elif [[ ! -s $login_file ]]; then
    echo "$login_shown/hosts.yml is empty"
  elif ! login_mode=$(stat -L -c %a -- "$login_file" 2>/dev/null); then
    echo "$login_shown/hosts.yml has no mode stat can read"
  elif [[ $login_mode != 600 ]]; then
    echo "$login_shown/hosts.yml is mode $login_mode, not 600"
  else
    return 1
  fi
}

# The environment of a session on the worker login: worker_login_env
worker_login_env() {
  local login_name
  login_name=$(worker_login) || return 1
  [[ -n $login_name ]] || return 0
  printf '%s\n' "GH_CONFIG_DIR=$(worker_login_dir)" GH_TOKEN= GITHUB_TOKEN=
}

# The env object of a session's settings, or the launch's refusal: worker_login_settings_env <login>
worker_login_settings_env() {
  local login_problem
  if [[ -z $1 ]]; then
    echo '{}'
    return 0
  fi
  if login_problem=$(worker_login_problem); then
    echo "${0##*/}: the worker login $1 is not on this machine ($login_problem): Daniel's team-secrets restore brings it (the secret worker-github-login)" >&2
    return 1
  fi
  worker_login_env | jq -Rcn '[inputs | capture("^(?<key>[^=]+)=(?<value>.*)$")] | from_entries'
}

# <command> on the worker login, a function such as bounded too: with_worker_login <command>...
with_worker_login() {
  local login_pairs=() login_env
  login_env=$(worker_login_env) || return 1
  [[ -z $login_env ]] || mapfile -t login_pairs <<<"$login_env"
  (
    ((${#login_pairs[@]} == 0)) || export "${login_pairs[@]}"
    "$@"
  )
}

# gh on the worker login: worker_gh <arg>...
worker_gh() {
  with_worker_login gh "$@"
}

# The names that, unset, leave gh and git on the owner login, the machine's own: owner_login_env
owner_login_env() {
  printf '%s\n' "${LOGIN_VARIABLES[@]}"
}

# <command> on the owner login, a function such as bounded too: with_owner_login <command>...
with_owner_login() {
  (
    use_owner_login
    "$@"
  )
}

# gh on the owner login: owner_gh <arg>...
owner_gh() {
  with_owner_login gh "$@"
}

# The calling shell on the owner login from here on: use_owner_login
use_owner_login() {
  local login_names=()
  mapfile -t login_names < <(owner_login_env)
  unset "${login_names[@]}"
}

# The team home's credential helpers for github.com, on the owner login: owner_git_helpers <gh>
owner_git_helpers() {
  local login_names=() login_words=''
  mapfile -t login_names < <(owner_login_env)
  login_words=$(printf ' -u %s' "${login_names[@]}")
  printf '%s\n' '' "!env$login_words $(printf %q "$1") auth git-credential"
}
