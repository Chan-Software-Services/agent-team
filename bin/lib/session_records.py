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
reading of an operand, in a Context of command_rules', as the hook's header says, and the roots of
a recursive reader (recursive_roots), refused above the config or the temporary directory; the
hook's header lists the shapes that rule does not reach, among them, on a Mac, a tar cluster such
as tar -cLC<dir>, since bsdtar's -H and -L take no value and it is read as GNU tar reads it.
"""

from __future__ import annotations

import fnmatch
import json
import os
import pwd
import re
import sys
from dataclasses import dataclass
from typing import Callable, Optional

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_rules import Context  # noqa: E402
from command_text import call_commands, command_name, long_options, redirection_targets, short_cluster  # noqa: E402
from delete_rules import Unread, expand, find_paths, reachable  # noqa: E402

# A UUID's shape, 8-4-4-4-12 lowercase hex.
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.ASCII)

UNREADABLE = "its input is not a hook call it can read, and a guard that cannot decide refuses."

# The tools whose paths are judged, the file tools' and Bash's; any other passes unread.
FILE_TOOLS = ("Read", "Grep", "Glob")
BASH = "Bash"
# A glob's special characters, and a leading ~login with what follows it.
GLOB = re.compile(r"[*?\[]")
LOGIN = re.compile(r"~([A-Za-z0-9._][A-Za-z0-9._-]*)(?=/|$)")
# A word that gives a value after its first =: an assignment, a name=value operand (dd's if=) or
# a long option's --name=value.
VALUED = re.compile(r"-{0,2}[A-Za-z_][A-Za-z0-9_.-]*(?:\[.*\])?\+?=", re.DOTALL)

# The recursive readers' options read as getopt_long reads them: of each, the short options that
# take a value, and its long options, those that take one first; the rest of a reader's long
# options holds each that takes none and is a prefix of one that does, so it is never read as that
# one.
GREP_SHORTS = set("ABCDdefm")
GREP_VALUED = {"after-context", "before-context", "binary-files", "context", "devices", "directories", "exclude",
               "exclude-dir", "exclude-from", "file", "group-separator", "include", "label", "max-count", "regexp"}
GREP_LONGS = GREP_VALUED | {"binary", "dereference-recursive", "recursive"}
RG_SHORTS = set("ABCEMTdefgjmrt")
RG_VALUED = {"after-context", "before-context", "color", "colors", "context", "context-separator", "dfa-size-limit",
             "encoding", "engine", "field-context-separator", "field-match-separator", "file", "glob", "iglob",
             "ignore-file", "max-columns", "max-count", "max-depth", "max-filesize", "path-separator", "pre",
             "pre-glob", "regex-size-limit", "regexp", "replace", "sort", "sortr", "threads", "type", "type-add",
             "type-clear", "type-not"}
RG_LONGS = RG_VALUED | {"files", "ignore", "type-list"}
CP_SHORTS = set("St")
CP_VALUED = {"suffix", "target-directory"}
CP_LONGS = CP_VALUED | {"archive", "recursive"}
RSYNC_SHORTS = set("BMTef")
RSYNC_VALUED = {"backup-dir", "block-size", "chmod", "chown", "compare-dest", "copy-dest", "exclude", "exclude-from",
                "files-from", "filter", "include", "include-from", "link-dest", "log-file", "out-format",
                "partial-dir", "password-file", "remote-option", "rsh", "rsync-path", "suffix", "temp-dir",
                "timeout"}
RSYNC_LONGS = RSYNC_VALUED | {"backup", "partial"}
# tar's short options that take a value, as GNU tar's are, of which -C names the directory it
# reads from. A limit kept: on a Mac, bsdtar's -H and -L take no value, so a cluster such as
# tar -cLC<dir> is read as GNU tar reads it and its directory is not judged.
TAR_SHORTS = set("bCfFgHIKLNTVX")


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
    directories above the config directory and the temporary directory among them, which only
    judge_recursive refuses."""
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


def component_matches(pattern, name):
    """Whether one component of a glob matches one name, as Bash's pathname expansion matches it:
    a name starting with . only by a pattern starting with . (no dotglob), ** as *, and a [^...]
    as [!...]."""
    if name.startswith(".") and not pattern.startswith("."):
        return False
    pattern = "*" if pattern == "**" else pattern.replace("[^", "[!")
    return fnmatch.fnmatchcase(name, pattern)


