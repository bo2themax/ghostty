import AppKit
import SwiftUI

// MARK: - Model

/// A window that shows its tab group in a `TabBarContainer` instead of the native tab bar.
@available(macOS 26.0, *)
protocol TabBarWindow: NSWindow {
    var tabBar: TabBarModel { get }
}

/// The tab bar state of one `TabBarWindow`. It doesn't depend on where the bar is placed.
///
/// The model never stores tab windows. Rows carry an `ObjectIdentifier` and actions look the
/// window up in the live tab group, so a closed tab can't be kept alive by a tab bar.
@available(macOS 26.0, *)
final class TabBarModel: ObservableObject {
    /// Post with the changed window as the object whenever something shown in a tab
    /// (title, color, shortcut, zoom state) changes.
    static let tabDidChangeNotification = Notification.Name("TabBarTabDidChange")

    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let font: NSFont?
        let color: TerminalTabColor
        let shortcut: String?
        let isZoomed: Bool

        init(_ window: NSWindow) {
            let terminalWindow = window as? TerminalWindow
            self.id = ObjectIdentifier(window)
            self.title = window.title
            self.font = terminalWindow?.titlebarFont
            self.color = terminalWindow?.tabColor ?? .none
            self.shortcut = terminalWindow?.keyEquivalent.flatMap { $0.isEmpty ? nil : $0 }
            self.isZoomed = terminalWindow?.surfaceIsZoomed ?? false
        }
    }

    /// Tab bar visibility, kept separate from `tabs` so tab changes don't re-evaluate
    /// the container (and with it the terminal view).
    final class Layout: ObservableObject {
        @Published var isVisible: Bool

        init(isVisible: Bool) {
            self.isVisible = isVisible
        }
    }

    /// The tabs of this window's tab group, in tab order.
    @Published private(set) var tabs: [Tab] = []

    /// False while this window is a background tab. Its bar is then replaced by an empty
    /// placeholder of the same size, so hidden tabs keep no bar views or layers.
    @Published private(set) var isActive = true

    let layout: Layout

    /// The visibility new windows start with: the last one the user chose.
    private static var lastIsVisible = true

    private weak var window: NSWindow?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupObservation: NSKeyValueObservation?
    private var tabDidChangeObserver: NSObjectProtocol?
    private var needsRefresh = true
    private var refreshScheduled = false

    init(window: NSWindow) {
        self.window = window
        self.layout = Layout(isVisible: Self.lastIsVisible)

        tabDidChangeObserver = NotificationCenter.default.addObserver(
            forName: Self.tabDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.tabDidChange(notification.object as? NSWindow)
        }
    }

    deinit {
        tabGroupObservation?.invalidate()
        if let tabDidChangeObserver {
            NotificationCenter.default.removeObserver(tabDidChangeObserver)
        }
    }

    var selectedID: ObjectIdentifier? {
        window.map(ObjectIdentifier.init)
    }

    // MARK: Refresh

    /// Rebuilds the rows if something changed since the last refresh.
    func refreshIfNeeded() {
        guard needsRefresh else { return }
        refresh()
    }

    /// Called when this window becomes the selected tab. Hidden tabs don't need a bar, so
    /// release the bars of the other windows in the group; each window rebuilds its own
    /// bar here. This keeps the number of live bar views independent of the number of tabs.
    func activate() {
        refreshIfNeeded()
        if !isActive {
            isActive = true
        }
        guard let window, let others = window.tabbedWindows else { return }
        for other in others where other !== window {
            (other as? TabBarWindow)?.tabBar.deactivate()
        }
    }

    private func deactivate() {
        needsRefresh = true
        if !tabs.isEmpty {
            tabs = []
        }
        if isActive {
            isActive = false
        }
    }

    /// Whether this window is the tab shown for its group. Background tabs still report
    /// `isVisible`, so ask the group.
    private var isSelectedTab: Bool {
        guard let window, window.isVisible else { return false }
        guard window.tabbedWindows != nil, let tabGroup = window.tabGroup else { return true }
        return tabGroup.selectedWindow === window
    }

    private func tabDidChange(_ sender: NSWindow?) {
        needsRefresh = true

        // Background tabs catch up in `activate()`. The selected tab rebuilds once per
        // run loop turn no matter how many changes arrive.
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.isSelectedTab {
                self.refreshIfNeeded()
            }
        }
    }

    private func refresh() {
        guard let window else { return }
        needsRefresh = false
        observeTabGroup(window.tabGroup)

        let newTabs = (window.tabbedWindows ?? [window]).map(Tab.init)
        if newTabs != tabs {
            tabs = newTabs
        }
    }

    /// Tab group membership and order changes don't go through any property we override,
    /// so observe the group itself.
    private func observeTabGroup(_ tabGroup: NSWindowTabGroup?) {
        guard observedTabGroup !== tabGroup || (tabGroup != nil && tabGroupObservation == nil) else { return }
        tabGroupObservation?.invalidate()
        tabGroupObservation = nil
        observedTabGroup = tabGroup

        guard let tabGroup else { return }
        tabGroupObservation = tabGroup.observe(\.windows) { [weak self] _, _ in
            // Never rebind inside the callback; tabDidChange defers the refresh.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.tabDidChange(window)
            }
        }
    }

    // MARK: Visibility

    func setVisible(_ isVisible: Bool) {
        Self.lastIsVisible = isVisible
        guard let window else { return }

        // The tab group shares one visibility so switching tabs doesn't resize the
        // terminal.
        for other in window.tabbedWindows ?? [window] {
            guard let model = (other as? TabBarWindow)?.tabBar else { continue }
            if model.layout.isVisible != isVisible {
                model.layout.isVisible = isVisible
            }
        }
    }

    func toggleVisibility() {
        withAnimation(.snappy(duration: 0.2)) {
            setVisible(!layout.isVisible)
        }
    }

    // MARK: Actions

    private func tabWindow(_ id: ObjectIdentifier) -> NSWindow? {
        guard let window else { return nil }
        return (window.tabbedWindows ?? [window]).first { ObjectIdentifier($0) == id }
    }

    private func controller(_ id: ObjectIdentifier) -> TerminalController? {
        tabWindow(id)?.windowController as? TerminalController
    }

    func select(_ id: ObjectIdentifier) {
        guard let target = tabWindow(id), target !== window else { return }
        target.makeKeyAndOrderFront(nil)
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func closeTab(_ id: ObjectIdentifier) {
        controller(id)?.closeTab(nil)
    }

    func closeOtherTabs(_ id: ObjectIdentifier) {
        controller(id)?.closeOtherTabs(nil)
    }

    func closeTabsOnTheRight(_ id: ObjectIdentifier) {
        controller(id)?.closeTabsOnTheRight(nil)
    }

    func hasTabsOnTheRight(_ id: ObjectIdentifier) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return index < tabs.count - 1
    }

    func moveTabToNewWindow(_ id: ObjectIdentifier) {
        tabWindow(id)?.moveTabToNewWindow(nil)
    }

    func renameTab(_ id: ObjectIdentifier) {
        controller(id)?.promptTabTitle()
    }

    func setColor(_ color: TerminalTabColor, for id: ObjectIdentifier) {
        (tabWindow(id) as? TerminalWindow)?.tabColor = color
    }

    /// Moves a tab by `offset` positions within the tab group.
    func moveTab(_ id: ObjectIdentifier, by offset: Int) {
        guard offset != 0,
              let window,
              let tabGroup = window.tabGroup,
              let selected = tabGroup.selectedWindow else { return }
        let windows = tabGroup.windows
        guard let from = windows.firstIndex(where: { ObjectIdentifier($0) == id }) else { return }
        let to = min(max(from + offset, 0), windows.count - 1)
        guard to != from else { return }
        let moving = windows[from]

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        if moving === selected {
            // Removing the selected window from its group makes AppKit briefly show a
            // neighbor, so move the tabs we pass over to the other side instead.
            if to < from {
                for passed in windows[to..<from].reversed() {
                    tabGroup.removeWindow(passed)
                    moving.addTabbedWindowSafely(passed, ordered: .above)
                }
            } else {
                for passed in windows[(from + 1)...to] {
                    tabGroup.removeWindow(passed)
                    moving.addTabbedWindowSafely(passed, ordered: .below)
                }
            }
        } else {
            tabGroup.removeWindow(moving)
            windows[to].addTabbedWindowSafely(moving, ordered: to < from ? .below : .above)
        }

        NSAnimationContext.endGrouping()

        // Shortcut labels follow the tab position.
        (window.windowController as? TerminalController)?.relabelTabs()
    }
}

