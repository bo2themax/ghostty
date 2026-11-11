import AppKit

/// Where the custom tab bar (`macos-titlebar-style = new-tabs`) is placed in the window.
///
/// This is a user preference chosen from the tab bar context menu rather than a
/// configuration value, so it is stored in user defaults and applies to all windows.
enum TerminalTabBarPosition: String, CaseIterable {
    case top
    case left
    case right
    case bottom

    /// Posted when the position or the sidebar width changes.
    static let didChangeNotification = Notification.Name("com.mitchellh.ghostty.tabBarPositionDidChange")

    private static let positionKey = "NewTabsTabBarPosition"
    private static let sidebarWidthKey = "NewTabsSidebarWidth"

    static let sidebarWidthRange: ClosedRange<CGFloat> = 120...480

    // Both values are read on every tab bar layout so we cache them
    // instead of going through user defaults each time.
    private static var cachedPosition: Self = UserDefaults.ghostty
        .string(forKey: positionKey)
        .flatMap(Self.init(rawValue:)) ?? .top

    private static var cachedSidebarWidth: CGFloat = {
        let stored = UserDefaults.ghostty.double(forKey: sidebarWidthKey)
        return stored > 0 ? clampSidebarWidth(CGFloat(stored)) : 200
    }()

    private static func clampSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    /// The current position for all windows.
    static var current: Self {
        get { cachedPosition }
        set {
            guard newValue != cachedPosition else { return }
            cachedPosition = newValue
            UserDefaults.ghostty.set(newValue.rawValue, forKey: positionKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// The width of the tab bar when it is on the left or right.
    static var sidebarWidth: CGFloat {
        get { cachedSidebarWidth }
        set {
            let width = clampSidebarWidth(newValue.rounded())
            guard width != cachedSidebarWidth else { return }
            cachedSidebarWidth = width
            UserDefaults.ghostty.set(Double(width), forKey: sidebarWidthKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// True if tabs are stacked vertically (the bar is a sidebar).
    var isVertical: Bool {
        self == .left || self == .right
    }

    /// The edge of the window content the bar is attached to.
    var edge: NSRectEdge {
        switch self {
        case .top: .maxY
        case .left: .minX
        case .right: .maxX
        case .bottom: .minY
        }
    }

    /// The size of the bar perpendicular to its edge. At the top this is only a
    /// minimum, the bar grows to cover the titlebar.
    var thickness: CGFloat {
        switch self {
        case .top: 28
        case .bottom: 32
        case .left, .right: Self.sidebarWidth
        }
    }

    var localizedName: String {
        switch self {
        case .top: "Top"
        case .left: "Left"
        case .right: "Right"
        case .bottom: "Bottom"
        }
    }

    var symbolName: String {
        switch self {
        case .top: "rectangle.topthird.inset.filled"
        case .left: "rectangle.leftthird.inset.filled"
        case .right: "rectangle.rightthird.inset.filled"
        case .bottom: "rectangle.bottomthird.inset.filled"
        }
    }
}
