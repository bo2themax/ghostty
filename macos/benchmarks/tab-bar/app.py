#!/usr/bin/env python3
"""Benchmarks tabs in the real (debug) app, driven over AppleScript.

usage: app.py <titlebar style> <tab bar position or -> <tab count>
   eg: app.py new-tabs left 20
       app.py transparent - 20

Prints one JSON object. See README.md for what is measured and what the
numbers are good for.
"""

import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.normpath(os.path.join(HERE, "../../build/Debug/Ghostty.app"))
BINARY = os.path.join(APP, "Contents/MacOS/ghostty")

# The debug app reads its user defaults from this suite when the environment
# variable below is set, so the benchmark doesn't touch the real preferences.
DEFAULTS_SUITE = "com.mitchellh.ghostty.tab-bar-benchmark"

WINDOW_CLASSES = {
    "new-tabs": "NewTabsTerminalWindow",
    "transparent": "TransparentTitlebarTerminalWindow",
    "native": "TerminalWindow",
    "tabs": "TitlebarTabsTahoeTerminalWindow",
}
UNITS = {"KB": 1 / 1024, "MB": 1, "GB": 1024}


def sh(command):
    return subprocess.run(command, shell=True, capture_output=True, text=True).stdout


def locked():
    return "CGSSessionScreenIsLocked" in sh("ioreg -n Root -d1")


def osa(body):
    """Runs AppleScript in the app. Returns how long that took in seconds."""
    script = f'with timeout of 300 seconds\ntell application "{APP}"\n{body}\nend tell\nend timeout'
    start = time.perf_counter()
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    elapsed = time.perf_counter() - start
    if result.returncode != 0:
        sys.exit(f"AppleScript failed: {result.stderr.strip()}")
    return elapsed


def quit_app():
    sh(f"pkill -f '{BINARY}'")
    time.sleep(1)


def footprint(pid):
    """The physical footprint in MB and its breakdown by category."""
    out = sh(f"footprint {pid}")
    total = re.search(r"phys_footprint: ([\d.]+) (\w+)", out)
    categories = {}
    for line in out.splitlines():
        m = re.match(r"\s*([\d.]+) (KB|MB|GB)\s+[\d.]+ \w+\s+[\d.]+ \w+\s+\d+\s+(.+)$", line)
        if m and m.group(3).strip() != "TOTAL":
            categories[m.group(3).strip()] = float(m.group(1)) * UNITS[m.group(2)]
    return float(total.group(1)) * UNITS[total.group(2)], categories


def heap(pid, classes):
    """The number of live instances of the given classes."""
    out = sh(f"heap {pid}")
    counts = {}
    for name in classes:
        m = re.search(r"^\s*(\d+)\s+\d+\s+[\d.]+\s+(?:\S+\.)?%s\s" % re.escape(name), out, re.M)
        counts[name] = int(m.group(1)) if m else 0
    return counts


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    style, position, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    if not os.path.exists(BINARY):
        sys.exit(f"{APP} doesn't exist, build it with macos/build.nu")
    if locked():
        sys.exit("the screen is locked, windows can't be shown")

    quit_app()
    if position != "-":
        sh(f"defaults write {DEFAULTS_SUITE} NewTabsTabBarPosition {position}")

    # `cat` instead of a shell so that we don't measure the user's shell config.
    sh(
        f'open -n "{APP}" --env GHOSTTY_USER_DEFAULTS_SUITE={DEFAULTS_SUITE} --args'
        " --config-default-files=false --window-save-state=never"
        f" --macos-titlebar-style={style} --confirm-close-surface=false"
        " --macos-applescript=true --command=/bin/cat"
    )
    time.sleep(4)
    osa("activate")
    time.sleep(2)
    pid = sh(f"pgrep -f '{BINARY}' | head -1").strip()

    one_tab, _ = footprint(pid)
    new_tab = osa(f"repeat {n - 1} times\nnew tab in front window\nend repeat")
    time.sleep(4)
    all_tabs, before_churn = footprint(pid)

    select = osa(
        f"repeat 3 times\nrepeat with i from 1 to {n}\n"
        "select tab (tab i of front window)\nend repeat\nend repeat"
    )
    retitle = osa(
        f"repeat with k from 1 to 5\nrepeat with i from 1 to {n}\n"
        'set name override of tab i of front window to "title " & k & " " & i\n'
        "end repeat\nend repeat"
    )
    time.sleep(3)
    after_churn, churn_categories = footprint(pid)

    classes = [
        WINDOW_CLASSES[style], "TerminalTabBarView", "TerminalTabBarItemView",
        "NSTabButton", "CALayer", "CATextLayer",
    ]
    live_open = heap(pid, classes)

    close = osa(f"repeat {n - 1} times\nclose tab (tab 1 of front window)\nend repeat")
    time.sleep(6)
    after_close, _ = footprint(pid)
    live_closed = heap(pid, classes)
    leaks = re.search(r"(\d+) leaks? for (\d+) total leaked bytes", sh(f"leaks {pid}"))
    was_locked = locked()
    quit_app()

    print(json.dumps({
        "style": style,
        "position": position,
        "tabs": n,
        "valid": not was_locked,
        "footprint_mb": {
            "one_tab": round(one_tab, 1),
            "all_tabs": round(all_tabs, 1),
            "per_tab": round((all_tabs - one_tab) / (n - 1), 2),
            "after_churn": round(after_churn, 1),
            "after_close": round(after_close, 1),
        },
        # What grew while selecting and renaming tabs, by footprint category.
        "churn_mb": {
            k: round(churn_categories.get(k, 0) - before_churn.get(k, 0), 1)
            for k in set(before_churn) | set(churn_categories)
            if abs(churn_categories.get(k, 0) - before_churn.get(k, 0)) >= 0.5
        },
        "ms": {
            "new_tab": round(new_tab * 1000 / (n - 1), 1),
            "select_tab": round(select * 1000 / (3 * n), 2),
            "retitle": round(retitle * 1000 / (5 * n), 2),
            "close_tab": round(close * 1000 / (n - 1), 1),
        },
        "live_objects_open": live_open,
        "live_objects_closed": live_closed,
        "leaks": leaks.group(0) if leaks else None,
    }))


if __name__ == "__main__":
    main()
