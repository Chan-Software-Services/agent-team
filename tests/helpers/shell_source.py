"""The shell source of the tests, read far enough for the checks of it: tests/guard-paths and
tests/bound-kills import it.

Lexer(text, line_of=...).run() reads a shell file into its commands, each a Command: a list of
Words (its span, its line, its $ expansions and whether it is a redirection's target), with the
operator that ended it and the group it was read in. It reads them as the file's own shell expands
it: a single-quoted string, a quoted heredoc's body, a comment and an escaped \\$x are left as they
are; an unquoted heredoc's body is read as code, its quotes as text; a $(...) or a backtick's
commands are commands of their own, a group of their own, listed before the command they stand
in. A newline or an operator (a pipe, ;, &, &&, ||, a parenthesis) ends a command.
line_finder(text) gives the line_of function the Lexer takes; raw(text, w) a word as written;
shell_files(root) every tracked shell file under tests/ but tests/vendor/ and tests/fixtures/, by
tests/run's shell_scripts rule (.sh, .bash or .bats, or a sh or bash shebang); usage(path) a
script's header, its --help.
"""

import os
import re
import subprocess

NAME = r"(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+)"
PLAIN = re.compile(rf"^({NAME})(\[[^\]]*\])?$")
GUARDED = re.compile(rf"^({NAME})(\[[^\]]*\])?:\?")
OPERATORS = set(";&|()<>")
SHEBANG = re.compile(r"^#!.*\b(ba)?sh\b")
HEREDOC = re.compile(r"<<(-?)[ \t]*((?:'[^'\n]*'|\"[^\"\n]*\"|\\.|[^\s;&|()<>'\"\\])+)")



class Expansion:
    """A $ expansion the outer shell runs: its span in the text and its kind."""

    def __init__(self, start, end, kind, text=""):
        self.start, self.end, self.kind, self.text = start, end, kind, text


class Word:
    def __init__(self, start, line):
        self.start, self.end, self.line = start, start, line
        self.expansions = []
        self.redirect = False


class Command(list):
    """A command's Words, with the operator that ended it (|, |&, ||, &&, ;, &, ( or ), a newline,
    or None at the end of its group's text) and its group: the text, $(...) or backtick it was
    read in, the same object for each command of one."""

    def __init__(self, group):
        super().__init__()
        self.group, self.ended = group, None


