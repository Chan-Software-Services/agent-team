#!/usr/bin/env python3
r"""The facts of a diff that a review brief lists for its reviewer, read from git alone, for team-brief.

Usage: python3 -I review_facts.py tests <worktree> <base ref> <head>
       python3 -I review_facts.py dependencies <worktree> <base ref> <head> <spec path>

Every subcommand reads the diff team-brief's reviewer reads, git diff <base ref>...<head> in
<worktree>, and each file's text at the merge base and at the head with git cat-file, never the
working tree; it prints one JSON list on stdout.

tests: the tests the diff drops. A test file is a changed path (git diff --name-status -M, a
rename by both names) with a directory segment test, tests, __tests__, spec or e2e, a name ending
.bats, a name matching [._-](test|spec).[cm]?[jt]sx?, test_*.py, *_test.py or *_test.go. Its
language is its extension's: .bats is bats; .js, .jsx, .ts, .tsx and their .c and .m forms are
JavaScript and TypeScript; .py is Python; .go is Go; a test file of any other extension has no
declarations or markers to read. A test is declared by a line matching, by language:
  bats        ^\s*@test\s+(["'])(.+)\1, the name the quoted text;
  JavaScript  ^\s*(it|test)(\.(only|skip|todo|concurrent|each\(.*?\)))?\s*\(\s*(["'`])(.+?)\4,
              the name the quoted text;
  Python      ^\s*(async\s+)?def\s+(test\w*)\s*\(, the name the function's;
  Go          ^func\s+((Test|Fuzz)\w*)\s*\(, the name the function's.
A test is removed when its name, declared in a changed test file's base text, is declared in no
changed test file's head text, so a test moved between files is not listed and a renamed one is;
one whose file the diff deletes is removed with its file. Skip and focus markers are counted in
each changed test file, head against base, by its language:
  skip   JavaScript \b(it|test|describe)\.(skip|todo)\s*\( and \bx(it|test|describe)\s*\(;
         Python @pytest\.mark\.(skip|skipif|xfail)\b and
         @unittest\.(skip|skipIf|skipUnless|expectedFailure)\b; Go \bt\.Skip(Now|f)?\s*\(;
         bats a line ^\s*skip(\s|$);
  focus  JavaScript \b(it|test|describe)\.only\s*\( and \bf(it|describe)\s*\(.
Each item is an object with the file's path (a rename's new one, a deletion's old one) and its
kind, in the order of the paths, then within a file its removed tests in their base order, its
skip markers, its focus markers:
  {"file", "kind": "removed", "name"}            a test gone from every changed test file
  {"file", "kind": "removed-with-file", "name"}  a test of a file the diff deletes
  {"file", "kind": "skip" | "focus", "more", "first"}
                                                 more such markers at the head than at the base,
                                                 and the first one at the head beyond the base's
                                                 count of its text, as matched, blanks trimmed
  {"file", "kind": "unreadable", "at"}           a file whose text cannot be read (not a blob,
                                                 or not UTF-8) at the commit "at", the first 8
                                                 characters of its sha, listed instead of its tests

dependencies: the direct dependencies the diff adds or changes. A manifest is a changed path
(a rename's base text at its old name, an added or copied file's base empty, a deleted one not
read) whose name is package.json, requirements*.txt or go.mod, in any directory; lock files and
other formats are not read. Each is read at the merge base and at the head:
  package.json      the names and version specs of dependencies, devDependencies,
                    peerDependencies and optionalDependencies, in that order; a name in none of
                    them at the base is added, one whose spec is none of its base specs changed
                    (from its base spec in the same section, else its first), so a move between
                    sections with the same spec is not listed;
  requirements*.txt each line less its comment (a # at its start or after a blank), blank lines
                    and option lines (one starting with -, but -e and --editable) skipped; an -e,
                    --editable or URL (holding ://) line is listed whole, keyed by its name when it
                    is "<name> @ <url>", else by the line; any other line is the name its leading
                    [A-Za-z0-9][A-Za-z0-9._-]*, extras dropped, normalized as PEP 503 says
                    (lowercase, each run of -, _ and . one -), and its spec the rest, trimmed;
  go.mod            each require line, single or in a require block, but one marked // indirect,
                    its module path and version.
Each dependency is named when <spec path>'s text holds its name (for a requirements line also its
name as written) case-insensitively as a whole word, or, for a name with / or @, as fixed text;
when <spec path> is no file, its named is null. Each item is an object with the manifest's path
and its kind, in the order of the paths, then within a manifest in its head order:
  {"file", "kind": "added", "name", "version", "section", "line", "named"}
  {"file", "kind": "changed", "name", "from", "version", "section", "line", "named"}
                                    section is package.json's, else null; line is true for a
                                    requirements line listed whole, whose name is the head's line
                                    and from the base's; version or from is "" with none
  {"file", "kind": "unreadable", "at"}
                                    a manifest whose text cannot be read (not a blob, not UTF-8,
                                    or a package.json that is not a JSON object) at the commit
                                    "at", the first 8 characters of its sha

Exit codes: 0 printed, 1 a git failure (no merge base, a bad head), with git's reason as the one
line on stderr, 2 a malformed command line.
"""
import collections
import fnmatch
import json
import os
import re
import subprocess
import sys


