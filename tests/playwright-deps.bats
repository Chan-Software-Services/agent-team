#!/usr/bin/env bats
# tests/playwright-deps, which CI's toolkits job runs as root to install the system libraries
# Playwright's pinned browsers need, on a stub node (playwright-core's install-deps) and a stub
# apt-get, with apt's directories inside the test's own (PLAYWRIGHT_DEPS_ROOT): the packages an
# earlier run saved, the fetch that comes before the install, its time limit and the next mirror,
# and what a run that fetches nothing ends with. Nothing here reaches apt or needs root.

load helpers/common

RUNNER='' DEBS='' ARCHIVES=''
OWN=http://us-east-2.ec2.archive.ubuntu.com/ubuntu/
AZURE=http://azure.archive.ubuntu.com/ubuntu/
CANONICAL=http://archive.ubuntu.com/ubuntu/

setup() {
  sandbox
  RUNNER=$BATS_TEST_TMPDIR/runner
  DEBS=$BATS_TEST_TMPDIR/debs
  ARCHIVES=$RUNNER/var/cache/apt/archives
  mkdir -p "$RUNNER/etc/apt/apt.conf.d" "$ARCHIVES"
  # The runner's mirror list, as an AWS runner's image has it.
  printf '%s\tpriority:1\n' "$OWN" >"$RUNNER/etc/apt/apt-mirrors.txt"
  export PLAYWRIGHT_DEPS_ROOT=$RUNNER
  stub_command node apt-get
  # apt-get autoclean drops each package apt can no longer fetch: here, the stale ones.
  stub_script apt-get <<'EOF'
rm -f "$PLAYWRIGHT_DEPS_ROOT"/var/cache/apt/archives/libstale_*.deb
EOF
  # install-deps, as one line of $BATS_TEST_TMPDIR/phases per call: "fetch" when apt is told to
  # download only, else "install", then the first mirror of the list and the packages apt holds.
  # Each fetch takes the next line of $BATS_TEST_TMPDIR/fetches: slow outlives any limit here,
  # fail ends as one apt cannot fetch for does, in apt's lines and then install-deps' two, and
  # none fetches one package.
  stub_script node <<'EOF'
apt=$PLAYWRIGHT_DEPS_ROOT/etc/apt archives=$PLAYWRIGHT_DEPS_ROOT/var/cache/apt/archives
phase=install
if grep -qsxF 'APT::Get::Download-Only "true";' "$apt"/apt.conf.d/*; then phase=fetch; fi
read -r mirror _ <"$apt/apt-mirrors.txt"
held=$(cd "$archives" && shopt -s nullglob && echo *.deb)
echo "$phase $mirror${held:+ $held}" >>"$BATS_TEST_TMPDIR/phases"
[[ $phase == fetch ]] || exit 0
outcome=''
if [[ -s $BATS_TEST_TMPDIR/fetches ]]; then
  outcome=$(head -n 1 "$BATS_TEST_TMPDIR/fetches")
  sed -i 1d "$BATS_TEST_TMPDIR/fetches"
fi
case $outcome in
  slow) sleep 30 ;;
  fail)
    printf '%s\n' 'E: Failed to fetch http://mirror/pool/libnew.deb  Connection failed' 'E: Some files failed to download' \
      'Failed to install browser dependencies' 'Error: Installation process exited with code: 100'
    exit 1
    ;;
esac
touch "$archives/libnew_2_amd64.deb"
EOF
}

# Run the script as the workflow's step does, but for sudo: playwright_deps
playwright_deps() {
  run "$REPO_ROOT/tests/playwright-deps" "$DEBS"
}

phases() {
  cat "$BATS_TEST_TMPDIR/phases"
}

# Each fetch's outcome, in order: fetches <outcome>...
fetches() {
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/fetches"
}

@test "apt holds an earlier run's packages before it fetches, installs only after, and the packages it installs from are saved" {
  mkdir "$DEBS"
  touch "$DEBS/libold_1_amd64.deb" "$DEBS/libstale_1_amd64.deb"
  playwright_deps
  assert_equal "$status" 0
  assert_equal "$(phases)" "fetch $OWN libold_1_amd64.deb libstale_1_amd64.deb
install $OWN libnew_2_amd64.deb libold_1_amd64.deb"
  # The stale package is dropped, so the saved set does not grow with every image.
  assert_equal "$(ls "$DEBS")" $'libnew_2_amd64.deb\nlibold_1_amd64.deb'
  assert_equal "$(stub_calls apt-get)" '["autoclean"]'
  assert_equal "$(stub_calls node | sort -u)" \
    "[\"$REPO_ROOT/servers/node_modules/playwright-core/cli.js\",\"install-deps\",\"chromium\",\"firefox\",\"webkit\"]"
  # The download-only setting is removed.
  assert_equal "$(ls "$RUNNER/etc/apt/apt.conf.d")" ""
}

@test "a fetch that outlives its limit is stopped and made again on azure.archive.ubuntu.com, where the install runs" {
  fetches slow
  SECONDS=0
  PLAYWRIGHT_DEPS_LIMITS='3 20 20' playwright_deps
  assert_equal "$status" 0
  ((SECONDS < 20))
  assert_equal "$(phases)" "fetch $OWN
fetch $AZURE
install $AZURE libnew_2_amd64.deb"
  assert_contains "$output" "playwright-deps: the fetch from the runner's mirror did not end within 3 s"
  assert_contains "$output" "playwright-deps: fetching from $AZURE, 20 s at most"
  # With no earlier run's packages, the first run saves its own.
  assert_equal "$(ls "$DEBS")" libnew_2_amd64.deb
}

@test "a fetch that fails is made on each next mirror, and with each failed the run ends with the last one's status, installing and saving nothing" {
  mkdir "$DEBS"
  touch "$DEBS/libold_1_amd64.deb"
  fetches fail fail fail
  playwright_deps
  assert_equal "$status" 1
  assert_equal "$(phases | cut -d' ' -f1,2)" "fetch $OWN
fetch $AZURE
fetch $CANONICAL"
  assert_contains "$output" "playwright-deps: the fetch from the runner's mirror failed (exit 1)"
  # Nothing follows the last fetch's own lines: team-ci-wait reads apt's failure as the runner's
  # only with at most 3 lines after its last "E: Failed to fetch", which these fill.
  assert_equal "$(tail -n 4 <<<"$output")" "E: Failed to fetch http://mirror/pool/libnew.deb  Connection failed
E: Some files failed to download
Failed to install browser dependencies
Error: Installation process exited with code: 100"
  assert_equal "$(ls "$DEBS")" libold_1_amd64.deb
  assert_equal "$(ls "$RUNNER/etc/apt/apt.conf.d")" ""
}

@test "when the last fetch outlives its limit the run fails, saying apt's packages could not be fetched" {
  fetches slow slow slow
  PLAYWRIGHT_DEPS_LIMITS='3 3 3' playwright_deps
  assert_equal "$status" 1
  assert_equal "$(phases | cut -d' ' -f1)" $'fetch\nfetch\nfetch'
  assert_equal "$(tail -n 1 <<<"$output")" \
    "E: Failed to fetch Playwright's system libraries: the last fetch, from $CANONICAL, did not end within 3 s"
}

@test "--help prints the header, and a call with no directory for the packages, or an option, is a malformed command line" {
  run "$REPO_ROOT/tests/playwright-deps" --help
  assert_equal "$status" 0
  assert_contains "$output" "Usage: tests/playwright-deps <debs>"
  for args in '' --force 'one two'; do
    # shellcheck disable=SC2086 # each word of args is an argument of its own
    run "$REPO_ROOT/tests/playwright-deps" $args
    assert_equal "$status" 2
    assert_contains "$output" "usage: tests/playwright-deps <debs>"
  done
  [[ ! -e $BATS_TEST_TMPDIR/phases ]]
}
