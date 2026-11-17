#!/usr/bin/env python3
"""session-records-guard's table and rule: whether a worker's call reaches another session's records.

Usage: python3 -I session_records.py   (the hook's input JSON on stdin)

bin/hooks/session-records-guard runs this file once per call its matcher takes, and refuses the
call when it prints a line. It prints one JSON line, {"reason": <text>}, the reason being the text
the hook puts after "Blocked by session-records-guard: ", when it refuses, and nothing when it
passes, exiting 0 either way. Any error of its own exits 1 with one line on stderr,
"session_records.py: <ErrorType>: <message>", so the hook refuses: a guard that cannot decide
refuses. It reads nothing of the team home.

places() builds the table of every session-record place, in the order a refusal picks its place by;
the hook's header says what each holds, what a session owns there, which paths of a call are
judged, the rule for one path, and every message. A place keyed by a session or job id lets a
session reach its own entry and refuses every other; a place not keyed that way is refused whole.
Read, Grep and Glob are judged by judge_file, Bash by decide_bash: the words its commands spell,
read through command_text's walk and its redirections' targets, each resolved by delete_rules'
reading of an operand, in a Context of command_rules', as the hook's header says.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from typing import Callable, Optional

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_rules import Context  # noqa: E402
from command_text import call_commands, command_name, redirection_targets  # noqa: E402
from delete_rules import Unread, candidates, expand  # noqa: E402

# A UUID's shape, 8-4-4-4-12 lowercase hex.
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.ASCII)

UNREADABLE = "its input is not a hook call it can read, and a guard that cannot decide refuses."

# The tools whose paths are judged, the file tools' and Bash's; any other passes unread.
FILE_TOOLS = ("Read", "Grep", "Glob")
BASH = "Bash"
# A word that gives a value after its first =: an assignment, a name=value operand (dd's if=) or
# a long option's --name=value.
VALUED = re.compile(r"-{0,2}[A-Za-z_][A-Za-z0-9_.-]*(?:\[.*\])?\+?=", re.DOTALL)


@dataclass(frozen=True)
class Place:
    """One row of the table: the name a refusal shows, the root resolved with its symlinks,
    whether its volume folds case, and, for a keyed place, what a session owns there as a refusal
    says it and the test of the components below the root (already folded) that names its own
    entry; a place refused whole has neither."""

    name: str
    root: str
    fold: bool
    owns: Optional[str] = None
    own: Optional[Callable[[list], bool]] = None

    def fit(self, path):
        """The path and the root as they are compared: both in lower case when the volume folds."""
        return (path.lower(), self.root.lower()) if self.fold else (path, self.root)


def folds(root, env):
    """Whether the root's volume folds case, so a name in another case is the same path: the seam
    says so, or the root in upper or in lower case is the root's own directory."""
    if env.get("SESSION_RECORDS_FOLD_CASE"):
        return True
    for recased in (root.upper(), root.lower()):
        if recased == root:
            continue
        try:
            if os.path.samefile(recased, root):
                return True
        except OSError:
            pass
    return False


def resolve(path, cwd, home):
    """The path made absolute against cwd, a leading ~ or ~/ read as the home directory, then
    resolved with its symlinks and its .. (a missing path allowed)."""
    if path == "~":
        path = home
    elif path.startswith("~/"):
        path = home + "/" + path[2:]
    if not path.startswith("/"):
        path = cwd + "/" + path
    return os.path.realpath(path)


def temporary_directory(env):
    """Claude Code's temporary directory: claude-<uid> in CLAUDE_CODE_TMPDIR, else in the OS temp
    dir as Node's os.tmpdir() finds it (TMPDIR, else TMP, else TEMP, else /tmp)."""
    base = next((env[k] for k in ("CLAUDE_CODE_TMPDIR", "TMPDIR", "TMP", "TEMP") if env.get(k)), "/tmp")
    return f"{base}/claude-{os.getuid()}"


def config_directory(env):
    """Claude Code's config directory: CLAUDE_CONFIG_DIR, else ~/.claude."""
    home = env.get("HOME") or os.path.expanduser("~")
    return env.get("CLAUDE_CONFIG_DIR") or f"{home}/.claude"


