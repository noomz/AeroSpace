#!/usr/bin/env bash
# Usage: script/bench-window-hiding/vm-test.sh
# Runs probe.sh and flash.sh (both methods) and crash-recovery.sh in a tart macOS VM with two monitors, so the developer's
# desktop is left alone. Build first with ./build-debug.sh.
#
# Env: VM (default aero-probe), TART (default tart), SSH_KEY (optional identity file for the guest's admin user).
# The guest needs, once: auto-login, passwordless sudo, Accessibility for /usr/libexec/sshd-keygen-wrapper
# (every ssh session is charged to it), Screen Recording for the same binary (System Settings in the guest GUI; the
# system TCC.db is read-only under SIP), and Automation access to TextEdit.
set -euo pipefail
cd "$(dirname "$0")/../.."
vm=${VM:-aero-probe}; tart=${TART:-tart}
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3)
[[ -n ${SSH_KEY:-} ]] && ssh_opts+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
bench=.build/bench/bench-window-hiding
mkdir -p .build/bench
[[ $bench -nt script/bench-window-hiding/main.swift ]] || swiftc -O script/bench-window-hiding/main.swift -o "$bench"
[[ .build/bench/flash-check -nt script/bench-window-hiding/flash.swift ]] ||
    swiftc -O script/bench-window-hiding/flash.swift -o .build/bench/flash-check
[[ .build/bench/vdisplay -nt script/bench-window-hiding/vdisplay.m ]] ||
    clang -fobjc-arc -framework Foundation -framework CoreGraphics script/bench-window-hiding/vdisplay.m -o .build/bench/vdisplay

started=
if ! "$tart" list | grep -E "^local +$vm .* running" > /dev/null; then
    "$tart" run --no-graphics "$vm" > /dev/null 2>&1 &
    started=1
fi
cleanup() { [[ -z $started ]] || "$tart" stop "$vm" > /dev/null; }
trap cleanup EXIT
guest() { ssh "${ssh_opts[@]}" "admin@$("$tart" ip "$vm")" "$@"; }
for _ in $(seq 60); do guest pgrep -x Dock > /dev/null 2>&1 && break; sleep 3; done
guest pgrep -x Dock > /dev/null || { echo "guest GUI session didn't start"; exit 1; }

# Debug builds that aren't app bundles read the default config from this source tree's absolute path
config=$PWD/docs/config-examples/default-config.toml
guest "sudo mkdir -p '$(dirname "$config")' && sudo chown -R admin '$(dirname "$config")'"
guest "cat > '$config'" < "$config"
guest 'rm -rf ~/aero/script && mkdir -p ~/aero'
tar czf - .debug/AeroSpaceApp .debug/aerospace "$bench" .build/bench/flash-check .build/bench/vdisplay script/bench-window-hiding |
    guest 'cd ~/aero && tar xzf -'

guest 'pkill -x vdisplay; nohup ~/aero/.build/bench/vdisplay 1280 800 > /dev/null 2>&1 & sleep 2'
status=0
for t in "probe.sh true" "probe.sh false" "flash.sh true" "flash.sh false" "crash-recovery.sh"; do
    echo "=== $t"
    out=$(guest "cd ~/aero && script/bench-window-hiding/$t" 2>&1) || status=1
    grep -v 'already focused' <<< "$out"
    ! grep -q '^FAIL' <<< "$out" || status=1
done
guest 'pkill -x vdisplay' || true
exit $status
