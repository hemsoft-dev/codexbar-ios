import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Run with the selected Xcode toolchain. This command never builds or launches the app.
struct Asset: Codable {
    let id: String
    let device: String
    let width: Int
    let height: Int
    let scene: String
    let appearance: String
    let entitlementFixture: String
    let caption: String
    let subtitle: String
    let rawPath: String
    let outputPath: String
}

struct CaptionManifest: Decodable {
    let schemaVersion: Int
    let release: String
    let assets: [Asset]
}

struct Device: Codable {
    let name: String
    let simulatorUdid: String
    let runtime: String
}

struct Capture: Codable {
    let sourceCommit: String
    let rawSha256: String
    let scene: String
    let appearance: String
    let entitlementFixture: String
    let capturedAt: String
}

struct Provenance: Decodable {
    let sourceCommit: String
    let build: String
    let xcode: String
    let devices: [String: Device]
    let captures: [String: Capture]
}

struct Rectangle: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    func appKitRect(canvasHeight: Int) -> CGRect {
        CGRect(x: x, y: Double(canvasHeight) - y - height, width: width, height: height)
    }
}

struct Geometry: Codable {
    let sourceRect: Rectangle
    let screenshotRect: Rectangle
    let captionRect: Rectangle
    let subtitleRect: Rectangle
    let scale: Double
    let cropped: Bool
}

struct ComposedAsset: Encodable {
    let asset: Asset
    let capture: Capture
    let device: Device
    let rawSha256: String
    let outputSha256: String
    let geometry: Geometry
    let pngColorType: String
    let inspectionStatus: String
}

struct CompositionReport: Encodable {
    let schemaVersion = 1
    let renderer = "AppKit / CoreGraphics / sRGB / RGB8"
    let sourceCommit: String
    let build: String
    let xcode: String
    let macos: String
    let compositionToolSha256: String
    let captionManifestSha256: String
    let captureProvenanceSha256: String
    let assets: [ComposedAsset]
}

struct CompositionError: Error, CustomStringConvertible {
    let description: String
}

struct Options {
    let manifest: URL
    let root: URL
    let provenance: URL
    let report: URL

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        let allowed = ["--manifest", "--root", "--provenance", "--report"]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard allowed.contains(key), values[key] == nil, index + 1 < arguments.count else {
                throw CompositionError(description: "Usage: compose.swift --manifest PATH --root PATH --provenance PATH --report PATH")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let manifestPath = values["--manifest"], let rootPath = values["--root"],
              let provenancePath = values["--provenance"], let reportPath = values["--report"] else {
            throw CompositionError(description: "All four path arguments are required.")
        }
        manifest = URL(fileURLWithPath: manifestPath)
        root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        provenance = URL(fileURLWithPath: provenancePath)
        report = URL(fileURLWithPath: reportPath)
    }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CompositionError(description: message) }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func containedURL(_ path: String, root: URL) throws -> URL {
    try require(!path.hasPrefix("/"), "Asset paths must be relative to the artifact root.")
    let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
    try require(url.path.hasPrefix(root.path + "/"), "Asset path escapes artifact root: \(path)")
    return url
}

func validate(_ asset: Asset, capture: Capture, provenance: Provenance) throws {
    let sizes = ["iphone": [1320, 2868], "ipad": [2064, 2752], "watch": [422, 514]]
    try require(sizes[asset.device] == [asset.width, asset.height], "Unexpected native dimensions: \(asset.id)")
    try require(asset.rawPath == "release-assets/2.0.0/raw/\(asset.id).png", "Unexpected raw path: \(asset.id)")
    try require(asset.outputPath == "release-assets/2.0.0/screenshots/\(asset.id).png", "Unexpected output path: \(asset.id)")
    let free = asset.scene == "free-overview"
    let fixture = asset.device == "watch" ? "synthetic-pro-watch-layout" : (free ? "synthetic-free" : "synthetic-pro")
    try require(asset.caption == (free ? "Free plan" : "CodexBar Pro"), "Missing plan disclosure: \(asset.id)")
    try require(asset.entitlementFixture == fixture, "Wrong entitlement fixture: \(asset.id)")
    try require(capture.sourceCommit == provenance.sourceCommit, "Capture source differs: \(asset.id)")
    try require(capture.scene == asset.scene && capture.appearance == asset.appearance, "Capture scene differs: \(asset.id)")
    try require(capture.entitlementFixture == asset.entitlementFixture, "Capture entitlement differs: \(asset.id)")
    try require(!capture.capturedAt.isEmpty, "Capture timestamp is missing: \(asset.id)")
}

