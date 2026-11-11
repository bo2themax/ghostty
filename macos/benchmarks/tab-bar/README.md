# Tab Bar Benchmarks

Benchmarks for the custom tab bar (`macos-titlebar-style = new-tabs`). The
requirement they exist to check is that the custom tab bar is no worse than
the native tab bar in time or memory, and that it doesn't leak.

There are two benchmarks because no single one can answer both "how much does
the tab bar cost?" and "does it matter in the real app?".

| Benchmark       | Runs                                  | Good for                                       |
| --------------- | ------------------------------------- | ---------------------------------------------- |
| `in-process.sh` | Windows without terminals, in a test  | Timing the tab bar itself against the native one |
| `app.py`        | The real app with terminals           | Memory, leaks, and a sanity check on timing    |

## Requirements

- Build the debug app first: `macos/build.nu`.
- **The screen must be unlocked and must stay unlocked.** Windows of a locked
  session aren't shown, and a tab bar only has tabs while its window is shown,
  so a run that overlaps a lock measures nothing useful. Both scripts refuse to
  start when locked and flag a run that ended locked, but the reliable fix is
  to turn off automatic locking and display sleep while benchmarking.
  `in-process.sh` also holds the display awake with `caffeinate`.
- `app.py` drives the app with AppleScript, so the terminal you run it from
  needs the Automation permission for the debug app.
- Don't use the machine during a run. The tests move focus between windows.

## `in-process.sh`

```sh
macos/benchmarks/tab-bar/in-process.sh [results.jsonl]
macos/benchmarks/tab-bar/summarize.py before.jsonl after.jsonl
```

Runs `Tests/Terminal/TerminalTabBarBenchmarks.swift` inside the test host and
prints a summary. The benchmark is skipped unless `GHOSTTY_TAB_BAR_BENCHMARK`
is set, which the script does.

### What it measures

For 10 and 50 tabs, with the custom tab bar and with the native one:

- `new_tab`: create a window, add it to the tab group, select it.
- `select_tab`: select another tab.
- `retitle`: change the title of a tab. Terminals do this constantly, and
  nine in ten changes are to a tab in the background, as in real use.
- `move_tab`: move a background tab to the other end of the tab group.
- `close_tab`: close the selected tab.
- `views_per_tab`: views in all windows of the tab group divided by the number
  of tabs. This is a proxy for how much the tab bar keeps around per tab.

Every operation is followed by a flush: run what was deferred to the main
queue, lay out, draw, and commit the Core Animation transaction. Without that
the benchmark would only time the bookkeeping and miss the work that is
deferred to the next frame, which is where most of a tab bar's cost is. The
custom tab bar in particular defers reloads to the main queue.

### Why it is built this way

- **Real windows in a real `NSWindowTabGroup`.** The custom tab bar mirrors
  the native tab group and reacts to what AppKit does to it, so a benchmark
  with mock windows would skip the part that matters.
- **No terminals.** A terminal surface costs far more than a tab bar. With
  terminals in the windows the tab bar is lost in the noise (see `app.py`).
- **The native tab bar as the baseline, in the same process.** The absolute
  numbers depend on the machine, the OS, and the debug build. Only the
  comparison between the two styles means something.
- **Order is alternated between rounds.** Every operation gets slower the
  longer the process runs, because the test host doesn't release closed
  windows promptly (within one run the same operation was up to twice as slow
  in the last round as in the first). An early version always ran the custom
  tab bar first, which favoured it. Now the order flips each round and the
  summary is the mean over an even number of rounds, so both styles are
  equally affected.
- **A warm-up round** so that neither style pays for one-time setup.
- **No memory numbers.** Footprint measured from inside the process varied
  from below zero to 10 MB per tab between rounds, because closed windows are
  released late and the first round pays for caches. Use `app.py` for memory.

### Reading the results

Most of the time in every row is AppKit's own tab group and window work, which
is the same for both styles and grows with the number of tabs. The tab bar is
a small share of it. So expect differences between the styles, and between
two versions of the custom tab bar, to be in the range of a few percent to
20%, and treat differences of a few percent as noise unless they repeat.

## `app.py`

```sh
macos/benchmarks/tab-bar/app.py new-tabs top 20
macos/benchmarks/tab-bar/app.py new-tabs left 20
macos/benchmarks/tab-bar/app.py transparent - 20
macos/benchmarks/tab-bar/app.py native - 20
macos/benchmarks/tab-bar/app.py tabs - 20
```

Launches the debug app with the given titlebar style and an isolated
configuration, then drives it over AppleScript: create tabs, select every tab
three times, rename every tab five times, close all but one tab. It prints one
JSON object.

### What it measures

- `footprint_mb`: physical footprint (from `footprint`) with one tab, with
  all tabs, after selecting and renaming tabs, and after closing them.
  `per_tab` is dominated by the terminal, so compare it between styles rather
  than reading it as the cost of a tab bar.
- `churn_mb`: which footprint categories grew while selecting and renaming
  tabs. This is how we found that recreating the tab views on every tab switch
  grew "owned unmapped" memory by 10 to 20 MB; handing the views over to the
  next tab bar instead fixed it.
- `live_objects_open` / `live_objects_closed`: live instances (from `heap`) of
  the window class and the tab bar classes, with all tabs open and after
  closing them. With N tabs open there must be N `TerminalTabBarItemView`s,
  not N per window, and after closing all but one tab there must be one window,
  one tab bar, and one item left. This is the leak check that matters.
- `leaks`: what `leaks` reports. The same small number shows up for every
  style, so it isn't caused by the tab bar.
- `ms`: time per operation **including AppleScript overhead**.

### Why it is built this way

- **The real app**, because memory and leaks depend on everything a tab owns,
  and because a regression that only shows with real terminals would be
  missed by the in-process benchmark.
- **`/bin/cat` as the command** instead of a shell, so that the user's shell
  configuration doesn't affect startup time or memory.
- **`--config-default-files=false` and a separate user defaults suite**, so
  the run doesn't depend on, or change, the user's configuration.
- **`heap` and `footprint` instead of in-process counters**, because they see
  the process from the outside after it has settled.

### Limits

- The timings are only meaningful relative to another style in the same
  session. Each operation is an AppleScript round trip, which costs more than
  the tab bar does.
- It is a debug build. Release numbers are lower across the board.
- Animations and how things look are not covered by either benchmark.
