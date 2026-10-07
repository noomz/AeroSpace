#!/usr/bin/env bash
# Usage: script/bench-window-hiding/probe.sh [true|false]   (hide-windows-in-private-space, default true)
set -uo pipefail
cd "$(dirname "$0")/../.."
cli=./.debug/aerospace
bench=.build/bench/bench-window-hiding
out=$(mktemp -d)
mkdir -p .build/bench
[[ $bench -nt script/bench-window-hiding/main.swift ]] || swiftc -O script/bench-window-hiding/main.swift -o "$bench" || exit 1
printf 'config-version = 2\nhide-windows-in-private-space = %s\n' "${1:-true}" > "$out/config.toml"
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
before=$("$cli" list-windows --all --format '%{window-id}' | sort)
osascript -e 'tell application "TextEdit" to make new document' -e 'tell application "TextEdit" to make new document' > /dev/null
settle 2
ids=($(comm -13 <(echo "$before") <("$cli" list-windows --all --format '%{window-id}' | sort)))
[[ ${#ids[@]} == 2 ]] || { echo "FAIL setup: expected 2 new windows, got ${#ids[@]}"; exit 1; }
w1=${ids[0]}; w2=${ids[1]}

"$cli" focus-monitor "$main"; "$cli" workspace probe-a; "$cli" move-node-to-workspace --window-id "$w1" probe-a
"$cli" focus-monitor "$other"; "$cli" workspace probe-b; "$cli" move-node-to-workspace --window-id "$w2" probe-b
"$cli" layout --window-id "$w1" floating
settle
f1=$(frame "$w1"); f2=$(frame "$w2"); display_other=$("$bench" --display "$w2")
check "both windows visible before hiding" "$([[ $f1 != offscreen && $f2 != offscreen ]] && echo yes)" yes

"$cli" workspace probe-b-empty; "$cli" focus-monitor "$main"; "$cli" workspace probe-a-empty
settle
check "window on main monitor hidden" "$(frame "$w1")" offscreen
check "window on other monitor hidden" "$(frame "$w2")" offscreen
settle 2
listed=$("$cli" list-windows --all --format '%{window-id}|%{window-title}' | grep -E "^($w1|$w2)\|" | grep -cv '|$')
check "hidden windows still tracked, titles readable over AX" "$listed" 2

"$cli" workspace probe-a; "$cli" focus-monitor "$other"; "$cli" workspace probe-b
settle
check "floating window returns to the exact frame" "$(frame "$w1")" "$f1"
check "tiling window on other monitor returns to the same frame" "$(frame "$w2")" "$f2"

"$cli" workspace probe-b-empty; "$cli" focus-monitor "$main"; "$cli" workspace probe-a-empty
settle
osascript -e 'tell application "TextEdit" to activate' > /dev/null
settle 1.5
visible=0; for id in "$w1" "$w2"; do [[ $(frame "$id") != offscreen ]] && visible=$((visible + 1)); done
echo "INFO activating TextEdit while its windows are hidden: focused workspace $("$cli" list-workspaces --focused), $visible/2 windows on screen"

"$cli" workspace probe-a-empty
"$cli" move-workspace-to-monitor --workspace probe-a "$other"
"$cli" focus-monitor "$other"; "$cli" workspace probe-a
settle
[[ $other == main ]] && echo "SKIP floating window follows its workspace to the other monitor: one monitor" ||
    check "floating window follows its workspace to the other monitor" "$("$bench" --display "$w1")" "$display_other"
