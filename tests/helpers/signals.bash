# Ending a script with a signal in the middle of a call, for the tests that show it leaves no
# temporary file behind; loaded after helpers/common by their files, once sandbox has run.
#   signalled <signal> <started> <command>...
#     runs <command> in the background, in a process group of its own, its stdin $SIGNAL_INPUT
#     (default /dev/null), its stdout and stderr $BATS_TEST_TMPDIR/signalled.out and .err; waits
#     up to 20 seconds for the file <started>, which a stub the command reaches makes before it
#     waits (stalled, below); sends <signal> to the command alone for TERM and HUP, as a hook's
#     timeout or a closed terminal does, and to its process group for INT, as Ctrl-C does; then
#     releases the stub and waits for the command, setting status to its exit status, as run does.
#   stalled <started>
#     the text of a stub script's body (stub_script) that makes <started> and waits until
#     signalled releases it, so the command is caught in the middle of that call. It waits in the
#     read builtin on a FIFO, which every one of the three signals ends at once: a sleep that
#     ends as INT arrives would be taken by Bash as a child that handled it, and the script would
#     go on.
#   leftovers
#     every path under TMPDIR, one per line, so a test asserts there is none.

signalled() {
  local sig=$1 started=$2 pid tries=0
  shift 2
  [[ -p $BATS_TEST_TMPDIR/signalled.fifo ]] || mkfifo "$BATS_TEST_TMPDIR/signalled.fifo"
  set -m
  "$@" <"${SIGNAL_INPUT:-/dev/null}" >"$BATS_TEST_TMPDIR/signalled.out" 2>"$BATS_TEST_TMPDIR/signalled.err" 3>&- &
  pid=$!
  set +m
  until [[ -e $started ]]; do
    if ((++tries > 400)); then
      signalled_release
      wait "$pid" || true
      echo "signalled: $* never reached the stalled call ($started)" >&2
      return 1
    fi
    sleep 0.05
  done
  if [[ $sig == INT ]]; then kill -INT -- "-${pid:?}"; else kill "-$sig" "${pid:?}"; fi
  signalled_release
  # shellcheck disable=SC2034 # status is read by the tests, as bats' run sets it
  status=0 && wait "$pid" || status=$?
}

# A line into the FIFO, through a descriptor that reads it too, so the write never waits for a
# reader the signal may have ended.
signalled_release() {
  local fifo
  exec {fifo}<>"$BATS_TEST_TMPDIR/signalled.fifo"
  echo >&"$fifo"
  exec {fifo}>&-
}

stalled() {
  printf ': >%q\nread -r _ <>%q || true\n' "$1" "$BATS_TEST_TMPDIR/signalled.fifo"
}

leftovers() {
  find "$TMPDIR" -mindepth 1
}
