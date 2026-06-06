import SwiftUI

extension Ghostty {
    /// A transient "find indicator" that pops over the currently selected
    /// search match — like `NSTextView.showFindIndicator(for:)` — showing the
    /// matched enlarged in the selected-highlight color, then fades.
    ///
    /// Getting selected texts from render is expensive, only enlarge the background for now
    struct SurfaceSearchFindIndicator: View {
        @ObservedObject var searchState: Ghostty.OSSurfaceView.SearchState
        let background: Color

        @State private var scale: CGSize = CGSize(width: 1, height: 1)
        @State private var opacity: CGFloat = 0

        var regions: [CGRect] {
            searchState.selected?.regions ?? []
        }

        var body: some View {
            ZStack(alignment: .topLeading) {
                // We should use contour in the future for multiple rects,
                // but I want to keep it simple for now
                ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                    background
                        .frame(width: region.width, height: region.height)
                        .scaleEffect(scale, anchor: .center)
                        .opacity(opacity)
                        .position(x: region.midX, y: region.midY)
                }
            }
            .compositingGroup()
            .shadow(radius: 5)
            .allowsHitTesting(false)
            .onReceive(searchState.$selected) { newValue in
                guard let newValue, newValue.reason == .navigation else {
                    return
                }
                regionsDidChange(newValue.regions)
            }
        }

        private func regionsDidChange(_ newValue: [CGRect]) {
            if newValue.isEmpty {
                fadeOut()
            } else {
                bam(rows: newValue.count)
            }
        }

        private func bam(rows: Int) {
            // If there'r multiple rows, we only scale it horizontally
            // to avoid overlap vertically
            scale = CGSize(width: 2, height: rows > 1 ? 1 : 2)
            opacity = 1

            fadeOut()
        }

        private func fadeOut() {
            withAnimation(.interactiveSpring) {
                scale = CGSize(width: 1, height: 1)
                opacity = 0
            }
        }
    }
}
