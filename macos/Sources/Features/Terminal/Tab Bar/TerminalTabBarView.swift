import AppKit
import SwiftUI

/// A custom tab bar for windows that use native window tabbing.
///
/// The native `NSWindowTabGroup` remains the source of truth: every tab is still its
/// own window and this view only mirrors the tab group of the window it is in. That
/// keeps everything that operates on tab groups (keybindings, restoration, undo,
/// AppleScript, etc.) working without knowing about this view.
///
/// Every window in a tab group has its own tab bar but only one of those windows is
/// ever visible. A tab bar only holds tab views while its window is visible (it is
/// "active"), so the number of live tab views is the number of tabs rather than its
/// square. When another tab is selected, the tab views are handed over to the tab
/// bar of its window, so selecting a tab doesn't create any views either.
final class TerminalTabBarView: NSView {
    private enum Metrics {
        static let horizontalMinItemWidth: CGFloat = 96
        static let horizontalMaxItemWidth: CGFloat = 240
        static let horizontalInset: CGFloat = 8
        static let horizontalTrackInset: CGFloat = 3
        static let verticalItemHeight: CGFloat = 30
        static let verticalItemSpacing: CGFloat = 2
        static let verticalInset: CGFloat = 8
        static let buttonSize: CGFloat = 24
        static let buttonSpacing: CGFloat = 6
        static let resizeHandleWidth: CGFloat = 6
        static let dragThreshold: CGFloat = 4
        static let tearOffDistance: CGFloat = 40
        static let animationDuration: TimeInterval = 0.2
    }

    var position: TerminalTabBarPosition = .current {
        didSet {
            guard position != oldValue else { return }
            scrollOffset = 0
            for item in items { item.style = itemStyle }
            updateSeparators()
            window?.invalidateCursorRects(for: resizeHandle)
            needsLayout = true
        }
    }

    /// True while our window is visible, which is the only time we hold tab views.
    private(set) var isActive = false

    private var items: [TerminalTabBarItemView] = []
    private var itemsByWindow: [ObjectIdentifier: TerminalTabBarItemView] = [:]
    private var scrollOffset: CGFloat = 0
    private var maxScrollOffset: CGFloat = 0
    private weak var hoveredItem: TerminalTabBarItemView?

    /// The view that holds the tabs. This is handed over to another
    /// tab bar together with the tabs, see `Handoff`.
    private var clipView = ClipView()
    private let newTabButton = TerminalTabBarButton(symbolName: "plus", toolTip: "New Tab")
    private let resizeHandle = ResizeHandleView()

    // MARK: Init

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        addSubview(clipView)
        addSubview(newTabButton)
        addSubview(resizeHandle)

