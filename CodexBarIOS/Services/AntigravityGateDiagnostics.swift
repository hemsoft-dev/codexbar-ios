import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// Development-build record of what the Antigravity page read observed, for the feasibility check in #601.
/// It holds page hosts and paths, outcomes and the quota response body. It never holds a profile response,
/// cookie, header or account name, and release builds compile it to nothing.
enum AntigravityGateDiagnostics {
    static func record(_ event: String) {
        #if DEBUG
        guard let directory else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event)\n"
        let file = directory.appendingPathComponent("events.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: file, options: .atomic)
        }
        #endif
    }

    static func recordQuotaResponse(_ body: String) {
        #if DEBUG
        guard let directory else { return }
        try? Data(body.utf8).write(to: directory.appendingPathComponent("quota-response.json"), options: .atomic)
        #endif
    }

    /// What a hidden page that reported no usage was showing: its route, whether it thinks it is visible, its
    /// headings, and a picture. Debug builds only. The picture can show the signed-in account's avatar, and it
    /// stays in the app's caches on the device.
    @MainActor
    static func recordPageState(of webView: WKWebView) async {
        #if DEBUG
        let script = """
        JSON.stringify({
          route: location.pathname + location.search.replace(/=[^&]*/g, function (m) { return m.length > 24 ? '=…' : m; }),
          visibility: document.visibilityState, focus: document.hasFocus(), width: innerWidth, height: innerHeight,
          headings: Array.prototype.slice.call(document.querySelectorAll('h1,h2,h3,[role=heading]'), 0, 12)
            .map(function (e) { return (e.innerText || '').slice(0, 40); }),
          buttons: Array.prototype.slice.call(document.querySelectorAll('button[aria-label]'), 0, 16)
            .map(function (e) { return e.getAttribute('aria-label').slice(0, 30); }),
          dialogs: document.querySelectorAll('[role=dialog]').length,
          hasUsageScreen: document.body.innerText.indexOf('Models & Usage') >= 0,
          hasQuotaRows: document.body.innerText.indexOf('Weekly Limit') >= 0
        })
        """
        let state = (try? await webView.evaluateJavaScript(script)) as? String
        record("read.page-state \(state ?? "unavailable")")
        #if canImport(UIKit)
        guard let directory, let image = try? await webView.takeSnapshot(configuration: nil),
              let data = image.pngData() else { return }
        try? data.write(to: directory.appendingPathComponent("hidden-page.png"), options: .atomic)
        #endif
        #endif
    }

    /// Host and path only: a query can carry account hints.
    static func describe(_ url: URL?) -> String {
        guard let url else { return "none" }
        return "\(url.host ?? "?")\(url.path)"
    }

    #if DEBUG
    private static var directory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("AntigravityGate", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    #endif
}