struct Layout {
    let inset: CGFloat
    let captionTop: CGFloat
    let captionHeight: CGFloat
    let captionSize: CGFloat
    let subtitleTop: CGFloat
    let subtitleHeight: CGFloat
    let subtitleSize: CGFloat
    let screenshotTop: CGFloat
    let bottom: CGFloat

    init(device: String) {
        switch device {
        case "watch":
            (inset, captionTop, captionHeight, captionSize) = (20, 20, 32, 21)
            (subtitleTop, subtitleHeight, subtitleSize, screenshotTop, bottom) = (64, 36, 26, 120, 20)
        case "ipad":
            (inset, captionTop, captionHeight, captionSize) = (96, 70, 86, 56)
            (subtitleTop, subtitleHeight, subtitleSize, screenshotTop, bottom) = (194, 160, 104, 424, 80)
        default:
            (inset, captionTop, captionHeight, captionSize) = (72, 80, 72, 44)
            (subtitleTop, subtitleHeight, subtitleSize, screenshotTop, bottom) = (190, 184, 82, 440, 72)
        }
    }
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func textAttributes(size: CGFloat, weight: NSFont.Weight, foreground: NSColor) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    return [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: foreground,
        .paragraphStyle: paragraph,
    ]
}

func drawText(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, foreground: NSColor) throws {
    let attributes = textAttributes(size: size, weight: weight, foreground: foreground)
    let bounds = (text as NSString).boundingRect(
        with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes,
    )
    try require(bounds.height <= rect.height, "Caption does not fit: \(text)")
    (text as NSString).draw(
        with: CGRect(x: rect.minX, y: rect.midY - bounds.height / 2, width: rect.width, height: bounds.height),
        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes,
    )
}

func render(_ asset: Asset, rawData: Data) throws -> (Data, Geometry) {
    guard let source = NSBitmapImageRep(data: rawData), let sourceImage = source.cgImage else {
        throw CompositionError(description: "Cannot decode PNG: \(asset.rawPath)")
    }
    try require(source.pixelsWide == asset.width && source.pixelsHigh == asset.height, "Raw image size differs: \(asset.id)")
    try require(!source.hasAlpha, "Raw PNG must be opaque RGB: \(asset.id)")
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
        data: nil, width: asset.width, height: asset.height, bitsPerComponent: 8,
        bytesPerRow: asset.width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
    ) else {
        throw CompositionError(description: "Cannot allocate RGB canvas: \(asset.id)")
    }
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high

    let dark = asset.appearance == "dark"
    let background = dark ? color(16, 21, 31) : color(248, 246, 242)
    let foreground = dark ? color(248, 246, 242) : color(28, 32, 39)
    let accent = dark ? color(255, 183, 130) : color(156, 67, 25)
    let pill = dark ? color(55, 40, 34) : color(246, 228, 212)
    background.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: asset.width, height: asset.height)).fill()

    let layout = Layout(device: asset.device)
    let width = CGFloat(asset.width)
    let height = CGFloat(asset.height)
    let captionWidth = (asset.caption as NSString).size(
        withAttributes: textAttributes(size: layout.captionSize, weight: .semibold, foreground: accent),
    ).width + layout.captionHeight * 0.85
    let caption = Rectangle(CGRect(
        x: (width - captionWidth) / 2, y: layout.captionTop, width: captionWidth, height: layout.captionHeight,
    ))
    let captionRect = caption.appKitRect(canvasHeight: asset.height)
    pill.setFill()
    NSBezierPath(roundedRect: captionRect, xRadius: captionRect.height / 2, yRadius: captionRect.height / 2).fill()
    try drawText(asset.caption, in: captionRect, size: layout.captionSize, weight: .semibold, foreground: accent)

    let subtitle = Rectangle(CGRect(
        x: layout.inset, y: layout.subtitleTop, width: width - layout.inset * 2, height: layout.subtitleHeight,
    ))
    try drawText(asset.subtitle, in: subtitle.appKitRect(canvasHeight: asset.height), size: layout.subtitleSize,
                 weight: .bold, foreground: foreground)

    let scale = min((width - layout.inset * 2) / width, (height - layout.screenshotTop - layout.bottom) / height)
    let screenshot = Rectangle(CGRect(x: (width - width * scale) / 2, y: layout.screenshotTop,
                                     width: width * scale, height: height * scale))
    let screenshotRect = screenshot.appKitRect(canvasHeight: asset.height)
    let borderRect = screenshotRect.insetBy(dx: -2, dy: -2)
    (dark ? color(71, 78, 90) : color(214, 213, 210)).setFill()
    NSBezierPath(rect: borderRect).fill()
    graphics.cgContext.interpolationQuality = .high
    graphics.cgContext.draw(sourceImage, in: screenshotRect)
    graphics.flushGraphics()

    let png = NSMutableData()
    guard let composed = context.makeImage(), let destination = CGImageDestinationCreateWithData(
        png, UTType.png.identifier as CFString, 1, nil,
    ) else {
        throw CompositionError(description: "Cannot encode sRGB PNG: \(asset.id)")
    }
    CGImageDestinationAddImage(destination, composed, nil)
    try require(CGImageDestinationFinalize(destination), "Cannot finalize PNG: \(asset.id)")
    let geometry = Geometry(
        sourceRect: Rectangle(CGRect(x: 0, y: 0, width: asset.width, height: asset.height)),
        screenshotRect: screenshot, captionRect: caption, subtitleRect: subtitle, scale: scale, cropped: false,
    )
    return (png as Data, geometry)
}