        newTabButton.action = { [weak self] in
            (self?.window?.windowController as? TerminalController)?.newTab(nil)
        }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self))

        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tab Bar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Activation

    /// All of the tab bars that are currently active.
    private static let activeBars = NSHashTable<TerminalTabBarView>.weakObjects()

    /// What a tab bar gives to the tab bar that takes its place. When a tab is
    /// selected the tab bar of the previous tab goes away and another takes over,
    /// and this lets the two look and behave like one continuous tab bar.
    private final class Handoff {
        /// The view holding all the tab views. Handing this over rather than
        /// every tab view means selecting a tab moves a single view.
        let clipView: ClipView
        /// The tab views, to be reused for the same tabs.
        let items: [TerminalTabBarItemView]
        /// The windows of the tabs in the order they were shown.
        let windows: [ObjectIdentifier]
        let scrollOffset: CGFloat

        init(clipView: ClipView, items: [TerminalTabBarItemView], scrollOffset: CGFloat) {
            self.clipView = clipView
            self.items = items
            self.windows = items.compactMap { $0.tabWindow.map(ObjectIdentifier.init) }
            self.scrollOffset = scrollOffset
        }
    }

    /// The handoff of the most recently deactivated tab bar. This is only kept until
    /// the end of the current event loop turn, which is when a tab bar that takes over
    /// would have done so.
    private static var parkedHandoff: Handoff?

    /// True if we gave our tabs to another tab bar but aren't deactivated yet.
    private var hasHandedOff = false

    private var occlusionObserver: NSObjectProtocol?
    private var tabGroupObservation: NSKeyValueObservation?
    private var selectionObservation: NSKeyValueObservation?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var activeObservers: [NSObjectProtocol] = []
    private var reloadScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        removeOcclusionObserver()
        if let window {
            // This is our fallback for anything that shows or hides our window
            // without us noticing in a more direct way.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.syncActive()
            }
        }

        syncActive()
    }

    private func removeOcclusionObserver() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
    }

    /// Stop everything that references our window. This must be called
    /// before the window goes away.
    func invalidate() {
        removeOcclusionObserver()
        if isActive { deactivate() }
    }

    /// True if our window is the one that is shown for its tab group.
    private var shouldBeActive: Bool {
        guard let window, window.isVisible else { return false }

        // Every window in a tab group is "visible", only the selected one is shown.
        // We avoid the tab group if we have no tabs because AppKit creates it lazily
        // and that is slow.
        guard window.tabbedWindows != nil else { return true }
        return window.tabGroup?.selectedWindow === window
    }

    /// Activate or deactivate depending on whether our window is shown. This is cheap
    /// and should be called whenever that may have changed.
    func syncActive() {
        let shouldBeActive = shouldBeActive
        guard shouldBeActive != isActive else {
            // We gave our tabs away expecting to be deactivated, but we're
            // still the one being shown, so we need them back.
            if isActive, hasHandedOff {
                hasHandedOff = false
                reload(animated: false)
            }
            return
        }

        if shouldBeActive {
            activate()
        } else {
            deactivate()
        }
    }

    private func activate() {
        guard let window else { return }
        isActive = true

        // Find what we're replacing before we register ourselves.
        let handoff = takeHandoff()
        Self.activeBars.add(self)

        let center = NotificationCenter.default
        activeObservers = [
            center.addObserver(
                forName: NewTabsTerminalWindow.tabStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let tabWindow = notification.object as? NSWindow else { return }
                self?.tabStateDidChange(tabWindow)
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                // The window is still part of the tab group at this point so we
                // have to look again once it is really gone.
                guard let self,
                      let closing = notification.object as? NSWindow,
                      itemsByWindow[ObjectIdentifier(closing)] != nil else { return }
                scheduleReload()
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.keyStateDidChange()
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.keyStateDidChange()
            },
        ]

        reload(animated: false, from: handoff)
    }

    private func deactivate() {
        // Keep our tabs around for a moment in case another tab bar takes over.
        if !hasHandedOff {
            let handoff = relinquish()
            Self.parkedHandoff = handoff
            DispatchQueue.main.async {
                if Self.parkedHandoff === handoff { Self.parkedHandoff = nil }
            }
        }

        Self.activeBars.remove(self)
        isActive = false
        hasHandedOff = false

        for observer in activeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activeObservers = []
        tabGroupObservation?.invalidate()
        tabGroupObservation = nil
        selectionObservation?.invalidate()
        selectionObservation = nil
        observedTabGroup = nil

        needsLayout = true
    }

    /// Give up all of our tabs so that another tab bar can show them.
    private func relinquish() -> Handoff {
        finishEditing(commit: true)
        cancelDrag()

        let handoff = Handoff(clipView: clipView, items: items, scrollOffset: scrollOffset)
        hoveredItem?.isHovered = false
        setClipView(ClipView())
        items = []
        itemsByWindow = [:]
        hoveredItem = nil
        return handoff
    }

    private func setClipView(_ newClipView: ClipView) {
        clipView.removeFromSuperview()
        clipView = newClipView
        addSubview(newClipView, positioned: .below, relativeTo: newTabButton)
    }

    /// Take over the tabs of the tab bar we're replacing, if there is one.
    private func takeHandoff() -> Handoff? {
        guard let window else { return nil }
        let windows = Set((window.tabbedWindows ?? [window]).map(ObjectIdentifier.init))

        // The previous tab bar is still active if we show up first. It is
        // about to be deactivated since we're the one that is shown now.
        for bar in Self.activeBars.allObjects where bar !== self && !bar.hasHandedOff {
            if bar.itemsByWindow.keys.contains(where: windows.contains) {
                bar.hasHandedOff = true
                return bar.relinquish()
            }
        }

        if let handoff = Self.parkedHandoff, handoff.windows.contains(where: windows.contains) {
            Self.parkedHandoff = nil
            return handoff
        }

        return nil
    }

    // MARK: Reloading

    private func scheduleReload() {
        guard isActive, !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, reloadScheduled else { return }
            reload(animated: true)
        }
    }

    /// Sync our tabs with the tab group of our window.
    private func reload(animated: Bool, from handoff: Handoff? = nil) {
        reloadScheduled = false
        guard isActive, !hasHandedOff, let window else { return }

        // Accessing the tab group of a window without tabs makes AppKit set up
        // all of its tabbing machinery, which is slow, so we avoid it.
        let tabbedWindows = window.tabbedWindows
        let windows = tabbedWindows ?? [window]
        observe(tabGroup: tabbedWindows != nil ? window.tabGroup : nil)

        // While a tab is dragged the order of our tabs is the order on screen
        // and we don't want to snap back to the tab group order.
        if let drag {
            let current = Set(windows.map(ObjectIdentifier.init))
            if current == Set(itemsByWindow.keys), drag.item.tabWindow != nil {
                for item in items { item.update() }
                return
            }

            cancelDrag()
        }

        // Tab views we can reuse: our own and the ones handed over to us. The
        // ones handed over to us come with the view they are in.
        var reusable = itemsByWindow
        if let handoff {
            for item in items { item.removeFromSuperview() }
            setClipView(handoff.clipView)
            for item in handoff.items {
                if let tabWindow = item.tabWindow { reusable[ObjectIdentifier(tabWindow)] = item }
            }
        }

        var newItems: [TerminalTabBarItemView] = []
        var newItemsByWindow: [ObjectIdentifier: TerminalTabBarItemView] = [:]
        var added: [TerminalTabBarItemView] = []
        newItems.reserveCapacity(windows.count)
        for tabWindow in windows {
            let id = ObjectIdentifier(tabWindow)
            let item: TerminalTabBarItemView
            if let existing = reusable[id], existing.tabWindow === tabWindow {
                item = existing
                if item.superview !== clipView { added.append(item) }
            } else {
                item = TerminalTabBarItemView(tabWindow: tabWindow)
                added.append(item)
            }

            item.style = itemStyle
            item.isSelected = tabWindow === window
            item.isWindowKey = window.isKeyWindow
            item.update()
            newItems.append(item)
            newItemsByWindow[id] = item
        }

        for item in items + (handoff?.items ?? []) {
            let isUsed = item.tabWindow.map { newItemsByWindow[ObjectIdentifier($0)] === item } ?? false
            guard !isUsed else { continue }
            if editing?.item === item { finishEditing(commit: false) }
            item.removeFromSuperview()
        }
        for item in added {
            clipView.addSubview(item)
        }

        items = newItems
        itemsByWindow = newItemsByWindow
        updateSeparators()

        if let handoff {
            // Start out exactly like the tab bar we replace and animate from there.
            scrollOffset = handoff.scrollOffset
            let slots = Dictionary(
                handoff.windows.enumerated().map { ($1, $0) },
                uniquingKeysWith: { first, _ in first })
            if slots.count != items.count || items.contains(where: { item in
                item.tabWindow.map { slots[ObjectIdentifier($0)] == nil } ?? true
            }) {
                layoutContents(animated: false, slots: slots, slotCount: handoff.windows.count)
                scrollSelectedItemToVisible(layout: false)
                animateAppearance(of: added.filter { item in
                    item.tabWindow.map { slots[ObjectIdentifier($0)] == nil } ?? true
                })
                layoutContents(animated: true)
            } else {
                scrollSelectedItemToVisible(layout: false)
                layoutContents(animated: false)
            }
        } else {
            if animated { animateAppearance(of: added) }
            layoutContents(animated: animated)
            scrollSelectedItemToVisible(layout: true)
        }

        refreshHover()
    }

    private func observe(tabGroup: NSWindowTabGroup?) {
        guard tabGroup !== observedTabGroup || (tabGroup != nil && tabGroupObservation == nil) else { return }
        tabGroupObservation?.invalidate()
        selectionObservation?.invalidate()
        observedTabGroup = tabGroup
        tabGroupObservation = tabGroup?.observe(\.windows) { [weak self] _, _ in
            // Never do real work in here: this is called in the middle
            // of AppKit changing the tab group.
            self?.scheduleReload()
        }
        selectionObservation = tabGroup?.observe(\.selectedWindow) { [weak self] tabGroup, _ in
            // Another tab was selected. Its tab bar takes over right away so that
            // it is ready before its window is drawn. We can't remove ourselves as
            // an observer from within the observation, so we go away later.
            (tabGroup.selectedWindow as? NewTabsTerminalWindow)?.tabBar.syncActive()
            DispatchQueue.main.async { self?.syncActive() }
        }
    }

    private func tabStateDidChange(_ tabWindow: NSWindow) {
        if let item = itemsByWindow[ObjectIdentifier(tabWindow)], item.tabWindow === tabWindow {
            item.update()
            return
        }

        // A window we don't know about. If it is in our tab group then we
        // missed a change to the group.
        if let tabbedWindows = window?.tabbedWindows, tabbedWindows.contains(tabWindow) {
            scheduleReload()
        }
    }

    private func keyStateDidChange() {
        let isKey = window?.isKeyWindow ?? false
        for item in items { item.isWindowKey = isKey }
    }

    private func updateSeparators() {
        for (index, item) in items.enumerated() {
            item.showsSeparator = index > 0 && !items[index - 1].isSelected
        }
    }

    private func animateAppearance(of added: [TerminalTabBarItemView]) {
        guard !added.isEmpty else { return }
        for item in added { item.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.animationDuration
            for item in added { item.animator().alphaValue = 1 }
        }
    }

    // MARK: Layout

    override var isFlipped: Bool { true }

    private var itemStyle: TerminalTabBarItemView.Style {
        position.isVertical ? .vertical : .horizontal
    }

    /// The space we have to leave for the window buttons when we're in the titlebar.
    private var windowButtonsInset: CGFloat {
        guard position == .top, let window, !window.styleMask.contains(.fullScreen) else {
            return Metrics.horizontalInset
        }

        let maxX = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .filter { !$0.isHidden && $0.window === window }
            .map { $0.convert($0.bounds, to: nil).maxX }
            .max()
        guard let maxX else { return Metrics.horizontalInset }
        return maxX + 12
    }

    /// The length of a single tab along the axis the tabs are laid out on, including spacing.
    private var itemPitch: CGFloat = 0

    override func layout() {
        super.layout()
        syncActive()
        layoutContents(animated: false)
    }

    /// Lay out all of our subviews.
    ///
    /// If slots are given then tabs are positioned at the given slot index rather than
    /// their own index. This is used to start an animation from another tab bar's layout.
    private func layoutContents(
        animated: Bool,
        slots: [ObjectIdentifier: Int]? = nil,
        slotCount: Int? = nil
    ) {
        let count = slotCount ?? items.count
        let itemSize: CGSize
        let contentLength: CGFloat
        let clipFrame: CGRect
        let buttonFrame: CGRect

        if position.isVertical {
            let inset = Metrics.verticalInset
            let available = bounds.height - inset * 2 - Metrics.buttonSize - Metrics.buttonSpacing
            itemPitch = Metrics.verticalItemHeight + Metrics.verticalItemSpacing
            itemSize = CGSize(width: max(bounds.width - inset * 2, 0), height: Metrics.verticalItemHeight)
            contentLength = itemPitch * CGFloat(count)
            let visibleLength = max(min(contentLength, available), 0)
            clipFrame = CGRect(x: inset, y: inset, width: itemSize.width, height: visibleLength)
            buttonFrame = CGRect(
                x: inset,
                y: clipFrame.maxY + Metrics.buttonSpacing - Metrics.verticalItemSpacing,
                width: Metrics.buttonSize,
                height: Metrics.buttonSize)
            maxScrollOffset = max(contentLength - visibleLength, 0)

            let handleX = position == .left ? bounds.width - Metrics.resizeHandleWidth : 0
            resizeHandle.frame = CGRect(x: handleX, y: 0, width: Metrics.resizeHandleWidth, height: bounds.height)
            resizeHandle.isHidden = false
        } else {
            let leading = windowButtonsInset
            let trackHeight = max(bounds.height - Metrics.horizontalTrackInset * 2, 0)
            let available = bounds.width - leading - Metrics.horizontalInset
                - Metrics.buttonSize - Metrics.buttonSpacing
            itemPitch = count > 0
                ? min(max((available / CGFloat(count)).rounded(.down), Metrics.horizontalMinItemWidth),
                      Metrics.horizontalMaxItemWidth)
                : 0
            itemSize = CGSize(width: itemPitch, height: trackHeight)
            contentLength = itemPitch * CGFloat(count)
            let visibleLength = max(min(contentLength, available), 0)
            clipFrame = CGRect(
                x: leading,
                y: Metrics.horizontalTrackInset,
                width: visibleLength,
                height: trackHeight)
            buttonFrame = CGRect(
                x: clipFrame.maxX + Metrics.buttonSpacing,
                y: ((bounds.height - Metrics.buttonSize) / 2).rounded(),
                width: Metrics.buttonSize,
                height: Metrics.buttonSize)
            maxScrollOffset = max(contentLength - visibleLength, 0)
            resizeHandle.isHidden = true
        }

        scrollOffset = min(max(scrollOffset, 0), maxScrollOffset)
        clipView.showsTrack = !position.isVertical

        let apply = {
            self.clipView.frame = clipFrame
            self.newTabButton.frame = buttonFrame
            for (index, item) in self.items.enumerated() where item !== self.drag?.item {
                let slot = item.tabWindow.flatMap { slots?[ObjectIdentifier($0)] } ?? index
                item.frame = self.itemFrame(at: slot, size: itemSize)
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Metrics.animationDuration
                context.allowsImplicitAnimation = true
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                apply()
                self.layoutSubtreeIfNeeded()
            }
        } else {
            apply()
        }
    }

    private func itemFrame(at index: Int, size: CGSize) -> CGRect {
        let offset = itemPitch * CGFloat(index) - scrollOffset
        return position.isVertical
            ? CGRect(x: 0, y: offset, width: size.width, height: size.height)
            : CGRect(x: offset, y: 0, width: size.width, height: size.height)
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }

        var delta: CGFloat
        if position.isVertical {
            delta = event.scrollingDeltaY
        } else {
            // Allow a regular mouse wheel to scroll horizontal tabs.
            delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX
                : event.scrollingDeltaY
        }
        if !event.hasPreciseScrollingDeltas { delta *= 10 }

        let newOffset = min(max(scrollOffset - delta, 0), maxScrollOffset)
        guard newOffset != scrollOffset else { return }
        scrollOffset = newOffset
        layoutContents(animated: false)
        refreshHover()
    }

    private func scrollSelectedItemToVisible(layout: Bool) {
        guard let index = items.firstIndex(where: { $0.isSelected }) else { return }
        let visibleLength = position.isVertical ? clipView.frame.height : clipView.frame.width
        let start = itemPitch * CGFloat(index)
        var newOffset = scrollOffset
        if start < newOffset {
            newOffset = start
        } else if start + itemPitch > newOffset + visibleLength {
            newOffset = start + itemPitch - visibleLength
        }

        guard newOffset != scrollOffset else { return }
        scrollOffset = newOffset
        if layout { layoutContents(animated: false) }
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    private func refreshHover() {
        guard let window, hoveredItem != nil || window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(at: bounds.contains(point) ? point : nil)
    }

    private func updateHover(at point: CGPoint?) {
        let item = drag == nil ? point.flatMap { self.item(at: $0) } : nil
        if hoveredItem !== item {
            hoveredItem?.isHovered = false
            hoveredItem = item
            item?.isHovered = true
        }

        if let item, let point {
            item.isCloseHovered = item.closeRect.contains(item.convert(point, from: self))
        }
    }

    private func item(at point: CGPoint) -> TerminalTabBarItemView? {
        guard clipView.frame.contains(point) else { return nil }
        let clipPoint = clipView.convert(point, from: self)
        return items.first { $0.frame.contains(clipPoint) }
    }

    // MARK: Introspection

    /// The windows of the tabs we show, in the order we show them.
    var tabWindows: [NSWindow] {
        items.compactMap(\.tabWindow)
    }

    /// The frame of the tab for the given window in window coordinates.
    func tabFrame(for tabWindow: NSWindow) -> CGRect? {
        guard let item = itemsByWindow[ObjectIdentifier(tabWindow)] else { return nil }
        return item.convert(item.bounds, to: nil)
    }

    // MARK: Window Dragging

    // The parts of the tab bar that aren't tabs behave like a titlebar. We do
    // this ourselves rather than with `mouseDownCanMoveWindow` because that
    // only applies to the titlebar, which we may not be in.

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        finishEditing(commit: true)

        if event.clickCount == 2 {
            // Same as double clicking a titlebar.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return
        }

        window.performDrag(with: event)
    }

    // MARK: Actions

    func select(_ item: TerminalTabBarItemView) {
        guard !item.isSelected, let tabWindow = item.tabWindow else { return }
        tabWindow.makeKeyAndOrderFront(nil)
    }

    func close(_ item: TerminalTabBarItemView) {
        // This goes through the same path as the native close button so
        // that we get close confirmation and so on.
        item.tabWindow?.performClose(nil)
    }

    /// Handles a mouse down on one of our tabs.
    func mouseDown(on item: TerminalTabBarItemView, with event: NSEvent) {
        guard let tabWindow = item.tabWindow else { return }
        let point = item.convert(event.locationInWindow, from: nil)

        if item.showsCloseButton, item.closeRect.contains(point) {
            if trackPress(on: item, in: item.closeRect) { close(item) }
            return
        }

        if item.isZoomed, item.zoomRect.contains(point) {
            if trackPress(on: item, in: item.zoomRect) {
                (tabWindow.windowController as? TerminalController)?.splitZoom(self)
            }
            return
        }

        if event.clickCount == 2 {
            // Wait for this click to be done, otherwise handling the
            // rest of it takes the focus away from the editor again.
            DispatchQueue.main.async { [weak self, weak tabWindow] in
                guard let self, let tabWindow else { return }
                beginEditing(for: tabWindow)
            }
            return
        }

        finishEditing(commit: true)

        // Selecting a tab swaps our window for the window of that tab, which
        // has its own tab bar. The drag session isn't tied to either so the
        // drag can carry on in the new tab bar.
        TabDragSession.begin(tabWindow: tabWindow, event: event)
        select(item)
    }

    /// Tracks the mouse until it is released. Returns true if it was released within the rect.
    private func trackPress(on item: TerminalTabBarItemView, in rect: CGRect) -> Bool {
        while let event = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if event.type == .leftMouseUp {
                return rect.contains(item.convert(event.locationInWindow, from: nil))
            }
        }

        return false
    }

    // MARK: Dragging

    private struct Drag {
        let item: TerminalTabBarItemView
        /// The offset of the mouse from the origin of the tab along the tab axis.
        let grabOffset: CGFloat
        /// The index of the tab when the drag started.
        let startIndex: Int
    }
    private var drag: Drag?

    /// The frame of the area holding the tabs in screen coordinates.
    var tabsFrameInScreen: CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    private func clipPoint(fromScreen point: NSPoint) -> CGPoint? {
        guard let window else { return nil }
        return clipView.convert(window.convertPoint(fromScreen: point), from: nil)
    }

    /// Start dragging the tab of the given window. Returns false if we can't.
    fileprivate func beginDrag(tabWindow: NSWindow, at screenPoint: NSPoint) -> Bool {
        guard isActive, drag == nil,
              let item = itemsByWindow[ObjectIdentifier(tabWindow)],
              let index = items.firstIndex(where: { $0 === item }),
              let point = clipPoint(fromScreen: screenPoint) else { return false }

        finishEditing(commit: true)
        updateHover(at: nil)
        let grabOffset = position.isVertical ? point.y - item.frame.minY : point.x - item.frame.minX
        drag = .init(item: item, grabOffset: grabOffset, startIndex: index)

        // The dragged tab is above all the others.
        clipView.addSubview(item, positioned: .above, relativeTo: nil)
        return true
    }

    /// Move the dragged tab to the given location. Returns true if the tab was dragged far
    /// enough away from the tab bar that it should become its own window.
    fileprivate func updateDrag(to screenPoint: NSPoint) -> Bool {
        guard let drag,
              let point = clipPoint(fromScreen: screenPoint),
              let currentIndex = items.firstIndex(where: { $0 === drag.item }) else { return false }

        // Tear the tab off if it has other tabs to leave behind.
        let distance = position.isVertical
            ? max(-point.x, point.x - clipView.bounds.width)
            : max(-point.y, point.y - clipView.bounds.height)
        if distance > Metrics.tearOffDistance, items.count > 1 {
            return true
        }

        // The dragged tab follows the mouse but stays within the tab bar.
        let visibleLength = position.isVertical ? clipView.bounds.height : clipView.bounds.width
        let itemLength = position.isVertical ? drag.item.frame.height : drag.item.frame.width
        let along = position.isVertical ? point.y : point.x
        let origin = min(max(along - drag.grabOffset, 0), max(visibleLength - itemLength, 0))
        var frame = drag.item.frame
        if position.isVertical {
            frame.origin.y = origin
        } else {
            frame.origin.x = origin
        }
        drag.item.frame = frame

        // Make room where the dragged tab would be dropped.
        guard itemPitch > 0 else { return false }
        let center = origin + itemLength / 2 + scrollOffset
        let newIndex = min(max(Int(center / itemPitch), 0), items.count - 1)
        if newIndex != currentIndex {
            items.remove(at: currentIndex)
            items.insert(drag.item, at: newIndex)
            updateSeparators()
            layoutContents(animated: true)
        }

        return false
    }

    /// Finish the drag by dropping the dragged tab where it is.
    fileprivate func endDrag() {
        guard let drag else { return }
        self.drag = nil
        layoutContents(animated: true)

        guard let window,
              drag.item.tabWindow === window,
              let newIndex = items.firstIndex(where: { $0 === drag.item }),
              newIndex != drag.startIndex,
              let tabGroup = window.tabGroup else {
            reload(animated: true)
            return
        }

        // We never move the window of the dragged tab itself. It is the selected
        // window, and removing that from the tab group makes AppKit show another
        // tab for a moment. Instead we move the tabs it passed to its other side.
        let windows = tabGroup.windows
        guard let oldIndex = windows.firstIndex(of: window),
              windows.indices.contains(newIndex) else {
            reload(animated: true)
            return
        }

        if newIndex < oldIndex {
            for passed in windows[newIndex..<oldIndex].reversed() {
                tabGroup.removeWindow(passed)
                window.addTabbedWindowSafely(passed, ordered: .above)
            }
        } else {
            for passed in windows[(oldIndex + 1)...newIndex] {
                tabGroup.removeWindow(passed)
                window.addTabbedWindowSafely(passed, ordered: .below)
            }
        }

        reload(animated: false)
        (window.windowController as? TerminalController)?.relabelTabs()
    }

    private func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        TabDragSession.current?.end()
    }

    /// Adds the given window to our tab group at the tab position under the given point.
    fileprivate func insert(tabWindow: NSWindow, atScreenPoint screenPoint: NSPoint) {
        guard isActive, let window, tabWindow !== window,
              let point = clipPoint(fromScreen: screenPoint) else { return }

        let along = (position.isVertical ? point.y : point.x) + scrollOffset
        let index = itemPitch > 0 ? Int((along / itemPitch).rounded()) : items.count
        if index <= 0, let first = items.first?.tabWindow {
            first.addTabbedWindowSafely(tabWindow, ordered: .below)
        } else if let previous = items[safe: min(index, items.count) - 1]?.tabWindow {
            previous.addTabbedWindowSafely(tabWindow, ordered: .above)
        } else {
            window.addTabbedWindowSafely(tabWindow, ordered: .above)
        }

        tabWindow.makeKeyAndOrderFront(nil)
        (tabWindow.windowController as? TerminalController)?.relabelTabs()
    }

    // MARK: Inline Title Editing

    private struct Editing {
        let field: NSTextField
        let item: TerminalTabBarItemView
    }
    private var editing: Editing?

    /// Begin editing the title of the tab for the given window. Returns false if
    /// that isn't possible, in which case the caller should fall back to a prompt.
    @discardableResult
    func beginEditing(for tabWindow: NSWindow) -> Bool {
        guard isActive,
              let window,
              let item = itemsByWindow[ObjectIdentifier(tabWindow)],
              let controller = tabWindow.windowController as? BaseTerminalController else { return false }

        finishEditing(commit: true)
        layoutSubtreeIfNeeded()

        let field = NSTextField(frame: item.titleRect.insetBy(dx: -2, dy: -1).offsetBy(dx: 0, dy: -1))
        field.stringValue = controller.titleOverride ?? tabWindow.title
        field.font = NSFont.systemFont(ofSize: 12)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.autoresizingMask = [.width]
        if let cell = field.cell as? NSTextFieldCell {
            cell.wraps = false
            cell.usesSingleLineMode = true
            cell.isScrollable = true
        }
        field.delegate = self

        item.isEditing = true
        item.addSubview(field)
        editing = .init(field: field, item: item)

        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        return true
    }

    func finishEditing(commit: Bool) {
        guard let editing else { return }
        self.editing = nil

        let title = editing.field.stringValue
        editing.field.delegate = nil
        editing.field.removeFromSuperview()
        editing.item.isEditing = false

        if commit, let controller = editing.item.tabWindow?.windowController as? BaseTerminalController {
            controller.titleOverride = title.isEmpty ? nil : title
        }

        // Give the focus back to the terminal.
        if let window,
           let controller = window.windowController as? BaseTerminalController,
           let surface = controller.focusedSurface {
            window.makeFirstResponder(surface)
        }
    }

    // MARK: Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(for: item(at: convert(event.locationInWindow, from: nil)))
    }

    func contextMenu(for item: TerminalTabBarItemView?) -> NSMenu {
        let menu = NSMenu()
        let hostController = window?.windowController as? TerminalController

        let newTab = NSMenuItem(title: "New Tab", action: #selector(TerminalController.newTab(_:)), keyEquivalent: "")
        newTab.target = hostController
        newTab.setImageIfDesired(systemSymbolName: "plus")
        menu.addItem(newTab)

        if let tabWindow = item?.tabWindow {
            let controller = tabWindow.windowController as? TerminalController
            menu.addItem(.separator())

            let close = NSMenuItem(title: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
            close.target = tabWindow
            close.setImageIfDesired(systemSymbolName: "xmark")
            menu.addItem(close)

            let closeOthers = NSMenuItem(
                title: "Close Other Tabs",
                action: #selector(TerminalController.closeOtherTabs(_:)),
                keyEquivalent: "")
            closeOthers.target = controller
            closeOthers.setImageIfDesired(systemSymbolName: "xmark")
            menu.addItem(closeOthers)

            let closeRight = NSMenuItem(
                title: position.isVertical ? "Close Tabs Below" : "Close Tabs to the Right",
                action: #selector(TerminalController.closeTabsOnTheRight(_:)),
                keyEquivalent: "")
            closeRight.target = controller
            closeRight.setImageIfDesired(systemSymbolName: "xmark")
            menu.addItem(closeRight)

            let moveToNewWindow = NSMenuItem(
                title: "Move Tab to New Window",
                action: #selector(NSWindow.moveTabToNewWindow(_:)),
                keyEquivalent: "")
            moveToNewWindow.target = tabWindow
            moveToNewWindow.isEnabled = items.count > 1
            menu.addItem(moveToNewWindow)

            let showAll = NSMenuItem(
                title: "Show All Tabs",
                action: #selector(showAllTabs(_:)),
                keyEquivalent: "")
            showAll.target = self
            menu.addItem(showAll)

            menu.addItem(.separator())

            let rename = NSMenuItem(title: "Rename Tab...", action: #selector(renameTab(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = tabWindow
            rename.setImageIfDesired(systemSymbolName: "pencil.line")
            menu.addItem(rename)

            let palette = NSMenuItem()
            let paletteView = NSHostingView(rootView: TabColorMenuView(
                selectedColor: (tabWindow as? TerminalWindow)?.tabColor ?? .none
            ) { [weak tabWindow] color in
                (tabWindow as? TerminalWindow)?.tabColor = color
            })
            paletteView.frame.size = paletteView.intrinsicContentSize
            palette.view = paletteView
            menu.addItem(palette)
        }

        menu.addItem(.separator())

        let positionItem = NSMenuItem(title: "Tab Bar Position", action: nil, keyEquivalent: "")
        positionItem.setImageIfDesired(systemSymbolName: TerminalTabBarPosition.current.symbolName)
        let positionMenu = NSMenu()
        for position in TerminalTabBarPosition.allCases {
            let item = NSMenuItem(
                title: position.localizedName,
                action: #selector(changePosition(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = position.rawValue
            item.state = position == TerminalTabBarPosition.current ? .on : .off
            item.setImageIfDesired(systemSymbolName: position.symbolName)
            positionMenu.addItem(item)
        }
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)

        return menu
    }

    @objc private func showAllTabs(_ sender: NSMenuItem) {
        // The menu action of the window is disabled while its native tab bar is hidden.
        guard let window, window.tabbedWindows != nil, let tabGroup = window.tabGroup else { return }
        tabGroup.isOverviewVisible.toggle()
    }

    @objc private func renameTab(_ sender: NSMenuItem) {
        guard let tabWindow = sender.representedObject as? NSWindow else { return }
        if beginEditing(for: tabWindow) { return }
        (tabWindow.windowController as? BaseTerminalController)?.promptTabTitle()
    }

    @objc private func changePosition(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let position = TerminalTabBarPosition(rawValue: rawValue) else { return }
        TerminalTabBarPosition.current = position
    }
}

// MARK: NSTextFieldDelegate

extension TerminalTabBarView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === editing?.field else { return false }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishEditing(commit: true)
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(commit: false)
            return true
        }

        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === editing?.field else { return }
        finishEditing(commit: true)
    }
}

