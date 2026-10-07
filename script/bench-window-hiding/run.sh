#!/usr/bin/env bash
# Usage: script/bench-window-hiding/run.sh <out-dir> [cycles=20] [windows-per-workspace=6] [blocks=2]
# STOCK=1 APP=... CLI=... measures a build without the private-Space option (corner only).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$1; cycles=${2:-20}; per=${3:-6}; blocks=${4:-2}
app=${APP:-./.debug/AeroSpaceApp}; cli=${CLI:-./.debug/aerospace}
methods=(corner private-space); [[ ${STOCK:-0} == 1 ]] && methods=(corner)
mkdir -p "$out" .build/bench
bench=.build/bench/bench-window-hiding
[[ $bench -nt script/bench-window-hiding/main.swift ]] || swiftc -O script/bench-window-hiding/main.swift -o "$bench"
cfg="$out/config.toml"

write_config() {
    { echo 'config-version = 2'
      [[ ${STOCK:-0} == 1 ]] || echo "hide-windows-in-private-space = $1"
      echo '[gaps]'; echo 'inner.horizontal = 0'; echo 'inner.vertical = 0'; echo 'outer.left = 0'
      echo 'outer.bottom = 0'; echo 'outer.top = 0'; echo 'outer.right = 0'; } > "$cfg"
}

write_config false
"$app" --config-path "$cfg" > "$out/server.log" 2>&1 &
server=$!
created=()
cleanup() {
    for id in ${created[@]+"${created[@]}"}; do "$cli" close --window-id "$id" > /dev/null 2>&1 || true; done
    kill -INT "$server" 2> /dev/null || true
    wait "$server" 2> /dev/null || true
}
trap cleanup EXIT
for _ in $(seq 100); do "$cli" list-workspaces --focused > /dev/null 2>&1 && break; sleep 0.3; done
"$cli" list-workspaces --focused > /dev/null || { echo "server didn't start (Accessibility permission?)"; exit 1; }

page="$out/page.html"
{ echo '<h1>bench</h1>'; for i in $(seq 200); do printf '<p>paragraph %s %s</p>\n' "$i" "$(printf 'lorem ipsum %.0s' $(seq 40))"; done; } > "$page"
open -ga TextEdit && open -ga Safari && sleep 3
before=$("$cli" list-windows --all --format '%{window-id}' | sort)
for i in $(seq $((per / 2 * 2))); do
    osascript -e 'tell application "TextEdit" to make new document' > /dev/null
    osascript -e "tell application \"Safari\" to make new document with properties {URL:\"file://$PWD/$page\"}" > /dev/null
done
sleep 2
created=($(comm -13 <(echo "$before") <("$cli" list-windows --all --format '%{window-id}' | sort)))
echo "created ${#created[@]} windows"
for i in "${!created[@]}"; do
    "$cli" move-node-to-workspace --window-id "${created[$i]}" "bench-$((i % 2 == 0 ? 0 : 1))"
done
for ws in bench-0 bench-1; do "$cli" list-windows --workspace "$ws" --format '%{workspace} %{window-id} %{app-name}'; done > "$out/windows.txt"

for block in $(seq "$blocks"); do
    for m in "${methods[@]}"; do
        write_config "$([[ $m == private-space ]] && echo true || echo false)"
        "$cli" reload-config --no-gui
        "$bench" --cli "$cli" --server-pid "$server" --ws-a bench-0 --ws-b bench-1 --cycles "$cycles" \
            --label "${LABEL_PREFIX:-}$m" --out "$out/$m-$block.tsv" > /dev/null
        echo "block $block $m done"
    done
done
if /usr/bin/xcrun --find python3 > /dev/null 2>&1 || [[ -x /opt/homebrew/bin/python3 ]]; then
    python3 script/bench-window-hiding/summarize.py "$out"/*.tsv | tee "$out/summary.txt"
else
    echo "no python3: run script/bench-window-hiding/summarize.py $out/*.tsv elsewhere"
fi
