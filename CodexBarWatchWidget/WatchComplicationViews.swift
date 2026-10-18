import SwiftUI
import WidgetKit

struct WatchComplicationView: View {
    let entry: WatchComplicationEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        let sample = entry.sample
        return Group {
            switch family {
            case .accessoryInline:
                WatchInlineComplication(sample: sample)
            case .accessoryCircular:
                WatchCircularComplication(sample: sample)
            case .accessoryRectangular:
                WatchRectangularComplication(sample: sample)
            case .accessoryCorner:
                WatchCornerComplication(sample: sample)
            default:
                WatchRectangularComplication(sample: sample)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sample.accessibilityLabel)
    }
}

private struct WatchInlineComplication: View {
    let sample: WatchComplicationSample

    var body: some View {
        Label {
            Text(inlineText)
        } icon: {
            Image(systemName: statusSymbol)
        }
    }

    private var inlineText: String {
        switch sample.availability {
        case .locked:
            return "CodexBar Pro • Unlock on iPhone"
        case .empty:
            return "CodexBar • Open iPhone app"
        case .unavailable:
            return "CodexBar • Selection unavailable"
        case .value:
            let state = sample.stateLabel.map { " • \($0)" } ?? ""
            return "\(sample.providerName) \(sample.metricLabel) \(sample.exactValue)\(state)"
        }
    }

    private var statusSymbol: String {
        switch sample.availability {
        case .locked:
            return "lock.fill"
        case .empty:
            return "iphone"
        case .unavailable:
            return "questionmark.circle"
        case .value:
            if sample.isStale {
                return "clock.badge.exclamationmark"
            }
            switch sample.severity {
            case .normal:
                return "gauge.with.dots.needle.50percent"
            case .warning, .critical:
                return "exclamationmark.triangle.fill"
            }
        }
    }
}

private struct WatchCircularComplication: View {
    let sample: WatchComplicationSample

    var body: some View {
        if sample.availability == .locked {
            VStack(spacing: 2) {
                Image(systemName: "lock.fill")
                Text("Pro")
                    .font(.caption2.bold())
            }
        } else if sample.supportsGauge {
            Gauge(value: sample.clampedUsedFraction) {
                Image(systemName: sample.isStale ? "clock.badge.exclamationmark" : "gauge")
            } currentValueLabel: {
                Text(sample.exactValue)
                    .font(.system(size: 10, weight: .semibold))
                    .minimumScaleFactor(0.55)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .widgetAccentable()
        } else if sample.availability == .value {
            VStack(spacing: 1) {
                Image(systemName: sample.isStale ? "clock.badge.exclamationmark" : "number")
                Text(sample.exactValue)
                    .font(.system(size: 10, weight: .semibold))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .widgetAccentable()
        } else {
            VStack(spacing: 1) {
                Image(systemName: sample.availability == .empty ? "iphone" : "questionmark")
                Text("--")
                    .font(.caption2.bold())
            }
        }
    }

    private var tint: Color {
        switch sample.severity {
        case .normal:
            return sample.isStale ? .secondary : .accentColor
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}

private struct WatchRectangularComplication: View {
    let sample: WatchComplicationSample

    var body: some View {
        if sample.availability == .locked {
            VStack(alignment: .leading, spacing: 2) {
                Label("CodexBar Pro", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                Text("Unlock on iPhone")
                    .font(.caption2)
            }
        } else if sample.availability == .value {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(sample.accountContextLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(sample.exactValue)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                }
                Text(sample.metricLabel)
                    .font(.caption2)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if let stateLabel = sample.stateLabel {
                        Label(stateLabel, systemImage: statusSymbol)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Text(sample.freshnessText)
                    }
                    Spacer(minLength: 2)
                    if let resetText = sample.resetText {
                        Text(resetText)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("CodexBar")
                    .font(.caption.weight(.semibold))
                Label(
                    sample.availability == .empty ? "Open iPhone app" : "Selection unavailable",
                    systemImage: sample.availability == .empty ? "iphone" : "questionmark.circle"
                )
                .font(.caption2)
            }
        }
    }

    private var statusSymbol: String {
        sample.isStale ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill"
    }
}

private struct WatchCornerComplication: View {
    let sample: WatchComplicationSample

    @ViewBuilder
    var body: some View {
        if sample.availability == .locked {
            Image(systemName: "lock.fill")
                .widgetLabel {
                    Text("Unlock with Pro on iPhone")
                }
        } else if sample.supportsGauge {
            valueText
                .widgetLabel {
                    Gauge(value: sample.clampedUsedFraction) {
                        Text(sample.cornerContextLabel)
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(tint)
                    .widgetAccentable()
                }
        } else {
            valueText
                .foregroundStyle(tint)
                .widgetAccentable()
                .widgetLabel {
                    Text(sample.cornerContextLabel)
                        .foregroundStyle(tint)
                        .widgetAccentable()
                }
        }
    }

    private var valueText: some View {
        Text(sample.availability == .value ? sample.exactValue : "--")
            .font(.caption.monospacedDigit().weight(.semibold))
    }

    private var tint: Color {
        if sample.availability != .value {
            return .secondary
        }
        switch sample.severity {
        case .normal:
            return sample.isStale ? .secondary : .accentColor
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}
