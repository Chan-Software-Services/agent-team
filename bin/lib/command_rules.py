#!/usr/bin/env python3
"""command-guard's rule table: whether a worker's Bash call runs a guarded thing.

Usage: python3 -I command_rules.py   (the hook's input JSON on stdin)

bin/hooks/command-guard runs this file once per Bash call it does not pass at once, and refuses
the call when it prints a line. It reads tool_input.command from the hook's input, takes its code
text in parts as command_text.code_parts gives them (the command with each heredoc's body left
out unless a shell may read it, then each string a shell, eval, env -S and find -exec run, and
what is piped into a shell, a part of its own, so a quote one leaves open hides no other, then the
parts of each script the command writes to a file and runs, by a heredoc, a here-string, echo or
printf, as its header says), each heredoc a part still opens blanked (blank_heredocs) so that
every line of it is code, and walks each simple
command each part runs, then each one the command's own text runs (its heredocs'
bodies left out as Bash reads them, so a substitution a body leaves open in the code text hides
no line after it), as command_text.commands yields them: past the wrappers env, nohup, command,
builtin, exec, time, nice, ionice, stdbuf, timeout, setsid, sudo, doas, xargs, parallel, watch
and flock with its file, their options and env's assignments, into the substitutions in
arithmetic, and into the strings a shell's -c, eval, trap's action, su's and script's -c, env -S,
flock -c, watch and parallel, and find -exec run, a shell's script file and what source or .
reads among them, by its name.
For each row of the table in order, and each command in the walk's order, the first command a
row refuses ends the walk: it prints one JSON line, {"rule": <id>, "reason": <text>, "allowed":
<text or null>, "where": <text or null>}, the reason being the text command-guard puts after
"Blocked by command-guard: ",
and the allowed way the row's, or one a delete row's refusal names of its own (a relative path
read from a cd's directory), null for every row but force-push and the kill and delete rows; where, for a call of
more than one line, "It stands on line <n> of the call: <the line>", the first line whose own walk
runs the refused command, else the first holding each of its words (one outside a heredoc's body
first), and, after a heredoc's closing line, "; the heredoc opened on line <n> (<its operator and
marker>) ended at line <n>, so Bash runs the lines after it as commands", with ", and line <n> is
<marker> again: that heredoc may have ended earlier than you meant" when a later line is its
closing line again, ending in a full stop; null for a call of one line, or when no line of it
holds the refused command. It prints nothing when no row refuses, and exits 0
either way. Any error of its own exits 1 with one line on stderr, "command_rules.py: <ErrorType>:
<message>", or "<row id>: <ErrorType>: <message>" when a row raised, so the hook refuses: a guard
that cannot decide refuses.

A command's name is its first word's basename, its quotes removed, so a path or a quoted name is
the name; and as a reading of where a command starts took it, a word past a wrapper's options
(and flock's file) that the walk took as an option's value may be the name too, the words after
it its arguments; a word holding a blank never is.
The rows, in order:
  ops-launch: team-worker or team-load-check with ops among its words before team-worker's --, or
    a word ending in =ops (--role=ops). Reason: an ops session is the coordinator's to launch, on
    Daniel's request.
  capture-script: the frontend toolkit's capture script, a command named ui-capture, or run by
    node, deno (run), bun (run), npx, source or . past their options. Reason: it is Daniel's own
    sessions'.
  role-assigned: an assignment of AGENT_TEAM_ROLE or AGENT_TEAM_TASK (+= too), or of an element
    of either (AGENT_TEAM_ROLE[0]=x), alone, before a command or through env; either, or an
    element, named by export, declare, typeset, local, readonly, let, read, mapfile or readarray;
    or by printf -v. Reason: a worker's role and task are its settings' (bin/lib/team.sh's
    worker_refusal reads them).
  role-unset: either, or an element of either, named by unset, or either by env's -u (alone or
    ending a short cluster, its value joined or next) or --unset. The same reason.
  login-assigned: an assignment of GH_CONFIG_DIR, GH_TOKEN or GITHUB_TOKEN (LOGIN_VARIABLES,
    bin/lib/github-login.sh's), in every form role-assigned reads, by the same reader. Reason: a
    session's GitHub login is its settings' (bin/lib/github-login.sh's worker_login_env), whether
    or not bin/lib/worker-login names one.
  login-unset: any of them, or an element, in every form role-unset reads, by the same reader.
    The same reason.
  environment-emptied: a command named team-<anything>, claude-coordinator or claude-assistant
    behind env -i (alone or among env's short options), env --ignore-environment (or a prefix GNU
    takes), env - or exec -c, past any wrappers between or in a string a shell runs there: it
    would run with no AGENT_TEAM_ROLE, so its own worker_refusal would not see the worker.
  lease-steal: team-lease or team-resume with --steal among its words before its --. Reason: a
    lease steal is Daniel's word, through the coordinator.
  coordinator-commands: team-ask, team-answer, team-inbox or team-run-approved with any words or
    none, or team-thread with a task id (T and digits) as its first word (team-thread wait T<n>
    passes, which each role's settings allow or deny).
  upload: a curl or wget sending a file or body to a literal host outside the team's own,
    directly or through a proxy, as bin/lib/outbound.py decides each command (its header says
    which flags and hosts); a host held in a variable is not seen.
  force-push, for a session with a role (a worker or the assistant; a gate agent has none, and
    never had the deny rules this row took over): git, past its own options, running push with a
    long option that names --force, --force-with-lease or --force-if-includes by a prefix of three
    letters or more, f among a short cluster's flags before -o's value (-f, -uf), or a refspec
    starting with + (after a -- too). Reason: it rewrites what others pushed. Its allowed way:
    push without forcing, or start a fresh local branch from the moved remote one.
  cd-secrets, for a session with a role: cd or pushd whose first operand, as written, holds
    .config/agent-team, or for a worker .claude/channels, or for the assistant whose last
    component is discord or discord-assistant. Reason: they hold the team's keys and the Discord
    bot's files. Each read command by command, never across a call's other commands, as the deny
    rules they replace in settings/worker.json and assistant.settings.json did (the coordinator,
    which runs no command-guard, keeps its own).
  The kill rows, bin/lib/kill_rules.py's (its header holds their wording): a kill by name or
    pattern, tmux's kill-*, a kill of PIDs read from input, of a PID the guard cannot read before
    it runs, of a process group, every process or PID 0 or 1, and of a literal PID not proven the
    session's to stop (gone, or the user's, not the session's own and working inside a root, as
    the process table says at the time of the call), each naming its allowed way.
  The delete rows, bin/lib/delete_rules.py's (its header holds their wording and how a path is
    resolved): a recursive delete (rm -r, find -delete or find -exec rm) of a path outside the
    worktree and the job tmp, of either of them, the worktree's .scratch/task or a directory
    holding one, of a repository's .git, of a variable the command leaves empty, by a find with no
    start path, and of a path the guard cannot read before it runs, each naming its allowed way.
  login-emptied, last so each row above speaks first: any other command behind an emptied
    environment, as environment-emptied reads one: it would run with no GH_CONFIG_DIR, so gh and
    git in it, directly or through any program or script, answer as the machine's own login.
    Reason: a session's GitHub login is its settings', as for the login rows.
Each row is given the call's context (Context): the command's text, the hook input's cwd, the
worktree, the job tmp, the roots, the kept paths and the role, each read on a row's first use of
it; only the kill and delete rows use it, so a call with neither reads no process or file for it.
A row reads every command the walk yields, a shell's script file and a sourced one among them (a
file named team-worker that bash runs is team-worker), but for the upload and delete rows, which
read no file's name as curl or rm.
Contract: the kill and delete rows refuse the forms an agent writes when it means no harm, each
form tests/command-guard-kill.bats and tests/command-guard-delete.bats hold, plainly spelled, run
directly or through the walk's wrappers and strings (bash -c, eval, a heredoc or here-string a
shell reads, a pipe into a shell, xargs, sudo, env, nohup, a path to the program, a quoted name,
a script written and run in the same command). Each refusal names what it refused and the
allowed way. An ordinary command, one an agent writes for its work, is never refused for a
guarded name it only mentions; but a delete of a variable, a relative path or a glob may be
unread in a call that names a variable or shell option that changes what the path means, even in
prose (delete_rules.py's header lists them). When the guard cannot decide (its reader fails, or a
process or path it needs cannot be read), it refuses. They do not promise to see a spelling
chosen to hide a name or a path from the reader, nor what Not seen lists below: those are for a
kernel layer to hold where a machine has one, which this guard is not.
Not seen: a name built by a substitution or held in a variable; a function of one's own, a
script of one's own written by an earlier call or the Write tool (one this call writes and runs is
read), or a copy or link of a guarded one; a string another interpreter runs (python3 -c, node -e,
perl -e, a require of the capture script); a file a shell reads on stdin (cat x | bash); what
command_text.commands does not walk (its header lists it: ssh's remote command, nsenter, chroot,
unshare, systemd-run, tmux send-keys, git rebase's --exec); each under an emptied environment
too, so a team script one of those runs there goes unseen. Of a kill or a delete, not seen: one in
a script file written by an earlier call or the Write tool, a package script (npm run, make),
systemctl, launchctl, docker kill or docker rm, ssh's remote command, a single file's rm, git
clean (which the worker settings deny); of a delete, a link or a move the same command makes
before it (ln -s /tmp l && rm -rf l/x). Nor, of a kill or a delete, the four families of
spellings chosen to hide one: a name or option built at run time; a shell option or variable
that changes what a path means; a program's own decoding of what it runs; and an interpreter's
own delete or kill (python3 -c "os.kill(...)", perl -e 'unlink ...'). Some of those the rows
read still, but none is promised.
It is a speed bump, as a deny rule is, which the role's rule against reaching a refused thing
another way holds.
"""