class GitError(Exception):
    """A git command that failed, with the first line of what it said."""


def git(worktree, *args):
    """The bytes git prints for args in worktree, or GitError with its first line of stderr."""
    done = subprocess.run(
        ["git", "-C", worktree, "-c", "core.quotePath=false", *args],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
    )
    if done.returncode != 0:
        said = done.stderr.decode("utf-8", "replace").strip().splitlines()
        raise GitError(said[0] if said else f"git {args[0]} failed with exit {done.returncode}")
    return done.stdout


def changed_paths(worktree, base_ref, head):
    """The merge base's sha, and each changed path as (status letter, old path, new path)."""
    # The diff first: with no merge base, git diff names the reason, where git merge-base says none.
    listing = git(
        worktree, "diff", "--name-status", "-M", "-z", "--no-relative", "--no-ext-diff", "--no-textconv",
        f"{base_ref}...{head}",
    )
    merge_base = git(worktree, "merge-base", base_ref, head).decode().strip()
    fields = listing.decode("utf-8", "surrogateescape").split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    changes, i = [], 0
    while i < len(fields):
        status = fields[i][:1]
        if status in "RC":
            changes.append((status, fields[i + 1], fields[i + 2]))
            i += 3
        else:
            changes.append((status, fields[i + 1], fields[i + 1]))
            i += 2
    return merge_base, changes


def text_at(worktree, rev, path):
    """The file's text at rev, or None when it is no blob there or is not UTF-8."""
    try:
        data = git(worktree, "cat-file", "blob", f"{rev}:{path}")
    except GitError:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


TEST_PATH = re.compile(
    r"(^|/)(test|tests|__tests__|spec|e2e)/"
    r"|\.bats$"
    r"|[._-](test|spec)\.[cm]?[jt]sx?$"
    r"|(^|/)test_[^/]*\.py$"
    r"|_test\.py$"
    r"|_test\.go$"
)


def language(path):
    """The language whose declarations and markers a test file holds, or None."""
    if path.endswith(".bats"):
        return "bats"
    if re.search(r"\.[cm]?[jt]sx?$", path):
        return "js"
    if path.endswith(".py"):
        return "python"
    if path.endswith(".go"):
        return "go"
    return None


DECLARATIONS = {
    "bats": (re.compile(r"""^\s*@test\s+(["'])(.+)\1"""), 2),
    "js": (re.compile(r"""^\s*(it|test)(\.(only|skip|todo|concurrent|each\(.*?\)))?\s*\(\s*(["'`])(.+?)\4"""), 5),
    "python": (re.compile(r"^\s*(async\s+)?def\s+(test\w*)\s*\("), 2),
    "go": (re.compile(r"^func\s+((Test|Fuzz)\w*)\s*\("), 1),
}

