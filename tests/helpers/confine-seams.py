#!/usr/bin/env python3
"""Runs bin/lib/confine.py with the two reads a test replaces, since the wrapper has no seam.

Usage: python3 -I confine-seams.py <confine.py's arguments>

Read from the environment:
  CONFINE_REAL       the confine.py to load, so its confine-roots is the one beside that file
  CONFINE_TEST_ABI   <n>, taken as the kernel's Landlock ABI
  CONFINE_TEST_FAIL  restrict, which makes entering the domain fail as the kernel's refusal
                     would, with "Operation not permitted"
"""
import ctypes
import errno
import importlib.util
import os
import sys

# The wrapper is loaded from the checkout, where no test may leave its bytecode.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("confine", os.environ["CONFINE_REAL"])
confine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(confine)

seam = os.environ.get("CONFINE_TEST_ABI", "")
if seam.isdigit():
    confine.abi = lambda: int(seam)

if os.environ.get("CONFINE_TEST_FAIL") == "restrict":
    real_libc = confine._libc

    class Failing:
        """The C library, whose landlock_restrict_self fails."""

        def __init__(self):
            self.libc = real_libc()
            self.prctl = self.libc.prctl

        def syscall(self, number, *arguments):
            if number == confine.SYS_RESTRICT:
                ctypes.set_errno(errno.EPERM)
                return -1
            return self.libc.syscall(number, *arguments)

    confine._libc = Failing

sys.exit(confine.main(sys.argv[1:]))
