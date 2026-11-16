#!/usr/bin/env python3
"""Runs a command where the kernel refuses a delete or a rename outside its roots.

Usage: python3 -I confine.py [--root <dir>]... [--session] -- <command> [args...]
       python3 -I confine.py --abi

  --root <dir>   a directory under which removing and renaming stay allowed; one that is no
                 directory is refused (exit 3)
  --session      add the roots of a worker's or gate agent's session (below)
  --abi          print the kernel's Landlock ABI version, 0 when it has none, and exit

It enters a Landlock domain and then runs the command in its place, so the command, and every
process it starts, removes or renames a directory entry only under a root: the kernel refuses
the unlink, rmdir or rename itself, with EACCES or EXDEV, whatever program asks and however the command was spelled. Nothing here reads the command.
The handled rights are REMOVE_DIR, REMOVE_FILE and REFER only, so reads, writes, creates and
truncations are as before everywhere. REFER is allowed beneath / and all three beneath each root,
so a rename out of a directory outside the roots is refused, into a root too, since it removes
the outside entry, and so is a rename onto an existing entry outside them.
Not held: a broker outside the domain (systemd-run --user, the Docker daemon, ssh), overwriting
or truncating a file's contents, whatever the command does inside its roots, and signals.
The domain sets no_new_privs, so a setuid program (sudo) gains nothing inside it, and it can
never be left: a confined command that runs this wrapper again only narrows its own roots.

--session's roots, each only when it is a directory, each resolved through its links:
  - the session's worktree: AGENT_TEAM_WORKTREE when it names a directory, else
    CLAUDE_PROJECT_DIR, never the working directory, so a cd into another repository roots
    nothing there. With neither, it exits 3 and the command does not run:
    "confine: no worktree for this session (AGENT_TEAM_WORKTREE and CLAUDE_PROJECT_DIR name no
    directory)";
  - that worktree's common git directory, AGENT_TEAM_GIT_DIR, which team-worker fixes at the
    launch, without which git could not remove its own index.lock in a linked worktree; none
    when it is unset, since nothing the session's commands may rewrite is asked for it. One
    that is not an absolute path, is a link or no directory, or is, holds or is under a
    directory no root may be in (below) is refused (exit 3);
  - $CLAUDE_JOB_DIR/tmp, when it is there; one that is a link, no directory or another user's
    is refused (exit 3);
  - the session tmp: /tmp/agent-team-<AGENT_TEAM_TASK> when that is T<digits>, else
    /tmp/agent-team-gate-<the first 8 characters of CLAUDE_CODE_SESSION_ID> when that holds only
    letters, digits and dashes, else none. It is made, mode 700, when missing, and the command
    gets it as TMPDIR; one that is a link, no directory or another user's is refused (exit 3);
  - each line of the file confine-roots beside this one, a path that may start with ~/. A line
    naming nothing is skipped. A line that is not an absolute path, that names a link or
    anything but a directory, or that is, holds or is under the team home (TEAM_HOME, else the
    first line of ~/.config/agent-team/home), ~/.config/agent-team or ~/.claude, is refused
    (exit 3) naming it, and so is a file that cannot be read.

Where the kernel has no Landlock, or only ABI 1 (no REFER), and on macOS, the command runs
unconfined, and stderr says so: "confine: this machine has no Landlock (ABI <n>), so this
command runs unconfined; the text guard alone holds it", once per session tmp (the marker file
.confine-unconfined in it), and every time when there is no session tmp.
Any other failure to set up the domain (a rule that cannot be added, no_new_privs, entering the
domain) exits 3 with "confine: <what failed>: <the error>" and never runs the command.

Exit status: the command's own; 2 for a malformed command line; 3 when the domain or a root
could not be set up; 127 when the command is not found and 126 when it cannot be run.

It has no test seam: nothing in its environment changes the ABI it reads or how it enters the
domain. The tests run it through tests/helpers/confine-seams.py, which loads this file and
replaces those two reads.
"""
import ctypes
import errno
import os
import re
import stat
import sys