// MARK: Drag Session

/// Tracks the mouse after a mouse down on a tab.
///
/// A mouse down on a tab selects it, and selecting a tab replaces the window (and with
/// it the tab bar) under the mouse. So rather than tracking the drag in a tab bar we
/// track it here and forward it to whichever tab bar currently shows the dragged tab,
/// which is always the tab bar of the window of that tab.
private final class TabDragSession {
    private(set) static var current: TabDragSession?

    private weak var tabWindow: NSWindow?
    private let startLocation: NSPoint
    private var monitor: Any?
    private var isDragging = false
    private var isTornOff = false

    static func begin(tabWindow: NSWindow, event: NSEvent) {
        current?.end()
        current = TabDragSession(tabWindow: tabWindow, startLocation: screenLocation(of: event))
    }

    /// The location of a mouse event in screen coordinates.
    private static func screenLocation(of event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private init(tabWindow: NSWindow, startLocation: NSPoint) {
        self.tabWindow = tabWindow
        self.startLocation = startLocation
        self.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private var tabBar: TerminalTabBarView? {
        (tabWindow as? NewTabsTerminalWindow)?.tabBar
    }

    func end() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        if isDragging {
            isDragging = false
            tabBar?.endDrag()
        }

        if Self.current === self { Self.current = nil }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            guard !isTornOff, let tabWindow, let tabBar, tabBar.isActive else { return }
            let location = Self.screenLocation(of: event)
            if !isDragging {
                guard hypot(location.x - startLocation.x, location.y - startLocation.y) > 4 else { return }

                // The only tab of a window drags the whole window, which
                // can then be dropped on the tab bar of another window.
                if tabBar.tabWindows.count <= 1 {
                    dragWindow(tabWindow, with: event)
                    return
                }

                guard tabBar.beginDrag(tabWindow: tabWindow, at: startLocation) else {
                    end()
                    return
                }
                isDragging = true
            }

            if tabBar.updateDrag(to: location) {
                tearOff(tabWindow, with: event)
            }

        case .leftMouseUp:
            if isTornOff { mergeIfDroppedOnTabBar(at: Self.screenLocation(of: event)) }
            end()

        default:
            end()
        }
    }

