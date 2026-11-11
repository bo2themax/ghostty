import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// What the tab bar tests need from the environment they run in.
enum TabBarTestEnvironment {
    /// Windows are only really shown in an unlocked login session, and a tab bar
    /// only has tabs while its window is shown.
    static var canShowWindows: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool ?? false
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        return onConsole && !locked
    }

    /// Where to write benchmark results. The benchmarks only run if this is set.
    static var benchmarkOutputPath: String? {
        ProcessInfo.processInfo.environment["GHOSTTY_TAB_BAR_BENCHMARK"]
    }
}

/// Tests for the custom tab bar used by `macos-titlebar-style = new-tabs`.
///
/// These use real windows in a real native tab group because mirroring the
/// tab group is the whole job of the tab bar.
@MainActor
@Suite(.serialized, .enabled(if: TabBarTestEnvironment.canShowWindows))
struct TerminalTabBarTests {
    // MARK: Helpers

    private func makeWindow(title: String) -> NewTabsTerminalWindow {
        let window = NewTabsTerminalWindow(
            contentRect: NSRect(x: 200, y: 200, width: 700, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.awakeFromNib()
        window.contentView = TerminalViewContainer { Color.clear }
        window.title = title
        return window
    }

    /// Creates a tab group with the given number of tabs. The last tab is selected.
    private func makeTabs(_ count: Int) async throws -> [NewTabsTerminalWindow] {
        var windows: [NewTabsTerminalWindow] = []
        for index in 0..<count {
            let window = makeWindow(title: "Tab \(index + 1)")
            if let last = windows.last {
                last.addTabbedWindow(window, ordered: .above)
            }
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }

        try await settle()
        return windows
    }

    private func close(_ windows: [NewTabsTerminalWindow]) async throws {
        for window in windows { window.close() }
        try await settle()
    }

    /// Let the main queue and layout catch up.
    private func settle() async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(50))
            for window in NSApp.windows { window.layoutIfNeeded() }
        }
    }

    private func withPosition(
        _ position: TerminalTabBarPosition,
        _ body: () async throws -> Void
    ) async throws {
        let old = TerminalTabBarPosition.current
        TerminalTabBarPosition.current = position
        defer { TerminalTabBarPosition.current = old }
        try await body()
    }

    private func sendMouse(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow,
        clickCount: Int = 1
    ) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1))
        NSApp.sendEvent(event)
    }

    private func center(of tab: NSWindow, in host: NewTabsTerminalWindow) throws -> NSPoint {
        let frame = try #require(host.tabBar.tabFrame(for: tab))
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: Tests

    @Test func mirrorsTabGroup() async throws {
        let windows = try await makeTabs(4)
        let selected = try #require(windows.last)

        #expect(selected.tabBar.isActive)
        #expect(selected.tabBar.tabWindows == windows)

        try await close(windows)
    }

    @Test func onlyVisibleWindowHasTabs() async throws {
        let windows = try await makeTabs(4)

        for window in windows.dropLast() {
            #expect(!window.tabBar.isActive)
            #expect(window.tabBar.tabWindows.isEmpty)
        }

        // Selecting another tab moves the tabs to its tab bar.
        windows[1].makeKeyAndOrderFront(nil)
        try await settle()
        #expect(windows[1].tabBar.tabWindows == windows)
        #expect(windows[3].tabBar.tabWindows.isEmpty)

        try await close(windows)
    }

    @Test func nativeTabBarIsHidden() async throws {
        let windows = try await makeTabs(3)
        let selected = try #require(windows.last)

        // The native tab bar must not take any space or be hit by clicks.
        for accessory in selected.titlebarAccessoryViewControllers {
            #expect(accessory.isHidden)
        }
        let nativeFrame = selected.tabBarView.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let content = try #require(selected.contentView)
        #expect(selected.tabIndex(atScreenPoint: selected.convertPoint(
            toScreen: NSPoint(x: content.bounds.midX, y: content.bounds.maxY - 40))) == nil,
                "native tab bar frame: \(nativeFrame)")

        try await close(windows)
    }

    @Test func followsTabGroupChanges() async throws {
        var windows = try await makeTabs(3)
        let selected = try #require(windows.last)

        // Add a tab in the background.
        let added = makeWindow(title: "Added")
        windows[0].addTabbedWindow(added, ordered: .above)
        windows.insert(added, at: 1)
        try await settle()
        #expect(selected.tabBar.tabWindows == windows)

        // Close a background tab.
        windows.remove(at: 1).close()
        try await settle()
        #expect(selected.tabBar.tabWindows == windows)

        // Close the selected tab, another tab takes over.
        windows.removeLast().close()
        try await settle()
        let visible = try #require(windows[0].tabGroup?.selectedWindow as? NewTabsTerminalWindow)
        #expect(visible.tabBar.tabWindows == windows)

        try await close(windows)
    }

    @Test func titleChangesUpdateTab() async throws {
        let windows = try await makeTabs(2)
        let selected = try #require(windows.last)

        windows[0].title = "Renamed"
        let item = try #require(selected.tabBar.firstDescendant(
            where: { ($0 as? TerminalTabBarItemView)?.tabWindow === windows[0] }) as? TerminalTabBarItemView)
        #expect(item.title == "Renamed")

        try await close(windows)
    }

    @Test(arguments: TerminalTabBarPosition.allCases)
    func clickSelectsTab(position: TerminalTabBarPosition) async throws {
        try await withPosition(position) {
            let windows = try await makeTabs(3)
            let selected = try #require(windows.last)

            let point = try center(of: windows[0], in: selected)
            try sendMouse(.leftMouseDown, at: point, in: selected)
            try sendMouse(.leftMouseUp, at: point, in: windows[0])
            try await settle()

            #expect(windows[0].tabGroup?.selectedWindow === windows[0])
            #expect(windows[0].tabBar.tabWindows == windows)

            try await close(windows)
        }
    }

    @Test(arguments: TerminalTabBarPosition.allCases)
    func dragReordersTabs(position: TerminalTabBarPosition) async throws {
        try await withPosition(position) {
            let windows = try await makeTabs(4)
            let selected = try #require(windows.last)

            // Drag the last tab onto the first.
            let start = try center(of: selected, in: selected)
            let end = try center(of: windows[0], in: selected)
            try sendMouse(.leftMouseDown, at: start, in: selected)
            for step in 1...10 {
                let t = CGFloat(step) / 10
                try sendMouse(
                    .leftMouseDragged,
                    at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                    in: selected)
            }
            try sendMouse(.leftMouseUp, at: end, in: selected)
            try await settle()

            let expected = [windows[3], windows[0], windows[1], windows[2]]
            #expect(selected.tabGroup?.windows == expected)
            #expect(selected.tabGroup?.selectedWindow === selected)
            #expect(selected.tabBar.tabWindows == expected)

            try await close(windows)
        }
    }

    @Test func scrollsWhenTabsOverflow() async throws {
        try await withPosition(.left) {
            let windows = try await makeTabs(20)
            let selected = try #require(windows.last)
            let tabBar = selected.tabBar

            // The selected tab is the last one and must have been scrolled into view,
            // which means the first one is scrolled out.
            let barFrame = tabBar.convert(tabBar.bounds, to: nil)
            let lastFrame = try #require(tabBar.tabFrame(for: selected))
            let firstFrame = try #require(tabBar.tabFrame(for: windows[0]))
            #expect(barFrame.contains(lastFrame))
            #expect(!barFrame.intersects(firstFrame))

            // Scroll all the way back up.
            let cgEvent = try #require(CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 10_000,
                wheel2: 0,
                wheel3: 0))
            tabBar.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))
            #expect(barFrame.contains(try #require(tabBar.tabFrame(for: windows[0]))))

            try await close(windows)
        }
    }

    @Test func sidebarCanBeResized() async throws {
        let oldWidth = TerminalTabBarPosition.sidebarWidth
        defer { TerminalTabBarPosition.sidebarWidth = oldWidth }

        try await withPosition(.left) {
            TerminalTabBarPosition.sidebarWidth = 200
            let windows = try await makeTabs(2)
            let selected = try #require(windows.last)
            #expect(selected.tabBar.frame.width == 200)

            // Drag the inner edge of the sidebar. The handle tracks the mouse itself,
            // so the rest of the drag has to be queued up before the mouse down.
            let y = selected.tabBar.convert(selected.tabBar.bounds, to: nil).midY
            for (type, x) in [(NSEvent.EventType.leftMouseDragged, 260.0), (.leftMouseUp, 260.0)] {
                NSApp.postEvent(try #require(NSEvent.mouseEvent(
                    with: type,
                    location: NSPoint(x: x, y: y),
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: selected.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1)), atStart: false)
            }
            try sendMouse(.leftMouseDown, at: NSPoint(x: 198, y: y), in: selected)
            try await settle()

            #expect(TerminalTabBarPosition.sidebarWidth == 260)
            #expect(selected.tabBar.frame.width == 260)

            // Every tab uses the same width, including the ones that aren't shown.
            windows[0].makeKeyAndOrderFront(nil)
            try await settle()
            #expect(windows[0].tabBar.frame.width == 260)

            try await close(windows)
        }
    }
}

private extension NSView {
    func firstDescendant(where predicate: (NSView) -> Bool) -> NSView? {
        for subview in subviews {
            if predicate(subview) { return subview }
            if let found = subview.firstDescendant(where: predicate) { return found }
        }

        return nil
    }
}