# landlock_create_ruleset, landlock_add_rule and landlock_restrict_self, the same numbers on
# x86_64 and arm64.
SYS_CREATE, SYS_ADD_RULE, SYS_RESTRICT = 444, 445, 446
CREATE_VERSION = 1
RULE_PATH_BENEATH = 1
REMOVE_DIR, REMOVE_FILE, REFER = 1 << 4, 1 << 5, 1 << 13
REMOVE = REMOVE_DIR | REMOVE_FILE | REFER
PR_SET_NO_NEW_PRIVS = 38
NEEDED_ABI = 2  # REFER's
MARKER = ".confine-unconfined"
NO_WORKTREE = ("no worktree for this session (AGENT_TEAM_WORKTREE and CLAUDE_PROJECT_DIR name no "
               "directory)")


class RulesetAttr(ctypes.Structure):
    _fields_ = [("handled_access_fs", ctypes.c_uint64)]


class PathBeneath(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("allowed_access", ctypes.c_uint64), ("parent_fd", ctypes.c_int32)]


class Refused(Exception):
    """The domain or a root could not be set up: the command must not run."""


def _libc():
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    return libc


def _error():
    return os.strerror(ctypes.get_errno())


def abi():
    """The kernel's Landlock ABI version, 0 with none or off Linux."""
    if not sys.platform.startswith("linux"):
        return 0
    version = _libc().syscall(SYS_CREATE, None, ctypes.c_size_t(0), ctypes.c_uint32(CREATE_VERSION))
    return max(version, 0)


def _within(path, directory):
    return path == directory or path.startswith(directory.rstrip("/") + "/")


def _home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def _team_home():
    """The team home as the scripts find it, or None when nothing names one."""
    named = os.environ.get("TEAM_HOME", "")
    if not named:
        try:
            with open(os.path.join(_home(), ".config/agent-team/home"), encoding="utf-8") as file:
                named = file.readline().strip()
        except (OSError, UnicodeDecodeError):
            return None
    return os.path.join(_home(), named) if named else None


def _kept():
    """The directories no root may be, hold or be under, resolved."""
    return [os.path.realpath(directory) for directory in
            (_team_home(), os.path.join(_home(), ".config/agent-team"), os.path.join(_home(), ".claude"))
            if directory]


def _own_directory(path):
    """Whether path is there; Refused when it is a link, no directory or another user's."""
    try:
        found = os.lstat(path)
    except FileNotFoundError:
        return False
    except OSError as error:
        raise Refused(f"cannot read {path}: {error.strerror}") from error
    if not stat.S_ISDIR(found.st_mode) or found.st_uid != os.geteuid():
        raise Refused(f"{path} is a link, no directory or another user's, so it is no root")
    return True


def _listed_roots():
    """The directories confine-roots lists, resolved; Refused on a line that may never be one."""
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "confine-roots")
    try:
        with open(path, encoding="utf-8") as file:
            lines = file.read().splitlines()
    except (OSError, UnicodeDecodeError) as error:
        raise Refused(f"cannot read {path}: {error}") from error
    kept = _kept()
    roots = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        named = os.path.join(_home(), line[2:]) if line.startswith("~/") else line
        if not os.path.isabs(named):
            raise Refused(f"{path} lists {line}, which is not an absolute path")
        root = os.path.realpath(named)
        for directory in kept:
            if _within(root, directory) or _within(directory, root):
                raise Refused(f"{path} lists {line}, which is, holds or is under {directory}; "
                              "no path of the team home, ~/.config/agent-team or ~/.claude is a root")
        if _own_directory(named.rstrip("/") or "/"):
            roots.append(root)
    return roots


def _worktree():
    for name in ("AGENT_TEAM_WORKTREE", "CLAUDE_PROJECT_DIR"):
        named = os.environ.get(name, "")
        if named and os.path.isdir(named):
            return os.path.realpath(named)
    raise Refused(NO_WORKTREE)


def _git_common():
    """The common git directory team-worker fixed at the launch, or None when none is named."""
    named = os.environ.get("AGENT_TEAM_GIT_DIR", "")
    if not named:
        return None
    if not os.path.isabs(named):
        raise Refused(f"AGENT_TEAM_GIT_DIR names {named}, which is not an absolute path")
    if not _own_directory(named.rstrip("/") or "/"):
        raise Refused(f"AGENT_TEAM_GIT_DIR names {named}, which is no directory")
    root = os.path.realpath(named)
    for directory in _kept():
        if _within(root, directory) or _within(directory, root):
            raise Refused(f"AGENT_TEAM_GIT_DIR names {named}, which is, holds or is under {directory}; "
                          "no path of the team home, ~/.config/agent-team or ~/.claude is a root")
    return root