def places(env, session):
    """The table, in order, for a session (its id when it has a UUID's shape, else "")."""
    home = env.get("HOME") or os.path.expanduser("~")
    config = config_directory(env)
    rows = []

    def add(name, root, owns=None, own_of=None):
        root = os.path.realpath(root)
        fold = folds(root, env)
        own = own_of(root, fold) if own_of else None
        rows.append(Place(name, root, fold, owns, own))

    def session_directory(root, fold):
        # <project>/<own>, where <own> is the session's transcript or its directory.
        return lambda parts: bool(session) and len(parts) > 1 and parts[1] in (session, session + ".jsonl")

    def first_is(names):
        return lambda parts: parts[0] in names

    def jobs_own(root, fold):
        # The job directory the session id's first 8 characters name, and the one CLAUDE_JOB_DIR
        # names when it lies directly in the jobs directory.
        if not session:
            return first_is(set())
        names = {session[:8]}
        job = env.get("CLAUDE_JOB_DIR")
        if job:
            job = os.path.realpath(job)
            parent, name = os.path.split(job)
            if fold:
                parent, name = parent.lower(), name.lower()
            if name and parent == (root.lower() if fold else root):
                names.add(name)
        return first_is(names)

    def session_named(root, fold):
        return first_is({session} if session else set())

    add("~/.claude/projects", f"{config}/projects",
        "its own records, its transcript and what lies under its own session directory", session_directory)
    temp = os.path.realpath(temporary_directory(env))
    add(temp, temp, "what lies under its own session directory", session_directory)
    add("~/.claude/jobs", f"{config}/jobs", "what lies in its own job directory", jobs_own)
    add("~/.claude/tasks", f"{config}/tasks", "its own task list", session_named)
    add("~/.claude/session-env", f"{config}/session-env", "its own environment files", session_named)
    for name in ("transcripts", "history.jsonl", "paste-cache", "sessions", "daemon", "daemon.log", "file-history"):
        add(f"~/.claude/{name}", f"{config}/{name}")
    for cache in (".cache/claude-cli-nodejs", "Library/Caches/claude-cli-nodejs"):
        add(f"~/{cache}", f"{home}/{cache}")
    return rows


def relation(path, root):
    """Where a resolved path lies against a root: "root", "above" it, "under" it, or None."""
    if path == root:
        return "root"
    if path == "/" or root.startswith(path + "/"):
        return "above"
    if path.startswith(root + "/"):
        return "under"
    return None


def judge_file(tool, real, given, table):
    """A file tool's refusal for one resolved path, or None: refused under a place but as the
    session's own entry, refused whole in or at a place not keyed, and refused as too wide for a
    Grep or Glob at a keyed place's root or above any place, naming the first row in order."""
    for place in table:
        at, root = place.fit(real)
        where = relation(at, root)
        if where is None:
            continue
        if place.own is None and where in ("root", "under"):
            return f"{tool} of {given}: {place.name} holds every session's records, and a worker session reads none of it."
        if where in ("root", "above"):
            if tool == "Read":
                continue
            return f"{tool} rooted at {given} would search every session's records under {place.name}; give it a narrower path."
        if place.own(at[len(root) + 1:].split("/")):
            continue
        return f"{tool} of {given}: under {place.name} a session reads only {place.owns}, and this is another session's."
    return None


def judge_bash(real, word, table, config):
    """A Bash command's refusal for one resolved path it names, or None: refused in a keyed place
    but as the session's own entry or under it, refused whole in or at a place not keyed, and
    refused as too wide at a keyed place's root or at the config directory (config, resolved and
    folded as its volume folds, with the fold), which names the first row; any other passes, the
    directories above the config directory and the temporary directory among them."""
    subject = f"a Bash command naming {word}"
    for place in table:
        at, root = place.fit(real)
        where = relation(at, root)
        if where in (None, "above"):
            continue
        if place.own is None:
            return f"{subject}: {place.name} holds every session's records, and a worker session reads none of it."
        if where == "root":
            return f"{subject} would reach every session's records under {place.name}; name a narrower path."
        if place.own(at[len(root) + 1:].split("/")):
            continue
        return f"{subject}: under {place.name} a session reads only {place.owns}, and this is another session's."
    root, fold = config
    if (real.lower() if fold else real) == root:
        return f"{subject} would reach every session's records under {table[0].name}; name a narrower path."
    return None


def glob_start(path):
    """A path's literal start when it holds a glob, cut as a Glob pattern's is (literal_start), a
    relative one with no directory before its glob being the directory it runs in."""
    start = literal_start(path)
    if not path.startswith("/") and start == "/":
        return "."
    return start


