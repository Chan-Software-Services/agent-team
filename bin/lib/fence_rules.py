#!/usr/bin/env python3
"""lease-fence's reader: which of the commands the fence holds a Bash call runs.

Usage: python3 -I fence_rules.py   (the hook's input JSON on stdin)

bin/hooks/lease-fence runs this file once per Bash call it does not pass at once, and decides by
the lines it prints: one class per line, each once, in CLASSES' order, for each class of command
the call runs, and nothing when it runs none. It reads tool_input.command from the hook's input
and walks each simple command the call runs, as command_text.call_commands yields them, the walk
bin/lib/command_rules.py reads for command-guard: past the wrappers (env, command, nohup, time,
timeout, xargs and the rest), into the strings a shell's -c, eval and find -exec run, what is
piped into a shell, a substitution, a group, a function's body and a script the call writes and
runs. So a command is read where the call runs it, never where the call only names it: in a
heredoc's body no shell reads, a quoted argument, a commit message or a search pattern.
A command's name is its first word's basename, its quotes removed, so a path or a quoted name is
the name; and, as command_text.heads reads them, a word past a wrapper's options that the walk
took as an option's value may be the name too.
A command behind command -v or -V is only looked up, and is in no class.
The classes:
  push: git with push as its first word past git's own options, those that take a value (-C, -c,
    --git-dir, --work-tree, --namespace, --super-prefix, --config-env, --attr-source)
    with it; and so read from any later word of a command, which may run it (strace -f git
    push, ssh host git push, op run -- git push, $(echo git push)), so an unquoted mention is a
    push too (echo then git push >> notes.md), and a quoted one, one word, is none.
  gh: gh or gh-axi.
  team_write: team-merge, team-catch-up, team-open or team-close.
  assistant_write: team-assistant or team-current.
  post: team-post, team-ask or team-inbox.
  answer: team-answer.
  wait: team-thread with wait as its first word.
  ci_wait: team-ci-wait or team-ci-run.
Where eval is given a substitution, whose output it runs (eval "$(cat <<EOF ... EOF)"), each line
of that word is read as a command too, a heredoc's body lines among them, once: an eval in such a
line is not read again, since the walk yields an eval nested in a substitution as a command of
its own.
It exits 0 with what it found. Any error of its own exits 1 with one line on stderr,
"fence_rules.py: <ErrorType>: <message>", so the hook refuses: a guard that cannot decide refuses.
Not seen: what command_text.commands does not walk (its header lists it: a name built by a
substitution or held in a variable, ssh's remote command, a string another interpreter runs, as
python3 -c or node -e does, a script written by an earlier call), a function, alias or script of
one's own that runs one, and a git alias for push. So a held command in one quoted word that
something else runs passes: c='git push origin'; $c, eval "$c", git rebase -x 'git push origin',
python3 -c 'os.system("git push origin")', ssh host 'git push'; and gh behind a command the walk
knows as no wrapper (strace gh pr view 6).
"""

import json
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from command_text import call_commands, command_name, heads  # noqa: E402

# git's own options whose value is the next word.
GIT_VALUED = frozenset("-C -c --git-dir --work-tree --namespace --super-prefix --config-env --attr-source".split())
# The classes a command's name alone decides.
NAMED = {
    "gh": "gh",
    "gh-axi": "gh",
    "team-merge": "team_write",
    "team-catch-up": "team_write",
    "team-open": "team_write",
    "team-close": "team_write",
    "team-assistant": "assistant_write",
    "team-current": "assistant_write",
    "team-post": "post",
    "team-ask": "post",
    "team-inbox": "post",
    "team-answer": "answer",
    "team-ci-wait": "ci_wait",
    "team-ci-run": "ci_wait",
}
CLASSES = ("push", "gh", "team_write", "assistant_write", "post", "answer", "wait", "ci_wait")


def _git_command(args):
    """git's subcommand among the words after its name: the first past its own options."""
    k = 0
    while k < len(args) and args[k].startswith("-"):
        k += 2 if args[k] in GIT_VALUED else 1
    return args[k] if k < len(args) else None


def class_of(words):
    """The class of the command whose words, from its name on, these are, or None."""
    if not words:
        return None
    name, args = command_name(words[0]), list(words[1:])
    if name == "git":
        return "push" if _git_command(args) == "push" else None
    if name == "team-thread":
        return "wait" if args[:1] == ["wait"] else None
    return NAMED.get(name)


def _looks_up(walked):
    """Whether the command only looks its name up: it stands behind command -v or -V, which
    prints where the name is found and runs nothing."""
    last = walked.wrappers[-1] if walked.wrappers else ()
    return bool(last) and command_name(last[0]) == "command" and any(
        word.startswith("-") and not word.startswith("--") and set(word) & set("vV") for word in last[1:]
    )


def _pushes_behind(words):
    """Whether a word after the command's name is git, by any path, with push as its first word
    past git's own options: a push the command may run from its arguments."""
    return any(
        command_name(word) == "git" and _git_command(list(words[k + 1 :])) == "push"
        for k, word in enumerate(words)
        if k
    )


def _found(command, line=False):
    """The set of the classes of the commands the text runs; line says the text is a line of a
    substitution whose output eval runs, an eval in which is not read again."""
    found, read = set(), set()
    for walked in call_commands(command):
        if not walked.words or _looks_up(walked):
            continue
        found.update(class_of(words) for words in heads(walked))
        if _pushes_behind(walked.words):
            found.add("push")
        if command_name(walked.words[0]) == "eval" and not line:
            # Each line of a substitution eval runs the output of, read as a command, once: the
            # walk yields an eval nested in it as a command of its own, so no line is read deeper.
            for word in walked.words[1:]:
                if ("$(" in word or "`" in word) and word not in read:
                    read.add(word)
                    for text in word.splitlines():
                        found |= _found(text, True)
    return found


def classes(command):
    """The classes of the commands the text runs, in CLASSES' order."""
    found = _found(command)
    return [name for name in CLASSES if name in found]


def main():
    if sys.argv[1:]:
        sys.stderr.write("usage: python3 -I fence_rules.py   (the hook's input JSON on stdin)\n")
        return 2
    try:
        call = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        command = call["tool_input"]["command"]
        if not isinstance(command, str):
            raise TypeError("tool_input.command is not a string")
        found = classes(command)
    except Exception as error:  # noqa: BLE001 - a guard that cannot decide refuses
        sys.stderr.write(f"fence_rules.py: {type(error).__name__}: {error}\n")
        return 1
    sys.stdout.write("".join(name + "\n" for name in found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
