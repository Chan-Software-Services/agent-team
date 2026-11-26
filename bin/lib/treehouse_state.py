#!/usr/bin/env python3
"""A treehouse pool's state file, read and re-rooted under a renamed pool folder, for team-pool-move.

Usage: python3 -I treehouse_state.py known <treehouse version>
       python3 -I treehouse_state.py pools <checkout>
       python3 -I treehouse_state.py check <pool>
       python3 -I treehouse_state.py reroot <old pool> <new pool>

treehouse keeps each pool's state in <pool>/treehouse-state.json beside the pool's own key,
<pool>/treehouse-state.key (32 bytes). Each entry's seed_inventory_digest is HMAC-SHA256 with that
key over the JSON of {name, path, seeded_paths, seed_backend, seed_auth_identity}, as Go's
encoding/json writes it, the path cleaned; an entry whose digest fails is quarantined under the
holder "recovered: state file was corrupt or truncated; verify before reuse", and freed by the
next pool command once it looks safe, its untracked files first moved into a backup folder
(treehouse's internal/pool/state.go and recovered.go). The digest covers the path, so a renamed
pool folder quarantines every slot unless each entry's path and digest are rewritten before any
treehouse command reads it.

known: exits 0 when <treehouse version> (as `treehouse --version` prints it, a leading v
allowed) is one whose state format this file was checked against (KNOWN_VERSIONS), else 1 saying
so.

pools: prints the folder treehouse keeps <checkout>'s pools in, found as its
internal/config/config.go does (ResolveRoot, Load and ResolvePoolRoot): the root is
TREEHOUSE_ROOT when set, else the root of <checkout>/treehouse.toml when that file exists, else
that of ~/.config/treehouse/config.toml; a root empty as written is HOME, a root's $VAR and
${VAR} are expanded as Go's os.ExpandEnv does (an unset one to nothing, so a root that expands to
nothing is <checkout>), a relative root is taken from <checkout>, and no symlink is resolved; the
pools are <root>/.treehouse. Refused when a config
file cannot be read.

check: prints each entry of <pool>'s state as "<name>\\t<path>\\t<holder>" (holder empty for a
slot not leased), after checking that the state's version is STATE_VERSION, that the key is 32
bytes, that every entry's path is under <pool>/, and that the formula reproduces the digest of
every entry whose seed inventory is known; refused (exit 1, one line on stderr) otherwise.

reroot: moves the pool <old pool> to <new pool> and rewrites its state there, under the pool's
lock (treehouse-state.lock, the flock treehouse takes, waited for at most TEAM_POOL_LOCK_SECONDS,
default 30), so no treehouse command runs between the rename and the rewrite. With <old pool>
there, it takes the lock in it, checks every entry, refuses when <new pool> exists, and renames
the folder, the open lock moving with it; with only <new pool> there, the folder already
renamed by a run that stopped, it takes the lock in <new pool>. Then each entry's path under
<old pool>/ is put under <new pool>/ and, for an entry whose seed inventory is known, its digest
recomputed with the pool's key; an entry already under <new pool>/ is kept, so a run again
changes nothing. Every entry's digest is checked first, at the path it holds, and nothing is
renamed or written when one is not reproduced, one is under neither folder, or the version or
key is not as check requires. The file is replaced atomically, keeping its mode. Then prints the
entries as check does. Exits 1 refused with nothing changed, or 3 when the folder was renamed
but its state could not be written, with the state still under <old pool>'s paths.
"""

import fcntl
import hashlib
import hmac
import json
import os
import re
import sys
import time
import tomllib

KNOWN_VERSIONS = ("3.1.5",)
STATE_VERSION = 4
STATE = "treehouse-state.json"
KEY = "treehouse-state.key"
LOCK = "treehouse-state.lock"


class Refused(Exception):
    status = 1


class Renamed(Refused):
    """Refused once the pool folder is renamed, its state not written."""

    status = 3


def go_json(value):
    """JSON as Go's json.Marshal writes it: compact, UTF-8, with <, >, &, U+2028 and U+2029 escaped."""
    text = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    for char, escaped in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"), ("\u2028", "\\u2028"), ("\u2029", "\\u2029")):
        text = text.replace(char, escaped)
    return text.encode()


def digest(key, entry, path=None):
    """The seed_inventory_digest treehouse writes for <entry>, at <path> when given."""
    data = go_json(
        {
            "name": entry.get("name") or "",
            "path": os.path.normpath(path if path is not None else entry.get("path") or ""),
            "seeded_paths": entry.get("seeded_paths") or [],
            "seed_backend": entry.get("seed_backend") or "",
            "seed_auth_identity": entry.get("seed_auth_identity") or "",
        }
    )
    return hmac.new(key, data, hashlib.sha256).hexdigest()


def load(pool):
    try:
        with open(os.path.join(pool, KEY), "rb") as f:
            key = f.read()
        with open(os.path.join(pool, STATE), encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, ValueError) as e:
        raise Refused(f"cannot read the state of {pool}: {e}")
    if len(key) != hashlib.sha256().digest_size:
        raise Refused(f"{os.path.join(pool, KEY)} is not a 32-byte key")
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION or not isinstance(state.get("worktrees"), list):
        raise Refused(f"{os.path.join(pool, STATE)} is not state version {STATE_VERSION}, the format this tool knows")
    return key, state


def verify(key, entry):
    if not entry.get("seed_inventory_known"):
        return
    stored = entry.get("seed_inventory_digest") or ""
    if not hmac.compare_digest(stored, digest(key, entry)):
        raise Refused(f"slot {entry.get('name')}: its stored digest is not reproduced, so treehouse's state format is not the one this tool knows")