    /// Moves the dragged tab into its own window and lets the user keep dragging that window.
    private func tearOff(_ tabWindow: NSWindow, with event: NSEvent) {
        isDragging = false
        tabBar?.endDrag()

        // Keep the mouse at the same place within the window.
        let location = Self.screenLocation(of: event)
        let offset = CGPoint(x: location.x - tabWindow.frame.minX, y: location.y - tabWindow.frame.minY)
        tabWindow.moveTabToNewWindow(nil)
        tabWindow.setFrameOrigin(NSPoint(x: location.x - offset.x + 20, y: location.y - offset.y - 20))
        tabWindow.makeKeyAndOrderFront(nil)
        (tabWindow.windowController as? TerminalController)?.relabelTabs()

        dragWindow(tabWindow, with: event)
    }

    /// Lets the user drag the window of the tab around until the mouse is released.
    private func dragWindow(_ tabWindow: NSWindow, with event: NSEvent) {
        isTornOff = true

        // This tracks the mouse until it is released.
        tabWindow.performDrag(with: event)
        if NSEvent.pressedMouseButtons & 1 == 0 {
            mergeIfDroppedOnTabBar(at: NSEvent.mouseLocation)
            end()
        }
    }

    /// If the torn off window was dropped on the tab bar of another window, make it a tab there.
    private func mergeIfDroppedOnTabBar(at location: NSPoint) {
        guard isTornOff, let tabWindow else { return }

        // Find the frontmost window under the mouse that isn't the one we're dragging.
        guard let target = NSApp.orderedWindows.first(where: {
            $0 !== tabWindow && $0.isVisible && $0.frame.contains(location)
        }) as? NewTabsTerminalWindow,
              target.tabBar.tabsFrameInScreen.contains(location) else { return }

        isTornOff = false
        target.tabBar.insert(tabWindow: tabWindow, atScreenPoint: location)
    }
}

