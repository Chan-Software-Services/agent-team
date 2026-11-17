#!/usr/bin/env python3
"""Runs a command where the kernel refuses a delete or a rename outside its roots.

Usage: python3 -I confine.py [--root <dir>]... [--session <file>] [--shell] [--entry shell|prefix] -- <command or the shell's arguments>
       python3 -I confine.py --abi

  --root <dir>      a directory under which removing and renaming stay allowed; one that is no
                    directory is refused (exit 3)
  --session <file>  add the roots of a worker's or gate agent's session, read from its session
                    file (below), which bin/lib/confine-session wrote at the launch
  --shell           run the session file's shell, with the words after -- as its arguments;
                    a usage error without --session
  --entry <form>    set AGENT_TEAM_CONFINE_SHELL=1 (shell) or AGENT_TEAM_CONFINE_PREFIX=1 (prefix)
                    for the command, which shows the load check which form ran; never read here
  --abi             print the kernel's Landlock ABI version, 0 when it has none, and exit

It enters a Landlock domain and then runs the command in its place, so the command, and every
process it starts, removes or renames a directory entry only under a root: the kernel refuses
the unlink, rmdir or rename itself, with EACCES or EXDEV, whatever program asks and however the command was spelled. Nothing here reads the command.
The handled rights are REMOVE_DIR, REMOVE_FILE and REFER only, so reads, writes, creates and
truncations are as before everywhere. REFER is allowed beneath / and all three beneath each root,
so a rename out of a directory outside the roots is refused, into a root too, since it removes
the outside entry, and so is a rename onto an existing entry outside them.
The claim: a confined session's roots are the ones its launcher wrote, and no program of the
session's choosing runs before the domain is entered.
Not held: a broker outside the domain (systemd-run --user, the Docker daemon, ssh); overwriting
or truncating a file's contents, the session file, the session's program bash, this file and a
settings file among them, since the write rights are not handled; a session whose settings no
longer name that program; whatever the command does inside its roots; and signals.
The domain sets no_new_privs, so a setuid program (sudo) gains nothing inside it, and it can
never be left: a confined command that runs this wrapper again only narrows its own roots.

--session's roots come from the file and the file confine-roots beside this one alone: no
variable of the environment names a root, a home directory or the team home, and nothing is
asked of the worktree's own files. The file is one
JSON object, version 1, with the keys task, home, kept, worktree, git_dir, session_tmp, shell
and, once the session has an id, job_tmp. Each root is resolved through its links:
  - worktree, the session's worktree, never the working directory, so a cd into another
    repository roots nothing there;
  - git_dir, that worktree's common git directory, without which git could not remove its own
    index.lock in a linked worktree. One that is not an absolute path, is a link, no directory
    or another user's, or is, holds or is under a directory of kept is refused (exit 3);
  - job_tmp, when the file names one and it is there; one that is a link, no directory or
    another user's is refused (exit 3);
  - session_tmp, an absolute path, made, mode 700, when missing, which the command gets as
    TMPDIR; one that is a link, no directory or another user's is refused (exit 3);
  - each line of the file confine-roots beside this one, a path that may start with ~/, which
    stands for the file's home. A line naming nothing is skipped. A line that is not an absolute
    path, that names a link or anything but a directory, or that is, holds or is under a
    directory of kept (the team home, ~/.config/agent-team and ~/.claude, as the launcher
    resolved them) is refused (exit 3) naming it, and so is a roots file that cannot be read.
The session file is refused, exit 3, and nothing runs:
  "the session file <file> is a link, no regular file, another user's, or writable by group or
  others"; "cannot read the session file <file>: <error>" (no JSON among them); "the session
  file <file> is not version 1"; "the session file <file> names no <key>" for home, kept,
  worktree, git_dir, session_tmp and shell; "the session file <file> names the shell <path>,
  which is no program"; "the session file <file> names the worktree <path>, which is no
  directory".

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
import json
import os
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
SESSION_KEYS = ("home", "kept", "worktree", "git_dir", "session_tmp", "shell")
ENTRIES = {"shell": "AGENT_TEAM_CONFINE_SHELL", "prefix": "AGENT_TEAM_CONFINE_PREFIX"}


class RulesetAttr(ctypes.Structure):
    _fields_ = [("handled_access_fs", ctypes.c_uint64)]


class PathBeneath(ctypes.Structure):
    # The kernel's struct is packed, 12 bytes; unpacked it has the same two offsets and four
    # bytes of padding the kernel never reads, and no packing warning from Python 3.14.
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


def _outside_kept(root, kept, named):
    """Refused when root is, holds or is under a directory no root may be in."""
    for directory in kept:
        if _within(root, directory) or _within(directory, root):
            raise Refused(f"{named}, which is, holds or is under {directory}; "
                          "no git directory or confine-roots line may be a path of the team home, "
                          "~/.config/agent-team or ~/.claude")


def _listed_roots(home, kept):
    """The directories confine-roots lists, resolved; Refused on a line that may never be one."""
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "confine-roots")
    try:
        with open(path, encoding="utf-8") as file:
            lines = file.read().splitlines()
    except (OSError, UnicodeDecodeError) as error:
        raise Refused(f"cannot read {path}: {error}") from error
    roots = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        named = os.path.join(home, line[2:]) if line.startswith("~/") else line
        if not os.path.isabs(named):
            raise Refused(f"{path} lists {line}, which is not an absolute path")
        root = os.path.realpath(named)
        _outside_kept(root, kept, f"{path} lists {line}")
        if _own_directory(named.rstrip("/") or "/"):
            roots.append(root)
    return roots


def read_session(path):
    """The session file's object, as bin/lib/confine-session wrote it; Refused on any other."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise Refused(f"the session file {path} is a link, no regular file, another user's, "
                          "or writable by group or others") from error
        raise Refused(f"cannot read the session file {path}: {error.strerror}") from error
    try:
        found = os.fstat(fd)
        if not stat.S_ISREG(found.st_mode) or found.st_uid != os.geteuid() or found.st_mode & 0o022:
            raise Refused(f"the session file {path} is a link, no regular file, another user's, "
                          "or writable by group or others")
        try:
            session = json.loads(os.read(fd, found.st_size + 1).decode("utf-8"))
        except (OSError, ValueError) as error:
            raise Refused(f"cannot read the session file {path}: {error}") from error
    finally:
        os.close(fd)
    if not isinstance(session, dict):
        raise Refused(f"cannot read the session file {path}: it holds no JSON object")
    if session.get("version") != 1 or session.get("version") is True:
        raise Refused(f"the session file {path} is not version 1")
    for key in SESSION_KEYS:
        value = session.get(key)
        if key == "kept":
            named = (isinstance(value, list) and value
                     and all(isinstance(one, str) and os.path.isabs(one) for one in value))
        else:
            named = isinstance(value, str) and value
        if not named:
            raise Refused(f"the session file {path} names no {key}")
    if not isinstance(session.get("job_tmp", ""), str):
        raise Refused(f"the session file {path} names no job_tmp")
    shell = session["shell"]
    if not (os.path.isabs(shell) and os.path.isfile(shell) and os.access(shell, os.X_OK)):
        raise Refused(f"the session file {path} names the shell {shell}, which is no program")
    return session


