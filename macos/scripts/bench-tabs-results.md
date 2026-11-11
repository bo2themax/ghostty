# Vertical tabs: benchmark results

Comparison of the `vertical-tabs` titlebar style against native tabs
(`transparent`) for the layouts tried, measured with `bench-tabs.zsh`.

## Approaches

| Approach | Commit | Layout | Hidden tabs keep |
|---|---|---|---|
| A. Split view | `d0f85fa4c` (branch `vertical-tabs-splitview`) | `NavigationSplitView`, sidebar column fixed at 220pt | sidebar views, no rows |
| B. Stack | (not committed, intermediate step) | `TabBarContainer` (HStack/VStack by edge) | bar views, no rows |
| C. Stack + empty hidden bars | `b04a2d1f4` (branch `vertical-tabs`) | same as B | an empty placeholder of the same width |

All three:

- keep native `NSWindow` tab groups;
- refresh only the selected tab's rows, coalesced per run loop;
- hold windows weakly.

B and C use a container that works for any edge. Only C keeps no bar views in
background tabs: the newly selected tab rebuilds its bar on `becomeKey`.

## Setup

- ReleaseLocal build, macOS 27 beta (Darwin 27.3), same machine.
- Command: `macos/scripts/bench-tabs.zsh -a macos/build/ReleaseLocal/Ghostty.app -n 30 -t 200`
  - 31 tabs, 3 switch rounds, 200 background title updates.
  - `undo-timeout = 0`, so closed tabs are not retained for undo.
- Each style runs in a fresh app instance. Each run measures native tabs first, then
  vertical tabs, so compare each vertical row with the native row from the same run.
  Baseline memory shifted between sessions: native measured 515 MB with tabs on the
  earlier day and 560 MB today.

Columns:

- create, switch, title, close: wall time per operation, in ms.
- cpu: app CPU seconds for the whole phase.
- mem: physical footprint in MB, measured with 31 tabs open and again after
  closing all but one tab.
- leaked: tab objects still alive after closing.

## Results

| Run | Style | create | cpu | switch | cpu | title | cpu | close | mem tabs | mem closed | leaked |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A-1 | native | 172–177 | 5.0–5.2 | 104 | 8.7–8.9 | 19.5 | 1.61–1.65 | 101–103 | 515–517 | 214–217 | 0 |
| A-1 | **A. split view** | 137–140 | 3.9–4.1 | 107 | 9.0–9.1 | 17.7–17.9 | 1.69–1.70 | 101–103 | 538–546 | 176–178 | 0 |
| B-1 | native | 173.9 | 5.27 | 100.5 | 8.41 | 19.35 | 1.70 | 102.1 | 562 | 190 | 0 |
| B-1 | **B. stack** | 115.2 | 3.41 | 96.6 | 8.09 | 17.40 | 1.70 | 95.9 | 600 | 194 | 0 |
| B-2 | native | 172.6 | 5.19 | 100.8 | 8.40 | 19.30 | 1.73 | 100.8 | 559 | 190 | 0 |
| B-2 | **B. stack** | 115.0 | 3.39 | 96.6 | 8.09 | 17.58 | 1.72 | 96.7 | 601 | 195 | 0 |
| C-1 | native | 171.9 | 5.17 | 101.6 | 8.45 | 19.49 | 1.72 | 100.7 | 560 | 189 | 0 |
| C-1 | **C. stack + empty hidden bars** | 115.1 | 3.38 | 104.9 | 8.81 | 17.44 | 1.72 | 99.2 | 552 | 192 | 0 |
| C-2 | native | 171.8 | 5.21 | 101.5 | 8.43 | 18.86 | 1.67 | 101.3 | 561 | 191 | 0 |
| C-2 | **C. stack + empty hidden bars** | 114.4 | 3.38 | 103.1 | 8.71 | 17.18 | 1.63 | 100.9 | 552 | 191 | 0 |

The A-1 rows are ranges over two runs from the earlier session.

## Relative to native in the same run

| | create | switch | title | memory with tabs | per tab |
|---|---|---|---|---|---|
| A. split view | −20% | +3% | −9% | +21–31 MB | ≈ +0.8 MB |
| B. stack | −34% | −4% | −10% | +38–42 MB | ≈ +1.3 MB |
| C. stack + empty hidden bars | −33% | +2–3% | −9–11% | −8–9 MB | ≈ −0.3 MB |

## Notes

- None of the approaches leaked tab windows, controllers, surfaces or models after
  closing.
- B is the fastest at switching because every tab window keeps its bar views
  alive. That costs the most memory.
- C trades about 2–3% switch time (the selected tab rebuilds its bar) for the
  lowest memory, below native tabs.
- An earlier variant of A kept rows in hidden tabs: +76 MB at 30 tabs (Debug).
- A fix applies to all three: background tab windows report `isVisible == true`,
  so the refresh is gated on `tabGroup.selectedWindow`. Before that fix, at 30 tabs:
  - title-update CPU was 1.67 s, against 0.45 s for native tabs;
  - memory was 119 MB higher.

## Not covered by the benchmark

- mouse input: click, hover close button, drag reorder, context menu
- the View > Show/Hide Tab Bar toggle and its animation
- fullscreen
- glass background blur
- whether the bar flashes empty for one frame on tab switch (C)
