#!/usr/bin/env python3
"""session-records-guard's table and rule: whether a worker's call reaches another session's records.

Usage: python3 -I session_records.py   (the hook's input JSON on stdin)

bin/hooks/session-records-guard runs this file once per call its matcher takes, and refuses the
call when it prints a line. It prints one JSON line, {"reason": <text>}, the reason being the text
the hook puts after "Blocked by session-records-guard: ", when it refuses, and nothing when it
passes, exiting 0 either way. Any error of its own exits 1 with one line on stderr,
"session_records.py: <ErrorType>: <message>", so the hook refuses: a guard that cannot decide
refuses. It reads nothing of the team home.

PLACES builds the table of every session-record place, in the order a refusal picks its place by;
the hook's header says what each holds, what a session owns there, which paths of a call are
judged, the rule for one path, and every message. A place keyed by a session or job id lets a
session reach its own entry and refuses every other; a place not keyed that way is refused whole.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from typing import Callable, Optional

sys.dont_write_bytecode = True

# A UUID's shape, 8-4-4-4-12 lowercase hex.
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.ASCII)

UNREADABLE = "its input is not a hook call it can read, and a guard that cannot decide refuses."

# The tools whose paths are judged; any other passes unread.
FILE_TOOLS = ("Read", "Grep", "Glob")


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


def places(env, session):
    """The table, in order, for a session (its id when it has a UUID's shape, else "")."""
    home = env.get("HOME") or os.path.expanduser("~")
    config = env.get("CLAUDE_CONFIG_DIR") or f"{home}/.claude"
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
    if tool not in FILE_TOOLS:
        return None
    session = call.get("session_id")
    session = session if isinstance(session, str) and UUID.fullmatch(session) else ""
    cwd = call.get("cwd")
    cwd = os.path.realpath(cwd if isinstance(cwd, str) and cwd else os.getcwd())
    home = env.get("HOME") or os.path.expanduser("~")
    table = places(env, session)

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