// MARK: Subviews

/// Holds the tabs and clips them to the visible part of the tab bar.
private final class ClipView: NSView {
    /// Draw a rounded track behind the tabs.
    var showsTrack = false {
        didSet {
            guard showsTrack != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    // Clicks between tabs go to the tab bar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? superview : view
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = showsTrack ? min(bounds.height / 2, 14) : 0
    }

    override func updateLayer() {
        layer?.backgroundColor = showsTrack ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : nil
    }
}

/// A small icon button in the tab bar.
final class TerminalTabBarButton: NSView {
    var action: (() -> Void)?

    private let iconLayer = CALayer()
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    init(symbolName: String, toolTip: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.toolTip = toolTip

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        iconLayer.mask = TerminalTabBarItemView.maskLayer(image: image)
        layer?.addSublayer(iconLayer)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        iconLayer.frame = bounds
        iconLayer.mask?.frame = bounds
        CATransaction.commit()
    }

    override func updateLayer() {
        let alpha: CGFloat = isPressed ? 0.14 : (isHovered ? 0.08 : 0)
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        iconLayer.backgroundColor = NSColor.secondaryLabelColor.cgColor
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // We're part of the tab bar as far as the context menu is concerned.
    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        defer { isPressed = false }

        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isPressed = inside
            if next.type == .leftMouseUp {
                if inside { action?() }
                return
            }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}

/// The edge of a sidebar tab bar that can be dragged to resize it.
private final class ResizeHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    // Like the edges of a window, this works without activating the window first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { return }
            let x = next.locationInWindow.x
            switch TerminalTabBarPosition.current {
            case .left: TerminalTabBarPosition.sidebarWidth = x
            case .right: TerminalTabBarPosition.sidebarWidth = window.frame.width - x
            default: return
            }
        }
    }
}