class Lexer:
    """Reads shell text into commands, each a list of words, far enough for the forms above."""

    def __init__(self, text, base=0, line_of=None, heredoc=False):
        self.text, self.base, self.heredoc = text, base, heredoc
        self.line_of = line_of
        self.commands = []
        self.pending = []
        self.i = 0

    def run(self):
        self.code(None)
        return self.commands

    def at(self, k=0):
        j = self.i + k
        return self.text[j] if j < len(self.text) else ""

    def code(self, stop):
        """Reads commands until the stop character (")" or "`") at depth 0, or the text's end."""
        group = object()
        words, depth, redirect = Command(group), 0, False

        def end(operator=None):
            nonlocal words
            if words:
                words.ended = operator
                self.commands.append(words)
            words = Command(group)

        while self.i < len(self.text):
            c = self.at()
            if c in " \t":
                self.i += 1
            elif c == "\\" and self.at(1) == "\n":
                self.i += 2
            elif c == "\n":
                self.i += 1
                end("\n")
                self.bodies()
            elif c == "#":
                while self.i < len(self.text) and self.at() != "\n":
                    self.i += 1
            elif stop == "`" and c == "`":
                self.i += 1
                break
            elif c == ")" and stop == ")" and depth == 0:
                self.i += 1
                break
            elif c in OPERATORS:
                if c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                if c == "<" and self.text.startswith("<<", self.i) and not self.text.startswith("<<<", self.i):
                    m = HEREDOC.match(self.text, self.i)
                    if m:
                        marker = m.group(2)
                        quoted = any(q in marker for q in "'\"\\")
                        self.pending.append((re.sub(r"['\"\\]", "", marker), m.group(1) == "-", quoted))
                        self.i = m.end()
                        continue
                if c in "<>" and self.at(1) == "(":
                    self.i += 1
                    redirect = False
                    continue
                if c in "<>":
                    redirect = True
                    while self.at() in ("<", ">", "&", "|") and self.at():
                        self.i += 1
                    continue
                operator = self.text[self.i:self.i + 2]
                operator = operator if operator in ("|&", "||", "&&") else c
                self.i += len(operator)
                redirect = False
                end(operator)
            else:
                w = self.word()
                w.redirect = redirect
                redirect = False
                words.append(w)
        end()

    def bodies(self):
        """Reads the bodies of the heredocs opened on the line just ended."""
        pending, self.pending = self.pending, []
        for marker, tabs, quoted in pending:
            start = self.i
            while self.i < len(self.text):
                eol = self.text.find("\n", self.i)
                eol = len(self.text) if eol < 0 else eol
                line = self.text[self.i:eol]
                if (line.lstrip("\t") if tabs else line) == marker:
                    body_end = self.i
                    self.i = min(eol + 1, len(self.text))
                    break
                self.i = eol + 1
            else:
                body_end = len(self.text)
            if not quoted:
                sub = Lexer(self.text[start:body_end], self.base + start, self.line_of, heredoc=True)
                self.commands.extend(sub.run())

    def word(self):
        w = Word(self.base + self.i, self.line_of(self.base + self.i))
        while self.i < len(self.text):
            c = self.at()
            if c in " \t\n" or c in OPERATORS:
                break
            if c == "\\":
                self.i += 2
            elif c == "'" and not self.heredoc:
                close = self.text.find("'", self.i + 1)
                self.i = len(self.text) if close < 0 else close + 1
            elif c == '"':
                self.i += 1
                self.double(w)
            elif c == "$":
                self.dollar(w)
            elif c == "`":
                self.i += 1
                self.code("`")
            else:
                self.i += 1
        w.end = self.base + self.i
        return w

    def double(self, w):
        while self.i < len(self.text):
            c = self.at()
            if c == "\\":
                self.i += 2
            elif c == '"':
                self.i += 1
                return
            elif c == "$":
                self.dollar(w)
            elif c == "`":
                self.i += 1
                self.code("`")
            else:
                self.i += 1

    def dollar(self, w):
        start = self.i
        nxt = self.at(1)
        if self.text.startswith("$((", self.i):
            self.i += 3
            depth = 2
            while self.i < len(self.text) and depth:
                depth += {"(": 1, ")": -1}.get(self.at(), 0)
                self.i += 1
            w.expansions.append(Expansion(self.base + start, self.base + self.i, "arith"))
        elif nxt == "(":
            self.i += 2
            self.code(")")
            w.expansions.append(Expansion(self.base + start, self.base + self.i, "command"))
        elif nxt == "{":
            self.i += 2
            depth, inner, scratch = 1, self.i, Word(0, 0)
            while self.i < len(self.text) and depth:
                c = self.at()
                if c == "\\":
                    self.i += 2
                elif self.text.startswith("${", self.i):
                    depth += 1
                    self.i += 2
                elif c == "$":
                    self.dollar(scratch)
                elif c == '"':
                    self.i += 1
                    self.double(scratch)
                else:
                    depth -= c == "}"
                    self.i += 1
            body = self.text[inner:self.i - 1]
            kind = "plain" if PLAIN.match(body) else "guarded" if GUARDED.match(body) else "hand"
            w.expansions.append(Expansion(self.base + start, self.base + self.i, kind, body))
        elif re.match(r"[A-Za-z_]", nxt):
            m = re.compile(r"[A-Za-z_][A-Za-z0-9_]*").match(self.text, self.i + 1)
            self.i = m.end()
            w.expansions.append(Expansion(self.base + start, self.base + self.i, "plain", m.group()))
        elif nxt.isdigit():
            self.i += 2
            w.expansions.append(Expansion(self.base + start, self.base + self.i, "plain", nxt))
        elif nxt and nxt in "@*#?$!-":
            self.i += 2
            w.expansions.append(Expansion(self.base + start, self.base + self.i, "hand", nxt))
        elif nxt == "'":
            self.i += 2
            while self.i < len(self.text) and self.at() != "'":
                self.i += 2 if self.at() == "\\" else 1
            self.i += 1
        else:
            self.i += 1


def raw(text, w):
    return text[w.start:w.end]


def line_finder(text):
    """The line_of function of the text: the line number, from 1, of a position in it."""
    starts = [0] + [m.end() for m in re.finditer("\n", text)]

    def line_of(pos):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    return line_of


def shell_files(root):
    listed = subprocess.run(["git", "-C", root, "ls-files", "-z", "tests"], check=True,
                            capture_output=True, text=True).stdout.split("\0")
    files = []
    for path in sorted(p for p in listed if p):
        if path.startswith(("tests/vendor/", "tests/fixtures/")):
            continue
        full = os.path.join(root, path)
        if not os.path.isfile(full):
            continue
        if path.endswith((".sh", ".bash", ".bats")):
            files.append(path)
            continue
        with open(full, "rb") as f:
            first = f.readline().decode("utf-8", "replace")
        if SHEBANG.match(first):
            files.append(path)
    return [(path, os.path.join(root, path)) for path in files]


def usage(path):
    with open(path) as f:
        lines = f.read().splitlines()[1:]
    header = []
    for line in lines:
        if not line.startswith("#"):
            break
        header.append(line[2:] if line.startswith("# ") else line[1:])
    return "\n".join(header)
