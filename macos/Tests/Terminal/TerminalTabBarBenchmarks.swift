import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// Benchmarks that compare the custom tab bar (`macos-titlebar-style = new-tabs`)
/// with the native tab bar.
///
/// These use real windows in a real tab group but no terminals, so that the numbers
/// are about the tab bars and not about everything else a tab does. They're disabled
/// unless `GHOSTTY_TAB_BAR_BENCHMARK` is set to the path of a file to write the
/// results to, one JSON object per line.
///
/// Run them with `macos/benchmarks/tab-bar/in-process.sh`. The README next to it
/// explains what is measured and why.
@MainActor
@Suite(
    "Tab Bar Benchmarks",
    .serialized,
    .enabled(if: TabBarTestEnvironment.benchmarkOutputPath != nil && TabBarTestEnvironment.canShowWindows),
    .tags(.benchmark)
)
struct TerminalTabBarBenchmarks {
    enum Style: String, CaseIterable {
        /// The custom tab bar.
        case newTabs = "new-tabs"
        /// The native tab bar, as used by the default titlebar style.
        case native

        func makeWindow() -> TerminalWindow {
            let contentRect = NSRect(x: 200, y: 200, width: 1000, height: 600)
            let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            return switch self {
            case .newTabs:
                NewTabsTerminalWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
            case .native:
                TransparentTitlebarTerminalWindow(
                    contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
            }
        }
    }

    // MARK: Measuring

    /// Do everything that would otherwise happen before the next frame: run
    /// whatever was deferred to the main queue, then lay out, draw and commit.
    private func flush(_ window: NSWindow?) {
        RunLoop.current.run(mode: .default, before: .distantPast)
        window?.layoutIfNeeded()
        window?.displayIfNeeded()
        CATransaction.flush()
    }

    /// Returns the average time of an iteration in microseconds.
    private func measure(iterations: Int, _ body: (Int) -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0..<iterations { body(iteration) }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(iterations) / 1000
    }

    private func viewCount(_ view: NSView?) -> Int {
        guard let view else { return 0 }
        return 1 + view.subviews.reduce(0) { $0 + viewCount($1) }
    }

    private func run(_ style: Style, tabs count: Int) async throws -> [String: Any] {
        var result: [String: Any] = ["style": style.rawValue, "tabs": count]

        // Creating tabs. Every new tab is selected, like a real new tab.
        var windows: [TerminalWindow] = []
        result["new_tab_us"] = measure(iterations: count) { index in
            let window = style.makeWindow()
            window.isReleasedWhenClosed = false
            window.awakeFromNib()
            window.contentView = TerminalViewContainer { Color.clear }
            window.title = "Tab \(index + 1): ~/Developer/ghostty"
            windows.last?.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            flush(window)
        }
        try await Task.sleep(for: .milliseconds(300))
        flush(windows.last)

        // Selecting tabs.
        result["select_tab_us"] = measure(iterations: count * 5) { iteration in
            let window = windows[(iteration * 7) % count]
            window.makeKeyAndOrderFront(nil)
            flush(window)
        }

        // The views it takes to show the tabs, over all windows of the tab group.
        // For the native style this includes the titlebar, where its tab bar is.
        result["views_per_tab"] = Double(windows.reduce(0) {
            $0 + viewCount($1.contentView?.superview)
        }) / Double(count)

        // Title changes, which terminals do all the time. One in ten are
        // for the selected tab, the rest for tabs in the background.
        let selected = try #require(windows[0].tabGroup?.selectedWindow)
        result["retitle_us"] = measure(iterations: 2000) { iteration in
            windows[iteration % count].title = "Tab \(iteration): ~/Developer/ghostty"
            flush(selected)
        }

        // Moving a tab in the background to the other end.
        if count > 2, let tabGroup = selected.tabGroup {
            result["move_tab_us"] = measure(iterations: 100) { _ in
                let moved = tabGroup.windows.first { $0 !== selected }!
                let last = tabGroup.windows.last!
                tabGroup.removeWindow(moved)
                last.addTabbedWindow(moved, ordered: .above)
                flush(selected)
            }
        }

        // Closing tabs, always the selected one, until one is left.
        result["close_tab_us"] = measure(iterations: count - 1) { _ in
            let closing = windows[0].tabGroup?.selectedWindow ?? windows[0]
            windows.removeAll { $0 === closing }
            closing.close()
            flush(windows.first?.tabGroup?.selectedWindow ?? windows.first)
        }

        for window in windows { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        flush(nil)
        return result
    }

    @Test(arguments: [10, 50])
    func tabBar(tabs count: Int) async throws {
        let path = try #require(TabBarTestEnvironment.benchmarkOutputPath)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let file = try #require(FileHandle(forWritingAtPath: path))
        defer { try? file.close() }

        // A single style can be selected, which is what you want for profiling.
        let allStyles = ProcessInfo.processInfo.environment["GHOSTTY_TAB_BAR_BENCHMARK_STYLE"]
            .flatMap(Style.init(rawValue:))
            .map { [$0] } ?? Style.allCases

        // Warm up so that neither style pays for one time setup.
        for style in allStyles { _ = try await run(style, tabs: 3) }

        // Everything gets slower the longer the process runs, so which style goes
        // first matters. Switch the order every round so that it evens out.
        for round in 0..<4 {
            let styles = round.isMultiple(of: 2) ? allStyles : allStyles.reversed()
            for style in styles {
                var result = try await run(style, tabs: count)
                result["round"] = round
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                try file.seekToEnd()
                try file.write(contentsOf: data + Data("\n".utf8))
            }
        }
    }
}
