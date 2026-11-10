import AppKit
import SwiftUI
@testable import CodexBarIOS

// The shell runner compiles the actual widget tile on macOS with only its
// system-background color adapted. This measures intrinsic layout, not iOS pixels.
@main
struct WidgetResetLayoutProbe {
    @MainActor
    static func main() throws {
        var count = 0
        for width in [128.0, 148.0, 168.0] {
            for visualization in MetricVisualizationStyle.allCases {
                for caption in ["Resets 3d 12h (Wed 10:26 AM GMT+2)", "Projected limit hit Wed 10:26 AM GMT+2", ""] {
                    let view = tile(visualization: visualization, caption: caption)
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .environment(\.dynamicTypeSize, .large)
                        .frame(width: width)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.cgImage else {
                        print("FAIL: Widget tile rendering failed")
                        exit(EXIT_FAILURE)
                    }
                    let height = Double(image.height) / renderer.scale
                    // A 158pt medium widget with 16pt margins leaves 126pt.
                    // Reserve 8pt spacing and 13pt for the Updated footer.
                    guard height <= 105 else {
                        print("FAIL: \(visualization.rawValue) at width \(width) needs \(height)pt; caption=\(caption)")
                        exit(EXIT_FAILURE)
                    }
                    count += 1
                }
            }
        }
        print("Widget reset layout: \(count) rendered fixtures fit the 105pt tile budget.")
    }

    @MainActor
    private static func tile(visualization: MetricVisualizationStyle, caption: String) -> some View {
        let bar = CodexBarWidgetUsageBarSnapshot(
            id: "fixture", label: "Other Models weekly", fractionUsed: 0.2, usageText: "20%",
            resetDescription: caption.isEmpty ? nil : caption,
            severity: .normal, visualizationStyle: visualization, allowsGauge: true
        )
        let tile = CodexBarWidgetTile(
            id: "fixture", accountID: "fixture", providerID: "claude", providerTitle: "Claude",
            title: bar.label, subtitle: "Fixture", bar: bar, creditsRemaining: nil, monetaryMetric: nil,
            barFetchedAt: nil, monetaryValueFetchedAt: nil, fetchedAt: nil, severity: .normal
        )
        return ProviderWidgetTile(renderedTile: .init(tile: tile, displayMode: .automatic), style: .standard)
    }
}
