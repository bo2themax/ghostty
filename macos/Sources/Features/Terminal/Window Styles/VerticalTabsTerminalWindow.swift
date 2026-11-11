import AppKit
import SwiftUI

/// `macos-titlebar-style = vertical-tabs` for macOS 26 (Tahoe) and later.
///
/// Tabs are still native `NSWindow` tabs, so everything that works on a tab group (goto/move/close
/// tab, tab overview, restoration) is unchanged. This window only changes the presentation: the
/// native tab bar is hidden and the tab group is rendered in a `VerticalTabBar` on the leading
/// edge instead.
///
/// Every window in a tab group has its own tab bar, but only the selected tab's window is visible.
/// Hidden windows only mark their tab bar dirty and rebuild it when they become visible again, so
/// title changes in background tabs cost O(1) per window.
@available(macOS 26.0, *)
class VerticalTabsTerminalWindow: TerminalWindow, TabBarWindow {
    /// The tab bar model for this window. It references this window weakly.
    private(set) lazy var tabBar = TabBarModel(window: self)

    /// Wraps the terminal content with the tab bar.
    func tabBarContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        TabBarContainer(edge: .leading, layout: tabBar.layout) {
            VerticalTabBar(model: tabBar)
        } content: {
            content()
        }
    }

    // MARK: NSWindow

    override func awakeFromNib() {
        super.awakeFromNib()

        // The content extends under the titlebar so the window buttons sit above the tab bar.
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true

        // Titles are shown in the tab bar.
        titleVisibility = .hidden
    }

    override func becomeKey() {
        super.becomeKey()
        hideNativeTabBar()
        tabBar.activate()
    }

    override func becomeMain() {
        super.becomeMain()
        hideNativeTabBar()
        tabBar.activate()
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)

        // AppKit adds the native tab bar as an accessory whenever the tab group has more
        // than one window. Our tab bar replaces it, so keep it hidden.
        if isTabBar(childViewController) {
            childViewController.isHidden = true
        }
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)

        // Match the tab bar and window buttons to the terminal background, the same as
        // the transparent titlebar style does.
        if let preferredBackgroundColor {
            appearance = NSAppearance(named: preferredBackgroundColor.isLightColor ? .aqua : .darkAqua)
        }
    }

    // MARK: Tab Bar Menu

    /// "View > Show/Hide Tab Bar" toggles our tab bar since the native one is never shown.
    override func toggleTabBar(_ sender: Any?) {
        tabBar.toggleVisibility()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTabBar(_:)) {
            menuItem.title = tabBar.layout.isVisible ? "Hide Tab Bar" : "Show Tab Bar"
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
        NotificationCenter.default.post(name: TabBarModel.tabDidChangeNotification, object: self)
    }
}