func compose() throws {
    let options = try Options(arguments: CommandLine.arguments)
    let manifestData = try Data(contentsOf: options.manifest)
    let provenanceData = try Data(contentsOf: options.provenance)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let manifest = try decoder.decode(CaptionManifest.self, from: manifestData)
    let provenance = try decoder.decode(Provenance.self, from: provenanceData)
    try require(manifest.schemaVersion == 1 && manifest.release == "2.0.0", "Unsupported caption manifest.")
    try require(!manifest.assets.isEmpty && Set(manifest.assets.map(\.id)).count == manifest.assets.count, "Empty or duplicate asset IDs.")
    try require(provenance.sourceCommit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil, "Expected full source commit SHA.")
    try require((Int(provenance.build) ?? 0) >= 5, "Expected build 5 or newer.")
    try require(!provenance.xcode.isEmpty, "Xcode version is missing.")

    var reports: [ComposedAsset] = []
    for asset in manifest.assets {
        guard let capture = provenance.captures[asset.id], let device = provenance.devices[asset.device] else {
            throw CompositionError(description: "Capture or device provenance is missing: \(asset.id)")
        }
        try validate(asset, capture: capture, provenance: provenance)
        let rawURL = try containedURL(asset.rawPath, root: options.root)
        let outputURL = try containedURL(asset.outputPath, root: options.root)
        let raw = try Data(contentsOf: rawURL)
        try require(sha256(raw) == capture.rawSha256, "Raw capture hash differs: \(asset.id)")
        let (png, geometry) = try render(asset, rawData: raw)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: outputURL, options: .atomic)
        reports.append(ComposedAsset(asset: asset, capture: capture, device: device, rawSha256: sha256(raw),
                                     outputSha256: sha256(png), geometry: geometry, pngColorType: "RGB8",
                                     inspectionStatus: "pending visual inspection"))
        print("Composed \(asset.id): \(asset.width)x\(asset.height), source scale \(geometry.scale)")
    }
    let toolURL = URL(fileURLWithPath: #filePath)
    let report = CompositionReport(
        sourceCommit: provenance.sourceCommit, build: provenance.build, xcode: provenance.xcode,
        macos: ProcessInfo.processInfo.operatingSystemVersionString,
        compositionToolSha256: sha256(try Data(contentsOf: toolURL)),
        captionManifestSha256: sha256(manifestData), captureProvenanceSha256: sha256(provenanceData), assets: reports,
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: options.report.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(report).write(to: options.report, options: .atomic)
    print("Composition report: \(options.report.path)")
}

do {
    try compose()
} catch {
    FileHandle.standardError.write(Data("Composition failed: \(error)\n".utf8))
    exit(1)
}
