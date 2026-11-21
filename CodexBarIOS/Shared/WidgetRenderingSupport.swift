import Foundation
import SwiftUI

public enum CodexBarCurrencyText {
    public static func format(
        _ value: Double,
        currencyCode: String = "USD",
        decimalPlaces: Int = 2
    ) -> String {
        value.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(min(max(decimalPlaces, 0), 6)))
        )
    }
}

public enum CodexBarSeverityPalette {
    public static let normal = Color.green
    public static let warning = Color.orange
    public static let critical = Color.red
    public static let projectedNormal = Color(red: 0x86 / 255.0, green: 0xEF / 255.0, blue: 0xAC / 255.0)
    public static let projectedWarning = Color(red: 0xFA / 255.0, green: 0xCC / 255.0, blue: 0x15 / 255.0)
    public static let projectedCritical = Color(red: 0xF8 / 255.0, green: 0x71 / 255.0, blue: 0x71 / 255.0)
}

public extension CodexBarWidgetSeverity {
    var tint: Color {
        switch self {
        case .normal:
            CodexBarSeverityPalette.normal
        case .warning:
            CodexBarSeverityPalette.warning
        case .critical:
            CodexBarSeverityPalette.critical
        }
    }

    var projectedTint: Color {
        switch self {
        case .normal:
            CodexBarSeverityPalette.projectedNormal
        case .warning:
            CodexBarSeverityPalette.projectedWarning
        case .critical:
            CodexBarSeverityPalette.projectedCritical
        }
    }
}

public struct CodexBarProviderLogo: View {
    public let providerID: String
    public let size: CGFloat
    public let background: Color
    public let border: Color
    public let fallbackSystemName: String
    public let imagePadding: CGFloat

    public init(
        providerID: String,
        size: CGFloat = 22,
        background: Color = .white,
        border: Color = .gray.opacity(0.35),
        fallbackSystemName: String = "square.grid.2x2",
        imagePadding: CGFloat = 3
    ) {
        self.providerID = providerID
        self.size = size
        self.background = background
        self.border = border
        self.fallbackSystemName = fallbackSystemName
        self.imagePadding = imagePadding
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(background)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(border, lineWidth: 0.5)
                }

            if let assetName = Self.assetName(for: providerID) {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(imagePadding)
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    public static func assetName(for providerID: String) -> String? {
        switch providerID {
        case "codex":
            "CodexLogo"
        case "copilot":
            "CopilotLogo"
        case "claude":
            "ClaudeLogo"
        case "openRouter":
            "OpenRouterLogo"
        case "openCodeZen":
            "OpenCodeZenLogo"
        case "moonshot":
            "MoonshotLogo"
        case "cursor":
            "CursorLogo"
        default:
            nil
        }
    }
}

public struct CodexBarUsageProgressBar: View {
    public let fractionUsed: Double
    public let projectedFraction: Double?
    public let severity: CodexBarWidgetSeverity
    public let projectedSeverity: CodexBarWidgetSeverity?
    public let fillColor: Color?
    public let projectedFillColor: Color?
    public let height: CGFloat
    public let trackColor: Color
    public let accessibilityText: String?

    public init(
        fractionUsed: Double,
        projectedFraction: Double? = nil,
        severity: CodexBarWidgetSeverity,
        projectedSeverity: CodexBarWidgetSeverity? = nil,
        fillColor: Color? = nil,
        projectedFillColor: Color? = nil,
        height: CGFloat = 6,
        trackColor: Color = Color.primary.opacity(0.12),
        accessibilityText: String? = nil
    ) {
        self.fractionUsed = fractionUsed
        self.projectedFraction = projectedFraction
        self.severity = severity
        self.projectedSeverity = projectedSeverity
        self.fillColor = fillColor
        self.projectedFillColor = projectedFillColor
        self.height = height
        self.trackColor = trackColor
        self.accessibilityText = accessibilityText
    }

    public var body: some View {
        Group {
            if let accessibilityText {
                progressBar.accessibilityLabel(accessibilityText)
            } else {
                progressBar.accessibilityHidden(true)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let actualWidth = proxy.size.width * clamped(fractionUsed)
            let projectedWidth = proxy.size.width * clamped(projectedFraction ?? 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)

                if projectedWidth > actualWidth {
                    Capsule()
                        .fill(
                            projectedFillColor
                                ?? (projectedSeverity ?? severity).projectedTint.opacity(0.55)
                        )
                        .frame(width: projectedWidth)
                }

                Capsule()
                    .fill(fillColor ?? severity.tint)
                    .frame(width: actualWidth)
            }
        }
        .frame(height: height)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
