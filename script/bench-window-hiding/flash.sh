#!/usr/bin/env bash
# Usage: script/bench-window-hiding/flash.sh [true|false] [switches=10]   (hide-windows-in-private-space, default true)
# Switches from a TextEdit window to an Activity Monitor window on another workspace and records the screen.
# FAILs when any switch flashes the title of the window being shown. A switch that shows the old window again for a
# frame is reported as KNOWN: the two Space moves can render in separate frames, and SkyLight can't batch them.
# Needs Screen Recording for the shell (see vm-test.sh).
set -uo pipefail
cd "$(dirname "$0")/../.."
source script/bench-window-hiding/lib.sh
cli=./.debug/aerospace
bench=.build/bench/bench-window-hiding
check=.build/bench/flash-check
out=$(mktemp -d)
switches=${2:-10}
mkdir -p .build/bench
[[ $bench -nt script/bench-window-hiding/main.swift ]] || swiftc -O script/bench-window-hiding/main.swift -o "$bench" || exit 1
[[ $check -nt script/bench-window-hiding/flash.swift ]] || swiftc -O script/bench-window-hiding/flash.swift -o "$check" || exit 1
printf '%s\n' 'config-version = 2' "hide-windows-in-private-space = ${1:-true}" > "$out/config.toml"
pgrep -x 'Activity Monitor' > /dev/null && { echo "FAIL setup: quit Activity Monitor first, the test closes it"; exit 1; }
./.debug/AeroSpaceApp --config-path "$out/config.toml" > "$out/server.log" 2>&1 &
server=$!
ids=()
cleanup() {
    for id in ${ids[@]+"${ids[@]}"}; do "$cli" close --window-id "$id" > /dev/null 2>&1 || true; done
    osascript -e 'quit application "Activity Monitor"' > /dev/null 2>&1
    kill -INT "$server" 2> /dev/null; wait "$server" 2> /dev/null
    echo "server log: $out/server.log"
}
trap cleanup EXIT
for _ in $(seq 100); do "$cli" list-workspaces --focused > /dev/null 2>&1 && break; sleep 0.3; done

a=$(new_window TextEdit) && ids+=("$a") || exit 1
osascript -e "tell application \"TextEdit\" to set d to document of (first window whose id is $a)" \
    -e 'set text of d to "AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA"' \
    -e 'tell application "TextEdit" to set size of text of d to 90' > /dev/null
open -a 'Activity Monitor'
b=
for _ in $(seq 50); do
    b=$("$cli" list-windows --monitor all --app-bundle-id com.apple.ActivityMonitor --format '%{window-id}' | head -1)
    [[ -n $b ]] && break
    sleep 0.2
done
[[ -n $b ]] && ids+=("$b") && wait_tracked "$cli" "$a" "$b" || { echo "FAIL setup: no Activity Monitor window"; exit 1; }

"$cli" workspace flash-a; "$cli" move-node-to-workspace --window-id "$a" flash-a
"$cli" workspace flash-b; "$cli" move-node-to-workspace --window-id "$b" flash-b; "$cli" focus --window-id "$b"
sleep 1
read -r x y w h < <("$bench" --frame "$b")
[[ $h =~ ^[0-9]+$ ]] || { echo "FAIL setup: Activity Monitor window $b is not on screen"; exit 1; }
flashed=0 reverted=0
switch() {
    "$cli" workspace flash-a; "$cli" focus --window-id "$a"
    sleep 2
    path=$("$check" "$x" "$y" "$w" "$h" "$cli" workspace flash-b)
}
for i in $(seq "$switches"); do
    switch
    status=$?
    [[ $status == 2 ]] && { echo "INFO switch $i proves nothing, retrying: $path"; switch; status=$?; }
    case $status in
        0) ;;
        1) flashed=$((flashed + 1)); echo "INFO switch $i flashed: $path" ;;
        3) reverted=$((reverted + 1)); echo "INFO switch $i showed the old window again: $path" ;;
        *) echo "FAIL setup: switch $i proves nothing: $path"; exit 1 ;;
    esac
done
[[ $reverted == 0 ]] || echo "KNOWN $reverted/$switches switches showed the old window again for a frame"
[[ $flashed == 0 ]] && echo "PASS $switches switches show the focused window without a title flash" ||
    echo "FAIL $flashed/$switches switches flashed the title of the window being shown"
