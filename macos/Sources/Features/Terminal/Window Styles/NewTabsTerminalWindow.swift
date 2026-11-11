import AppKit

/// A terminal window style with a transparent titlebar that replaces the native tab bar
/// with our own (``TerminalTabBarView``), which can be placed on any edge of the window.
///
/// Tabs are still native window tabs. We only hide the native tab bar and show ours
/// instead, so everything else about tabs behaves like in the other styles.
class NewTabsTerminalWindow: TerminalWindow {
    /// Posted with the window as the object when anything a tab shows about
    /// its window changed (title, color, key equivalent, etc.).
    static let tabStateDidChangeNotification = Notification.Name("com.mitchellh.ghostty.newTabsTabStateDidChange")

    /// The tab bar of this window. Every window in a tab group has one but it only
    /// has contents while its window is the visible one.
    let tabBar = TerminalTabBarView()

    /// The accessory AppKit puts the native tab bar in. We hold on to it for AppKit
    /// but never add it to our titlebar, see `addTitlebarAccessoryViewController`.
    private var nativeTabBarAccessory: NSTitlebarAccessoryViewController?

    private var positionObserver: NSObjectProtocol?

    // The titlebar may be covered by our tab bar so we have no room for accessories.
    override var supportsUpdateAccessory: Bool { false }

    // The native tab bar still exists, it is just hidden. Without this, double
    // clicks where it would be start editing a tab title nobody can see.
    override var supportsNativeTabTitleEditing: Bool { false }

    deinit {
        if let positionObserver {
            NotificationCenter.default.removeObserver(positionObserver)
        }
    }

    // MARK: NSWindow

    override func awakeFromNib() {
        super.awakeFromNib()

        // Our tab bar is part of the content view, including when it takes the
        // place of the titlebar, so the content has to extend below the titlebar.
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true

        positionObserver = NotificationCenter.default.addObserver(
            forName: TerminalTabBarPosition.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncTabBarPosition()
        }
    }

    override var contentView: NSView? {
        didSet { syncTabBarPosition() }
    }

    override func close() {
        // Whichever tab is selected once we're gone has to show the tabs.
        let siblings = tabbedWindows?.compactMap { $0 as? NewTabsTerminalWindow }.filter { $0 !== self }

        tabBar.invalidate()
        super.close()

        siblings?.forEach { $0.tabBar.syncActive() }
    }

    // Selecting a tab makes its window key and main, so these are
    // our earliest signals to move the tabs to another tab bar.

    override func becomeKey() {
        super.becomeKey()
        tabBar.syncActive()
    }

    override func resignKey() {
        super.resignKey()
        tabBar.syncActive()
    }

    override func becomeMain() {
        super.becomeMain()
        tabBar.syncActive()
    }

    override func resignMain() {
        super.resignMain()
        tabBar.syncActive()
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        // We have no room for accessories: our tab bar may be where the titlebar is.
        guard isTabBar(childViewController) else { return }

        // This is the native tab bar, which we replace. All windows of a tab group
        // share a single native tab bar that AppKit moves into the window of the
        // selected tab. If we let it into our titlebar, even hidden, every tab
        // selection pays for moving it and laying it out, which takes far longer
        // than everything our own tab bar does and grows with the number of tabs.
        // AppKit is happy to put its tab bar into an accessory that isn't part of
        // any window, where all of that is free.
        childViewController.identifier = Self.tabBarIdentifier
        nativeTabBarAccessory = childViewController
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        // AppKit removes the tab bar accessory by its index in our accessories,
        // which it doesn't have since we never added it.
        guard titlebarAccessoryViewControllers.indices.contains(index) else {
            nativeTabBarAccessory = nil
            return
        }

        super.removeTitlebarAccessoryViewController(at: index)
    }

    // MARK: Tab Bar

    /// Put the tab bar where the user wants it.
    private func syncTabBarPosition() {
        guard let container = contentView as? TerminalViewContainer else { return }
        let position = TerminalTabBarPosition.current

        // At the top our tab bar takes the place of the titlebar and
        // shows the titles itself.
        let newTitleVisibility: NSWindow.TitleVisibility = position == .top ? .hidden : .visible
        if titleVisibility != newTitleVisibility {
            titleVisibility = newTitleVisibility

            if newTitleVisibility == .visible {
                // AppKit drops the proxy icon while the title is hidden and
                // only brings it back when the represented URL is set again.
                let url = representedURL
                representedURL = nil
                representedURL = url

                // We skip styling a title that isn't visible, so catch up.
                syncWindowTitleAppearance(font: titlebarFont)
            }
        }

        // The tab bar is exactly as tall as the titlebar it replaces so that it
        // lines up with the window buttons.
        let thickness = position == .top
            ? max(position.thickness, fullSizeContentTitlebarHeight)
            : position.thickness

        tabBar.position = position
        container.setEdgeAccessory(.init(view: tabBar, edge: position.edge, thickness: thickness))
    }

    // AppKit lets the user move the window by dragging anything outside of this
    // rect, which is normally the titlebar. When our tab bar is in the titlebar
    // that would also move the window when a tab is dragged, so we claim the
    // titlebar and let the tab bar move the window.
    override var contentLayoutRect: CGRect {
        guard TerminalTabBarPosition.current == .top else { return super.contentLayoutRect }
        var rect = super.contentLayoutRect
        rect.origin.y = 0
        rect.size.height = frame.height
        return rect
    }

    override func beginInlineTabTitleEdit(for targetWindow: NSWindow) -> Bool {
        // Only the tab bar of the visible window in the tab group has tabs.
        let host = (tabbedWindows != nil ? tabGroup?.selectedWindow : nil) as? NewTabsTerminalWindow ?? self
        return host.tabBar.beginEditing(for: targetWindow)
    }

    // MARK: Tab State

    private func tabStateDidChange() {
        NotificationCenter.default.post(name: Self.tabStateDidChangeNotification, object: self)
    }

    override var title: String {
        didSet { if title != oldValue { tabStateDidChange() } }
    }

    override var titlebarFont: NSFont? {
        didSet { if titlebarFont != oldValue { tabStateDidChange() } }
    }

    override var tabColor: TerminalTabColor {
        didSet { if tabColor != oldValue { tabStateDidChange() } }
    }

    override var surfaceIsZoomed: Bool {
        didSet { if surfaceIsZoomed != oldValue { tabStateDidChange() } }
    }

    override var keyEquivalent: String? {
        // This isn't conditional on purpose: tabs are relabeled whenever the tab
        // group changes, so this also tells tab bars about windows they don't
        // know yet.
        didSet { tabStateDidChange() }
    }

    // MARK: Appearance

    /// True once the title in the titlebar was given a custom font.
    private var titleHasCustomAppearance = false

    override func syncWindowTitleAppearance(font: NSFont? = nil) {
        // This searches the titlebar for the title, on every title change. That is
        // only worth it if there is a title and something to apply to it (or undo).
        let isCustom = font != nil || titlebarFont != nil
        guard titleVisibility == .visible, isCustom || titleHasCustomAppearance else { return }
        titleHasCustomAppearance = isCustom
        super.syncWindowTitleAppearance(font: font)
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)

        // Our titlebar and tab bar show the terminal background, so their
        // contents have to be legible on that rather than follow the theme.
        if (NSApp.delegate as? AppDelegate)?.appearanceOverride == nil,
           let preferredBackgroundColor {
            appearance = NSAppearance(named: preferredBackgroundColor.isLightColor ? .aqua : .darkAqua)
        }
    }
}