def reaches(pattern, names):
    """Each remainder of a glob's components once they have matched every one of names, in
    order: ** matching no name or any number, a component with no glob character only itself."""
    if not names:
        return [tuple(pattern)]
    if not pattern:
        return []
    first, out = pattern[0], []
    if first == "**":
        out += reaches(pattern[1:], names)
        if component_matches(first, names[0]):
            out += reaches(pattern, names[1:])
    elif component_matches(first, names[0]):
        out += reaches(pattern[1:], names[1:])
    return out


def glob_parts(path):
    """An absolute path holding a glob as its literal start (its components before the first that
    holds a glob, resolved) and the glob's components after it, a leading .. taken off the start."""
    parts = path.split("/")
    k = next(i for i, part in enumerate(parts) if GLOB.search(part))
    start = os.path.realpath("/".join(parts[:k]) or "/")
    rest = [part for part in os.path.normpath("/".join(parts[k:])).split("/") if part not in ("", ".")]
    while rest and rest[0] == "..":
        start, rest = os.path.dirname(start), rest[1:]
    return start, rest


def judge_glob(path, word, table, config):
    """A Bash command's refusal for an absolute path holding a glob, or None: judged by its literal
    start (its components before the first that holds a glob, resolved), and, from a start above a
    place, by each place the glob's components may reach (the place's root and what lies under
    it, as judge_bash judges them, a glob character left in a name never naming a session's own
    entry) and by the config directory when it may match that alone."""
    parts = path.split("/")
    k = next(i for i, part in enumerate(parts) if GLOB.search(part))
    found = judge_bash(os.path.realpath("/".join(parts[:k]) or "/"), word, table, config)
    if found:
        return found
    start, rest = glob_parts(path)
    config_root, fold = config
    targets = [(place.root.lower() if place.fold else place.root, place.fold) for place in table]
    targets.append((config_root, fold))
    for root, folded in targets:
        at = start.lower() if folded else start
        if relation(at, root) != "above":
            continue
        names = root[len(at.rstrip("/")) + 1:].split("/")
        pattern = [part.lower() for part in rest] if folded else rest
        for remainder in reaches(pattern, names):
            if root == config_root and remainder:
                continue
            found = judge_bash("/".join((root,) + remainder), word, table, config)
            if found:
                return found
    return None


def judge_recursive(path, word, globbed, guarded):
    """A recursive reader's refusal for one resolved path it is rooted at, or None: refused when the
    path lies above a guarded root (the config directory or the temporary directory, each
    (root, fold, the name a refusal shows)), so its walk would pass through every session's
    records there, or, for a path holding a glob, when the glob may match a directory above one."""
    start, rest = glob_parts(path) if globbed else (os.path.realpath(path), [])
    for root, fold, name in guarded:
        at = start.lower() if fold else start
        if relation(at, root) != "above":
            continue
        names = root[len(at.rstrip("/")) + 1:].split("/")
        pattern = [part.lower() for part in rest] if fold else rest
        # The start itself, with no glob, or each directory between it and the root the glob may match.
        if not rest or any(all(left == "**" for left in remainder)
                           for k in range(1, len(names)) for remainder in reaches(pattern, names[:k])):
            return (f"a Bash command reading {word} recursively would reach every session's records under {name}; "
                    "name a narrower path.")
    return None


def options(args, shorts, valued, longs):
    """A command's words after its name read as getopt_long reads them, operands anywhere: its
    options, each as (its name, its value or None), and its operands, every word after a -- among
    them; shorts and valued are the short and long options that take a value, longs every long one."""
    found, operands, k = [], [], 0
    while k < len(args):
        word, k = args[k], k + 1
        if word == "--":
            operands += args[k:]
            break
        if word.startswith("--"):
            name, eq, value = word[2:].partition("=")
            named = long_options(name, longs)
            name = next(iter(named)) if len(named) == 1 else name
            if name in valued and not eq and k < len(args):
                value, k = args[k], k + 1
            found.append((name, value if eq or name in valued else None))
        elif word.startswith("-") and word != "-":
            flags, flag, joined = short_cluster(word, shorts)
            found += [(f, None) for f in flags]
            if flag:
                if not joined and k < len(args):
                    joined, k = args[k], k + 1
                found.append((flag, joined))
        else:
            operands.append(word)
    return found, operands


def searched(found, operands, patterns):
    """The paths a search reads, past its pattern: every operand when an option in patterns gave it
    one, else all but its first; its working directory, ".", with none."""
    paths = operands if any(name in patterns for name, _ in found) else operands[1:]
    return paths or ["."]


