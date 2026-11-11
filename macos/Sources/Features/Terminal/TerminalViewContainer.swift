import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer: NSView {
    private let terminalView: NSView

    /// Background color applied with glass effect
    private(set) var glassEffectView: NSView?
    private var derivedConfig: DerivedConfig?

    var windowThemeFrameView: NSView? {
        window?.contentView?.superview
    }

    var windowCornerRadius: CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }

        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    init<Root: View>(@ViewBuilder rootView: () -> Root) {
        self.terminalView = NSHostingView(rootView: rootView())
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The initial content size to use as a fallback before the SwiftUI
    /// view hierarchy has completed layout (i.e. before @FocusedValue
    /// propagates `lastFocusedSurface`). Once the hosting view reports
    /// a valid intrinsic size, this fallback is no longer used.
    var initialContentSize: NSSize?

    override var intrinsicContentSize: NSSize {
        let hostingSize = terminalView.intrinsicContentSize
        // The hosting view returns a valid size once SwiftUI has laid out
        // with the correct idealWidth/idealHeight. Before that (when
        // @FocusedValue hasn't propagated), it returns a tiny default.
        // Fall back to initialContentSize in that case.
        let contentSize: NSSize
        if let initialContentSize,
           hostingSize.width < initialContentSize.width || hostingSize.height < initialContentSize.height {
            contentSize = initialContentSize
        } else {
            contentSize = hostingSize
        }

        // Anything the edge accessory takes away from the terminal has to be
        // added back so the terminal itself ends up at the requested size.
        let extra = edgeAccessoryExtraSize
        return NSSize(width: contentSize.width + extra.width, height: contentSize.height + extra.height)
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        updateTerminalViewConstraints()
    }

    // MARK: Edge Accessory

    /// An accessory view (e.g. a custom tab bar) pinned to one edge of the container.
    /// The terminal view fills the remaining space.
    struct EdgeAccessory {
        let view: NSView
        let edge: NSRectEdge
        /// The size of the accessory perpendicular to its edge. For the top edge this is
        /// the minimum; the accessory grows to cover the titlebar if there is one.
        let thickness: CGFloat
    }

    private(set) var edgeAccessory: EdgeAccessory?
    private var layoutConstraints: [NSLayoutConstraint] = []

    /// Set (or remove, with nil) the accessory view pinned to an edge of the container.
    ///
    /// This expects the window to use a full size content view when an accessory is set:
    /// a top accessory takes the place of the titlebar and everything else is laid out
    /// below the titlebar.
    func setEdgeAccessory(_ accessory: EdgeAccessory?) {
        if let old = edgeAccessory?.view, old !== accessory?.view {
            old.removeFromSuperview()
        }

        edgeAccessory = accessory
        if let view = accessory?.view, view.superview !== self {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view, positioned: .above, relativeTo: terminalView)
        }

        updateTerminalViewConstraints()
        invalidateIntrinsicContentSize()
    }

    private func updateTerminalViewConstraints() {
        NSLayoutConstraint.deactivate(layoutConstraints)

        guard let accessory = edgeAccessory else {
            layoutConstraints = [
                terminalView.topAnchor.constraint(equalTo: topAnchor),
                terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
                terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            NSLayoutConstraint.activate(layoutConstraints)
            return
        }

        // We use left/right rather than leading/trailing on purpose: the
        // accessory edge is a physical edge chosen by the user.
        let view = accessory.view
        let safeTop = safeAreaLayoutGuide.topAnchor
        switch accessory.edge {
        case .maxY:
            // Top: the accessory replaces the titlebar. It is as tall as the
            // titlebar when there is one and falls back to its own thickness
            // otherwise (e.g. fullscreen).
            let coverTitlebar = view.bottomAnchor.constraint(equalTo: safeTop)
            coverTitlebar.priority = .defaultHigh
            layoutConstraints = [
                view.topAnchor.constraint(equalTo: topAnchor),
                view.leftAnchor.constraint(equalTo: leftAnchor),
                view.rightAnchor.constraint(equalTo: rightAnchor),
                view.heightAnchor.constraint(greaterThanOrEqualToConstant: accessory.thickness),
                coverTitlebar,
                terminalView.topAnchor.constraint(equalTo: view.bottomAnchor),
                terminalView.leftAnchor.constraint(equalTo: leftAnchor),
                terminalView.rightAnchor.constraint(equalTo: rightAnchor),
                terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]

        case .minY:
            layoutConstraints = [
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leftAnchor.constraint(equalTo: leftAnchor),
                view.rightAnchor.constraint(equalTo: rightAnchor),
                view.heightAnchor.constraint(equalToConstant: accessory.thickness),
                terminalView.topAnchor.constraint(equalTo: safeTop),
                terminalView.leftAnchor.constraint(equalTo: leftAnchor),
                terminalView.rightAnchor.constraint(equalTo: rightAnchor),
                terminalView.bottomAnchor.constraint(equalTo: view.topAnchor),
            ]

        case .minX:
            layoutConstraints = [
                view.topAnchor.constraint(equalTo: safeTop),
                view.leftAnchor.constraint(equalTo: leftAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.widthAnchor.constraint(equalToConstant: accessory.thickness),
                terminalView.topAnchor.constraint(equalTo: safeTop),
                terminalView.leftAnchor.constraint(equalTo: view.rightAnchor),
                terminalView.rightAnchor.constraint(equalTo: rightAnchor),
                terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]

        case .maxX:
            layoutConstraints = [
                view.topAnchor.constraint(equalTo: safeTop),
                view.rightAnchor.constraint(equalTo: rightAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.widthAnchor.constraint(equalToConstant: accessory.thickness),
                terminalView.topAnchor.constraint(equalTo: safeTop),
                terminalView.leftAnchor.constraint(equalTo: leftAnchor),
                terminalView.rightAnchor.constraint(equalTo: view.leftAnchor),
                terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]

        @unknown default:
            layoutConstraints = []
        }

        NSLayoutConstraint.activate(layoutConstraints)
    }

    /// The space the edge accessory and the titlebar take away from the terminal.
    private var edgeAccessoryExtraSize: NSSize {
        guard let accessory = edgeAccessory else { return .zero }

        // We can't rely on our safe area here because this is used to size the
        // window before it has ever been laid out.
        let titlebarHeight = window?.fullSizeContentTitlebarHeight ?? 0

        switch accessory.edge {
        case .maxY: return NSSize(width: 0, height: max(titlebarHeight, accessory.thickness))
        case .minY: return NSSize(width: 0, height: titlebarHeight + accessory.thickness)
        case .minX, .maxX: return NSSize(width: accessory.thickness, height: titlebarHeight)
        @unknown default: return .zero
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
    }

    override func layout() {
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
    }

    func ghosttyConfigDidChange(_ config: Ghostty.Config, preferredBackgroundColor: NSColor?) {
        let newValue = DerivedConfig(config: config, preferredBackgroundColor: preferredBackgroundColor, cornerRadius: windowCornerRadius)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue

        // Attach the glass effect synchronously if missing to prevent flicker when a new tab appears.
        // Existing updates remain deferred, as they can occur during SwiftUI rendering.
        if glassEffectView == nil {
            updateGlassEffectIfNeeded()
        } else {
            DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
        }
    }
}

// MARK: - BaseTerminalController + terminalViewContainer

extension BaseTerminalController {
    var terminalViewContainer: TerminalViewContainer? {
        window?.contentView as? TerminalViewContainer
    }
}

// MARK: Glass

/// An `NSView` that contains a liquid glass background effect and
/// an inactive-window tint overlay.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private class TerminalGlassView: NSView, ObservableObject {
    /// We use this to apply glass effect to background colors
    ///
    struct GlassBackground: View {
        @ObservedObject var model: GlassViewModel

        var body: some View {
            model.color
                .glassEffect(
                    model.glass,
                    in: RoundedRectangle(cornerRadius: model.cornerRadius)
                )
        }
    }

    class GlassViewModel: ObservableObject {
        @Published var backgroundColor: Color = .clear
        @Published var backgroundOpacity: Double = 0
        @Published var cornerRadius: CGFloat = 0
        @Published var glass: Glass = .identity

        /// backgroundColor applied with backgroundOpacity
        var color: Color {
            backgroundColor.opacity(backgroundOpacity)
        }
    }

    private let glassEffectView: NSView
    private var topConstraint: NSLayoutConstraint!
    private let glassViewModel: GlassViewModel

    init(topOffset: CGFloat) {
        let viewModel = GlassViewModel()
        self.glassEffectView = NSHostingView(rootView: GlassBackground(model: viewModel))
        self.glassViewModel = viewModel
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Glass effect view fills this view.
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        topConstraint = glassEffectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        NSLayoutConstraint.activate([
            topConstraint,
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configures the glass, tint color, corner radius.
    func configure(
        glass: Glass,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
    ) {
        glassViewModel.backgroundColor = Color(backgroundColor)
        glassViewModel.backgroundOpacity = backgroundOpacity
        glassViewModel.cornerRadius = cornerRadius ?? 0
        glassViewModel.glass = glass
    }

    /// Updates the top inset offset for both the glass effect and tint overlay.
    /// Call this when the safe area insets change (e.g., during layout).
    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }
}
#endif // compiler(>=6.2)

extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func addGlassEffectViewIfNeeded() -> TerminalGlassView? {
        if let existed = glassEffectView as? TerminalGlassView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = windowThemeFrameView else {
            return nil
        }
        let effectView = TerminalGlassView(topOffset: -themeFrameView.safeAreaInsets.top)
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    private func updateGlassEffectIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), let derivedConfig else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            return
        }
        guard let effectView = addGlassEffectViewIfNeeded() else {
            return
        }

        effectView.configure(
            glass: derivedConfig.glass.official,
            backgroundColor: derivedConfig.backgroundColor,
            backgroundOpacity: derivedConfig.backgroundOpacity,
            cornerRadius: derivedConfig.cornerRadius,
        )
#endif // compiler(>=6.2)
    }

    private func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard
            #available(macOS 26.0, *),
            let effectView = glassEffectView as? TerminalGlassView,
            let themeFrameView = windowThemeFrameView
        else {
            return
        }
        effectView.updateTopInset(-themeFrameView.safeAreaInsets.top)
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        let glass: BackportGlass
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat?

        init?(config: Ghostty.Config, preferredBackgroundColor: NSColor?, cornerRadius: CGFloat?) {
            switch config.backgroundBlur {
            case .macosGlassRegular:
                glass = .regular
            case .macosGlassClear:
                glass = .clear
            default:
                return nil
            }
            self.backgroundColor = preferredBackgroundColor ?? NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.cornerRadius = cornerRadius
        }
    }
}
