import AppKit
import CryptoKit
import SwiftUI
import Vision
import WidgetKit
@testable import CodexBarIOS

// Only staged widget source copies read these keys. The production readonly
// WidgetKit keys cannot be injected into an ImageRenderer environment.
private struct FixtureWidgetFamilyKey: EnvironmentKey {
    static let defaultValue = WidgetFamily.systemSmall
}

private struct FixtureShowsContainerBackgroundKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var fixtureWidgetFamily: WidgetFamily {
        get { self[FixtureWidgetFamilyKey.self] }
        set { self[FixtureWidgetFamilyKey.self] = newValue }
    }

    var fixtureShowsContainerBackground: Bool {
        get { self[FixtureShowsContainerBackgroundKey.self] }
        set { self[FixtureShowsContainerBackgroundKey.self] = newValue }
    }
}

private enum FixtureAppearance: String, CaseIterable {
    case fullColorBackground = "full-color-background"
    case fullColorRemoved = "full-color-removed"
    case accented
    case vibrant

    var renderingMode: WidgetRenderingMode {
        switch self {
        case .fullColorBackground, .fullColorRemoved: .fullColor
        case .accented: .accented
        case .vibrant: .vibrant
        }
    }

    var showsBackground: Bool { self == .fullColorBackground }

    var caption: String {
        switch self {
        case .fullColorBackground: "Full color, background present"
        case .fullColorRemoved: "Full color, background removed"
        case .accented: "Accented, native alpha-mask fixture"
        case .vibrant: "Vibrant, native grayscale source"
        }
    }
}

private struct FixtureFamily {
    let name: String
    let family: WidgetFamily
    let size: CGSize

    static let all: [Self] = [
        .init(name: "small", family: .systemSmall, size: .init(width: 170, height: 170)),
        .init(name: "medium", family: .systemMedium, size: .init(width: 364, height: 170)),
        .init(name: "large", family: .systemLarge, size: .init(width: 364, height: 382)),
        .init(name: "extra-large", family: .systemExtraLarge, size: .init(width: 720, height: 344)),
        .init(name: "inline", family: .accessoryInline, size: .init(width: 240, height: 34)),
        .init(name: "circular", family: .accessoryCircular, size: .init(width: 76, height: 76)),
        .init(name: "rectangular", family: .accessoryRectangular, size: .init(width: 180, height: 76)),
    ]
}

private struct CaptureRecord: Encodable {
    let filename: String
    let sha256: String
    let width: Int
    let height: Int
}

private struct CheckRecord: Encodable {
    let name: String
    let passed: Bool
    let detail: String
}

private struct EvidenceSummary: Encodable {
    let fixtureDescription: String
    let captures: [CaptureRecord]
    let checks: [CheckRecord]
}

