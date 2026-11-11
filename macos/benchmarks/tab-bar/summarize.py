#!/usr/bin/env python3
"""Summarizes results of the in-process tab bar benchmark.

usage: summarize.py results.jsonl [other.jsonl ...]

With more than one file, the files are shown next to each other so that two
versions of the code can be compared.
"""

import collections
import json
import os
import statistics
import sys

TIMINGS = ["new_tab_us", "select_tab_us", "retitle_us", "move_tab_us", "close_tab_us"]
COUNTS = ["views_per_tab"]


def load(path):
    groups = collections.defaultdict(list)
    with open(path) as f:
        for line in f:
            if line.strip():
                row = json.loads(line)
                groups[(row["tabs"], row["style"])].append(row)
    return groups


def main():
    paths = sys.argv[1:]
    if not paths:
        sys.exit(__doc__)

    for path in paths:
        groups = load(path)
        rounds = max(len(rows) for rows in groups.values())
        print(f"{os.path.basename(path)}: mean of {rounds} rounds, times in ms")
        header = ["tabs", "style"] + [k.replace("_us", "") for k in TIMINGS] + COUNTS
        print("".join(f"{h:>14}" for h in header))
        for (tabs, style), rows in sorted(groups.items()):
            cells = [str(tabs), style]
            for key in TIMINGS:
                values = [r[key] for r in rows if key in r]
                cells.append(f"{statistics.mean(values) / 1000:.2f}" if values else "-")
            for key in COUNTS:
                cells.append(f"{statistics.median(r[key] for r in rows):.1f}")
            print("".join(f"{c:>14}" for c in cells))

        # How the custom tab bar compares to the native one, per tab count.
        for tabs in sorted({t for t, _ in groups}):
            native, custom = groups.get((tabs, "native")), groups.get((tabs, "new-tabs"))
            if not native or not custom:
                continue
            parts = []
            for key in TIMINGS:
                a = [r[key] for r in native if key in r]
                b = [r[key] for r in custom if key in r]
                if a and b:
                    change = statistics.mean(b) / statistics.mean(a) - 1
                    parts.append(f"{key.replace('_us', '')} {change:+.0%}")
            print(f"  {tabs} tabs, new-tabs vs native: " + ", ".join(parts))
        print()


if __name__ == "__main__":
    main()
