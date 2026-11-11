#!/usr/bin/env zsh
#
# Benchmarks tab performance and memory of the macOS app for one or more
# `macos-titlebar-style` values, e.g. the native tab bar vs. vertical tabs.
#
# Each style runs in a fresh app instance with an isolated config and is
# driven through AppleScript:
#
#   create   open N tabs in one window
#   switch   select every tab, ROUNDS times
#   title    rename background tabs TITLES times (sidebar update path)
#   close    close every tab but the first
#
# Reported per style:
#   *_ms     wall time per operation as seen by AppleScript (main thread work)
#   *_cpu    app CPU seconds consumed during the phase
#   mem      physical footprint (MB) at launch, with N+1 tabs, after closing
#   leaked   tab objects still alive after closing (should be 0)
#
# Usage:
#   macos/scripts/bench-tabs.zsh [-a APP] [-n TABS] [-r ROUNDS] [-t TITLES] [STYLE ...]
#
# Defaults: APP=macos/build/Release/Ghostty.app (falls back to Debug),
# TABS=20, ROUNDS=3, TITLES=100, styles "transparent vertical-tabs".
# Prefer a Release build; Debug numbers are dominated by debug overhead.
#
# The first run asks for permission to control Ghostty (Automation).
# `heap` needs the get-task-allow entitlement (Debug builds have it); without
# it the leak column shows "n/a".

emulate -L zsh
setopt err_return pipe_fail
zmodload zsh/datetime

script_dir=${0:A:h}
app=""
tabs=20
rounds=3
titles=100

while getopts "a:n:r:t:h" opt; do
    case $opt in
        a) app=${OPTARG:A} ;;
        n) tabs=$OPTARG ;;
        r) rounds=$OPTARG ;;
        t) titles=$OPTARG ;;
        *) sed -n '2,32p' $0 | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done
shift $((OPTIND - 1))
styles=("$@")
(( $#styles )) || styles=(transparent vertical-tabs)

if [[ -z $app ]]; then
    for config in Release ReleaseLocal Debug; do
        if [[ -d $script_dir/../build/$config/Ghostty.app ]]; then
            app=${script_dir:h}/build/$config/Ghostty.app
            break
        fi
    done
fi
[[ -d $app ]] || { print -u2 "app not found, build it first or pass -a"; exit 1 }
bin=$app/Contents/MacOS/ghostty

work=$(mktemp -d /tmp/ghostty-bench-tabs.XXXXXX)
pid=""

# The app writes files such as default.profraw into its working directory.
cd $work

cleanup() {
    [[ -n $pid ]] && kill $pid 2>/dev/null
    rm -rf $work
}
trap cleanup EXIT INT TERM

ascript() {
    osascript -e "tell application \"$app\"" -e "$1" -e "end tell"
}

# CPU seconds used so far by the app (ps prints [[dd-]hh:]mm:ss.cc).
cpu_seconds() {
    ps -o time= -p $pid | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

footprint_mb() {
    footprint -p $pid 2>/dev/null |
        awk '{ for (i = 1; i < NF - 1; i++) if ($i == "Footprint:") {
                 v = $(i + 1); u = $(i + 2)
                 if (u == "KB") v /= 1024; if (u == "GB") v *= 1024
                 printf "%.1f", v; exit } }'
}

# Live instances of the per-tab classes beyond the one remaining tab. Window
# classes are counted together since KVO renames observed instances.
leaked_objects() {
    heap $pid 2>/dev/null | awk '
        $5 != "Swift" { next }
        $4 ~ /(^|\.)TerminalController$/ { n["controller"] += $1 }
        $4 ~ /(^|\.)SurfaceView$/        { n["surface"] += $1 }
        $4 ~ /TerminalWindow$/            { n["window"] += $1 }
        $4 ~ /(^|\.)VerticalTabsModel$/  { n["sidebar"] += $1 }
        END {
            if (!("controller" in n)) { print "n/a"; exit }
            leaked = 0; for (c in n) if (n[c] > 1) leaked += n[c] - 1
            print leaked
        }'
}

wait_for_window() {
    local i
    for i in {1..50}; do
        [[ $(ascript "count windows" 2>/dev/null) -ge 1 ]] && return 0
        sleep 0.2
    done
    print -u2 "app did not open a window"
    return 1
}

# Runs an AppleScript phase and prints "<ms per op> <cpu seconds>".
timed_phase() {
    local ops=$1 body=$2 cpu0 cpu1 t0 t1
    cpu0=$(cpu_seconds)
    t0=$EPOCHREALTIME
    ascript $body >/dev/null
    t1=$EPOCHREALTIME
    cpu1=$(cpu_seconds)
    printf "%.2f %.2f" $(( (t1 - t0) * 1000.0 / ops )) $(( cpu1 - cpu0 ))
}

bench_style() {
    local style=$1 conf=$work/$1.conf
    cat > $conf <<EOF
macos-titlebar-style = $style
window-save-state = never
confirm-close-surface = false
undo-timeout = 0
command = /bin/sh
EOF

    $bin --config-default-files=false --config-file=$conf >$work/$style.log 2>&1 &
    pid=$!
    wait_for_window
    sleep 2

    local mem_base=$(footprint_mb)

    local create=$(timed_phase $tabs "
        set w to front window
        repeat $tabs times
            new tab in w
        end repeat")
    sleep 2
    local mem_tabs=$(footprint_mb)

    local total=$((tabs + 1))
    local switch=$(timed_phase $((rounds * total)) "
        set w to front window
        repeat $rounds times
            repeat with i from 1 to (count tabs of w)
                set t to tab i of w
                select tab t
            end repeat
        end repeat")

    # Rename tabs other than the selected one, so the visible sidebar has to
    # pick up changes from background windows.
    local title=$(timed_phase $titles "
        set w to front window
        set n to count tabs of w
        repeat with k from 1 to $titles
            set t to tab ((k mod (n - 1)) + 1) of w
            set name override of t to \"bench \" & k
        end repeat")

    local close=$(timed_phase $tabs "
        set w to front window
        repeat while (count tabs of w) > 1
            set t to tab (count tabs of w) of w
            close tab t
        end repeat")
    sleep 3
    local mem_closed=$(footprint_mb)
    local leaked=$(leaked_objects)

    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
    pid=""

    printf "%-14s %9s %9s %9s %9s %9s %9s %9s %9s %9s %9s %9s %7s\n" \
        $style ${=create} ${=switch} ${=title} ${=close} \
        $mem_base $mem_tabs $mem_closed $leaked
}

print "app:    $app"
print "tabs:   $tabs (+1), switch rounds: $rounds, title updates: $titles"
print
printf "%-14s %9s %9s %9s %9s %9s %9s %9s %9s %9s %9s %9s %7s\n" \
    style create_ms cpu_s switch_ms cpu_s title_ms cpu_s close_ms cpu_s \
    mem_base mem_tabs mem_closed leaked
for style in $styles; do
    bench_style $style
done
