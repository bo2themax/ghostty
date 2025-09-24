//
//  DefaultConfigProvider.swift
//  GhosttyKit
//
//  Created by luca on 24.09.2025.
//

@testable import GhosttyKit

class DefaultConfigProvider {
    private var config: ghostty_config_t? {
        didSet {
            // Free the old value whenever we change
            guard let old = oldValue else { return }
            ghostty_config_free(old)
        }
    }

    init(testConfigName: String) {
        guard
            let cfg = ghostty_config_new(),
            let path = Bundle.module.path(forResource: testConfigName, ofType: nil, inDirectory: "testdata")
        else {
            fatalError("Failed to create ghostty config")
        }
        ghostty_config_load_file(cfg, path)
        if !isRunningInXcode() {
            ghostty_config_load_cli_args(cfg)
        }

        ghostty_config_load_recursive_files(cfg)

        // Finalize to make defaults available
        ghostty_config_finalize(cfg)
        self.config = cfg
    }

    deinit {
        self.config = nil
    }

    // Set any config field by key-value
    func setValue(_ key: String, value: String) {
        guard let config = config else { return }
        ghostty_config_set(config, key, value)
    }

    func export() -> String {
        guard let config = config else { return "" }
        return String(cString: ghostty_config_export_string(config).ptr)
    }

    /// Get a boolean value from the config
    func getBool(_ key: String) -> Bool {
        guard let config = config else { return false }
        var value = false
        let success = ghostty_config_get(config, &value, key, UInt(key.count))
        guard success else {
            fatalError("Failed to get config value for key: \(key)")
        }
        return value
    }

    /// Get a UInt32 value from the config (for colors)
    func getUInt32(_ key: String) -> UInt32 {
        guard let config = config else { return 0 }
        var value: UInt32 = 0
        let success = ghostty_config_get(config, &value, key, UInt(key.count))
        guard success else {
            fatalError("Failed to get config value for key: \(key)")
        }
        return value
    }

    /// Get a Float value from the config
    func getFloat(_ key: String) -> Float {
        guard let config = config else { return 0.0 }
        var value: Float = 0
        let success = ghostty_config_get(config, &value, key, UInt(key.count))
        guard success else {
            fatalError("Failed to get config value for key: \(key)")
        }
        return value
    }

    /// Get a UInt8 value from the config
    func getUInt8(_ key: String) -> UInt8 {
        guard let config = config else { return 0 }
        var value: UInt = 0
        let success = ghostty_config_get(config, &value, key, UInt(key.count))
        guard success else {
            fatalError("Failed to get config value for key: \(key)")
        }
        return UInt8(value)
    }

    /// Get a UInt8 value from the config
    func getColor(_ key: String) -> ghostty_config_color_s? {
        guard let config = config else { return nil }
        var value: ghostty_config_color_s?
        let success = ghostty_config_get(config, &value, key, UInt(key.count))
        guard success else {
            fatalError("Failed to get config value for key: \(key)")
        }
        return value
    }
}