def bash_words(command):
    """The words of one walked command that are judged as paths, each as (the word shown, the
    word read): the value of each assignment before it; each word of each wrapper it ran behind;
    its name when the name holds a /; each word after its name; and, of a word that gives a value
    after its first = (VALUED), that value as well as the whole word."""
    found = []
    for assignment in command.assignments:
        found.append((assignment, assignment.partition("=")[2]))
    words = [word for wrapper in command.wrappers for word in wrapper]
    if command.words:
        if "/" in command.words[0]:
            words.append(command.words[0])
        words += command.words[1:]
    for word in words:
        found.append((word, word))
        if VALUED.match(word):
            found.append((word, word.partition("=")[2]))
    return found


def decide_bash(call, env, table, config):
    """A Bash call's refusal, or None: the first path, in the walk's order, one of its commands
    names (bash_words, then each redirection's target) that a place refuses (judge_bash)."""
    tool_input = call.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str):
        return UNREADABLE
    context = Context(call, env)
    # A word holding a blank is no path but where a root holds one: a longer string that mentions
    # a path (a message, a pattern) passes.
    blanks = any(re.search(r"\s", place.root) for place in table)
    seen = set()
    pairs = [pair for found in call_commands(command) for pair in bash_words(found)]
    pairs += [(target, target) for target in redirection_targets(command)]
    for shown, word in pairs:
        if not word or (shown, word) in seen or (re.search(r"\s", word) and not blanks):
            continue
        seen.add((shown, word))
        try:
            paths = [path for path in expand(word, context) if path]
            for path in paths:
                path = glob_start(path) if re.search(r"[*?\[{]", path) else path
                bases = [""] if path.startswith("/") else candidates(context)
                for base in bases:
                    found = judge_bash(os.path.realpath(os.path.join(base, path)), shown, table, config)
                    if found:
                        return found
        except Unread:
            # A word the guard cannot read before the command runs passes (the header says why).
            continue
    return None


def literal_start(pattern):
    """A Glob pattern's literal start: all of it when it has no wildcard, else up to its last /
    before the first one, or / when that leaves nothing."""
    cut = re.split(r"[*?\[{]", pattern, maxsplit=1)[0]
    if cut != pattern and "/" in cut:
        cut = cut[: cut.rindex("/")]
    return cut or "/"


def field(tool_input, name):
    """A tool_input field: its text, "" for none, or None for any other type."""
    value = tool_input.get(name) if isinstance(tool_input, dict) else None
    if value is None:
        return ""
    return value if isinstance(value, str) else None


def decide(raw, env):
    """The refusal's reason for one hook input (bytes), or None when the call passes."""
    try:
        call = json.loads(raw.decode("utf-8"))
    except ValueError:
        return UNREADABLE
    if not isinstance(call, dict) or not isinstance(call.get("tool_name"), str):
        return UNREADABLE
    tool = call["tool_name"]
    if tool not in FILE_TOOLS and tool != BASH:
        return None
    session = call.get("session_id")
    session = session if isinstance(session, str) and UUID.fullmatch(session) else ""
    table = places(env, session)
    if tool == BASH:
        config = os.path.realpath(config_directory(env))
        fold = folds(config, env)
        return decide_bash(call, env, table, (config.lower() if fold else config, fold))
    cwd = call.get("cwd")
    cwd = os.path.realpath(cwd if isinstance(cwd, str) and cwd else os.getcwd())
    home = env.get("HOME") or os.path.expanduser("~")

    def judge(path, given=None):
        return judge_file(tool, resolve(path, cwd, home), given or path, table)

    tool_input = call.get("tool_input")
    if tool == "Read":
        file_path = field(tool_input, "file_path")
        if not file_path:
            return UNREADABLE
        return judge(file_path)
    path, pattern = field(tool_input, "path"), field(tool_input, "pattern")
    if path is None or pattern is None:
        return UNREADABLE
    found = judge(path or cwd)
    if not found and tool == "Glob" and pattern.startswith(("/", "~")):
        found = judge(literal_start(pattern), pattern)
    return found


def main():
    if sys.argv[1:]:
        sys.stderr.write("usage: python3 -I session_records.py   (the hook's input JSON on stdin)\n")
        return 2
    try:
        reason = decide(sys.stdin.buffer.read(), os.environ)
    except Exception as error:  # noqa: BLE001 - a guard that cannot decide refuses
        sys.stderr.write(f"session_records.py: {type(error).__name__}: {error}\n")
        return 1
    if reason:
        sys.stdout.write(json.dumps({"reason": reason}, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
