import Foundation

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
