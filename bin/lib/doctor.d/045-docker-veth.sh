# docker veth   Arch only: net.ipv6.conf.default.addr_gen_mode is 1, so a new Docker veth gets no
#               IPv6 link-local address, whose coming and going makes Chromium fail a page load
#               with net::ERR_NETWORK_CHANGED; passes too with IPv6 off, at boot or for new
#               interfaces (net.ipv6.conf.default.disable_ipv6 1). Otherwise it warns, with
#               Daniel's sysctl.d file. macOS has no line: Docker Desktop's veths are in its VM.
# shellcheck shell=bash
# shellcheck disable=SC2154 # os, from the os check
# reads state from: 010-os.sh

# TEAM_CGROUP_ROOT stands for / (the tests' seam, as team-capacity's).
if [[ $os == arch ]]; then
  ipv6=${TEAM_CGROUP_ROOT:-}/proc/sys/net/ipv6
  if [[ ! -d $ipv6 ]]; then
    report 'docker veth' PASS "IPv6 is off (no /proc/sys/net/ipv6), so a Docker veth gets no IPv6 link-local address"
  elif [[ $(cat "$ipv6/conf/default/disable_ipv6" 2>/dev/null) == 1 ]]; then
    report 'docker veth' PASS "net.ipv6.conf.default.disable_ipv6 is 1, so a new Docker veth gets no IPv6 address at all"
  else
    mode=$(cat "$ipv6/conf/default/addr_gen_mode" 2>/dev/null) || mode=''
    if [[ $mode == 1 ]]; then
      report 'docker veth' PASS "net.ipv6.conf.default.addr_gen_mode is 1, so a new Docker veth gets no IPv6 link-local address"
    else
      if [[ -n $mode ]]; then mode="is $mode"; else mode="cannot be read"; fi
      report 'docker veth' WARN "net.ipv6.conf.default.addr_gen_mode $mode, so each new Docker veth gets an IPv6 link-local address, and Chromium beside a container that starts or stops can fail with net::ERR_NETWORK_CHANGED" \
        "Daniel runs echo 'net.ipv6.conf.default.addr_gen_mode = 1' | sudo tee /etc/sysctl.d/90-docker-no-ll6.conf, then sudo sysctl --system"
    fi
  fi
fi
