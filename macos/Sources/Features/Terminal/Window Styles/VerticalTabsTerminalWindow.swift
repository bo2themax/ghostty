import AppKit
import SwiftUI

/// `macos-titlebar-style = vertical-tabs` for macOS 26 (Tahoe) and later.
///
/// Tabs are still native `NSWindow` tabs, so everything that works on a tab group (goto/move/close
/// tab, tab overview, restoration) is unchanged. This window only changes the presentation: the
/// native tab bar is hidden and the tab group is rendered in a sidebar instead
/// (see `VerticalTabsSplitView`).
///
/// Every window in a tab group has its own sidebar, but only the selected tab's window is visible.
/// Hidden windows only mark their sidebar dirty and rebuild it when they become visible again, so
/// title changes in background tabs cost O(1) per window.
@available(macOS 26.0, *)
class VerticalTabsTerminalWindow: TerminalWindow {
    /// Posted with the changed window as the object whenever something shown in a sidebar
    /// row (title, color, shortcut, zoom state) changes.
    static let tabDidChangeNotification = Notification.Name("VerticalTabsTabDidChange")

    /// The sidebar model for this window. It references this window weakly.
    private(set) lazy var verticalTabs = VerticalTabsModel(window: self)

    // MARK: NSWindow

    override func awakeFromNib() {
        super.awakeFromNib()

        // The sidebar extends under the titlebar so the window buttons sit on top of it.
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true

        // Titles are shown in the sidebar.
        titleVisibility = .hidden
    }

    override func becomeKey() {
        super.becomeKey()
        hideNativeTabBar()
        verticalTabs.activate()
    }

    override func becomeMain() {
        super.becomeMain()
        hideNativeTabBar()
        verticalTabs.activate()
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)

        // AppKit adds the native tab bar as an accessory whenever the tab group has more
        // than one window. The sidebar replaces it, so keep it hidden.
        if isTabBar(childViewController) {
            childViewController.isHidden = true
        }
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)

        // Match the sidebar and window buttons to the terminal background, the same as
        // the transparent titlebar style does.
        if let preferredBackgroundColor {
            appearance = NSAppearance(named: preferredBackgroundColor.isLightColor ? .aqua : .darkAqua)
        }
    }

    // MARK: Tab Bar Menu

    /// "View > Show/Hide Tab Bar" toggles the sidebar since the native tab bar is never shown.
    override func toggleTabBar(_ sender: Any?) {
        verticalTabs.toggleSidebar()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTabBar(_:)) {
            menuItem.title = verticalTabs.layout.isSidebarVisible ? "Hide Tab Bar" : "Show Tab Bar"
            return true
        }

        return super.validateMenuItem(menuItem)
    }

    // MARK: Row Properties

    override var title: String {
        didSet {
            guard title != oldValue else { return }
            postTabDidChange()
        }
    }

    override var titlebarFont: NSFont? {
        didSet {
            guard titlebarFont != oldValue else { return }
            postTabDidChange()
        }
    }

    override var tabColor: TerminalTabColor {
        didSet {
            guard tabColor != oldValue else { return }
            postTabDidChange()
        }
    }

    override var keyEquivalent: String? {
        didSet {
            guard keyEquivalent != oldValue else { return }
            postTabDidChange()
        }
    }

    override var surfaceIsZoomed: Bool {
        didSet {
            guard surfaceIsZoomed != oldValue else { return }
            postTabDidChange()
        }
    }

    // MARK: Private

    private func hideNativeTabBar() {
        for accessory in titlebarAccessoryViewControllers where isTabBar(accessory) && !accessory.isHidden {
            accessory.isHidden = true
        }
    }

    private func postTabDidChange() {
        NotificationCenter.default.post(name: Self.tabDidChangeNotification, object: self)
    }
}
