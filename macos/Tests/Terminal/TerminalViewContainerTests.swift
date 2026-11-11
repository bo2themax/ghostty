//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }
}

class MockConfig: Ghostty.Config {
    internal init(backgroundBlur: Ghostty.Config.BackgroundBlur, backgroundColor: Color, backgroundOpacity: Double) {
        self._backgroundBlur = backgroundBlur
        self._backgroundColor = backgroundColor
        self._backgroundOpacity = backgroundOpacity
        super.init(config: nil)
    }

    var _backgroundBlur: Ghostty.Config.BackgroundBlur
    var _backgroundColor: Color
    var _backgroundOpacity: Double

    override var backgroundBlur: Ghostty.Config.BackgroundBlur {
        _backgroundBlur
    }

    override var backgroundColor: Color {
        _backgroundColor
    }

    override var backgroundOpacity: Double {
        _backgroundOpacity
    }
}

struct TerminalViewContainerTests {
    @Test func glassAvailability() async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }

    @MainActor
    @Test(arguments: [
        (NSRectEdge.minX, NSRect(x: 0, y: 0, width: 50, height: 300)),
        (NSRectEdge.maxX, NSRect(x: 350, y: 0, width: 50, height: 300)),
        (NSRectEdge.minY, NSRect(x: 0, y: 0, width: 400, height: 50)),
        (NSRectEdge.maxY, NSRect(x: 0, y: 250, width: 400, height: 50)),
    ])
    func edgeAccessoryLayout(edge: NSRectEdge, expected: NSRect) async throws {
        let container = TerminalViewContainer {
            Color.clear.frame(idealWidth: 200, idealHeight: 100)
        }
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.layoutSubtreeIfNeeded()
        let sizeWithoutAccessory = container.intrinsicContentSize

        let accessory = NSView()
        container.setEdgeAccessory(.init(view: accessory, edge: edge, thickness: 50))
        container.layoutSubtreeIfNeeded()
        #expect(accessory.superview === container)
        #expect(accessory.frame == expected)

        // The accessory must not take space away from the terminal.
        let isHorizontal = edge == .minX || edge == .maxX
        #expect(container.intrinsicContentSize == NSSize(
            width: sizeWithoutAccessory.width + (isHorizontal ? 50 : 0),
            height: sizeWithoutAccessory.height + (isHorizontal ? 0 : 50)))

        container.setEdgeAccessory(nil)
        container.layoutSubtreeIfNeeded()
        #expect(accessory.superview == nil)
        #expect(container.intrinsicContentSize == sizeWithoutAccessory)
    }
}