import functools
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Callable

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_text import (  # noqa: E402
    ASSIGNMENT, call_commands, command_name, commands, from_wrappers, has_blank, heads, leads, read_command,
    short_cluster,
)
import delete_rules  # noqa: E402
import kill_rules  # noqa: E402
import outbound  # noqa: E402

ROLE_VARIABLES = ("AGENT_TEAM_ROLE", "AGENT_TEAM_TASK")
# The names that choose a session's GitHub login, bin/lib/github-login.sh's LOGIN_VARIABLES.
LOGIN_VARIABLES = ("GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN")
DECLARERS = frozenset("export declare typeset local readonly let read mapfile readarray".split())
# What runs a script by its path, with its options before it.
INTERPRETERS = frozenset(("node", "deno", "bun", "npx", "source", "."))
COORDINATOR = frozenset(("team-ask", "team-answer", "team-inbox", "team-run-approved"))
# The launchers, the team scripts whose names do not begin team-.
LAUNCHERS = frozenset(("claude-coordinator", "claude-assistant"))
TASK_ID = re.compile(r"T[0-9]+")
# env's -u, alone or ending a short cluster, with its value joined (-uAGENT_TEAM_ROLE) or next.
ENV_UNSET = re.compile(r"-[A-Za-z0-9]*u")
# The options that empty the environment of what a command runs, each with the form of it whose
# value is the next word: env's -i among its short options (one after it that takes a value
# with it), its --ignore-environment by a prefix, or a lone -; exec's -c among its short options.
EMPTIES = {
    "env": (
        re.compile(r"-[A-Za-z0-9]*i(?:[A-Za-z0-9]*[CuS].*|[A-Za-z0-9]*)|--ignore-e[a-z-]*|-"),
        re.compile(r"-[A-Za-z0-9]*i[A-Za-z0-9]*[CuS]"),
    ),
    "exec": (
        re.compile(r"-[A-Za-z0-9]*c(?:[A-Za-z0-9]*a.*|[A-Za-z0-9]*)"),
        re.compile(r"-[A-Za-z0-9]*c[A-Za-z0-9]*a"),
    ),
}


