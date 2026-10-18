import SwiftUI
import WidgetKit

struct AccessoryInlineWidget: View {
    let tiles: [CodexBarWidgetTile]

    var body: some View {
        if let tile = tiles.first {
            Text("\(tile.providerTitle) \(tile.summaryText)")
        } else {
            Text("CodexBar")
        }
    }
}

struct AccessoryCircularWidget: View {
    private var appearance = WidgetRenderingAppearance()

    let tile: CodexBarWidgetTile?

    var body: some View {
        if let tile, !tile.allowsUsageGauge {
            VStack(spacing: 1) {
                Image(systemName: "number")
                Text(tile.summaryText)
                    .font(.system(size: 10, weight: .semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .foregroundStyle(appearance.tint(for: tile.severity))
            .widgetAccentable()
        } else {
            Gauge(value: tile?.bar?.effectiveFractionUsed ?? 0) {
                Image(systemName: "gauge.with.dots.needle.50percent")
            } currentValueLabel: {
                Text(tile.map(\.summaryText) ?? "--")
                    .font(.system(size: 10, weight: .semibold))
                    .minimumScaleFactor(0.6)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tile.map { appearance.tint(for: $0.severity) } ?? (appearance.isFullColor ? .secondary : appearance.primaryForeground))
        }
    }
}

struct AccessoryRectangularWidget: View {
    let tile: CodexBarWidgetTile?

    var body: some View {
        if let tile {
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.providerTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(tile.summaryText)
                    .font(.caption2)
                    .lineLimit(1)
            }
        } else {
            Text("Open CodexBar")
        }
    }
}

struct EmptyWidgetState: View {
    private var appearance = WidgetRenderingAppearance()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2)
            Text("CodexBar")
                .font(.headline)
            Text("Open the app to refresh usage.")
                .font(.caption)
                .foregroundStyle(appearance.secondaryForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
    }
}
