import AppKit
import Foundation

@MainActor
struct QualificationChecks {
    static func run(model: QualificationModel, window: NSWindow) async -> Bool {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac476-evidence", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let outside = URL(fileURLWithPath: "/private/tmp/mac476-outside-\(UUID().uuidString)")
            do {
                try Data("fixture".utf8).write(to: outside)
                check(false, "Sandbox denies ungranted outside-container write")
                try? FileManager.default.removeItem(at: outside)
            } catch { check(true, "Sandbox denies ungranted outside-container write") }
            let credentials = FixtureCredentials(service: "com.hemsoft.qualification.mac476.tests.\(UUID().uuidString)")
            defer {
                try? credentials.remove("personal")
                try? credentials.remove("work")
            }
            try credentials.save("personal", token: Data("fixture-personal".utf8))
            try credentials.save("work", token: Data("fixture-work".utf8))
            check(try credentials.read("personal") == Data("fixture-personal".utf8), "Keychain personal isolation")
            check(try credentials.read("work") == Data("fixture-work".utf8), "Keychain work isolation")
            try credentials.save("personal", token: Data("fixture-updated".utf8))
            check(try credentials.read("work") == Data("fixture-work".utf8), "Keychain update preserves other account")
            try credentials.remove("personal")
            check(try credentials.read("personal") == nil, "Keychain disconnect removes only target")
            check(try credentials.read("work") != nil, "Keychain second account survives disconnect")
            await model.connect(openBrowser: false)
            guard let url = model.authorization.authorizationURL else { throw CocoaError(.fileReadUnknown) }
            let (page, response) = try await URLSession.shared.data(from: url)
            check((response as? HTTPURLResponse)?.statusCode == 200 && String(data: page, encoding: .utf8)?.contains("Select an account") == true,
                  "Sandbox loopback serves browser account selection")
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            check(model.authorization.respond("GET /callback?state=forged&account=fixture-work HTTP/1.1\r\n").0 == "403 Forbidden",
                  "Forged callback denied")
            check(model.authorization.respond("GET /callback?state=\(state)&state=\(state)&account=fixture-work HTTP/1.1\r\n").0 == "403 Forbidden",
                  "Duplicate state denied")
            check(model.authorization.respond("GET /callback?state=\(state)&account=unknown HTTP/1.1\r\n").0 == "400 Bad Request",
                  "Unknown account denied")
            var callback = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            callback.path = "/callback"
            callback.queryItems = [.init(name: "state", value: state), .init(name: "account", value: "fixture-personal")]
            _ = try await URLSession.shared.data(from: callback.url!)
            check(model.connected.contains("fixture-personal"), "HTTP callback saves credential before connected state")
            check(model.authorization.respond("GET /callback?state=\(state)&account=fixture-work HTTP/1.1\r\n").0 == "410 Gone",
                  "Replayed callback denied")
            try await Task.sleep(for: .milliseconds(400))
            check(model.screen == "Dashboard", "Authorized account returns to dashboard")
            await model.connect(openBrowser: false)
            guard let secondURL = model.authorization.authorizationURL,
                  let secondState = URLComponents(url: secondURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else {
                throw CocoaError(.fileReadUnknown)
            }
            check(model.authorization.respond("GET /authorize?state=\(secondState) HTTP/1.1\r\n", now: Date().addingTimeInterval(121)).0 == "410 Gone",
                  "Expired authorization denied")
            _ = model.authorization.respond("GET /callback?state=\(secondState)&cancel=1 HTTP/1.1\r\n")
            check(!model.busy && !model.connected.contains("fixture-work"), "Browser cancel saves no second credential")
            model.cancel()
            model.screen = "Settings"
            try await Task.sleep(for: .milliseconds(300))
            check(model.screen == "Settings", "Settings state reachable")
            print("PASS Qualification window size \(window.frame.size); capture OS window separately")
            do {
                try model.restore.prepare()
                check(await model.restore.restore() == false, "Synthetic empty restore remains free")
                try await model.restore.seedLifetime()
                check(await model.restore.restore(), "Synthetic verified lifetime restore")
                try model.restore.revoke()
                check(await model.restore.restore() == false, "Synthetic refund removes lifetime")
                model.restore.reset()
                check(!SyntheticRestore.grants(.init(productID: NativeStoreKitRestore.lifetimeID, verified: false, revoked: false)),
                      "Synthetic unverified receipt denied")
                check(!SyntheticRestore.grants(.init(productID: "unknown", verified: true, revoked: false)),
                      "Synthetic unrelated product denied")
            } catch {
                print("FAIL Synthetic restore rehearsal: \(error)")
                failures += 1
            }
            model.disconnect("fixture-personal")
            model.authorization.cancel()
        } catch {
            print("FAIL qualification: \(error)")
            failures += 1
        }
        print("RESULT \(failures) failures")
        fflush(nil)
        return failures == 0
    }

}