@dataclass(frozen=True)
class Row:
    """A rule: its id, its test over one Command and the call's context, which refuses by
    returning True (the row's reason), a reason of its own, or a reason and an allowed way of its
    own as a tuple, its reason and its allowed way (None: the refusal names none)."""

    id: str
    test: Callable
    reason: str | None
    allowed: str | None = None


# A session id's first 8 characters, which name a background session's job directory.
JOB_ID = re.compile(r"[A-Za-z0-9-]{8}")


class Context:
    """The call's context, each part read on a row's first use of it, so only a call with a kill
    or a recursive delete in it reads the process table or the file system: the command's text;
    cwd, the hook input's, resolved; the worktree, CLAUDE_PROJECT_DIR when it is a directory, else
    the git top level of cwd; the job tmp, $CLAUDE_JOB_DIR/tmp when it is a directory, else
    ~/.claude/jobs/<the session id's first 8 characters>/tmp when that is one; the roots, those of
    the two that exist, resolved; the kept paths, each root and the worktree's .scratch/task; and
    the role, AGENT_TEAM_ROLE, empty in a gate agent. The assistant's session is read the same
    way, so its worktree is its directory, the team home."""

    def __init__(self, call, environ=None):
        self.call = call
        self.environ = os.environ if environ is None else environ
        self.text = call["tool_input"]["command"]

    @functools.cached_property
    def cwd(self):
        cwd = self.call.get("cwd")
        return os.path.realpath(cwd) if isinstance(cwd, str) and cwd else None

    @functools.cached_property
    def worktree(self):
        project = self.environ.get("CLAUDE_PROJECT_DIR")
        if project and os.path.isdir(project):
            return os.path.realpath(project)
        if self.cwd is None:
            return None
        try:
            found = subprocess.run(
                ["git", "-C", self.cwd, "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, timeout=5, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        top = found.stdout.strip()
        return os.path.realpath(top) if found.returncode == 0 and top and os.path.isdir(top) else None

    @functools.cached_property
    def job_tmp(self):
        job = self.environ.get("CLAUDE_JOB_DIR")
        if job and os.path.isdir(os.path.join(job, "tmp")):
            return os.path.realpath(os.path.join(job, "tmp"))
        session = self.call.get("session_id")
        home = self.environ.get("HOME")
        if isinstance(session, str) and JOB_ID.match(session) and home:
            tmp = os.path.join(home, ".claude", "jobs", session[:8], "tmp")
            if os.path.isdir(tmp):
                return os.path.realpath(tmp)
        return None

    @functools.cached_property
    def roots(self):
        return tuple(root for root in (self.worktree, self.job_tmp) if root)

    @functools.cached_property
    def kept(self):
        task = (os.path.realpath(os.path.join(self.worktree, ".scratch", "task")),) if self.worktree else ()
        return self.roots + task

    @functools.cached_property
    def role(self):
        return self.environ.get("AGENT_TEAM_ROLE", "")


def _before_end(args):
    """A command's words up to its first --."""
    return args[: args.index("--")] if "--" in args else args


def _named(names, test=None):
    """A test refusing a command named one of names, whose words after the name pass test."""

    def named(command, context):
        for words in heads(command):
            if words and command_name(words[0]) in names and (test is None or test(list(words[1:]))):
                return True
        return False

    return named


def _ops(args):
    return any(word == "ops" or word.endswith("=ops") for word in _before_end(args))


def _capture(command, context):
    for words in heads(command):
        if not words:
            continue
        name = command_name(words[0])
        if name == "ui-capture":
            return True
        if name in INTERPRETERS:
            args = list(words[1:])
            if name in ("deno", "bun") and args[:1] == ["run"]:
                args = args[1:]
            reached = leads(args, wrappers=False)
            if any(command_name(args[k]) == "ui-capture" and not has_blank(args[k]) for k in reached):
                return True
    return False


def _names_word(variables, word, ends):
    """Whether word names one of variables, followed by nothing or by one of ends."""
    for variable in variables:
        if word.startswith(variable):
            rest = word[len(variable) :]
            if not rest or rest[0] in ends:
                return True
    return False


def _assigned(variables):
    """A test refusing an assignment of one of variables, or of an element of one, alone, before
    a command or through env, or one named by a declarer or printf -v."""

    def assigned(command, context):
        if any(_names_word(variables, word, "=+[") and ASSIGNMENT.match(word) for word in command.assignments):
            return True
        for words in heads(command):
            if not words:
                continue
            name, args = command_name(words[0]), list(words[1:])
            if name in DECLARERS and any(_names_word(variables, word, "=+[<) \t\n'\";&|") for word in args):
                return True
            if name == "printf":
                for k, word in enumerate(args):
                    if word == "-v" and k + 1 < len(args) and args[k + 1].startswith(variables):
                        return True
                    if word.startswith(tuple("-v" + variable for variable in variables)):
                        return True
        return False

    return assigned


def _env_unsets(variables, words):
    """Whether env's words unset one of variables: -u or --unset with it, joined or next."""
    for k, word in enumerate(words):
        following = words[k + 1] if k + 1 < len(words) else ""
        unset = ENV_UNSET.fullmatch(word) or word == "--unset"
        if unset and following.startswith(variables):
            return True
        joined = ENV_UNSET.match(word)
        if joined and word[joined.end() :].startswith(variables):
            return True
        if word.startswith("--unset=") and word[len("--unset=") :].startswith(variables):
            return True
    return False


def _unset(variables):
    """A test refusing one of variables, or an element of one, named by unset, or one by env's -u
    or --unset."""

    def unset(command, context):
        for words in heads(command):
            if not words:
                continue
            name, args = command_name(words[0]), list(words[1:])
            if name == "unset" and any(_names_word(variables, word, "[") for word in args):
                return True
            if name == "env" and _env_unsets(variables, args):
                return True
        return any(
            command_name(words[0]) == "env" and _env_unsets(variables, list(words[1:]))
            for words in from_wrappers(command)
        )

    return unset


def _team_script(word):
    """Whether a word names a team script: team-<anything> or a launcher, by any path."""
    name = command_name(word)
    if has_blank(word) or word.startswith("-"):
        return False
    return name in LAUNCHERS or (name.startswith("team-") and len(name) > len("team-"))


def _empties(wrapper):
    """Whether a wrapper's words empty the environment of what it runs: env -i, env
    --ignore-environment, env - or exec -c."""
    pattern = EMPTIES.get(command_name(wrapper[0])) if wrapper else None
    return pattern is not None and any(pattern[0].fullmatch(word) for word in wrapper[1:])


def _command_word(word):
    """Whether a word may name a command: any but an option."""
    return bool(word) and not word.startswith("-")


def _behind_emptied(runs):
    """A test refusing a command whose name runs(word) accepts behind an emptied environment."""

    def emptied(command, context):
        # What runs behind an emptied environment, a string a shell runs there among it.
        if command.words and runs(command.words[0]) and any(_empties(w) for w in command.wrappers):
            return True
        # One past env's or exec's options where the walk took it as an option's value.
        return _past_emptying_options(command, runs)

    return emptied


def _past_emptying_options(command, runs):
    for words in from_wrappers(command):
        for k in leads(words):
            pattern = EMPTIES.get(command_name(words[k]))
            if pattern is None:
                continue
            empties, valued = pattern
            rest = words[k + 1 :]
            for e in leads(rest, wrappers=False):
                if not empties.fullmatch(rest[e]):
                    continue
                after = rest[e + 1 :]
                starts = (0, 1) if valued.fullmatch(rest[e]) else (0,)
                if any(runs(after[j]) for j in leads(after, starts)):
                    return True
    return False


def _steal(args):
    return "--steal" in _before_end(args)


def _thread(args):
    return bool(args) and TASK_ID.fullmatch(args[0]) is not None


def _coordinator(command, context):
    return _named(COORDINATOR)(command, context) or _named({"team-thread"}, _thread)(command, context)


def _upload(command, context):
    return outbound.uploads_outside(command)


# git's options before its subcommand that take the next word as their value.
GIT_VALUED = frozenset(("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path"))
# git push's long options that force, any of which a prefix of three letters or more names.
FORCES = ("force", "force-with-lease", "force-if-includes")


def _git_push(words):
    """git push's words after push, when words run git push past git's own options, else None."""
    words = list(words)
    if not words or command_name(words[0]) != "git":
        return None
    k = 1
    while k < len(words) and words[k].startswith("-"):
        k += 2 if words[k] in GIT_VALUED else 1
    return list(words[k + 1 :]) if words[k : k + 1] == ["push"] else None


def _forces(args):
    """Whether git push's words force: a long option naming one of FORCES by a prefix, f among a
    short cluster's flags before -o's value, or a refspec starting with +."""
    ended = False
    for word in args:
        if ended or not word.startswith("-"):
            if word.startswith("+"):
                return True
        elif word == "--":
            ended = True
        elif word.startswith("--"):
            name = word[2:].partition("=")[0]
            if len(name) >= 3 and any(force.startswith(name) for force in FORCES):
                return True
        elif "f" in short_cluster(word, "o")[0]:
            return True
    return False


def _force_push(command, context):
    """A worker's or the assistant's force push; a gate agent, which has no role, never had the
    deny rules this row took over."""
    if not context.role:
        return False
    return any((args := _git_push(words)) is not None and _forces(args) for words in heads(command))


# The directories a cd may not enter, by role: a worker's and the assistant's.
WORKER_KEPT_OUT = (".config/agent-team", ".claude/channels")
ASSISTANT_KEPT_OUT = (".config/agent-team",)
# The Discord bot's directories the assistant keeps out of, by their last component.
DISCORD = ("discord", "discord-assistant")


def _cd_into(command, context):
    """A worker's or the assistant's cd or pushd whose target, as written, names one of the
    directories its role keeps out of."""
    if not context.role:
        return None
    assistant = context.role == "assistant"
    for words in heads(command):
        if not words or command_name(words[0]) not in ("cd", "pushd"):
            continue
        targets = [word for word in words[1:] if not word.startswith("-")]
        target = targets[0] if targets else ""
        kept = ASSISTANT_KEPT_OUT if assistant else WORKER_KEPT_OUT
        if any(name in target for name in kept) or (
            assistant and target.rstrip("/").rpartition("/")[2] in DISCORD
        ):
            return CD_ASSISTANT if assistant else CD_SECRETS
    return None


FORCE_REASON = (
    "a force push (git push with --force, --force-with-lease, --force-if-includes, -f or a +refspec),"
    " which rewrites what others pushed"
)
FORCE_WAY = (
    "push without forcing; when the remote branch moved under you, start a fresh local branch from it under a new"
    " name and carry your commits over"
)
CD_SECRETS = "a cd into ~/.config/agent-team or ~/.claude/channels, which hold the team's keys and the Discord bot's files"
CD_ASSISTANT = "a cd into ~/.config/agent-team or the Discord bot's directories, which hold the team's keys and the bot's files"
ROLE_REASON = "a worker's role and task are its settings' ({})"
LOGIN_REASON = "a session's GitHub login is its settings' ({})"

ROWS = (
    Row(
        "ops-launch",
        _named({"team-worker", "team-load-check"}, _ops),
        "an ops session is the coordinator's to launch, on Daniel's request (team-worker or team-load-check with ops)",
    ),
    Row(
        "capture-script",
        _capture,
        "the frontend toolkit's capture script is Daniel's own sessions' (run by its path or by an interpreter)",
    ),
    Row(
        "role-assigned",
        _assigned(ROLE_VARIABLES),
        ROLE_REASON.format("an assignment of AGENT_TEAM_ROLE or AGENT_TEAM_TASK"),
    ),
    Row("role-unset", _unset(ROLE_VARIABLES), ROLE_REASON.format("an unset of AGENT_TEAM_ROLE or AGENT_TEAM_TASK")),
    Row(
        "login-assigned",
        _assigned(LOGIN_VARIABLES),
        LOGIN_REASON.format("an assignment of GH_CONFIG_DIR, GH_TOKEN or GITHUB_TOKEN"),
    ),
    Row(
        "login-unset",
        _unset(LOGIN_VARIABLES),
        LOGIN_REASON.format("an unset of GH_CONFIG_DIR, GH_TOKEN or GITHUB_TOKEN"),
    ),
    Row(
        "environment-emptied",
        _behind_emptied(_team_script),
        ROLE_REASON.format(
            "a team script run with its environment emptied, by env -i, env --ignore-environment, env - or exec -c"
        ),
    ),
    Row(
        "lease-steal",
        _named({"team-lease", "team-resume"}, _steal),
        "a lease steal is Daniel's word, through the coordinator (team-lease or team-resume with --steal)",
    ),
    Row(
        "coordinator-commands",
        _coordinator,
        "the coordinator's commands (team-ask, team-answer, team-inbox, team-thread T<n> and team-run-approved)",
    ),
    Row("upload", _upload, outbound.REASON),
    Row("force-push", _force_push, FORCE_REASON, FORCE_WAY),
    Row("cd-secrets", _cd_into, None),
) + tuple(Row(id, test, None, allowed) for id, test, allowed in kill_rules.ROWS + delete_rules.ROWS) + (
    # Last, so a more particular row behind an emptied environment (a team script, an upload, a
    # kill or a delete) speaks first.
    Row(
        "login-emptied",
        _behind_emptied(_command_word),
        LOGIN_REASON.format(
            "a command run with its environment emptied, by env -i, env --ignore-environment, env - or exec -c"
        ),
    ),
)


# The most characters of a line a refusal quotes.
LINE_CHARACTERS = 160


def _line_number(text, offset):
    return text.count("\n", 0, offset) + 1


def _line_of(found, text):
    """The line number of the call's text the refused command stands on: the first line whose own
    walk runs it, else the first that holds each of its words; lines outside a heredoc's body
    first, then those in one (a body a shell reads); None when none does."""
    lines = text.split("\n")
    bodies = set()
    for heredoc in read_command(text).heredocs:
        bodies.update(range(_line_number(text, heredoc.body[0]), _line_number(text, heredoc.end - 1)))
    order = [n for n in range(1, len(lines) + 1) if n not in bodies] + sorted(bodies)

    def runs(line):
        try:
            return found in list(commands(line))
        except Exception:  # noqa: BLE001 - a line that does not read alone holds no command of its own
            return False

    for matches in (runs, lambda line: bool(found.words) and all(word in line for word in found.words)):
        for n in order:
            if n <= len(lines) and matches(lines[n - 1]):
                return n
    return None


def where(found, text):
    """The second line of a refusal of a call of more than one line: the line its command stands
    on, and the heredoc that ended last before it, with a later line that is its closing line
    again; None for a call of one line, or when no line holds the command."""
    if "\n" not in text.rstrip("\n"):
        return None
    n = _line_of(found, text)
    if n is None:
        return None
    lines = text.split("\n")
    line = lines[n - 1].strip()
    if len(line) > LINE_CHARACTERS:
        line = line[: LINE_CHARACTERS - 3] + "..."
    out = f"It stands on line {n} of the call: {line}"
    ended = [h for h in read_command(text).heredocs if _line_number(text, h.end - 1) < n]
    if ended:
        heredoc = max(ended, key=lambda h: h.end)
        opened, closed = _line_number(text, heredoc.marker[0]), _line_number(text, heredoc.end - 1)
        marker = lines[closed - 1].strip()
        out += (
            f"; the heredoc opened on line {opened} ({text[heredoc.marker[0] : heredoc.marker[1]]}) ended at line"
            f" {closed}, so Bash runs the lines after it as commands"
        )
        again = next((k for k in range(closed + 1, len(lines) + 1) if lines[k - 1].strip() == marker), None)
        if again is not None:
            out += f", and line {again} is {marker} again: that heredoc may have ended earlier than you meant"
    return out + "."


class RowError(Exception):
    """A row that raised, named."""


def refusal(command, context=None):
    """The first row, in table order, that refuses any command the text runs, with its reason and
    allowed way, or None; each row is given the call's context."""
    walked = call_commands(command)
    for row in ROWS:
        for found in walked:
            try:
                refused = row.test(found, context)
            except Exception as error:  # noqa: BLE001 - named, then refused by the caller
                raise RowError(f"{row.id}: {type(error).__name__}: {error}") from error
            if refused:
                reason, allowed = refused if isinstance(refused, tuple) else (refused, row.allowed)
                reason = reason if isinstance(reason, str) else row.reason
                return {"rule": row.id, "reason": reason, "allowed": allowed, "where": where(found, command)}
    return None


def main():
    if sys.argv[1:]:
        sys.stderr.write("usage: python3 -I command_rules.py   (the hook's input JSON on stdin)\n")
        return 2
    try:
        call = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        command = call["tool_input"]["command"]
        if not isinstance(command, str):
            raise TypeError("tool_input.command is not a string")
        found = refusal(command, Context(call))
    except RowError as error:
        sys.stderr.write(f"{error}\n")
        return 1
    except Exception as error:  # noqa: BLE001 - a guard that cannot decide refuses
        sys.stderr.write(f"command_rules.py: {type(error).__name__}: {error}\n")
        return 1
    if found:
        sys.stdout.write(json.dumps(found, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
