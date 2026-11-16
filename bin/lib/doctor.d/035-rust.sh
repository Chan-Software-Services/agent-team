# tool rust-toolchain
#               The Rust toolchain the code checkout's rust-toolchain.toml pins (its channel and
#               components), as rustup sees it run there: installed with every component it
#               names, and cargo, found on the library's PATH, rustup's ~/.cargo/bin/cargo, which
#               runs it ("1.100.0 with clippy, rust-analyzer, rust-src, rustfmt"). Without rustup
#               (rustup's own line installs it), without the toolchain or lacking a component it
#               fails, the fix `cd <code checkout> && rustup toolchain install`, which installs
#               what rust-toolchain.toml names; another cargo first on PATH (a rustup installed
#               elsewhere, whose own cargo the library's ~/.cargo/bin does not shadow) fails, the
#               fix the tool rustup line's install command from bin/lib/tools.lock, which puts
#               rustup and its cargo in ~/.cargo/bin. No line without a rust-toolchain.toml, nor on
#               an OS whose tools go unchecked.
# shellcheck shell=bash
# shellcheck disable=SC2154 # bin and os, the doctor's
# reads state from: 010-os.sh

# The channel and the components of <toml>, rust-toolchain.toml's one-line forms, one per line, the
# channel first: rust_pins <toml>
rust_pins() {
  sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' "$1"
  sed -n 's/^components *= *\[\(.*\)\].*/\1/p' "$1" | tr ',' '\n' | tr -d ' "' | grep . | LC_ALL=C sort
}

# rustup <args...> in the code checkout, bounded by its 30 s, never installing what it reads:
# rust_rustup <args...>
rust_rustup() {
  (cd "$rust_code" && RUSTUP_AUTO_INSTALL=0 bounded 30 rustup "$@" </dev/null 2>"$err")
}

rust_code=$(dirname "$bin")
if [[ -n $os && -f $rust_code/rust-toolchain.toml ]]; then
  rust_fix="cd $(tilde "$rust_code") && rustup toolchain install"
  mapfile -t rust_wanted < <(rust_pins "$rust_code/rust-toolchain.toml")
  rust_channel=${rust_wanted[0]} rust_wanted=("${rust_wanted[@]:1}")
  rust_rc=0
  rust_toolchains=$(rust_rustup toolchain list) || rust_rc=$?
  rust_lacking=()
  if ((rust_rc == 127)); then
    report "tool rust-toolchain" FAIL "rustup is not installed" "$rust_fix"
  elif ((rust_rc == 124)); then
    report "tool rust-toolchain" FAIL "\`rustup toolchain list\` did not answer within 30 s" "$rust_fix"
  elif ((rust_rc)) || ! grep -qE "^${rust_channel//./\\.}-[a-z0-9_]+-" <<<"$rust_toolchains"; then
    report "tool rust-toolchain" FAIL "$rust_channel is not installed" "$rust_fix"
  else
    rust_installed=$(rust_rustup component list --installed --toolchain "$rust_channel") || true
    for rust_component in "${rust_wanted[@]}"; do
      grep -qE "^${rust_component}(-(x86_64|aarch64)-.*)?$" <<<"$rust_installed" || rust_lacking+=("$rust_component")
    done
    rust_cargo=$(command -v cargo || echo 'not on PATH')
    if ((${#rust_lacking[@]})); then
      report "tool rust-toolchain" FAIL "$rust_channel lacks $(printf '%s, ' "${rust_lacking[@]}" | sed 's/, $//')" "$rust_fix"
    elif [[ $rust_cargo != "$HOME/.cargo/bin/cargo" ]]; then
      report "tool rust-toolchain" FAIL "cargo is $(tilde "$rust_cargo"), not ~/.cargo/bin/cargo" \
        "$(jq -L "$TEAM_LIB" -r --arg os "$os" --arg machine "$(uname -m)" \
          'include "tools"; first(tools_for($os; $machine) | select(.name == "rustup") | .source)' "$TEAM_LIB/tools.lock")"
    else
      report "tool rust-toolchain" PASS "$rust_channel with $(printf '%s, ' "${rust_wanted[@]}" | sed 's/, $//')"
    fi
  fi
fi