def _session_tmp():
    """The session tmp, made when missing, or None when the session names none."""
    task = os.environ.get("AGENT_TEAM_TASK", "")
    session = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if re.fullmatch(r"T[0-9]+", task, re.ASCII):
        path = f"/tmp/agent-team-{task}"
    elif re.fullmatch(r"[A-Za-z0-9-]+", session):
        path = f"/tmp/agent-team-gate-{session[:8]}"
    else:
        return None
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    except OSError as error:
        raise Refused(f"cannot make the session tmp {path}: {error.strerror}") from error
    try:
        found = os.lstat(path)
    except OSError as error:
        raise Refused(f"cannot read the session tmp {path}: {error.strerror}") from error
    if not stat.S_ISDIR(found.st_mode) or found.st_uid != os.geteuid():
        raise Refused(f"the session tmp {path} is a link, no directory or another user's")
    return path


def session_roots():
    """A session's roots and its session tmp (or None)."""
    worktree = _worktree()
    tmp = _session_tmp()
    job = os.environ.get("CLAUDE_JOB_DIR", "")
    job = os.path.join(job, "tmp") if job else None
    if job and not _own_directory(job):
        job = None
    roots = [os.path.realpath(root) for root in (worktree, _git_common(), job, tmp) if root]
    return roots + _listed_roots(), tmp


def _unconfined_notice(version, tmp):
    if tmp:
        try:
            os.close(os.open(os.path.join(tmp, MARKER), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        except FileExistsError:
            return
        except OSError:
            pass
    print(f"confine: this machine has no Landlock (ABI {version}), so this command runs unconfined; "
          "the text guard alone holds it", file=sys.stderr)


def _allow(libc, ruleset, path, access):
    try:
        fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
    except OSError as error:
        raise Refused(f"cannot add a rule for {path}: {error.strerror}") from error
    rule = PathBeneath(access, fd)
    if libc.syscall(SYS_ADD_RULE, ctypes.c_int(ruleset), ctypes.c_int(RULE_PATH_BENEATH),
                    ctypes.byref(rule), ctypes.c_uint32(0)) != 0:
        raise Refused(f"cannot add a rule for {path}: {_error()}")
    os.close(fd)


def enter(roots):
    """Enters the domain: from here this process removes and renames only under the roots."""
    libc = _libc()
    attr = RulesetAttr(REMOVE)
    ruleset = libc.syscall(SYS_CREATE, ctypes.byref(attr), ctypes.c_size_t(ctypes.sizeof(attr)),
                           ctypes.c_uint32(0))
    if ruleset < 0:
        raise Refused(f"cannot create the ruleset: {_error()}")
    _allow(libc, ruleset, "/", REFER)
    for root in roots:
        _allow(libc, ruleset, root, REMOVE)
    if libc.prctl(ctypes.c_int(PR_SET_NO_NEW_PRIVS), ctypes.c_ulong(1), ctypes.c_ulong(0),
                  ctypes.c_ulong(0), ctypes.c_ulong(0)) != 0:
        raise Refused(f"cannot set no_new_privs: {_error()}")
    if libc.syscall(SYS_RESTRICT, ctypes.c_int(ruleset), ctypes.c_uint32(0)) != 0:
        raise Refused(f"cannot enter the domain: {_error()}")
    os.close(ruleset)


def _usage():
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


def main(argv):
    roots, session = [], False
    while argv and argv[0] != "--":
        word = argv.pop(0)
        if word == "--help":
            print(__doc__, end="")
            return 0
        if word == "--abi":
            print(abi())
            return 0
        if word == "--session":
            session = True
        elif word == "--root" and argv:
            roots.append(argv.pop(0))
        else:
            return _usage()
    command = argv[1:]
    if not command:
        return _usage()
    try:
        for root in roots:
            if not os.path.isdir(root):
                raise Refused(f"--root names no directory: {root}")
        roots = [os.path.realpath(root) for root in roots]
        tmp = None
        if session:
            found, tmp = session_roots()
            roots += found
            if tmp:
                os.environ["TMPDIR"] = tmp
        version = abi()
        if version < NEEDED_ABI:
            _unconfined_notice(version, tmp)
        else:
            enter(roots)
    except Refused as refused:
        print(f"confine: {refused}", file=sys.stderr)
        return 3
    try:
        os.execvp(command[0], command)
    except OSError as error:
        print(f"confine: cannot run {command[0]}: {error.strerror}", file=sys.stderr)
        return 127 if error.errno == errno.ENOENT else 126


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