def recursive_roots(command):
    """The words a recursive reader is rooted at, of one walked command: grep's paths with -r, -R or
    -d recurse, rg's and find's (each "." with none), every word of tar's and the directory of its
    -C<dir>, and the sources of cp's with -r, -R or -a and of rsync's (every operand but the last,
    the destination, unless cp's -t names it), each as (the word shown, the word read); [] for any
    other command. A word of the form <name>=<value> gives its value too."""
    if not command.words:
        return []
    name, args = command_name(command.words[0]), list(command.words[1:])
    pairs = []
    if name == "grep":
        found, operands = options(args, GREP_SHORTS, GREP_VALUED, GREP_LONGS)
        if not any(option in ("r", "R", "recursive", "dereference-recursive")
                   or (option in ("d", "directories") and value == "recurse") for option, value in found):
            return []
        roots = searched(found, operands, ("e", "f", "regexp", "file"))
    elif name == "rg":
        found, operands = options(args, RG_SHORTS, RG_VALUED, RG_LONGS)
        roots = searched(found, operands, ("e", "f", "regexp", "file", "files", "type-list"))
    elif name == "find":
        roots = [path for path in find_paths(args) if path != "{}"] or ["."]
    elif name == "tar":
        roots = args
        for word in args:
            if word.startswith("-") and not word.startswith("--"):
                _, flag, joined = short_cluster(word, TAR_SHORTS)
                if flag == "C" and joined:
                    pairs.append((word, joined))
    elif name in ("cp", "rsync"):
        cp = name == "cp"
        found, operands = options(args, *((CP_SHORTS, CP_VALUED, CP_LONGS) if cp else
                                          (RSYNC_SHORTS, RSYNC_VALUED, RSYNC_LONGS)))
        names = {option for option, _ in found}
        if cp and not names & {"r", "R", "a", "recursive", "archive"}:
            return []
        targeted = cp and names & {"t", "target-directory"}
        roots = operands if targeted or len(operands) < 2 else operands[:-1]
    else:
        return []
    for word in roots:
        pairs.append((word, word))
        if VALUED.match(word):
            pairs.append((word, word.partition("=")[2]))
    return pairs


def logins(word):
    """The word with a leading ~login read as that login's home directory, as Bash reads it, when
    the login is one; else as it stands."""
    match = LOGIN.match(word)
    if not match:
        return word
    try:
        return pwd.getpwnam(match.group(1)).pw_dir + word[match.end():]
    except KeyError:
        return word


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


def decide_bash(call, env, table, config, guarded):
    """A Bash call's refusal, or None: the first path, in the walk's order, one of its commands
    names (bash_words, then each redirection's target) that a place refuses (judge_bash), or a
    recursive reader is rooted at above a guarded root (recursive_roots, judge_recursive)."""
    tool_input = call.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str):
        return UNREADABLE
    context = Context(call, env)
    # A word holding a blank is no path but where a root holds one or the path it names exists: a
    # longer string that mentions a path (a message, a pattern) passes.
    blanks = any(re.search(r"\s", place.root) for place in table)
    seen = set()
    pairs = []
    for found in call_commands(command):
        pairs += [(shown, word, False) for shown, word in bash_words(found)]
        pairs += [(shown, word, True) for shown, word in recursive_roots(found)]
    pairs += [(target, target, False) for target in redirection_targets(command)]
    for shown, word, recursive in pairs:
        if not word or (shown, word, recursive) in seen:
            continue
        seen.add((shown, word, recursive))
        blank = bool(re.search(r"\s", word)) and not blanks
        try:
            # A word the walk decoded ($'...') or range-expanded is read as Bash made it.
            paths = [path for path in expand(logins(str(word)), context) if path]
            for path in paths:
                bases = [""] if path.startswith("/") else [base.path for base in reachable(context)]
                for base in bases:
                    joined = os.path.join(base, path)
                    if blank and not os.path.lexists(os.path.realpath(joined)):
                        found = None
                    elif recursive:
                        found = judge_recursive(joined, shown, bool(GLOB.search(path)) and not blank, guarded)
                    elif GLOB.search(path) and not blank:
                        found = judge_glob(joined, shown, table, config)
                    else:
                        found = judge_bash(os.path.realpath(joined), shown, table, config)
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
        config = (config.lower() if fold else config, fold)
        temp = next(place for place in table if place.name == place.root)
        # The roots a recursive reader may not be rooted above, each as judge_recursive takes it.
        guarded = [config + (table[0].name,), (temp.root.lower() if temp.fold else temp.root, temp.fold, temp.name)]
        return decide_bash(call, env, table, config, guarded)
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