MARKERS = {
    "skip": {
        "js": [re.compile(r"\b(it|test|describe)\.(skip|todo)\s*\("), re.compile(r"\bx(it|test|describe)\s*\(")],
        "python": [
            re.compile(r"@pytest\.mark\.(skip|skipif|xfail)\b"),
            re.compile(r"@unittest\.(skip|skipIf|skipUnless|expectedFailure)\b"),
        ],
        "go": [re.compile(r"\bt\.Skip(Now|f)?\s*\(")],
        "bats": [re.compile(r"^\s*skip(\s|$)")],
    },
    "focus": {
        "js": [re.compile(r"\b(it|test|describe)\.only\s*\("), re.compile(r"\bf(it|describe)\s*\(")],
    },
}


def declared(lang, text):
    """The names of the tests text declares, in order, each once."""
    pattern, group = DECLARATIONS[lang]
    names = []
    for line in text.splitlines():
        match = pattern.match(line)
        if match and match.group(group) not in names:
            names.append(match.group(group))
    return names


def markers(kind, lang, text):
    """The markers of kind in text, in the order they appear, each as matched, blanks trimmed."""
    patterns = MARKERS[kind].get(lang, [])
    found = []
    for number, line in enumerate(text.splitlines()):
        for pattern in patterns:
            for match in pattern.finditer(line):
                found.append((number, match.start(), match.group(0).strip()))
    return [marker for _, _, marker in sorted(found)]


def dropped_tests(worktree, base_ref, head):
    merge_base, changes = changed_paths(worktree, base_ref, head)
    head_sha = git(worktree, "rev-parse", "--verify", f"{head}^{{commit}}").decode().strip()
    files = []
    for status, old, new in changes:
        if not (TEST_PATH.search(old) or TEST_PATH.search(new)):
            continue
        lang = language(new)
        if lang is None:
            continue
        # A copy leaves its old path as it was, so its base text is none; an added file has none.
        base = text_at(worktree, merge_base, old) if status not in "AC" else ""
        after = text_at(worktree, head_sha, new) if status != "D" else ""
        files.append({"status": status, "path": old if status == "D" else new, "lang": lang,
                      "base": base, "head": after})
    still = set()
    for file in files:
        if file["head"] is not None:
            still.update(declared(file["lang"], file["head"]))
    items = []
    for file in files:
        path = file["path"]
        if file["base"] is None or file["head"] is None:
            at = merge_base if file["base"] is None else head_sha
            items.append({"file": path, "kind": "unreadable", "at": at[:8]})
            continue
        kind = "removed-with-file" if file["status"] == "D" else "removed"
        for name in declared(file["lang"], file["base"]):
            if name not in still:
                items.append({"file": path, "kind": kind, "name": name})
        for marker in ("skip", "focus"):
            before = collections.Counter(markers(marker, file["lang"], file["base"]))
            now = markers(marker, file["lang"], file["head"])
            more = len(now) - sum(before.values())
            if more <= 0:
                continue
            first = None
            for found in now:
                if before[found]:
                    before[found] -= 1
                else:
                    first = found
                    break
            items.append({"file": path, "kind": marker, "more": more, "first": first})
    return items


PACKAGE_SECTIONS = ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")


class Unreadable(Exception):
    """A manifest whose text is not one its reader can read."""


def package_entries(text):
    """package.json's direct dependencies, as (name, spec, section, written, whole), in order."""
    try:
        manifest = json.loads(text) if text.strip() else {}
    except ValueError:
        raise Unreadable() from None
    if not isinstance(manifest, dict):
        raise Unreadable()
    entries = []
    for section in PACKAGE_SECTIONS:
        deps = manifest.get(section)
        if not isinstance(deps, dict):
            continue
        for name, spec in deps.items():
            entries.append((name, spec if isinstance(spec, str) else json.dumps(spec), section, name, False))
    return entries


REQUIREMENT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
DIRECT_REFERENCE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*@")


