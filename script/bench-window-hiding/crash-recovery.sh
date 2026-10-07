#!/usr/bin/env bash
# Usage: script/bench-window-hiding/crash-recovery.sh
# Stashes windows into the private Space, kills AeroSpace with SIGKILL, and checks that the
# windows are off screen while it's dead and back on screen after relaunch.
set -euo pipefail
cd "$(dirname "$0")/../.."
cli=./.debug/aerospace
bench=.build/bench/bench-window-hiding
out=$(mktemp -d)
mkdir -p .build/bench
swiftc -O script/bench-window-hiding/main.swift -o "$bench"
printf 'config-version = 2\nhide-windows-in-private-space = true\n' > "$out/config.toml"
start() {
    ./.debug/AeroSpaceApp --config-path "$out/config.toml" >> "$out/server.log" 2>&1 &
    server=$!
    for _ in $(seq 100); do "$cli" list-workspaces --focused > /dev/null 2>&1 && return; sleep 0.3; done
    echo "server didn't start"; exit 1
}
start
before=$("$cli" list-windows --all --format '%{window-id}' | sort)
for _ in 1 2 3; do osascript -e 'tell application "TextEdit" to make new document' > /dev/null; done
sleep 2
ids=($(comm -13 <(echo "$before") <("$cli" list-windows --all --format '%{window-id}' | sort)))
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
for id in "${ids[@]}"; do "$cli" close --window-id "$id" > /dev/null 2>&1 || true; done
kill -INT "$server"; wait "$server" 2> /dev/null || true
[[ $back == "${#ids[@]}" ]] && echo "PASS" || { echo "FAIL"; exit 1; }
