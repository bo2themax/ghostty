#!/bin/sh
# Runs the in-process tab bar benchmark (Tests/Terminal/TerminalTabBarBenchmarks.swift)
# and prints a summary. See README.md.
#
# usage: in-process.sh [results.jsonl]
#
# Set STYLE to `new-tabs` or `native` to only run that style, e.g. to profile it
# with `sample` or Instruments while it runs.
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
macos=$(cd "$dir/../.." && pwd)
out=${1:-$macos/build/tab-bar-benchmark.jsonl}

locked() {
    ioreg -n Root -d1 | grep -q CGSSessionScreenIsLocked
}

if locked; then
    echo "error: the screen is locked, windows can't be shown" >&2
    exit 1
fi

mkdir -p "$(dirname "$out")"
rm -f "$out"

# Same clean environment as build.nu. `caffeinate` keeps the display awake so the
# screen doesn't lock half way through, and TEST_RUNNER_ variables are passed to
# the test process without the prefix.
caffeinate -d -u env -i \
    "HOME=$HOME" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "TEST_RUNNER_GHOSTTY_TAB_BAR_BENCHMARK=$out" \
    "TEST_RUNNER_GHOSTTY_TAB_BAR_BENCHMARK_STYLE=${STYLE:-}" \
    xcodebuild \
    -project "$macos/Ghostty.xcodeproj" \
    -scheme Ghostty \
    -configuration Debug \
    "SYMROOT=$macos/build" \
    -skip-testing GhosttyUITests \
    -only-testing:GhosttyTests/TerminalTabBarBenchmarks \
    test 2>&1 | grep -E "error:|\*\* TEST" || true

if locked; then
    echo "warning: the screen locked during the run, the results are not valid" >&2
fi

if [ ! -s "$out" ]; then
    echo "error: no results, the benchmark didn't run" >&2
    exit 1
fi

python3 "$dir/summarize.py" "$out"