def _git_common(path, named, kept):
    """The common git directory the launcher fixed, resolved."""
    told = f"the session file {path} names the git directory {named}"
    if not os.path.isabs(named):
        raise Refused(f"{told}, which is not an absolute path")
    if not _own_directory(named.rstrip("/") or "/"):
        raise Refused(f"{told}, which is no directory")
    root = os.path.realpath(named)
    _outside_kept(root, kept, told)
    return root


def _session_tmp(path, named):
    """The session tmp, made when missing."""
    if not os.path.isabs(named):
        raise Refused(f"the session file {path} names the session tmp {named}, which is not an absolute path")
    try:
        os.mkdir(named, 0o700)
    except FileExistsError:
        pass
    except OSError as error:
        raise Refused(f"cannot make the session tmp {named}: {error.strerror}") from error
    try:
        found = os.lstat(named)
    except OSError as error:
        raise Refused(f"cannot read the session tmp {named}: {error.strerror}") from error
    if not stat.S_ISDIR(found.st_mode) or found.st_uid != os.geteuid():
        raise Refused(f"the session tmp {named} is a link, no directory or another user's")
    return named


def session_roots(path, session):
    """A session's roots and its session tmp, from its session file alone."""
    kept = [os.path.realpath(directory) for directory in session["kept"]]
    worktree = session["worktree"]
    if not (os.path.isabs(worktree) and os.path.isdir(worktree)):
        raise Refused(f"the session file {path} names the worktree {worktree}, which is no directory")
    tmp = _session_tmp(path, session["session_tmp"])
    git = _git_common(path, session["git_dir"], kept)
    job = session.get("job_tmp", "")
    if job and not (os.path.isabs(job) and _own_directory(job.rstrip("/") or "/")):
        job = None
    roots = [os.path.realpath(root) for root in (worktree, git, job, tmp) if root]
    return roots + _listed_roots(session["home"], kept), tmp


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
    roots, session_file, shell, entry = [], None, False, None
    while argv and argv[0] != "--":
        word = argv.pop(0)
        if word == "--help":
            print(__doc__, end="")
            return 0
        if word == "--abi":
            print(abi())
            return 0
        if word == "--shell":
            shell = True
        elif word == "--session" and argv and argv[0] != "--":
            session_file = argv.pop(0)
        elif word == "--entry" and argv and argv[0] in ENTRIES:
            entry = argv.pop(0)
        elif word == "--root" and argv:
            roots.append(argv.pop(0))
        else:
            return _usage()
    command = argv[1:]
    if not command or (shell and session_file is None):
        return _usage()
    try:
        for root in roots:
            if not os.path.isdir(root):
                raise Refused(f"--root names no directory: {root}")
        roots = [os.path.realpath(root) for root in roots]
        tmp = None
        if session_file is not None:
            session = read_session(session_file)
            found, tmp = session_roots(session_file, session)
            roots += found
            os.environ["TMPDIR"] = tmp
            if shell:
                command = [session["shell"]] + command
        if entry:
            os.environ[ENTRIES[entry]] = "1"
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