def pep503(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def requirement_entries(text):
    """requirements*.txt's lines, as (key, spec, None, written name, whole), in order."""
    entries = []
    for raw in text.splitlines():
        line = re.sub(r"(^|\s)#.*$", "", raw).strip()
        if not line:
            continue
        editable = re.match(r"(-e|--editable)\b", line)
        if line.startswith("-") and not editable:
            continue
        if editable or "://" in line:
            reference = DIRECT_REFERENCE.match(line)
            if reference:
                entries.append((pep503(reference.group(1)), line, None, reference.group(1), True))
            else:
                entries.append((line, line, None, line, True))
            continue
        name = REQUIREMENT_NAME.match(line)
        if not name:
            continue
        rest = re.sub(r"^\s*\[[^\]]*\]", "", line[name.end():]).strip()
        entries.append((pep503(name.group(0)), rest, None, name.group(0), False))
    return entries


def go_entries(text):
    """go.mod's direct requirements, as (module path, version, None, module path, False), in order."""
    entries, block = [], False
    for raw in text.splitlines():
        indirect = re.search(r"//\s*indirect\b", raw)
        line = re.sub(r"//.*$", "", raw).strip()
        if block:
            if line.startswith(")"):
                block = False
                continue
            words = line.split()
        elif re.match(r"require\s*\(", line):
            block = True
            continue
        elif re.match(r"require\s", line):
            words = line.split()[1:]
        else:
            continue
        if len(words) >= 2 and not indirect:
            entries.append((words[0], words[1], None, words[0], False))
    return entries


def manifest_reader(path):
    """The reader of a manifest at path, or None for a path that is no manifest."""
    name = path.rsplit("/", 1)[-1]
    if name == "package.json":
        return package_entries
    if fnmatch.fnmatchcase(name, "requirements*.txt"):
        return requirement_entries
    if name == "go.mod":
        return go_entries
    return None


def named_in(spec_text, names):
    """Whether spec_text holds any of names, as a whole word or, with / or @, as fixed text."""
    folded = spec_text.casefold()
    for name in names:
        if "/" in name or "@" in name:
            if name.casefold() in folded:
                return True
        elif re.search(r"(?<!\w)" + re.escape(name) + r"(?!\w)", spec_text, re.IGNORECASE):
            return True
    return False


def dependencies(worktree, base_ref, head, spec_path):
    merge_base, changes = changed_paths(worktree, base_ref, head)
    head_sha = git(worktree, "rev-parse", "--verify", f"{head}^{{commit}}").decode().strip()
    try:
        with open(spec_path, encoding="utf-8", errors="replace") as file:
            spec_text = file.read()
    except OSError:
        spec_text = None
    items = []
    for status, old, new in changes:
        read = manifest_reader(new)
        if status == "D" or read is None:
            continue
        base = text_at(worktree, merge_base, old) if status not in "AC" else ""
        after = text_at(worktree, head_sha, new)
        sides = {}
        for side, text, sha in (("base", base, merge_base), ("head", after, head_sha)):
            try:
                if text is None:
                    raise Unreadable()
                sides[side] = read(text)
            except Unreadable:
                items.append({"file": new, "kind": "unreadable", "at": sha[:8]})
                break
        if len(sides) < 2:
            continue
        before = collections.defaultdict(list)
        for key, spec, section, _, whole in sides["base"]:
            before[key].append((spec, section))
        listed = set()
        for key, spec, section, written, whole in sides["head"]:
            if key in listed:
                continue
            listed.add(key)
            olds = before.get(key)
            if olds and spec in [old_spec for old_spec, _ in olds]:
                continue
            item = {"file": new, "kind": "changed" if olds else "added",
                    "name": spec if whole else key}
            if olds:
                same = [old_spec for old_spec, old_section in olds if old_section == section]
                item["from"] = same[0] if same else olds[0][0]
            item.update({"version": "" if whole else spec, "section": section, "line": whole,
                         "named": None if spec_text is None else named_in(spec_text, {key, written})})
            items.append(item)
    return items


SUBCOMMANDS = {"tests": (dropped_tests, ()), "dependencies": (dependencies, ("<spec path>",))}


def main(argv):
    run, extra = SUBCOMMANDS.get(argv[0] if argv else None, (None, None))
    if run is None or len(argv) != 4 + len(extra):
        for name, (_, more) in SUBCOMMANDS.items():
            print(f"usage: review_facts.py {name} <worktree> <base ref> <head>{''.join(' ' + m for m in more)}",
                  file=sys.stderr)
        return 2
    try:
        facts = run(*argv[1:])
    except GitError as error:
        print(error, file=sys.stderr)
        return 1
    print(json.dumps(facts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
