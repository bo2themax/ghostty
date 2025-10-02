# GitHub Copilot Instructions for Ghostty

Ghostty is a fast, native, cross-platform terminal emulator written in Zig with multi-platform UI support.

## Architecture Overview

Ghostty uses a modular architecture with clear separation of concerns:

- **Core Terminal Logic**: `src/terminal/` - Terminal emulation, VT sequences, screen management
- **Application Runtime (apprt)**: `src/apprt/` - Cross-platform UI abstraction (GTK, macOS Cocoa, browser, embedded)
- **Rendering**: `src/renderer/` - Backend-agnostic rendering (Metal, OpenGL, software)
- **Configuration**: `src/config/` - Comprehensive config system with conditional states
- **Platform Integration**: `src/os/` - OS-specific functionality and abstractions

The entry point is determined by `build_config.exe_entrypoint` and routes through `main.zig` to appropriate main files (`main_ghostty.zig`, `main_wasm.zig`, etc.).

## Critical Build and Development Commands

**Never use `xcodebuild` for macOS builds** - always use `zig build`:

```bash
zig build                    # Debug build (default)
zig build run                # Run Ghostty directly
zig build test               # Run all tests
zig build test -Dtest-filter="test_name"  # Run specific tests
zig fmt .                    # Format Zig code
prettier -w .                # Format non-Zig files
zig build update-translations # Update i18n strings
zig build dist               # Create source tarball
zig build distcheck          # Validate source tarball
```

For memory debugging: `zig build run-valgrind` and `zig build test-valgrind`

## Zig-Specific Patterns

### Error Handling
- Uses Zig's error union types extensively: `!T` for fallible operations
- Error sets are defined per module (e.g., `CreateError`, `ConfigError`)
- `try` for error propagation, `catch` for handling
- `errdefer` for cleanup on error paths
- Custom error conversion functions in wrapper modules

### Memory Management
- Uses arena allocators extensively for config and temporary data
- `GlobalState` manages the main GPA (GeneralPurposeAllocator)
- Prefer stack allocation for small buffers, arena for batched allocations
- `defer` and `errdefer` for RAII-style resource cleanup

### Comptime Configuration
- `build_config.zig` provides comptime constants for feature flags
- Cross-compilation handled through `builtin.target`
- App runtime selected at compile time via `build_config.app_runtime`

## Cross-Platform Abstractions

### Application Runtime (apprt)
The `apprt` system provides platform abstraction:
- `apprt.runtime` is selected at compile time
- `Surface` represents a terminal window/view
- Events flow through platform-specific implementations to core logic
- GTK for Linux/FreeBSD, native Cocoa for macOS, browser for WASM

### Platform-Specific Code
- `src/os/` contains OS abstractions
- `pkg/macos/` for macOS-specific APIs
- Use `internal_os` import for cross-platform OS functionality
- Check `builtin.target.os.tag` for platform-specific branches

## Configuration System

- Configuration is hierarchical with defaults, user config, and conditional overrides
- `Config.zig` is the main config structure
- `ConditionalState` tracks environment conditions for conditional config
- Config errors accumulate in `ErrorList` rather than failing immediately
- String parsing supports Zig string literal escape sequences

## Testing Patterns

### Unit Tests
- Zig tests embedded in source files with `test` blocks
- Use `std.testing` for assertions
- Test files often create temporary allocator: `const alloc = testing.allocator;`

### Acceptance Tests
- Visual testing via `test/` directory with screenshot comparison
- Runs terminal emulators in windowing environments
- Use `./test/run-host.sh --exec <terminal> --case <test>` for single tests

## Key Conventions

### File Naming
- Zig files use PascalCase for main types: `Config.zig`, `Screen.zig`, `Surface.zig`  
- Package files use lowercase: `config.zig`, `apprt.zig`
- Platform-specific files grouped in subdirectories

### Logging
- Scoped loggers: `const log = std.log.scoped(.module_name);`
- Log levels configured in `std_options.log_level`
- Platform-specific log backends (stderr, macOS os_log, WASM console)

### Resource Management
- Resources loaded through `GhosttyResources` build step
- Embedded files accessible via build-generated constants
- i18n strings handled through `GhosttyI18n` when enabled

## Integration Points

- **libghostty**: C API for embedding (`include/ghostty.h`)
- **WASM**: Browser integration with JS interop
- **IPC**: Inter-process communication for advanced features
- **Shell Integration**: Scripts in `src/shell-integration/`

## Development Workflow

1. Always build debug versions during development (`zig build` without optimize flags)
2. Use `zig build run` for quick testing
3. Run relevant tests frequently: `zig build test -Dtest-filter="your_area"`
4. Check formatting before commits: `zig fmt .` and `prettier -w .`
5. For GUI changes, test on multiple platforms via apprt implementations
