import AppKit

/// A single tab in a ``TerminalTabBarView``.
///
/// This is intentionally a single view with a handful of layers rather than a tree
/// of controls: a tab bar can hold a lot of these and they are recreated whenever a
/// different tab becomes visible, so they have to be cheap. All mouse handling is
/// done by the tab bar.
final class TerminalTabBarItemView: NSView {
    enum Style {
        /// Tabs are laid out left to right (tab bar on top or bottom).
        case horizontal
        /// Tabs are stacked (tab bar on the left or right).
        case vertical
    }

    /// The window (native tab) this item represents.
    private(set) weak var tabWindow: NSWindow?

    var style: Style = .horizontal {
        didSet {
            guard style != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }

    // MARK: Tab State

    private(set) var title: String = ""
    private(set) var titleFont: NSFont?
    private(set) var keyEquivalent: String = ""
    private(set) var tabColor: TerminalTabColor = .none
    private(set) var isZoomed: Bool = false

    var isSelected: Bool = false {
        didSet {
            guard isSelected != oldValue else { return }
            setAccessibilityValue(isSelected)
            needsDisplay = true
        }
    }

    /// True if the window containing the tab bar is the key window.
    var isWindowKey: Bool = true {
        didSet { if isWindowKey != oldValue { needsDisplay = true } }
    }

    var isHovered: Bool = false {
        didSet {
            guard isHovered != oldValue else { return }
            if !isHovered { isCloseHovered = false }
            needsLayout = true
            needsDisplay = true
        }
    }

    var isCloseHovered: Bool = false {
        didSet { if isCloseHovered != oldValue { needsDisplay = true } }
    }

    /// Draws a separator on the left edge. Only used by the horizontal style.
    var showsSeparator: Bool = false {
        didSet { if showsSeparator != oldValue { needsDisplay = true } }
    }

    /// True while the title is replaced by an inline editor.
    var isEditing: Bool = false {
        didSet { if isEditing != oldValue { needsDisplay = true } }
    }

    // MARK: Layers

    private let backgroundLayer = CALayer()
    private let separatorLayer = CALayer()
    private let colorLayer = CALayer()
    private let titleLayer = CATextLayer()
    private let shortcutLayer = CATextLayer()
    private let closeBackgroundLayer = CALayer()
    private let closeLayer = CALayer()
    private let zoomLayer = CALayer()
    private lazy var titleFadeMask: CAGradientLayer = {
        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        return mask
    }()

    private var titleSize: CGSize = .zero
    private var shortcutSize: CGSize = .zero
    private var isTitleTruncated = false

    // MARK: Geometry

    /// The frame of the title in our coordinate space.
    private(set) var titleRect: CGRect = .zero

    /// The frame of the close button, only valid while hovered.
    private(set) var closeRect: CGRect = .zero

    /// The frame of the reset zoom button, only valid while zoomed.
    private(set) var zoomRect: CGRect = .zero

    var showsCloseButton: Bool { isHovered && !isEditing }

    // MARK: Init

    init(tabWindow: NSWindow) {
        self.tabWindow = tabWindow
        super.init(frame: .zero)

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let scale = tabWindow.backingScaleFactor
        for textLayer in [titleLayer, shortcutLayer] {
            textLayer.contentsScale = scale
            textLayer.truncationMode = .none
            textLayer.isWrapped = false
            textLayer.alignmentMode = .left
        }

        backgroundLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        backgroundLayer.shadowRadius = 1.5
        colorLayer.cornerRadius = 3
        closeBackgroundLayer.cornerRadius = 8
        closeLayer.mask = Self.maskLayer(image: Self.closeImage)
        zoomLayer.mask = Self.maskLayer(image: Self.zoomImage)

        for sublayer in [
            backgroundLayer, separatorLayer, colorLayer, titleLayer, shortcutLayer,
            zoomLayer, closeBackgroundLayer, closeLayer,
        ] {
            layer?.addSublayer(sublayer)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(.tabButtonSubrole)
        setAccessibilityValue(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Updating

    /// Syncs the tab state from the tab window. This is cheap if nothing changed.
    func update() {
        guard let tabWindow else { return }
        let terminalWindow = tabWindow as? TerminalWindow

        let newFont = terminalWindow?.titlebarFont
        if tabWindow.title != title || newFont != titleFont {
            title = tabWindow.title
            if newFont != titleFont {
                titleFont = newFont
                resolvedTitleFont = newFont
                    .flatMap { NSFont(descriptor: $0.fontDescriptor, size: Self.titleFontSize) }
                    ?? Self.defaultTitleFont
            }
            titleSize = NSAttributedString(string: title, attributes: [.font: resolvedTitleFont]).size()
            setAccessibilityLabel(title)
            needsLayout = true
            needsDisplay = true
        }

        let newKeyEquivalent = terminalWindow?.keyEquivalent ?? ""
        if newKeyEquivalent != keyEquivalent {
            keyEquivalent = newKeyEquivalent
            shortcutSize = NSAttributedString(string: keyEquivalent, attributes: [.font: Self.shortcutFont]).size()
            needsLayout = true
            needsDisplay = true
        }

        let newColor = terminalWindow?.tabColor ?? .none
        if newColor != tabColor {
            tabColor = newColor
            needsLayout = true
            needsDisplay = true
        }

        let newZoomed = terminalWindow?.surfaceIsZoomed ?? false
        if newZoomed != isZoomed {
            isZoomed = newZoomed
            needsLayout = true
            needsDisplay = true
        }
    }

    /// The font we draw the title with: the title font of the window at our size.
    private var resolvedTitleFont: NSFont = TerminalTabBarItemView.defaultTitleFont

    /// What our text layers currently show. Setting the string of a text layer makes
    /// it draw its text again, and we're asked to update much more often than our text
    /// changes (e.g. whenever another tab is selected), so we only set what changed.
    private struct TextContent: Equatable {
        let string: String
        let font: NSFont
        let color: CGColor

        var attributedString: NSAttributedString {
            // The color has to be resolved for our appearance at this point. A text
            // layer draws later, when a dynamic color may resolve for another appearance.
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        }
    }
    private var shownTitle: TextContent?
    private var shownShortcut: TextContent?

    // MARK: NSView

    override var mouseDownCanMoveWindow: Bool { false }

    // Like native tabs, a tab can be selected by clicking it in an inactive window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor else { return }
        titleLayer.contentsScale = scale
        shortcutLayer.contentsScale = scale
    }

    override func layout() {
        super.layout()

        // Our sublayers aren't managed by AppKit so they'd animate every change
        // unless we're in an explicit animation (e.g. tabs sliding around).
        CATransaction.begin()
        CATransaction.setDisableActions(!NSAnimationContext.current.allowsImplicitAnimation)
        defer { CATransaction.commit() }

        let capsule = style == .horizontal ? bounds.insetBy(dx: 1, dy: 2) : bounds
        backgroundLayer.frame = capsule
        backgroundLayer.cornerRadius = min(capsule.height / 2, 14)
        separatorLayer.frame = CGRect(x: 0, y: bounds.midY - 7, width: 1, height: 14)

        let midY = capsule.midY
        var leading = capsule.minX + 10
        var trailing = capsule.maxX - 8

        if tabColor != .none {
            colorLayer.frame = CGRect(x: leading, y: midY - 3, width: 6, height: 6)
            leading += 11
        }

        // The close button and the key equivalent share the trailing slot.
        closeRect = CGRect(x: trailing - 16, y: midY - 8, width: 16, height: 16)
        closeBackgroundLayer.frame = closeRect
        closeLayer.frame = closeRect
        closeLayer.mask?.frame = closeLayer.bounds
        let showsShortcut = !showsCloseButton && !keyEquivalent.isEmpty && capsule.width >= 90
        if showsCloseButton {
            trailing -= 20
        } else if showsShortcut {
            shortcutLayer.frame = CGRect(
                x: trailing - shortcutSize.width,
                y: midY - shortcutSize.height / 2,
                width: shortcutSize.width,
                height: shortcutSize.height
            ).integral
            trailing -= shortcutSize.width + 6
        }
        shortcutLayer.isHidden = !showsShortcut

        if isZoomed {
            zoomRect = CGRect(x: trailing - 16, y: midY - 8, width: 16, height: 16)
            zoomLayer.frame = zoomRect
            zoomLayer.mask?.frame = zoomLayer.bounds
            trailing -= 20
        }

        let lineHeight = ceil(titleSize.height)
        titleRect = CGRect(
            x: leading,
            y: (midY - lineHeight / 2).rounded(),
            width: max(trailing - leading, 0),
            height: lineHeight)
        titleLayer.frame = titleRect

        // Fade the title out instead of truncating it.
        isTitleTruncated = titleSize.width > titleRect.width
        if isTitleTruncated, titleRect.width > 0 {
            let fade = min(24 / titleRect.width, 1)
            titleFadeMask.frame = titleLayer.bounds
            titleFadeMask.locations = [0, NSNumber(value: 1 - fade), 1]
            titleLayer.mask = titleFadeMask
        } else {
            titleLayer.mask = nil
        }

        // Only pay for a tooltip when there is something we can't show.
        let newToolTip = isTitleTruncated ? title : nil
        if toolTip != newToolTip { toolTip = newToolTip }
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // Background
        if isSelected {
            backgroundLayer.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.white.withAlphaComponent(0.95)).cgColor
            backgroundLayer.borderColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.08 : 0.12).cgColor
            backgroundLayer.borderWidth = 0.5
            backgroundLayer.shadowOpacity = isDark ? 0 : 0.12
        } else {
            backgroundLayer.backgroundColor = isHovered
                ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                : nil
            backgroundLayer.borderWidth = 0
            backgroundLayer.shadowOpacity = 0
        }

        separatorLayer.isHidden = !(showsSeparator && style == .horizontal && !isSelected && !isHovered)
        separatorLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor

        // Tab color
        colorLayer.isHidden = tabColor == .none
        colorLayer.backgroundColor = tabColor.displayColor?.cgColor

        // Text
        let textColor: NSColor = if isSelected {
            isWindowKey ? .labelColor : .secondaryLabelColor
        } else {
            isWindowKey ? .secondaryLabelColor : .tertiaryLabelColor
        }
        titleLayer.isHidden = isEditing
        let newTitle = TextContent(string: title, font: resolvedTitleFont, color: textColor.cgColor)
        if newTitle != shownTitle {
            shownTitle = newTitle
            titleLayer.string = newTitle.attributedString
        }
        let newShortcut = TextContent(
            string: keyEquivalent,
            font: Self.shortcutFont,
            color: NSColor.tertiaryLabelColor.cgColor)
        if newShortcut != shownShortcut {
            shownShortcut = newShortcut
            shortcutLayer.string = newShortcut.attributedString
        }

        // Buttons
        closeLayer.isHidden = !showsCloseButton
        closeLayer.backgroundColor = (isCloseHovered ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor
        closeBackgroundLayer.isHidden = !(showsCloseButton && isCloseHovered)
        closeBackgroundLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        zoomLayer.isHidden = !isZoomed
        zoomLayer.backgroundColor = (isWindowKey ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
    }

    // MARK: Events

    // All of our mouse events are handled by the tab bar so that it can
    // coordinate selection, dragging, and so on across all tabs.

    private var tabBar: TerminalTabBarView? {
        var view = superview
        while let current = view {
            if let tabBar = current as? TerminalTabBarView { return tabBar }
            view = current.superview
        }

        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let tabBar else { return super.mouseDown(with: event) }
        tabBar.mouseDown(on: self, with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle click closes the tab, like most tabbed applications.
        guard event.buttonNumber == 2,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let tabBar else { return super.otherMouseUp(with: event) }
        tabBar.close(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        tabBar?.contextMenu(for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let tabBar else { return false }
        tabBar.select(self)
        return true
    }

    // MARK: Resources

    private static let titleFontSize: CGFloat = 12
    private static let defaultTitleFont = NSFont.systemFont(ofSize: titleFontSize)
    private static let shortcutFont = NSFont.systemFont(ofSize: 11)

    // The images are shared by every tab, each tab only has a small mask layer.
    private static let closeImage: NSImage? = NSImage(
        systemSymbolName: "xmark",
        accessibilityDescription: "Close Tab"
    )?.withSymbolConfiguration(.init(pointSize: 8, weight: .bold))

    private static let zoomImage: NSImage? = NSImage(named: "ResetZoom")

    static func maskLayer(image: NSImage?) -> CALayer {
        let mask = CALayer()
        mask.contents = image
        mask.contentsGravity = .center
        mask.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        return mask
    }
}