private struct NativeCapture {
    let image: CGImage
    let label: String
}

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct WidgetRenderingProbe {
    private static let scale = 2.0
    private static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let outputIndex = arguments.firstIndex(of: "--output"), arguments.indices.contains(outputIndex + 1) else {
            throw ProbeFailure(description: "Missing --output directory")
        }
        let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
        let recordOnly = arguments.contains("--record-only")
        let baseline = arguments.firstIndex(of: "--compare-baseline").map {
            URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true)
        }
        var captures: [CaptureRecord] = []
        var checks: [CheckRecord] = []
        var smallCaptures: [NativeCapture] = []

        for appearance in FixtureAppearance.allCases {
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                var familyCaptures: [NativeCapture] = []
                for family in FixtureFamily.all {
                    let view = rootFixture(family: family, appearance: appearance, dark: dark)
                    let image = try render(view)
                    let name = "\(appearance.rawValue)-\(theme)-\(family.name).png"
                    captures.append(try save(image, name: name, output: output))
                    let label = "\(family.name), \(Int(family.size.width)) x \(Int(family.size.height)) pt"
                    familyCaptures.append(NativeCapture(image: image, label: label))
                    if family.family == .systemSmall {
                        smallCaptures.append(NativeCapture(image: image, label: "\(appearance.caption), \(theme)"))
                    }
                }
                let sheet = try contactSheet(
                    familyCaptures,
                    title: "\(appearance.caption) / \(theme)",
                    subtitle: "Injected OS state, native SwiftUI and macOS font metrics. Synthetic data."
                )
                captures.append(try save(sheet, name: "sheet-\(appearance.rawValue)-\(theme).png", output: output))
                try checkTile(
                    appearance: appearance, dark: dark, output: output,
                    baseline: baseline, captures: &captures, checks: &checks
                )
                try captureExtras(
                    appearance: appearance, dark: dark, output: output,
                    captures: &captures, checks: &checks
                )
            }
        }

        let smallSheet = try contactSheet(
            smallCaptures,
            title: "Small widget across rendering states",
            subtitle: "Accented uses an alpha mask. Vibrant shows source grayscale, not system material."
        )
        captures.append(try save(smallSheet, name: "small-rendering-matrix.png", output: output))
        if let baseline {
            try saveComparison(baseline: baseline, output: output, captures: &captures)
        }
        let summary = EvidenceSummary(
            fixtureDescription: "Actual widget SwiftUI views; injected OS state; alpha-mask accented fixture; grayscale vibrant source; macOS metrics.",
            captures: captures,
            checks: checks
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: output.appendingPathComponent("summary.json"))
        let failures = checks.filter { !$0.passed }
        for check in checks {
            print("\(check.passed ? "PASS" : "FAIL"): \(check.name): \(check.detail)")
        }
        print("Native widget evidence: \(captures.count) PNGs, \(checks.count - failures.count)/\(checks.count) checks passed. \(output.path)")
        if !failures.isEmpty && !recordOnly { exit(EXIT_FAILURE) }
    }

    @MainActor
    private static func rootFixture(
        family: FixtureFamily, appearance: FixtureAppearance, dark: Bool,
        snapshot suppliedSnapshot: CodexBarWidgetSnapshot? = nil,
        configuration: CodexBarWidgetConfigurationIntent? = nil
    ) -> some View {
        let entry = CodexBarWidgetEntry(
            date: fixedDate,
            snapshot: suppliedSnapshot ?? snapshot,
            configuration: configuration ?? CodexBarWidgetConfigurationIntent(),
            isPreview: true
        )
        let systemFamily = family.name != "inline" && family.name != "circular" && family.name != "rectangular"
        let source = CodexBarWidgetView(entry: entry)
            .environment(\.fixtureWidgetFamily, family.family)
            .environment(\.fixtureShowsContainerBackground, appearance.showsBackground)
            .environment(\.widgetRenderingMode, appearance.renderingMode)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
            .padding(systemFamily ? 16 : 3)
            .frame(width: family.size.width, height: family.size.height)
        return presentation(source, appearance: appearance, dark: dark)
            .clipShape(RoundedRectangle(cornerRadius: systemFamily ? 24 : 8))
    }

    @MainActor
    @ViewBuilder
    private static func presentation<Content: View>(
        _ content: Content, appearance: FixtureAppearance, dark: Bool
    ) -> some View {
        ZStack {
            if appearance == .fullColorBackground {
                (dark ? Color(white: 0.09) : .white)
            } else {
                // A synthetic wallpaper plate makes the injected background-removal state visible.
                LinearGradient(
                    colors: dark
                        ? [Color(red: 0.08, green: 0.13, blue: 0.22), Color(red: 0.22, green: 0.12, blue: 0.28)]
                        : [Color(red: 0.36, green: 0.52, blue: 0.67), Color(red: 0.52, green: 0.39, blue: 0.65)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            if appearance == .accented {
                // Apple documents that accented rendering preserves source alpha.
                // This fixture intentionally does not claim to be the OS compositor.
                content.hidden().overlay { Color.white.mask(content) }
            } else {
                content
            }
        }
        .fixedSize()
    }

    @MainActor
    private static func checkTile(
        appearance: FixtureAppearance, dark: Bool, output: URL, baseline: URL?,
        captures: inout [CaptureRecord], checks: inout [CheckRecord]
    ) throws {
        let theme = dark ? "dark" : "light"
        let source = ProviderWidgetTile(
            renderedTile: .init(tile: snapshot.results[0].summaryTile, displayMode: .compactPercent),
            style: .small
        )
        .environment(\.fixtureShowsContainerBackground, appearance.showsBackground)
        .environment(\.widgetRenderingMode, appearance.renderingMode)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.dynamicTypeSize, .large)
        .frame(width: 170)
        let raw = try render(source)
        let rawName = "tile-source-\(appearance.rawValue)-\(theme).png"
        let record = try save(raw, name: rawName, output: output)
        captures.append(record)
        let coverage = try alphaCoverage(raw)
        if appearance != .fullColorBackground {
            checks.append(CheckRecord(
                name: "\(appearance.rawValue)/\(theme) removes opaque inner panel",
                passed: coverage < 0.50,
                detail: String(format: "%.1f%% pixels contain visible ink; limit 50%%", coverage * 100)
            ))
        }
        if appearance == .fullColorRemoved {
            // Whole-tile coverage misses small opaque badges. Inspect the leading
            // 22 pt header area inside the tile's 10 pt padding separately.
            guard let header = raw.cropping(to: CGRect(x: 10 * scale, y: 10 * scale, width: 22 * scale, height: 22 * scale)) else {
                throw ProbeFailure(description: "Cannot inspect the provider header")
            }
            captures.append(try save(header, name: "header-source-\(appearance.rawValue)-\(theme).png", output: output))
            let headerCoverage = try alphaCoverage(header)
            checks.append(CheckRecord(
                name: "\(appearance.rawValue)/\(theme) removes opaque provider badge",
                passed: headerCoverage < 0.50,
                detail: String(format: "%.1f%% header pixels contain visible ink; limit 50%%", headerCoverage * 100)
            ))
        }
        checks.append(CheckRecord(
            name: "\(appearance.rawValue)/\(theme) retains foreground content",
            passed: coverage > 0.025,
            detail: String(format: "%.1f%% pixels contain visible ink; minimum 2.5%%", coverage * 100)
        ))
        let visible = try render(presentation(source, appearance: appearance, dark: dark))
        captures.append(try save(visible, name: "tile-visible-\(appearance.rawValue)-\(theme).png", output: output))
        let recognized = try recognizedText(visible)
        checks.append(CheckRecord(
            name: "\(appearance.rawValue)/\(theme) exposes provider and usage glyphs",
            passed: recognized.localizedCaseInsensitiveContains("Codex") && recognized.contains("48"),
            detail: "Native Vision OCR: \(recognized)"
        ))
        if appearance == .fullColorBackground, let baseline {
            let previous = baseline.appendingPathComponent(rawName)
            let previousDigest = digest(try Data(contentsOf: previous))
            checks.append(CheckRecord(
                name: "full-color/\(theme) preserves baseline tile pixels",
                passed: previousDigest == record.sha256,
                detail: previousDigest == record.sha256 ? "PNG SHA-256 identical" : "PNG SHA-256 differs"
            ))
        }
    }

    private static var snapshot: CodexBarWidgetSnapshot {
        let definitions: [(String, String, Double, MetricVisualizationStyle)] = [
            ("codex", "Codex", 0.48, .linearBar),
            ("claude", "Claude", 0.79, .segmentedBar),
            ("copilot", "Copilot", 0.91, .circularRing),
            ("gemini", "Gemini", 0.34, .semicircularDial),
            ("cursor", "Cursor", 0.62, .largeNumeric),
            ("openRouter", "OpenRouter", 0.27, .linearBar),
        ]
        let providers = definitions.enumerated().map { index, definition in
            let severity: CodexBarWidgetSeverity = index == 1 ? .warning : (index == 2 ? .critical : .normal)
            let bar = CodexBarWidgetUsageBarSnapshot(
                id: "synthetic.\(definition.0).usage",
                label: index == 0 ? "5-hour limit" : "Weekly limit",
                fractionUsed: definition.2,
                usageText: "\(Int((definition.2 * 100).rounded()))%",
                resetDescription: "Resets in 3h",
                severity: severity,
                projectedFraction: min(definition.2 + 0.18, 1),
                projectedSeverity: severity,
                visualizationStyle: definition.3,
                allowsGauge: true
            )
            return CodexBarWidgetProviderSnapshot(
                accountID: "widget-evidence.\(definition.0)",
                providerID: definition.0,
                title: definition.1,
                subtitle: "Synthetic account",
                bars: [bar], creditsRemaining: nil, fetchedAt: fixedDate, severity: severity
            )
        }
        return CodexBarWidgetSnapshot(generatedAt: fixedDate, results: providers)
    }

    @MainActor
    private static func captureExtras(
        appearance: FixtureAppearance, dark: Bool, output: URL,
        captures: inout [CaptureRecord], checks: inout [CheckRecord]
    ) throws {
        let theme = dark ? "dark" : "light"
        let usage = snapshot.results[0].summaryTile
        let numeric = sampleTile(visualization: .largeNumeric, allowsGauge: false)
        let balance = CodexBarWidgetTile(
            id: "synthetic.balance", accountID: "widget-evidence.balance",
            providerID: "openRouter", providerTitle: "OpenRouter", title: "Credit balance",
            subtitle: "Synthetic account", bar: nil, creditsRemaining: nil,
            monetaryMetric: .init(
                kind: "credits", label: "Credit balance", minorUnits: 1234,
                currencyCode: "USD", decimalPlaces: 2, detail: "Synthetic balance"
            ),
            barFetchedAt: nil, monetaryValueFetchedAt: fixedDate,
            fetchedAt: fixedDate, severity: .normal
        )
        let variants: [(String, CodexBarWidgetTile, CodexBarWidgetTileDisplayMode)] = [
            ("Compact percent", usage, .compactPercent),
            ("Full bar with projection", usage, .fullBar),
            ("Balance only, monetary data", balance, .balanceOnly),
            ("Balance only, missing data", usage, .balanceOnly),
            ("Urgent status, warning", snapshot.results[1].summaryTile, .urgentStatus),
            ("Urgent status, critical", snapshot.results[2].summaryTile, .urgentStatus),
            ("Circular ring, standard tile", sampleTile(visualization: .circularRing), .automatic),
            ("Semicircular dial, standard tile", sampleTile(visualization: .semicircularDial), .automatic),
            ("Segmented bar", sampleTile(visualization: .segmentedBar), .automatic),
            ("Large numeric", sampleTile(visualization: .largeNumeric), .automatic),
            ("Non-gauge numeric", numeric, .automatic),
            ("Unavailable provider", .unavailable(choice: .init(id: "missing", title: "Saved provider", subtitle: "")), .urgentStatus),
        ]
        var visibleCaptures: [NativeCapture] = []
        var coverages: [Double] = []
        for (_, tile, mode) in variants {
            let source = ProviderWidgetTile(renderedTile: .init(tile: tile, displayMode: mode), style: .standard)
                .environment(\.fixtureShowsContainerBackground, appearance.showsBackground)
                .environment(\.widgetRenderingMode, appearance.renderingMode)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.dynamicTypeSize, .large)
                .frame(width: 210)
            coverages.append(try alphaCoverage(render(source)))
        }
        // Paired medium widgets exercise the production root's inherited vibrant
        // foreground and the standard tile layout, including actual ring/dial paths.
        for start in stride(from: 0, to: variants.count, by: 2) {
            let pair = Array(variants[start..<min(start + 2, variants.count)])
            let configuration = CodexBarWidgetConfigurationIntent()
            configuration.layout = .twoTiles
            configuration.tile1DisplayMode = pair[0].2
            configuration.tile2DisplayMode = pair[1].2
            let pairSnapshot = CodexBarWidgetSnapshot(
                generatedAt: fixedDate,
                results: pair.enumerated().map { provider(for: $0.element.1, index: $0.offset) }
            )
            let image = try render(rootFixture(
                family: FixtureFamily.all[1], appearance: appearance, dark: dark,
                snapshot: pairSnapshot, configuration: configuration
            ))
            visibleCaptures.append(NativeCapture(image: image, label: "\(pair[0].0) / \(pair[1].0)"))
        }
        let circular = rootFixture(
            family: FixtureFamily.all[5], appearance: appearance, dark: dark,
            snapshot: .init(generatedAt: fixedDate, results: [provider(for: numeric, index: 0)])
        )
        visibleCaptures.append(NativeCapture(
            image: try render(circular),
            label: "Circular accessory, non-gauge"
        ))
        let empty = rootFixture(
            family: FixtureFamily.all[0], appearance: appearance, dark: dark, snapshot: .empty
        )
        visibleCaptures.append(NativeCapture(
            image: try render(empty),
            label: "Empty system widget"
        ))
        let image = try contactSheet(
            visibleCaptures,
            title: "Configured modes and alternate content / \(appearance.rawValue) / \(theme)",
            subtitle: "\(appearance.caption). Native fixture; synthetic data; not the OS compositor.",
            columns: 2, cellWidth: 400, cellHeight: 240
        )
        captures.append(try save(image, name: "extras-\(appearance.rawValue)-\(theme).png", output: output))
        let maximum = coverages.max() ?? 0
        let minimum = coverages.min() ?? 0
        checks.append(CheckRecord(
            name: "\(appearance.rawValue)/\(theme) retains all 12 alternate tile layouts",
            passed: minimum > 0.025,
            detail: String(format: "Minimum visible ink %.1f%%", minimum * 100)
        ))
        if appearance != .fullColorBackground {
            checks.append(CheckRecord(
                name: "\(appearance.rawValue)/\(theme) removes panels from all 12 alternate tile layouts",
                passed: maximum < 0.50,
                detail: String(format: "Maximum visible ink %.1f%%; limit 50%%", maximum * 100)
            ))
        }
    }

    private static func sampleTile(
        visualization: MetricVisualizationStyle, allowsGauge: Bool = true
    ) -> CodexBarWidgetTile {
        let bar = CodexBarWidgetUsageBarSnapshot(
            id: "synthetic.\(visualization.rawValue)", label: allowsGauge ? "5-hour limit" : "Request count",
            fractionUsed: 0.48, usageText: allowsGauge ? "48%" : "128",
            resetDescription: "Resets in 3h", severity: .normal,
            projectedFraction: 0.66, projectedSeverity: .normal,
            visualizationStyle: visualization, allowsGauge: allowsGauge
        )
        return CodexBarWidgetTile(
            id: "synthetic.\(visualization.rawValue)", accountID: "widget-evidence.sample",
            providerID: "codex", providerTitle: "Codex", title: bar.label, subtitle: "Synthetic account",
            bar: bar, creditsRemaining: nil, monetaryMetric: nil,
            barFetchedAt: fixedDate, monetaryValueFetchedAt: nil, fetchedAt: fixedDate, severity: .normal
        )
    }

    private static func provider(for tile: CodexBarWidgetTile, index: Int) -> CodexBarWidgetProviderSnapshot {
        CodexBarWidgetProviderSnapshot(
            accountID: "widget-evidence.extra.\(index)", providerID: tile.providerID,
            title: tile.providerTitle, subtitle: tile.subtitle,
            bars: tile.bar.map { [$0] } ?? [], creditsRemaining: tile.creditsRemaining,
            monetaryMetrics: tile.monetaryMetric.map { [$0] } ?? [],
            fetchedAt: fixedDate, severity: tile.severity
        )
    }

    @MainActor
    private static func render<Content: View>(_ content: Content) throws -> CGImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            throw ProbeFailure(description: "Native SwiftUI rendering produced no image")
        }
        return image
    }

    private static func save(_ image: CGImage, name: String, output: URL) throws -> CaptureRecord {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw ProbeFailure(description: "Cannot encode \(name)")
        }
        try png.write(to: output.appendingPathComponent(name))
        return CaptureRecord(filename: name, sha256: digest(png), width: image.width, height: image.height)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func alphaCoverage(_ image: CGImage) throws -> Double {
        let byteCount = image.width * image.height * 4
        var pixels = [UInt8](repeating: 0, count: byteCount)
        guard let context = CGContext(
            data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ProbeFailure(description: "Cannot inspect native tile pixels")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let visible = stride(from: 3, to: byteCount, by: 4).filter { pixels[$0] > 20 }.count
        return Double(visible) / Double(image.width * image.height)
    }

    private static func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
    }

    @MainActor
    private static func contactSheet(
        _ captures: [NativeCapture], title: String, subtitle: String,
        columns: Int = 2, cellWidth: Double = 400, cellHeight: Double = 410
    ) throws -> CGImage {
        let rows = (captures.count + columns - 1) / columns
        let width = Double(columns) * cellWidth + Double(columns - 1) * 16 + 48
        let height = Double(rows) * (cellHeight + 16) + 104
        guard let context = CGContext(
            data: nil, width: Int(width * scale), height: Int(height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ProbeFailure(description: "Cannot allocate native contact sheet")
        }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor(white: 0.94, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let previousGraphics = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previousGraphics }
        drawText(title, size: 21, bold: true, in: CGRect(x: 24, y: height - 56, width: width - 48, height: 32))
        drawText(subtitle, size: 12, in: CGRect(x: 24, y: height - 82, width: width - 48, height: 24))
        for (index, capture) in captures.enumerated() {
            let originX = 24 + Double(index % columns) * (cellWidth + 16)
            let top = height - 104 - Double(index / columns) * (cellHeight + 16)
            drawText(
                capture.label, size: 13, bold: true,
                in: CGRect(x: originX, y: top - 32, width: cellWidth, height: 32)
            )
            let imageWidth = Double(capture.image.width) / scale
            let imageHeight = Double(capture.image.height) / scale
            let fit = min(cellWidth / imageWidth, (cellHeight - 42) / imageHeight)
            context.draw(capture.image, in: CGRect(
                x: originX, y: top - 42 - imageHeight * fit,
                width: imageWidth * fit, height: imageHeight * fit
            ))
        }
        guard let image = context.makeImage() else {
            throw ProbeFailure(description: "Cannot finish native contact sheet")
        }
        return image
    }

    @MainActor
    private static func drawText(_ text: String, size: Double, bold: Bool = false, in rectangle: CGRect) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: NSColor.black,
        ]).draw(in: rectangle)
    }

    @MainActor
    private static func saveComparison(baseline: URL, output: URL, captures: inout [CaptureRecord]) throws {
        var comparison: [NativeCapture] = []
        for appearance in FixtureAppearance.allCases {
            let filename = "tile-visible-\(appearance.rawValue)-dark.png"
            for (directory, label) in [(baseline, "Before"), (output, "After")] {
                let data = try Data(contentsOf: directory.appendingPathComponent(filename))
                guard let representation = NSBitmapImageRep(data: data), let image = representation.cgImage else {
                    throw ProbeFailure(description: "Cannot load comparison image \(filename)")
                }
                comparison.append(NativeCapture(image: image, label: "\(label): \(appearance.caption)"))
            }
        }
        let image = try contactSheet(
            comparison,
            title: "Standalone widget tile before and after",
            subtitle: "Accented alpha model; vibrant source without root foreground. See family sheets for the complete root."
        )
        captures.append(try save(image, name: "before-after-tiles.png", output: output))
    }
}
