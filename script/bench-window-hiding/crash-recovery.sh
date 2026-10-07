#!/usr/bin/env bash
# Usage: script/bench-window-hiding/crash-recovery.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source script/bench-window-hiding/lib.sh
cli=./.debug/aerospace
bench=.build/bench/bench-window-hiding
out=$(mktemp -d)
journal="$(getconf DARWIN_USER_TEMP_DIR)bobko.aerospace.debug.private-space.json"
[[ -e $journal ]] && { echo "journal exists, a stash may be pending: $journal"; exit 1; }
mkdir -p .build/bench
[[ $bench -nt script/bench-window-hiding/main.swift ]] || swiftc -O script/bench-window-hiding/main.swift -o "$bench"
printf 'config-version = 2\nhide-windows-in-private-space = true\n' > "$out/config.toml"
server=; ids=()
cleanup() {
    [[ -n $server ]] && { kill -INT "$server" 2> /dev/null; wait "$server" 2> /dev/null; }
    rmdir "$journal" 2> /dev/null
    (( ${#ids[@]} == 0 )) || close_windows TextEdit "${ids[@]}"
}
trap cleanup EXIT
start() {
    ./.debug/AeroSpaceApp --config-path "$out/config.toml" >> "$out/server.log" 2>&1 &
    server=$!
    for _ in $(seq 100); do "$cli" list-workspaces --focused > /dev/null 2>&1 && break; sleep 0.3; done
    "$cli" list-workspaces --focused > /dev/null || { echo "server didn't start"; exit 1; }
    (( ${#ids[@]} == 0 )) || wait_tracked "$cli" "${ids[@]}"
}
stop() { kill "-$1" "$server"; wait "$server" 2> /dev/null || true; server=; }

start
for _ in 1 2 3; do id=$(new_window TextEdit); ids+=("$id"); done
wait_tracked "$cli" "${ids[@]}"
sleep 2
csv=$(IFS=,; echo "${ids[*]}")
for id in "${ids[@]}"; do "$cli" move-node-to-workspace --window-id "$id" crash-test; done
sleep 1
echo "stashed, on screen: $("$bench" --on-screen "$csv")/${#ids[@]} (expect 0)"
stop KILL
sleep 1
echo "after SIGKILL, on screen: $("$bench" --on-screen "$csv")/${#ids[@]} (expect 0: stranded)"
start
sleep 2
back=$("$bench" --on-screen "$csv")
echo "after relaunch, on screen: $back/${#ids[@]} (expect ${#ids[@]})"
for id in "${ids[@]}"; do "$cli" move-node-to-workspace --window-id "$id" crash-test; done
sleep 1
echo "stashed again, on screen: $("$bench" --on-screen "$csv")/${#ids[@]} (expect 0)"
stop INT
sleep 1
quit=$("$bench" --on-screen "$csv")
echo "after quit, on screen: $quit/${#ids[@]} (expect ${#ids[@]})"

# A journal that can't be written must stop stashing, so a crash can't strand untracked windows
mkdir "$journal" # a directory where the journal file belongs makes every write fail
start
"$cli" move-node-to-workspace --window-id "${ids[0]}" crash-test
sleep 1
unwritable=$("$bench" --state "${ids[0]}")
echo "journal unwritable, hidden window: $unwritable (expect sliver: corner)"
stop INT

[[ $back == "${#ids[@]}" && $quit == "${#ids[@]}" && $unwritable == sliver ]] && echo "PASS" || { echo "FAIL"; exit 1; }
