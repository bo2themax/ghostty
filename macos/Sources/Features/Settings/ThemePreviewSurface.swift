import Combine
import GhosttyKit
import SwiftUI

extension Ghostty {
    /// A SwiftUI view that displays a theme preview using Ghostty's actual terminal renderer.
    /// This creates a real terminal surface that shows the theme in action, reusing the same
    /// preview logic as the CLI but rendering with the actual terminal engine.
    struct ThemePreviewSurface: View {
        let themeName: String
        let themePath: String?

        @EnvironmentObject private var ghostty: Ghostty.App
        @State private var surfaceView: SurfaceView?
        @State private var isLoading: Bool = true
        @State private var errorMessage: String?
        @State private var previewSize: CGSize?
        @State private var maskHeight: CGFloat?
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                // Theme name header
                Text(themeName)
                    .font(.headline)
                    .padding(.horizontal)

                if let themePath = themePath {
                    Text(themePath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                ScrollView {
                    if let surfaceView = surfaceView {
                        GeometryReader { geo in
                            SurfaceRepresentable(view: surfaceView, size: geo.size)
                                .disabled(true) // Disable interaction for preview
                                .cornerRadius(8)
                        }
                        .frame(height: previewSize?.height ?? 100)
                        .frame(maxWidth: .greatestFiniteMagnitude)
                        .mask(alignment: .top) {
                            Color.red
                                .frame(height: maskHeight ?? 0)
                        }
                    }
                }
                .frame(height: 200)
                .overlay {
                    if isLoading {
                        ProgressView("Loading theme preview...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage = errorMessage {
                        Text("Error: \(errorMessage)")
                            .foregroundColor(.red)
                            .padding()
                    }
                }
            }
            .onReceive(titleChangePublisher, perform: { _ in
                guard let surface = surfaceView?.surface else {
                    return
                }
                let size = ghostty_surface_size(surface)
                let rows = ghostty_surface_total_content_rows(surface) // add
                let scaleFactorX = Double(ghostty_surface_scale_factor_x(surface))
                let scaleFactorY = Double(ghostty_surface_scale_factor_y(surface))
                let ptSize = CGSize(width: Double(size.columns) * Double(size.cell_width_px) / scaleFactorX, height: Double(rows + 1) * Double(size.cell_height_px) / scaleFactorY) // add one more row so that contents are not clipped
                previewSize = ptSize
                maskHeight = ptSize.height - 2 * Double(size.cell_height_px) / scaleFactorY // one for cursor, one for additional space
                isLoading = rows < 10
            })
            .task {
                await createPreviewSurface()
            }
        }

        var titleChangePublisher: AnyPublisher<String, Never> {
            surfaceView?.$title.removeDuplicates().eraseToAnyPublisher() ?? Just("").eraseToAnyPublisher()
        }

        @MainActor
        private func createPreviewSurface() async {
            isLoading = true
            errorMessage = nil

            guard let app = ghostty.app else {
                errorMessage = "No Ghostty app available"
                isLoading = false
                return
            }

            do {
                // Create a new surface configured for theme preview
                var config = Ghostty.SurfaceConfiguration()
                config.waitAfterCommand = true
                config.command = "bash"
                config.workingDirectory = Bundle.main.resourceURL?.appendingPathComponent("ghostty/settings-resources").path(percentEncoded: false)
                let command = "clear && cat theme-preview.txt"
                config.waitAfterCommand = true
                config.initialInput = """
                \(command)

                """
                let surface = SurfaceView(app, baseConfig: config)
                // Use the internal C API to run the theme preview
                await runThemePreview(surface: surface)

                surfaceView = surface

            } catch {
                errorMessage = "Failed to create theme preview: \(error.localizedDescription)"
                isLoading = false
            }
        }

        @MainActor
        private func runThemePreview(surface: SurfaceView) async {
            var themes = ghostty_surface_theme_list_s()
            let result = ghostty_surface_get_themes(surface.surface, &themes)

            let buffer = UnsafeBufferPointer(start: themes.themes, count: themes.len)

            print("========", result, (buffer.map { (location: $0.location, path: String(cString: $0.path), theme: String(cString: $0.theme)) })[0])
        }
    }
}

#if DEBUG
struct ThemePreviewSurface_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            Ghostty.ThemePreviewSurface(themeName: "Default", themePath: nil)
                .previewDisplayName("Default Theme")

            Ghostty.ThemePreviewSurface(themeName: "One Dark", themePath: "/path/to/one-dark.conf")
                .previewDisplayName("One Dark Theme")
        }
        .frame(width: 600, height: 400)
        .environmentObject(Ghostty.App())
    }
}
#endif
