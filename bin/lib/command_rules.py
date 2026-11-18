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
    none, or team-thread with a task id (T and digits) or archive as its first word (team-thread
    wait T<n> passes, which each role's settings allow or deny); for the assistant alone
    (AGENT_TEAM_ROLE assistant), the coordinator's read forms pass: any of the four with a first
    word --help or -h, which the library answers before the script does anything, and team-inbox
    --item <n> with no other word, which reads waiting.json alone.
  assistant-acts, for the assistant alone (AGENT_TEAM_ROLE assistant): the coordinator's acts,
    which its deny rules held by any call naming the script until this row: team-checkpoint,
    team-handoff, team-load-check, team-ops-end, team-records-rewrite, team-resume,
    team-review-comment, team-stow and claude-coordinator with any words; team-capacity install
    or place, team-config apply or capture, team-heavy run, team-lease take, renew or release,
    team-secrets restore or save, team-stack down, seed, stop or up and team-timers disable,
    enable or run, any of those among the words before a --; either kind passing with a first
    word --help or -h, which the library answers before the script does anything. Reason: the
    coordinator's acts, which an assistant session never runs (<the act and its subcommand>); its
    --help and a read of its file pass. Each act but team-heavy run also refuses the assistant
    itself (assistant_refusal in bin/lib/team.sh), where the walk cannot read a call.
  assistant-github-write, for the assistant alone: a GitHub write by gh or gh-axi, which its deny
    rules held by any gh api call with a field and any release, secret or variable call until this
    row, and the other groups' writes, many of which (gh gist create, gh workflow run) no deny
    rule held, the pr, issue and repo writes its settings still deny among them. gh api (after
    gh's own options, as cobra finds its command) with a last -X or --method (joined too, any
    case) other than GET or HEAD, with --input, or with a field (-f, -F, --field, --raw-field,
    joined too) and no method, its endpoint being its first word that is no option and no option's
    value; but for the endpoint graphql, whose fields pass, whatever the method, only as a query:
    a query field (and every one) whose value begins with no @, holds no $ or backtick (a GraphQL
    variable reads as the shell's expansion, the walk having dropped the quotes) and has no
    mutation or subscription as a whole name. Any other gh or gh-axi call whose group (the first
    word that is no option and no option's value, a long option without = and a two-character
    short one taking the next word, but --help and -h) and subcommand are not among the reads
    GITHUB_READS lists for each: a group it lists no read of (a user alias, an extension, gh co,
    copilot, preview, gh-axi setup and update but its --check), a subcommand outside its group's
    reads, a subcommand's own outside its reads (repo deploy-key, repo autolink, gh-axi issue
    subissue), gh auth status with -t or --show-token, which prints the token, gh config get of a
    key gh config list does not name (GH_CONFIG_KEYS; a host's oauth_token is its token), and gh
    repo clone or gh gist clone with words after --, which it passes to git clone. gh alone, a
    group with no subcommand and the groups that read with any words (search, browse, status,
    licenses, completion, help, version) pass. Reason: a GitHub write, which an assistant session
    never makes (<the method, the body, the field, the mutation, the query it cannot read, or the
    group and subcommand>).
  assistant-thread-cache, for the assistant alone: a call naming the thread cache the Discord
    guard trusts (assistant-threads, as written or with its quotes and backslashes removed, or the
    library's ASSISTANT_THREADS or assistant_thread_keep), which its deny rule refused whatever it
    ran until this row, unless it only reads it: unless it is a plain list of readers, each by its
    bare name, joined by pipes, &&, || and ; alone, in any of the texts the walk reads. Refused by
    a redirection that writes (>, >>, >|, &>, &>>, <>, and >& to no fd, with an fd before it)
    anywhere but /dev/null, a bare one with no command among them
    (command_text.call_redirections), a named fd's ({NAME}<, which assigns NAME), and any other
    but an input one (<, <<, <<-, <<<) or an fd's duplication; by a writer naming it (tee, cp, mv,
    install, ln, rsync, truncate, rm, unlink, shred, touch, chmod or chown, by a word or an
    option's value after its =, dd's of= value, and sed, perl or ruby with -i or --in-place); by
    any command that is no plain reader by its bare name (CACHE_READERS: cat, grep, head, tail,
    wc, jq, diff and the like, none with an option that writes a file, runs a program or assigns a
    variable; dd writing to no file; sed with only plain options and a plain script, no w, W or e;
    sort with no -o, -T or --compress-program), so a wrapper (env, timeout, nice, xargs, time and
    the rest, whose option may stand before the program it runs), a builtin that assigns (read,
    printf, cd, declare, let), an interpreter's program, a reader by a path, a source of the
    library and a shell string are refused; by any assignment, before a command or on its own,
    since a PATH may find another program of a reader's name; by an arithmetic expansion or
    command ($((, $[, ((), which may assign; and by a call that is no plain list of commands
    (command_text.plain_sequence with pipes: no group, subshell, loop, function, substitution,
    background or !; and no code part but the call's own text, command_text.code_parts). Reason:
    the thread cache the Discord guard trusts, which only the scripts and hooks write (<the path
    as written, its quotes removed; the redirection and its target; the command that is no plain
    reader, as written; the assignment; the arithmetic; or a call that is no plain list of
    readers>).
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
it; only the kill and delete rows read the process table or a file from it, so a call with
neither reads no process or file for it.
A row reads every command the walk yields, a shell's script file and a sourced one among them (a
file named team-worker that bash runs is team-worker), but for the upload and delete rows, which
read no file's name as curl or rm. A row with a call test (assistant-thread-cache) runs it first,
on the call's command, for what no one command holds (a redirection, the call's name of the
cache), its where being the first line holding the refused path or command.
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
    ASSIGNMENT, DIRECT, Command, call_commands, call_redirections, command_name, commands, from_wrappers, has_blank,
    code_parts, heads, leads, plain_sequence, read_command, short_cluster,
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
    own as a tuple, its reason and its allowed way (None: the refusal names none); and, for a row
    that reads what no Command holds, its call test over the call's command and context, run
    before its test, which refuses by returning its reason and the words to find the refused line
    by, or None."""

    id: str
    test: Callable
    reason: str | None
    allowed: str | None = None
    call: Callable | None = None


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
    return bool(args) and (TASK_ID.fullmatch(args[0]) is not None or args[0] == "archive")


# The first words the library answers with the calling script's header before the script does anything.
HELP = ("--help", "-h")


def _coordinator_read(name, args):
    """Whether the words after one of the coordinator's commands are a read the assistant may run:
    a first --help or -h, or team-inbox --item <n> alone."""
    return (bool(args) and args[0] in HELP) or (name == "team-inbox" and len(args) == 2 and args[0] == "--item")


def _coordinator(command, context):
    reads = context is not None and context.role == "assistant"
    for words in heads(command):
        if not words:
            continue
        name, args = command_name(words[0]), list(words[1:])
        if name in COORDINATOR and not (reads and _coordinator_read(name, args)):
            return True
        if name == "team-thread" and _thread(args):
            return True
    return False


# The coordinator's acts, which an assistant session never runs: the whole scripts, refused with
# any arguments, and the scripts whose listed subcommands act, refused when one of them is among
# the words before a --. Either passes with a first word --help or -h, which the library answers
# with the script's header before the script does anything.
ASSISTANT_WHOLE_ACTS = frozenset((
    "team-checkpoint", "team-handoff", "team-load-check", "team-ops-end", "team-records-rewrite", "team-resume",
    "team-review-comment", "team-stow", "claude-coordinator",
))
ASSISTANT_SUBCOMMAND_ACTS = {
    "team-capacity": ("install", "place"),
    "team-config": ("apply", "capture"),
    "team-heavy": ("run",),
    "team-lease": ("take", "renew", "release"),
    "team-secrets": ("restore", "save"),
    "team-stack": ("down", "seed", "stop", "up"),
    "team-timers": ("disable", "enable", "run"),
}
ACTS_REASON = (
    "the coordinator's acts, which an assistant session never runs ({}); its --help and a read of its file pass"
)


def _assistant_act(command, context):
    """The assistant's run of one of the coordinator's acts, the reason naming it and its
    subcommand; any other role's call is not this row's."""
    if context is None or context.role != "assistant":
        return None
    for words in heads(command):
        if not words:
            continue
        name, args = command_name(words[0]), list(words[1:])
        if args[:1] and args[0] in HELP:
            continue
        if name in ASSISTANT_WHOLE_ACTS:
            return ACTS_REASON.format(name)
        acting = next((word for word in _before_end(args) if word in ASSISTANT_SUBCOMMAND_ACTS.get(name, ())), None)
        if acting is not None:
            return ACTS_REASON.format(f"{name} {acting}")
    return None


# The GitHub CLIs whose writes an assistant session never makes, and gh api's options: those that
# take a value (joined, or the next word), its fields among them, and its methods that only read.
GITHUB_CLIS = frozenset(("gh", "gh-axi"))
API_VALUED_SHORT = "XHfFqtp"
API_VALUED_LONG = frozenset((
    "--method", "--header", "--raw-field", "--field", "--input", "--jq", "--template", "--hostname", "--cache",
    "--preview",
))
API_FIELDS = frozenset(("-f", "-F", "--raw-field", "--field"))
API_LONG = {"-X": "--method", "-H": "--header", "-f": "--raw-field", "-F": "--field", "-q": "--jq",
            "-t": "--template", "-p": "--preview"}
API_READS = frozenset(("GET", "HEAD"))
# The reads of gh's and gh-axi's groups, each group's subcommands that only read (ls where list
# is one, as gh aliases it), a subcommand's own reads where it is a group too (None: any words
# after it), and ANY_READ for a group all of whose subcommands read; any other group or
# subcommand is a write, an unknown group (a user alias, an extension) among them.
ANY_READ = "any"


def _reads(*subcommands, **groups):
    table = {sub: None for sub in subcommands}
    if "list" in table:
        table["ls"] = None
    table.update({sub.replace("_", "-"): frozenset(reads) for sub, reads in groups.items()})
    return table


GITHUB_READS = {
    "gh": {
        "auth": _reads("status"), "codespace": _reads("list", "view", "logs"), "discussion": _reads("list", "view"),
        "gist": _reads("list", "view", "clone"), "issue": _reads("list", "status", "view"), "org": _reads("list"),
        "pr": _reads("list", "status", "checks", "diff", "view"),
        "project": _reads("list", "view", "field-list", "item-list"),
        "release": _reads("list", "view", "download", "verify", "verify-asset"),
        "repo": _reads("list", "view", "clone", "gitignore", "license", "read-dir", "read-file",
                       autolink=("list", "ls", "view"), deploy_key=("list", "ls")),
        "skill": _reads("list", "search", "preview"), "cache": _reads("list"),
        "run": _reads("list", "view", "watch", "download"), "workflow": _reads("list", "view"),
        "agent-task": _reads("list", "view"), "alias": _reads("list"),
        "attestation": _reads("download", "trusted-root", "verify"), "config": _reads("get", "list"),
        "extension": _reads("list", "search"), "gpg-key": _reads("list"), "ssh-key": _reads("list"),
        "label": _reads("list"), "ruleset": _reads("check", "list", "view"), "search": ANY_READ,
        "secret": _reads("list"), "variable": _reads("list", "get"),
        # The commands with no subcommand, each a read with any words.
        "browse": ANY_READ, "status": ANY_READ, "licenses": ANY_READ, "completion": ANY_READ, "help": ANY_READ,
        "version": ANY_READ,
    },
    "gh-axi": {
        "issue": _reads("list", "view", subissue=("list",)), "pr": _reads("list", "view", "checks", "diff"),
        "run": _reads("list", "view", "watch", "download"), "workflow": _reads("list", "view"),
        "release": _reads("list", "view", "download"), "repo": _reads("view", "list"), "label": _reads("list"),
        "secret": _reads("list"), "variable": _reads("list"), "search": ANY_READ,
    },
}
# The keys gh config get may read, those gh config list names (gh 2.103): any other is a host's
# key of its hosts file, oauth_token among them, which gh config get -h <host> prints as the token.
GH_CONFIG_KEYS = frozenset((
    "api_host", "git_protocol", "editor", "prompt", "prefer_editor_prompt", "expiring_credentials", "pager",
    "http_unix_socket", "browser", "clipboard", "color_labels", "accessible_colors", "accessible_prompter", "spinner",
    "telemetry",
))
# GraphQL's operation keywords that write or stream, as whole names (case-sensitive, as GraphQL's are).
GRAPHQL_WRITES = re.compile(r"(?<![_0-9A-Za-z])(?:mutation|subscription)(?![_0-9A-Za-z])")
GITHUB_REASON = "a GitHub write, which an assistant session never makes ({})"


def _cobra_commands(args):
    """Where the words gh reads as its command and subcommands stand, as cobra finds them: every
    word that is no option and no option's value, up to a --, a long option without = and a short
    one of two characters taking the next word as its value, but for --help and -h."""
    found, k = [], 0
    while k < len(args):
        word = args[k]
        if word == "--":
            break
        if word.startswith("-") and word not in ("--help", "-h"):
            k += 2 if (word.startswith("--") and "=" not in word) or len(word) == 2 else 1
            continue
        if not word.startswith("-"):
            found.append(k)
        k += 1
    return found


def _api_options(args):
    """gh api's words read as gh reads them: its last method (upper case, "" when it has no value)
    or None, whether it has --input, its fields' key=value texts and its endpoint, its first word
    that is no option and no option's value."""
    method, has_input, fields, endpoint, k = None, False, [], None, 0
    while k < len(args):
        word = args[k]
        k += 1
        if word == "--":
            endpoint = endpoint if endpoint is not None else (args[k] if k < len(args) else None)
            break
        if not word.startswith("-") or word == "-":
            endpoint = word if endpoint is None else endpoint
            continue
        if word.startswith("--"):
            name, joined, value = word.partition("=")
            if name not in API_VALUED_LONG:
                continue
            if not joined:
                value = args[k] if k < len(args) else ""
                k += 1
        else:
            _, flag, value = short_cluster(word, API_VALUED_SHORT)
            if flag is None:
                continue
            name = API_LONG[f"-{flag}"]
            if not value:
                value = args[k] if k < len(args) else ""
                k += 1
        if name == "--method":
            method = value.upper()
        elif name == "--input":
            has_input = True
        elif name in API_FIELDS:
            fields.append(value)
    return method, has_input, fields, endpoint


def _graphql_write(fields):
    """Why a GraphQL call's fields are no query the guard can read, or None for a query: a literal
    query field holding neither mutation nor subscription."""
    queries = [value.partition("=")[2] for value in fields if value.partition("=")[0] == "query"]
    if not queries:
        return "gh api graphql with a field but no query"
    for query in queries:
        if query.lstrip()[:1] == "@":
            return "a GraphQL query from a file or stdin the guard cannot read"
    # The walk drops a word's quotes, so a GraphQL variable ($n in single quotes) and the shell's
    # expansion ($M in double quotes) read alike: neither passes.
    for query in queries:
        if "$" in query or "`" in query:
            return "a GraphQL query holding a $ or a backtick, which may be a shell expansion: write its values into the query"
    if any(GRAPHQL_WRITES.search(query) for query in queries):
        return "a GraphQL mutation or subscription"
    return None


def _api_write(args):
    """What makes gh api's words a write, or None for a read."""
    method, has_input, fields, endpoint = _api_options(args)
    if method is not None and method not in API_READS:
        return f"gh api --method {method}"
    if has_input:
        return "gh api --input, a request body"
    if endpoint == "graphql" and fields:
        return _graphql_write(fields)
    if fields and method is None:
        return "gh api with a field and no --method GET or HEAD, which sends a POST"
    return None


def _github_write(command, context):
    """The assistant's GitHub write by gh or gh-axi, the reason naming what it read; any other
    role's call is not this row's."""
    if context is None or context.role != "assistant":
        return None
    for words in heads(command):
        if not words or command_name(words[0]) not in GITHUB_CLIS:
            continue
        name, args = command_name(words[0]), list(words[1:])
        found = _cobra_commands(args)
        group = args[found[0]] if found else None
        if group == "api":
            write = _api_write(args[found[0] + 1 :])
            if write is not None:
                return GITHUB_REASON.format(write)
        elif group is not None and (write := _group_write(name, args, found)) is not None:
            return GITHUB_REASON.format(write)
    return None


def _group_write(name, args, found):
    """What makes a gh or gh-axi call past its group no read, or None: a group the guard knows no
    read of, a subcommand (or a subcommand's own) outside its reads, gh auth status showing the
    token, and gh-axi update but its --check. A group with no subcommand prints its help."""
    group = args[found[0]]
    if name == "gh-axi" and group == "update":
        return None if "--check" in args else f"{name} update, a command the guard knows no read of"
    reads = GITHUB_READS[name].get(group)
    if reads is None:
        return f"{name} {group}, a command the guard knows no read of"
    if reads == ANY_READ or len(found) < 2:
        return None
    sub = args[found[1]]
    if sub not in reads:
        return f"{name} {group} {sub}"
    if reads[sub] is not None and len(found) > 2 and args[found[2]] not in reads[sub]:
        return f"{name} {group} {sub} {args[found[2]]}"
    shows = any(word == "-t" or word.startswith("--show-token") or re.fullmatch(r"-[A-Za-z]*t[A-Za-z]*", word)
                for word in args[found[1] + 1 :])
    if (name, group, sub) == ("gh", "auth", "status") and shows:
        return "gh auth status --show-token, which prints the token"
    after = list(args[found[1] + 1 :])
    if (name, group, sub) == ("gh", "config", "get"):
        key = _config_key(after)
        return None if key is None or key in GH_CONFIG_KEYS else f"gh config get {key}, a key gh config list does not name"
    if name == "gh" and sub == "clone" and "--" in after and after.index("--") + 1 < len(after):
        return f"gh {group} clone with words after --, which it passes to git clone"
    return None


def _config_key(args):
    """The first word gh config get takes as its key among its words after get, or None: a word
    that is no option and no value of its -h or --host."""
    k = 0
    while k < len(args):
        word = args[k]
        if word in ("-h", "--host"):
            k += 2
            continue
        if not word.startswith("-"):
            return word
        k += 1
    return None


# The thread cache the Discord guard trusts (ASSISTANT_THREADS in bin/lib/team.sh), by the start
# of a path's basename, as the deny rule *assistant-threads* this row took over matched any spelling.
THREAD_CACHE = "assistant-threads"
# The redirection operators that write their target, the fd before them aside; >& writes one only
# when its target is no fd.
WRITE_REDIRECTS = frozenset((">", ">>", ">|", "&>", "&>>", "<>"))
# The commands that write, make, move, link, remove or change a file their words name.
CACHE_WRITERS = frozenset(("tee", "cp", "mv", "install", "ln", "rsync", "truncate", "rm", "unlink", "shred", "touch",
                           "chmod", "chown"))
# The editors that write their files in place with -i or --in-place, each with its short options
# that take the rest of their word as their value, so an i in it is no flag.
IN_PLACE_EDITORS = {"sed": "efl", "perl": "eEIMmxdD", "ruby": "eIrxCEFKTW0"}
CACHE_REASON = "the thread cache the Discord guard trusts, which only the scripts and hooks write ({})"


def _cache(word):
    """Whether a word, or an option's value joined to it by =, names the thread cache."""
    return any(command_name(path).startswith(THREAD_CACHE) for path in (word, word.rpartition("=")[2]))


def _in_place(name, args):
    """Whether an editor's words edit its files in place: --in-place (by a prefix, joined value
    too) or i among a short cluster's flags before one taking a value (-i, -i.bak, -pi, -ni)."""
    for word in args:
        if word == "--":
            return False
        if word.startswith("--"):
            option = word[2:].partition("=")[0]
            if option.startswith("i") and "in-place".startswith(option):
                return True
        elif word.startswith("-"):
            for flag in word[1:]:
                if flag == "i":
                    return True
                if flag in IN_PLACE_EDITORS[name]:
                    break
    return False


def _cache_writes(name, args):
    """The word naming the thread cache among a writer's words, or None: dd's of= value, an
    in-place editor's words, and any other writer's words."""
    if name == "dd":
        found = (word[3:] for word in args if word.startswith("of=") and _cache(word[3:]))
    elif name in IN_PLACE_EDITORS:
        found = (word for word in args if _in_place(name, args) and _cache(word))
    elif name in CACHE_WRITERS:
        found = (word for word in args if _cache(word))
    else:
        return None
    return next(found, None)


# The library's names of the cache, which a call sourcing it may write by: its variable and the
# function that adds an id.
CACHE_NAMES = re.compile(r"assistant-threads|ASSISTANT_THREADS|assistant_thread_keep")
# The commands that only read what they are given or filter text, none with an option that writes a
# file, runs a program or assigns a variable, which a call naming the cache may run by its bare
# name (dd too, writing to no file, sed with a plain script, sort with no -o, --output,
# --compress-program or -T, and diff with no -l or --paginate, which runs pr); no wrapper and no
# builtin that assigns (read, printf -v, cd) is one; the one target an output redirection in it
# may write.
CACHE_READERS = frozenset((
    "cat", "head", "tail", "grep", "egrep", "fgrep", "wc", "jq", "diff", "cmp", "stat", "ls", "sha256sum", "sha1sum",
    "md5sum", "sha512sum", "echo", "true", "false", "test", "[", "pwd", ":", "cut", "tr", "nl", "paste", "column",
    "fold", "rev", "basename", "dirname", "realpath", "readlink", "od", "hexdump",
))
QUIET_TARGETS = frozenset(("/dev/null",))
# The input redirections, the fd before them aside, which a call naming the cache may make: no
# heredoc, whose body the walk does not read in full, and a here-string only with a word holding
# no $ or backtick, since the walk does not read a substitution in a double-quoted one.
READ_REDIRECTS = frozenset(("<", "<<<"))
HEREDOCS = frozenset(("<<", "<<-"))
# An arithmetic expansion or command, which may assign a variable: $((, $[ or ((.
ARITHMETIC = re.compile(r"\$\[|\(\(")
# A parameter expansion, which may assign a variable (${name:=word}).
PARAMETER = re.compile(r"\$\{")
PLAIN_LIST = "a call naming it that is no plain list of readers joined by |, &&, || or ;"
# sed's options a plain reading takes, and the script it reads with: one command a part (split on
# ;), an address or range, then p, q, Q, =, d, l, n or N, or s/.../.../ with g, p, i, I or a number,
# so no w, W or e command or flag writes or runs.
SED_PLAIN_OPTIONS = frozenset((
    "-n", "--quiet", "--silent", "-E", "-r", "--regexp-extended", "-s", "--separate", "-z", "--null-data", "-u",
    "--unbuffered", "--posix",
))
SED_ADDRESS = r"(?:[0-9]+|\$|/(?:[^/\\]|\\.)*/)"
SED_PLAIN = re.compile(
    rf"(?:{SED_ADDRESS}(?:,{SED_ADDRESS})?)?!?(?:[pqQ=dlnN]|s/(?:[^/\\]|\\.)*/(?:[^/\\]|\\.)*/[gpiI0-9]*)"
)


def _names_cache(text):
    """Whether a call's text names the thread cache, as written or with its quotes and
    backslashes removed, as the hook's fast path reads it."""
    return any(CACHE_NAMES.search(form) for form in (text, re.sub(r"['\"\\]", "", text.replace("\\\n", ""))))


def _plain_sed(args):
    """Whether sed's words read only: no option but the plain ones and -e, and each script plain."""
    scripts, k = [], 0
    while k < len(args):
        word = args[k]
        if word in ("-e", "--expression"):
            if k + 1 >= len(args):
                return False
            scripts.append(args[k + 1])
            k += 2
            continue
        if word.startswith("--expression="):
            scripts.append(word.partition("=")[2])
        elif word.startswith("-e") and not word.startswith("--"):
            scripts.append(word[2:])
        elif word.startswith("-") and word != "-" and word not in SED_PLAIN_OPTIONS:
            return False
        k += 1
    if not scripts:
        script = next((word for word in args if not word.startswith("-") or word == "-"), None)
        if script is None:
            return False
        scripts.append(script)
    return all(
        "\n" not in script and all(SED_PLAIN.fullmatch(part.strip()) for part in script.split(";"))
        for script in scripts
    )


def _plain_reader(found):
    """Whether a walked command only reads: a reader by its bare name (dd writing to no file, sed
    with a plain script, sort and diff writing no file and running no program), behind no
    wrapper, with no assignment before it and with a name at all; a path, a PATH or a wrapper's
    option may run another program than a reader's name says."""
    if found.assignments or found.wrappers or not found.words or "/" in found.words[0]:
        return False
    name, args = found.words[0], list(found.words[1:])
    if name == "dd":
        return all(word[3:] in QUIET_TARGETS for word in args if word.startswith("of="))
    if name == "sed":
        return _plain_sed(args)
    if name == "sort":
        # sort writes a file by -o or --output, its temporary files by -T or
        # --temporary-directory, and runs a program by --compress-program, each named by any
        # prefix getopt_long takes (--o, --t, --co).
        return not any(word.startswith(("--o", "--t", "--co")) or re.fullmatch(r"-[A-Za-z]*[oT].*", word)
                       for word in args)
    if name == "diff":
        # diff runs pr by -l or --paginate, named by any prefix getopt_long takes (--pag) or in a
        # short cluster (-ul).
        return not any((word.startswith("--") and len(word) > 2 and "paginate".startswith(word[2:].partition("=")[0]))
                       or re.fullmatch(r"-[A-Za-z]*l.*", word) for word in args)
    return name in CACHE_READERS


def _cache_call(command, context):
    """The assistant's call naming the thread cache that may do more than read it, as its reason
    and the words of its refused line, or None: a redirection that writes anywhere but /dev/null
    (the cache's path when it names it), a named fd's (which assigns its variable) or any other
    but an input one or an fd's duplication, a heredoc, a here-string whose word holds a $ or a
    backtick (each holding text the walk does not read in full), a writer naming it (that path),
    any command that is no plain reader (its name, or its assignment), an arithmetic or parameter
    expansion anywhere in its text (which may assign), and a call that is no plain list of
    commands joined by pipes, &&, || and ; with no code part but its own text
    (command_text.plain_sequence with pipes, and code_parts). Any other role's call, and one
    naming no cache, is not this row's."""
    if context is None or context.role != "assistant" or not _names_cache(command):
        return None
    for operator, target in call_redirections(command):
        named = re.match(r"\{\w+\}", operator)
        bare = re.sub(r"^(?:[0-9]+|\{\w+\})", "", operator)
        duplicates = bare in (">&", "<&") and re.fullmatch(r"[0-9]*-?", target)
        writes = bare in WRITE_REDIRECTS or (bare == ">&" and not duplicates)
        if writes and target not in QUIET_TARGETS:
            if command_name(target).startswith(THREAD_CACHE):
                return CACHE_REASON.format(target), (target,)
            return CACHE_REASON.format(f"{operator}{target}, a write in a call naming it"), (target,)
        if named:
            return CACHE_REASON.format(f"{operator}{target}, a redirection that assigns a variable, in a call naming it"), (
                target,
            )
        if bare in HEREDOCS:
            return CACHE_REASON.format(
                f"{operator}{target}, a heredoc, whose body the walk does not read in full, in a call naming it"
            ), (target,)
        if bare == "<<<" and re.search(r"[$`]", target):
            return CACHE_REASON.format(
                f"{operator}{target}, a here-string whose word the walk does not read in full, in a call naming it"
            ), (target,)
        if not writes and not duplicates and bare not in READ_REDIRECTS:
            return CACHE_REASON.format(f"{operator}{target}, a redirection in a call naming it"), (target,)
    walked = call_commands(command)
    for found in walked:
        for words in heads(found):
            if words and (path := _cache_writes(command_name(words[0]), list(words[1:]))) is not None:
                return CACHE_REASON.format(path), tuple(words)
    for found in walked:
        if not _plain_reader(found):
            if found.assignments:
                assignment = found.assignments[0]
                return CACHE_REASON.format(f"{assignment}, an assignment in a call naming it"), (assignment,)
            ran = next((wrapper for wrapper in found.wrappers if wrapper), found.words)
            if not ran:
                return CACHE_REASON.format("a command with no name, in a call naming it"), ()
            return CACHE_REASON.format(f"{ran[0]}, which is no plain reader of it, in a call naming it"), tuple(ran[:1])
    if ARITHMETIC.search(command):
        return CACHE_REASON.format("an arithmetic expansion, which may assign a variable, in a call naming it"), ()
    if PARAMETER.search(command):
        return CACHE_REASON.format("a parameter expansion, which may assign a variable, in a call naming it"), ()
    if len(code_parts(command)) != 1 or plain_sequence(command, pipes=True) is None:
        return CACHE_REASON.format(PLAIN_LIST), ()
    return None


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
        "the coordinator's commands (team-ask, team-answer, team-inbox, team-thread T<n>, team-thread archive and team-run-approved)",
    ),
    Row("assistant-acts", _assistant_act, None),
    Row("assistant-github-write", _github_write, None),
    Row("assistant-thread-cache", lambda command, context: None, None, call=_cache_call),
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
        try:
            refused = row.call(command, context) if row.call is not None else None
        except Exception as error:  # noqa: BLE001 - named, then refused by the caller
            raise RowError(f"{row.id}: {type(error).__name__}: {error}") from error
        if refused:
            # The refused line is the first holding the call test's words.
            reason, words = refused
            return {
                "rule": row.id, "reason": reason, "allowed": row.allowed,
                "where": where(Command((), words, (), DIRECT), command),
            }
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
