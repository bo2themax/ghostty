//
//  GhosttyConfigTests.swift
//  Ghostty
//
//  Created by luca on 24.09.2025.
//

import Foundation
@testable import GhosttyKit
import Testing

@Suite(.serialized)
struct GhosttyConfigTests {
    init() throws {
        try #require(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS, "ghostty_init failed")
    }

    @Test
    func defaultValuesMatchZigImplementation() async throws {
        let defaultProvider = DefaultConfigProvider(testConfigName: "test_config")

        let background = try #require(defaultProvider.getColor("background"))
        #expect(background.r == 0x12)
        #expect(background.g == 0x3A)
        #expect(background.b == 0xBC)

        let foreground = try #require(defaultProvider.getColor("foreground"))
        #expect(foreground.r == 0xAB)
        #expect(foreground.g == 0xC1)
        #expect(foreground.b == 0x23)

        defaultProvider.setValue("background", value: "")
        #expect(defaultProvider.getColor("background") == nil)
    }
}

/// True if we appear to be running in Xcode.
func isRunningInXcode() -> Bool {
    if let _ = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
        return true
    }

    return false
}
