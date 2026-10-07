#!/usr/bin/env bash
# Usage: script/bench-window-hiding/probe.sh [true|false]   (hide-windows-in-private-space, default true)
set -uo pipefail
cd "$(dirname "$0")/../.."
source script/bench-window-hiding/lib.sh
cli=./.debug/aerospace
bench=.build/bench/bench-window-hiding
out=$(mktemp -d)
mkdir -p .build/bench
[[ $bench -nt script/bench-window-hiding/main.swift ]] || swiftc -O script/bench-window-hiding/main.swift -o "$bench" || exit 1
# A workspace that was never visible opens on the main monitor, whichever monitor has focus.
# probe-a stays unassigned because the probe moves it between monitors.
printf '%s\n' 'config-version = 2' "hide-windows-in-private-space = ${1:-true}" '[workspace-to-monitor-force-assignment]' \
    "probe-a-empty = 'main'" "probe-b = 'secondary'" "probe-b-empty = 'secondary'" > "$out/config.toml"
./.debug/AeroSpaceApp --config-path "$out/config.toml" > "$out/server.log" 2>&1 &
server=$!
ids=()
cleanup() {
    for id in "${ids[@]}"; do "$cli" close --window-id "$id" > /dev/null 2>&1 || true; done
    kill -INT "$server" 2> /dev/null; wait "$server" 2> /dev/null
    echo "server log: $out/server.log"
}
trap cleanup EXIT
for _ in $(seq 100); do "$cli" list-workspaces --focused > /dev/null 2>&1 && break; sleep 0.3; done
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', expected '$3'"; fi; }
frame() { "$bench" --frame "$1"; }
settle() { sleep "${1:-0.7}"; }

main=main; other=secondary
[[ $("$cli" list-monitors | wc -l) -ge 2 ]] || other=main
for _ in 1 2; do id=$(new_window TextEdit) && ids+=("$id"); done
[[ ${#ids[@]} == 2 ]] && wait_tracked "$cli" "${ids[@]}" || { echo "FAIL setup: expected 2 new windows, got ${#ids[@]}"; exit 1; }
settle 2
w1=${ids[0]}; w2=${ids[1]}

[[ ${1:-true} == true ]] && hidden=offscreen || hidden=sliver
state() { "$bench" --state "$1"; }

"$cli" focus-monitor "$main"; "$cli" workspace probe-a; "$cli" move-node-to-workspace --window-id "$w1" probe-a
"$cli" layout --window-id "$w1" floating
settle
f1=$(frame "$w1")
"$cli" focus-monitor "$other"; "$cli" workspace probe-b; "$cli" move-node-to-workspace --window-id "$w2" probe-b
settle
f2=$(frame "$w2"); display_other=$("$bench" --display "$w2")
check "both windows visible before hiding" "$(state "$w1")/$(state "$w2")" "$([[ $other == main ]] && echo "$hidden" || echo visible)/visible"

"$cli" workspace probe-b-empty; "$cli" focus-monitor "$main"; "$cli" workspace probe-a-empty
settle
check "window on main monitor hidden" "$(state "$w1")" "$hidden"
check "window on other monitor hidden" "$(state "$w2")" "$hidden"
settle 2
listed=$("$cli" list-windows --all --format '%{window-id}|%{window-title}' | grep -E "^($w1|$w2)\|" | grep -cv '|$')
check "hidden windows still tracked, titles readable over AX" "$listed" 2

"$cli" workspace probe-a
settle
check "floating window returns to the exact frame" "$(frame "$w1")" "$f1"
"$cli" focus-monitor "$other"; "$cli" workspace probe-b
settle
check "tiling window returns to the same frame" "$(frame "$w2")" "$f2"

"$cli" workspace probe-b-empty; "$cli" focus-monitor "$main"; "$cli" workspace probe-a-empty
settle
osascript -e 'tell application "TextEdit" to activate' > /dev/null
settle 1.5
visible=0; for id in "$w1" "$w2"; do [[ $(state "$id") == visible ]] && visible=$((visible + 1)); done
echo "INFO activating TextEdit while its windows are hidden: focused workspace $("$cli" list-workspaces --focused), $visible/2 windows visible"

"$cli" workspace probe-a-empty
"$cli" move-workspace-to-monitor --workspace probe-a "$other"
"$cli" focus-monitor "$other"; "$cli" workspace probe-a
settle
[[ $other == main ]] && echo "SKIP floating window follows its workspace to the other monitor: one monitor" ||
    check "floating window follows its workspace to the other monitor" "$("$bench" --display "$w1")" "$display_other"
