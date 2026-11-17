# github login  `gh auth status` for github.com on the owner login, the machine's own
#               (with_owner_login in bin/lib/github-login.sh), whatever login the session running
#               the doctor has.
# shellcheck shell=bash

if with_owner_login bounded 30 gh auth status --hostname github.com >/dev/null 2>&1 </dev/null; then
  report "github login" PASS "gh is signed in to github.com"
else
  report "github login" FAIL "gh auth status finds no working login for github.com" \
    "gh auth login --hostname github.com --git-protocol https --web"
fi