// MARK: - Views

/// Places a tab bar on one edge of the terminal content.
///
/// A plain stack rather than a split view: the bar has a fixed size, so it needs no divider
/// or column state, and the same container works for a bar on any edge.
@available(macOS 26.0, *)
struct TabBarContainer<Bar: View, Content: View>: View {
    let edge: Edge
    @ObservedObject private var layout: TabBarModel.Layout
    private let bar: Bar
    private let content: Content

    init(
        edge: Edge,
        layout: TabBarModel.Layout,
        @ViewBuilder bar: () -> Bar,
        @ViewBuilder content: () -> Content
    ) {
        self.edge = edge
        self.layout = layout
        self.bar = bar()
        self.content = content()
    }

    var body: some View {
        let stack = switch edge {
        case .leading, .trailing: AnyLayout(HStackLayout(spacing: 0))
        case .top, .bottom: AnyLayout(VStackLayout(spacing: 0))
        }

        // The content keeps its position in the view tree whether or not the bar is
        // shown, so toggling the bar never recreates the terminal.
        stack {
            if layout.isVisible, edge == .leading || edge == .top {
                placedBar
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if layout.isVisible, edge == .trailing || edge == .bottom {
                placedBar
            }
        }
        .clipped()
    }

    private var placedBar: some View {
        bar.transition(.move(edge: edge))
    }
}

/// The tab bar for the leading or trailing edge: a fixed width column of rows.
@available(macOS 26.0, *)
struct VerticalTabBar: View {
    @ObservedObject var model: TabBarModel

