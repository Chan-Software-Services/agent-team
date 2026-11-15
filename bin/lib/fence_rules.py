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
The classes:
  push: git with push as its first word past git's own options, those that take a value (-C, -c,
    --git-dir, --work-tree, --namespace, --super-prefix, --config-env, --attr-source)
    with it.
  gh: gh or gh-axi.
  team_write: team-merge, team-catch-up, team-open or team-close.
  assistant_write: team-assistant or team-current.
  post: team-post, team-ask or team-inbox.
  answer: team-answer.
  wait: team-thread with wait as its first word.
  ci_wait: team-ci-wait or team-ci-run.
It exits 0 with what it found. Any error of its own exits 1 with one line on stderr,
"fence_rules.py: <ErrorType>: <message>", so the hook refuses: a guard that cannot decide refuses.
Not seen: what command_text.commands does not walk (its header lists it: a name built by a
substitution or held in a variable, ssh's remote command, a string another interpreter runs, as
python3 -c or node -e does, a script written by an earlier call), a function, alias or script of
one's own that runs one, and a git alias for push.
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


def classes(command):
    """The classes of the commands the text runs, in CLASSES' order."""
    found = {class_of(words) for walked in call_commands(command) for words in heads(walked)}
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
