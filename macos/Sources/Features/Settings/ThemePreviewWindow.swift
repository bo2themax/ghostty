import Cocoa
import SwiftUI
import GhosttyKit

class ThemePreviewWindow: NSWindow {
    init(ghosttyApp: Ghostty.App) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        self.title = "Theme Preview"
        self.center()
        self.isReleasedWhenClosed = false
        
        // Create the SwiftUI content view
        let contentView = NSHostingView(rootView: ThemePreviewContentView(ghosttyApp: ghosttyApp))
        self.contentView = contentView
    }
}

struct ThemePreviewContentView: View {
    @StateObject private var ghosttyApp: Ghostty.App
    @State private var selectedTheme = "Default"
    @State private var availableThemes = ["Default", "One Dark", "Solarized Light", "Dracula"]

    init(ghosttyApp: Ghostty.App) {
        _ghosttyApp = .init(wrappedValue: ghosttyApp)
    }

    var body: some View {
        Form {
            // Header with theme selector
            HStack {
                Text("Theme Preview")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Picker("Theme:", selection: $selectedTheme) {
                    ForEach(availableThemes, id: \.self) { theme in
                        Text(theme).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 150)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Theme preview area
            if ghosttyApp.app != nil {
                    Ghostty.ThemePreviewSurface(
                        themeName: selectedTheme,
                        themePath: themePathForSelectedTheme()
                    )
                    .environmentObject(ghosttyApp)
            } else {
                VStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Initializing Ghostty...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .formStyle(.grouped)
    }
    
    private func themePathForSelectedTheme() -> String? {
        // Return the path to the theme file if it's not the default theme
        switch selectedTheme {
        case "Default":
            return nil
        case "One Dark":
            return expandPath("~/.config/ghostty/themes/one-dark.conf")
        case "Solarized Light":
            return expandPath("~/.config/ghostty/themes/solarized-light.conf")
        case "Dracula":
            return expandPath("~/.config/ghostty/themes/dracula.conf")
        default:
            return nil
        }
    }
    
    private func expandPath(_ path: String) -> String {
        return NSString(string: path).expandingTildeInPath
    }
}