def under(path, pool):
    return os.path.normpath(path).startswith(pool + os.sep)


def lines(state):
    out = []
    for entry in state["worktrees"]:
        holder = (entry.get("lease_holder") or "") if entry.get("leased") else ""
        out.append(f"{entry.get('name')}\t{entry.get('path')}\t{holder}")
    return out


def check(pool):
    pool = os.path.normpath(os.path.abspath(pool))
    key, state = load(pool)
    for entry in state["worktrees"]:
        if not under(entry.get("path") or "", pool):
            raise Refused(f"slot {entry.get('name')}: {entry.get('path')} is not under {pool}")
        verify(key, entry)
    return lines(state)


def expand_env(text):
    """<text> with its $VAR and ${VAR} expanded as Go's os.ExpandEnv does."""
    out, i = [], 0
    while i < len(text):
        if text[i] != "$" or i + 1 == len(text):
            out.append(text[i])
            i += 1
            continue
        rest = text[i + 1 :]
        special = "*#$@!?-0123456789"
        if rest[0] == "{":
            if len(rest) > 2 and rest[1] in special and rest[2] == "}":
                name, width = rest[1], 3
            else:
                close = rest.find("}")
                name, width = (rest[1:close], close + 1) if close > 1 else ("", 2 if close == 1 else 1)
        elif rest[0] in special:
            name, width = rest[0], 1
        else:
            name = re.match(r"[A-Za-z0-9_]*", rest).group()
            width = len(name)
        if name:
            out.append(os.environ.get(name, ""))
        elif width == 0:
            out.append("$")
        i += 1 + width
    return "".join(out)


def config_root(path):
    """The root of the treehouse config file <path>, or None when there is no such file."""
    if not os.path.exists(path):
        return None
    try:
        with open(path, "rb") as f:
            root = tomllib.load(f).get("root", "")
    except (OSError, ValueError) as e:
        raise Refused(f"cannot read {path}: {e}")
    return root if isinstance(root, str) else ""


def pools(checkout):
    checkout = os.path.normpath(os.path.abspath(checkout))
    root = os.environ.get("TREEHOUSE_ROOT", "")
    if not root:
        root = config_root(os.path.join(checkout, "treehouse.toml"))
        if root is None:
            root = config_root(os.path.join(os.path.expanduser("~"), ".config", "treehouse", "config.toml")) or ""
    if not root:
        return [os.path.join(os.path.normpath(os.path.expanduser("~")), ".treehouse")]
    root = expand_env(root)
    return [os.path.normpath(os.path.join(checkout, root, ".treehouse"))]


def locked(pool):
    """The pool's lock file, open and locked, waiting at most TEAM_POOL_LOCK_SECONDS for it."""
    path = os.path.join(pool, LOCK)
    try:
        lock = open(path, "a")
    except OSError as e:
        raise Refused(f"cannot open {path}: {e}")
    deadline = time.monotonic() + float(os.environ.get("TEAM_POOL_LOCK_SECONDS") or 30)
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock
        except BlockingIOError:
            if time.monotonic() >= deadline:
                lock.close()
                raise Refused(f"{path} is held by another command: let it end, then run this again")
            time.sleep(0.2)


def reroot(old, new):
    old = os.path.normpath(os.path.abspath(old))
    new = os.path.normpath(os.path.abspath(new))
    renaming = os.path.lexists(old)
    with locked(old if renaming else new):
        key, state = load(old if renaming else new)
        for entry in state["worktrees"]:
            path = entry.get("path") or ""
            if not (under(path, old) or under(path, new)):
                raise Refused(f"slot {entry.get('name')}: {path} is under neither {old} nor {new}")
            verify(key, entry)
        if renaming:
            if os.path.lexists(new):
                raise Refused(f"{new} exists: a pool is already at the new name")
            try:
                os.rename(old, new)
            except OSError as e:
                raise Refused(f"cannot rename {old} to {new}: {e}")
        changed = False
        for entry in state["worktrees"]:
            path = os.path.normpath(entry["path"])
            if not under(path, old):
                continue
            entry["path"] = new + path[len(old):]
            if entry.get("seed_inventory_known"):
                entry["seed_inventory_digest"] = digest(key, entry)
            changed = True
        if changed:
            target = os.path.join(new, STATE)
            temp = target + ".team-pool-move"
            try:
                mode = os.stat(target).st_mode & 0o7777
                with open(temp, "w", encoding="utf-8") as f:
                    json.dump(state, f, indent=2, ensure_ascii=False)
                    f.write("\n")
                    f.flush()
                    os.fsync(f.fileno())
                os.chmod(temp, mode)
                os.replace(temp, target)
            except OSError as e:
                if os.path.exists(temp):
                    os.remove(temp)
                raise (Renamed if renaming else Refused)(f"cannot write {target}: {e}")
    return lines(state)


def main(argv):
    if len(argv) == 2 and argv[0] == "known":
        version = argv[1].strip().removeprefix("v")
        if version in KNOWN_VERSIONS:
            return 0
        print(f"treehouse {version} is not a version whose state format this tool was checked against ({', '.join(KNOWN_VERSIONS)}): read its internal/pool/state.go, then add it to KNOWN_VERSIONS in bin/lib/treehouse_state.py", file=sys.stderr)
        return 1
    if len(argv) == 2 and argv[0] == "pools":
        result = pools(argv[1])
    elif len(argv) == 2 and argv[0] == "check":
        result = check(argv[1])
    elif len(argv) == 3 and argv[0] == "reroot":
        result = reroot(argv[1], argv[2])
    else:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    for line in result:
        print(line)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Refused as e:
        print(e, file=sys.stderr)
        sys.exit(e.status)
