# Sourced by probe.sh, run.sh and crash-recovery.sh.
# Window ids come from the app that made the window, never from a diff of AeroSpace's window list.
# The server answers commands before its first window scan, so a diff also catches the user's windows
# that AeroSpace finds late, and the cleanup then closes them.

# new_window <app> [url]: prints the id of a window the app just created
new_window() {
    local make='make new document' id
    [[ -n ${2:-} ]] && make="make new document with properties {URL:\"$2\"}"
    id=$(osascript -e "tell application \"$1\"" -e 'set known to id of every window' -e "$make" \
        -e 'repeat with w in windows' -e 'if known does not contain (id of w) then return id of w' \
        -e 'end repeat' -e 'end tell')
    [[ $id =~ ^[0-9]+$ ]] || { echo "$1 made no new window" >&2; return 1; }
    echo "$id"
}

# close_windows <app> <id>...: closes those windows without saving; never touches the app's other windows
close_windows() {
    local app=$1 id
    shift
    for id in "$@"; do osascript -e "tell application \"$app\" to close (every window whose id is $id) saving no"; done
}

# wait_tracked <cli> <id>...: waits until AeroSpace lists every id
wait_tracked() {
    local cli=$1 all id missing
    shift
    for _ in $(seq 50); do
        all=$("$cli" list-windows --all --format '%{window-id}') missing=
        for id in "$@"; do grep -qx "$id" <<< "$all" || missing=1; done
        [[ -z $missing ]] && return 0
        sleep 0.2
    done
    echo "AeroSpace never listed windows $*" >&2
    return 1
}
