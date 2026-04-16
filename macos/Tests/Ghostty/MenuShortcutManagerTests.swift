import AppKit
import Foundation
import Testing
import SwiftUI
@testable import Ghostty

struct MenuShortcutManagerTests {
    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/779", id: 779))
    func unbindShouldDiscardDefault() async throws {
        let config = try TemporaryConfig("keybind = super+d=unbind")

        let item = NSMenuItem(title: "Split Right", action: #selector(BaseTerminalController.splitRight(_:)), keyEquivalent: "d")
        item.keyEquivalentModifierMask = .command
        let menu = NSMenu()
        menu.addItem(item)

        let manager = await Ghostty.MenuShortcutManager()
        await manager.saveInitialState(for: menu)

        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)

        try config.reload("")

        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11396", id: 11396))
    func overrideDefault() async throws {
        let config = try TemporaryConfig("keybind=super+h=goto_split:left")

        let hideItem = NSMenuItem(title: "Hide Ghostty", action: "hide:", keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = .command

        let goToLeftItem = NSMenuItem(title: "Select Split Left", action: "splitMoveFocusLeft:", keyEquivalent: "")
        let menu = NSMenu()
        [hideItem, goToLeftItem].forEach(menu.addItem(_:))

        let manager = await Ghostty.MenuShortcutManager()
        await manager.saveInitialState(for: menu)

        await manager.reset()

        await manager.syncMenuShortcut(config, action: nil, menuItem: hideItem)
        await manager.syncMenuShortcut(config, action: "goto_split:left", menuItem: goToLeftItem)

        #expect(hideItem.keyEquivalent.isEmpty)
        #expect(hideItem.keyEquivalentModifierMask.isEmpty)

        #expect(goToLeftItem.keyEquivalent == "h")
        #expect(goToLeftItem.keyEquivalentModifierMask == .command)

        // Even triggers not in the menu should also override defaults

        try config.reload("keybind = cmd+h=toggle_readonly")

        await manager.reset()

        await manager.syncMenuShortcut(config, action: nil, menuItem: hideItem)
        await manager.syncMenuShortcut(config, action: "goto_split:left", menuItem: goToLeftItem)

        #expect(hideItem.keyEquivalent.isEmpty)
        #expect(hideItem.keyEquivalentModifierMask.isEmpty)

        let goToLeftShortcut = try #require(Ghostty.MenuShortcutManager.MenuShortcutKey(goToLeftItem)?.swiftUIShortcut)
        #expect(goToLeftShortcut.key.character == SwiftUI.KeyEquivalent.leftArrow.character)
        #expect(goToLeftShortcut.modifiers == [.command, .option])
    }

    // MARK: - Menu observer (dynamic items)

    @Test
    func dynamicItemConflictCleared() async throws {
        // A dynamically inserted item whose shortcut conflicts with a Ghostty binding
        // should have its shortcut cleared by the observer.
        let config = try TemporaryConfig("keybind=super+t=new_tab")

        let newTabItem = NSMenuItem(title: "New Tab", action: "newTab:", keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(newTabItem)

        let manager = await Ghostty.MenuShortcutManager()
        await manager.saveInitialState(for: menu)

        await manager.saveInitialState(for: menu)
        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_tab", menuItem: newTabItem)
        await manager.checkItems(in: menu)

        // Now simulate the system inserting "Window" with Cmd+T
        // which conflicts with Cmd+T already owned by Ghostty's "new_tab".
        let submenu = NSMenu()
        let windowItem = NSMenuItem(title: "Window", action: "window:", keyEquivalent: "t")
        windowItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(windowItem)

        let showAllTabs = NSMenuItem(title: "Show All Tabs", action: "showAllTabs:", keyEquivalent: "\\")
        showAllTabs.keyEquivalentModifierMask = [.command, .shift]

        // Insert into the submenu — this posts NSMenu.didAddItemNotification
        submenu.addItem(showAllTabs)

        let submenuItem = NSMenuItem(title: "Submenu", action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        menu.addItem(submenuItem)

        // Give the run loop a tick so the Combine sink fires
        await Task.yield()

        #expect(windowItem.keyEquivalent.isEmpty)
        #expect(windowItem.keyEquivalentModifierMask.isEmpty)

        // Non conflicts should be found
        #expect(showAllTabs.keyEquivalent == "\\")
        #expect(showAllTabs.keyEquivalentModifierMask == [.command, .shift])

        try config.reload(#"keybind = cmd+shift+\=new_tab"#)
        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_tab", menuItem: newTabItem)

        await manager.checkItems(in: menu)

        // Conflicts with ghostty action
        #expect(showAllTabs.keyEquivalent.isEmpty)
        #expect(showAllTabs.keyEquivalentModifierMask.isEmpty)
    }

    @Test
    func dynamicItemIgnoredForUnrelatedMenu() async throws {
        // Items added to a menu that is NOT a descendant of the tracked menu
        // should be ignored by the observer.

        let newTabItem = NSMenuItem(title: "New Tab", action: "newTab:", keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(newTabItem)

        let trackedMenu = NSMenu()
        let unrelatedMenu = NSMenu()

        let manager = await Ghostty.MenuShortcutManager()
        await manager.saveInitialState(for: trackedMenu)

        await manager.reset()
        await manager.checkItems(in: trackedMenu)

        let item = NSMenuItem(title: "Show All Tabs", action: "showAllTabs:", keyEquivalent: "t")
        item.keyEquivalentModifierMask = [.command, .shift]
        unrelatedMenu.addItem(item)

        await Task.yield()

        // Should NOT be cleared — the item is in an unrelated menu
        #expect(item.keyEquivalent == "t")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }

    @Test
    func dynamicItemAddedDirectlyToTrackedMenu() async throws {
        // Items added directly to the tracked (top-level) menu itself should
        // also be processed — tests the `updatedMenu == menu` path.
        let config = try TemporaryConfig("keybind=super+t=new_tab")

        let newTabItem = NSMenuItem(title: "New Tab", action: "newTab:", keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(newTabItem)

        let manager = await Ghostty.MenuShortcutManager()
        await manager.saveInitialState(for: menu)

        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_tab", menuItem: newTabItem)
        await manager.checkItems(in: menu)

        let windowItem = NSMenuItem(title: "Window", action: "window:", keyEquivalent: "t")
        windowItem.keyEquivalentModifierMask = [.command]
        menu.addItem(windowItem)

        await Task.yield()

        #expect(windowItem.keyEquivalent.isEmpty)
        #expect(windowItem.keyEquivalentModifierMask.isEmpty)
    }
}
