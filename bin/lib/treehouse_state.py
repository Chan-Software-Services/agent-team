#!/usr/bin/env python3
"""A treehouse pool's state file, read and re-rooted under a renamed pool folder, for team-pool-move.

Usage: python3 -I treehouse_state.py known <treehouse version>
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

check: prints each entry of <pool>'s state as "<name>\\t<path>\\t<holder>" (holder empty for a
slot not leased), after checking that the state's version is STATE_VERSION, that the key is 32
bytes, that every entry's path is under <pool>/, and that the formula reproduces the digest of
every entry whose seed inventory is known; refused (exit 1, one line on stderr) otherwise.

reroot: under the pool's lock (treehouse-state.lock, the flock treehouse takes), rewrites the
state of <new pool>, the folder already renamed from <old pool>: each entry's path under
<old pool>/ is put under <new pool>/ and its digest recomputed with the pool's key; an entry
already under <new pool>/ is kept, so a run again changes nothing. Every entry's digest is
checked first, at the path it holds, and nothing is written when one is not reproduced, one is
under neither folder, or the version or key is not as check requires. The file is replaced
atomically, keeping its mode. Then prints the entries as check does.
"""

import fcntl
import hashlib
import hmac
import json
import os
import sys

KNOWN_VERSIONS = ("3.1.5",)
STATE_VERSION = 4
STATE = "treehouse-state.json"
KEY = "treehouse-state.key"
LOCK = "treehouse-state.lock"


class Refused(Exception):
    pass


def go_json(value):
    """JSON as Go's json.Marshal writes it: compact, UTF-8, with <, >, &, U+2028 and U+2029 escaped."""
    text = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    for char, escaped in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"), (" ", "\\u2028"), (" ", "\\u2029")):
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


def reroot(old, new):
    old = os.path.normpath(os.path.abspath(old))
    new = os.path.normpath(os.path.abspath(new))
    with open(os.path.join(new, LOCK), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key, state = load(new)
        for entry in state["worktrees"]:
            path = entry.get("path") or ""
            if not (under(path, old) or under(path, new)):
                raise Refused(f"slot {entry.get('name')}: {path} is under neither {old} nor {new}")
            verify(key, entry)
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
            mode = os.stat(target).st_mode & 0o7777
            with open(temp, "w", encoding="utf-8") as f:
                json.dump(state, f, indent=2, ensure_ascii=False)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            os.chmod(temp, mode)
            os.replace(temp, target)
    return lines(state)


def main(argv):
    if len(argv) == 2 and argv[0] == "known":
        version = argv[1].strip().removeprefix("v")
        if version in KNOWN_VERSIONS:
            return 0
        print(f"treehouse {version} is not a version whose state format this tool was checked against ({', '.join(KNOWN_VERSIONS)}): read its internal/pool/state.go, then add it to KNOWN_VERSIONS in bin/lib/treehouse_state.py", file=sys.stderr)
        return 1
    if len(argv) == 2 and argv[0] == "check":
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
        sys.exit(1)