    @State private var draggingID: ObjectIdentifier?
    @State private var dragOffset: CGFloat = 0

    /// Fixed so every tab in a group has the same terminal size; a per-window user
    /// width would resize (and reflow) the terminal on every tab switch.
    static let width: CGFloat = 220
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 4

    var body: some View {
        Group {
            if model.isActive {
                bar
            } else {
                Color.clear
            }
        }
        .frame(width: Self.width)
    }

    private var bar: some View {
        ScrollView {
            LazyVStack(spacing: Self.rowSpacing) {
                ForEach(model.tabs) { tab in
                    row(tab)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: model.newTab) {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .help("New Tab")
        }
        .onAppear(perform: model.refreshIfNeeded)
    }

    private func row(_ tab: TabBarModel.Tab) -> some View {
        let isDragging = draggingID == tab.id
        return VerticalTabRow(
            tab: tab,
            isSelected: tab.id == model.selectedID,
            onClose: { model.closeTab(tab.id) }
        )
        .equatable()
        .offset(y: isDragging ? dragOffset : 0)
        .zIndex(isDragging ? 1 : 0)
        .onTapGesture { model.select(tab.id) }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    draggingID = tab.id
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    let steps = Int((value.translation.height / (Self.rowHeight + Self.rowSpacing)).rounded())
                    draggingID = nil
                    dragOffset = 0
                    model.moveTab(tab.id, by: steps)
                }
        )
        .contextMenu { contextMenu(tab) }
        .accessibilityAction { model.select(tab.id) }
    }

    @ViewBuilder
    private func contextMenu(_ tab: TabBarModel.Tab) -> some View {
        Button("Close Tab", systemImage: "xmark") { model.closeTab(tab.id) }
        Button("Close Other Tabs", systemImage: "xmark") { model.closeOtherTabs(tab.id) }
            .disabled(model.tabs.count < 2)
        Button("Close Tabs to the Right", systemImage: "xmark") { model.closeTabsOnTheRight(tab.id) }
            .disabled(!model.hasTabsOnTheRight(tab.id))
        Divider()
        Button("Move Tab to New Window", systemImage: "macwindow") { model.moveTabToNewWindow(tab.id) }
            .disabled(model.tabs.count < 2)
        Button("Rename Tab...", systemImage: "pencil.line") { model.renameTab(tab.id) }
        Picker("Tab Color", selection: Binding(
            get: { tab.color },
            set: { model.setColor($0, for: tab.id) }
        )) {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Text(color.localizedName).tag(color)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct VerticalTabRow: View, Equatable {
    let tab: TabBarModel.Tab
    let isSelected: Bool
    let onClose: () -> Void

    /// `onClose` is left out so a title change only re-renders its own row; it always
    /// closes `tab.id`.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tab == rhs.tab && lhs.isSelected == rhs.isSelected
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(tab.color.displayColor.map { Color(nsColor: $0) } ?? Color.secondary)
                .frame(width: 16)

            Text(tab.title.isEmpty ? " " : tab.title)
                .font(tab.font.map { Font($0) } ?? .body)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if tab.isZoomed {
                Image("ResetZoom")
                    .foregroundStyle(.secondary)
                    .help("Split Zoomed")
            }

            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: VerticalTabBar.rowHeight)
        .background {
            if isSelected {
                // A raised row: the window background in light mode, a lighter
                // fill in dark mode where the background would read as sunken.
                Group {
                    if colorScheme == .dark {
                        shape.fill(Color.primary.opacity(0.16))
                    } else {
                        shape.fill(.background)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            } else {
                shape.fill(Color.primary.opacity(isHovering ? 0.10 : 0.05))
            }
        }
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .help(tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovering {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab")
            .accessibilityLabel("Close Tab")
        } else if let shortcut = tab.shortcut {
            Text(shortcut)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}
