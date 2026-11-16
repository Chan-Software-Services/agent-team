#!/usr/bin/env python3
r"""The facts of a diff that a review brief lists for its reviewer, read from git alone, for team-brief.

Usage: python3 -I review_facts.py tests <worktree> <base ref> <head>

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

Exit codes: 0 printed, 1 a git failure (no merge base, a bad head), with git's reason as the one
line on stderr, 2 a malformed command line.
"""
import collections
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


SUBCOMMANDS = {"tests": dropped_tests}


def main(argv):
    if len(argv) != 4 or argv[0] not in SUBCOMMANDS:
        print(f"usage: review_facts.py {{{'|'.join(SUBCOMMANDS)}}} <worktree> <base ref> <head>", file=sys.stderr)
        return 2
    subcommand, worktree, base_ref, head = argv
    try:
        facts = SUBCOMMANDS[subcommand](worktree, base_ref, head)
    except GitError as error:
        print(error, file=sys.stderr)
        return 1
    print(json.dumps(facts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
