#!/usr/bin/env bash
# Usage: script/bench-window-hiding/crash-recovery.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source script/bench-window-hiding/lib.sh
cli=./.debug/aerospace
bench=.build/bench/bench-window-hiding
out=$(mktemp -d)
mkdir -p .build/bench
[[ $bench -nt script/bench-window-hiding/main.swift ]] || swiftc -O script/bench-window-hiding/main.swift -o "$bench"
printf 'config-version = 2\nhide-windows-in-private-space = true\n' > "$out/config.toml"
start() {
    ./.debug/AeroSpaceApp --config-path "$out/config.toml" >> "$out/server.log" 2>&1 &
    server=$!
    for _ in $(seq 100); do "$cli" list-workspaces --focused > /dev/null 2>&1 && return; sleep 0.3; done
    echo "server didn't start"; exit 1
}
start
ids=()
for _ in 1 2 3; do id=$(new_window TextEdit); ids+=("$id"); done
wait_tracked "$cli" "${ids[@]}"
sleep 2
csv=$(IFS=,; echo "${ids[*]}")
for id in "${ids[@]}"; do "$cli" move-node-to-workspace --window-id "$id" crash-test; done
sleep 1
echo "stashed, on screen: $("$bench" --on-screen "$csv")/${#ids[@]} (expect 0)"
kill -KILL "$server"; wait "$server" 2> /dev/null || true
sleep 1
echo "after SIGKILL, on screen: $("$bench" --on-screen "$csv")/${#ids[@]} (expect 0: stranded)"
start
sleep 2
back=$("$bench" --on-screen "$csv")
echo "after relaunch, on screen: $back/${#ids[@]} (expect ${#ids[@]})"
for id in "${ids[@]}"; do "$cli" move-node-to-workspace --window-id "$id" crash-test; done
sleep 1
echo "stashed again, on screen: $("$bench" --on-screen "$csv")/${#ids[@]} (expect 0)"
kill -INT "$server"; wait "$server" 2> /dev/null || true
sleep 1
quit=$("$bench" --on-screen "$csv")
echo "after quit, on screen: $quit/${#ids[@]} (expect ${#ids[@]})"
"$bench" --close "$(pgrep -x TextEdit | head -1)" "$csv"
[[ $back == "${#ids[@]}" && $quit == "${#ids[@]}" ]] && echo "PASS" || { echo "FAIL"; exit 1; }
