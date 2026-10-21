import AppKit
import Foundation

@MainActor
struct QualificationChecks {
    static func run(window: NSWindow) async -> Bool {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let modelCredentials = FixtureCredentials(service: "com.hemsoft.qualification.mac476.selftest.\(UUID().uuidString)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac476-evidence", isDirectory: true)
        do {
            try modelCredentials.save("fixture-work", token: Data("preexisting-work".utf8))
            let model = QualificationModel(credentials: modelCredentials)
            defer {
                model.cancel()
                try? modelCredentials.remove("fixture-personal")
                try? modelCredentials.remove("fixture-work")
            }
            check(model.connected.contains("fixture-work"), "Model restores preexisting Work credential before cancellation")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let outside = URL(fileURLWithPath: "/private/tmp/mac476-outside-\(UUID().uuidString)")
            do {
                try Data("fixture".utf8).write(to: outside)
                check(false, "Sandbox denies ungranted outside-container write")
                try? FileManager.default.removeItem(at: outside)
            } catch {
                let failure = error as NSError
                let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
                let denied = (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteNoPermissionError)
                    || (failure.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(failure.code)))
                    || (underlying?.domain == NSPOSIXErrorDomain
                        && [Int(EACCES), Int(EPERM)].contains(underlying?.code ?? 0))
                print("Sandbox write error: \(failure.domain) \(failure.code)")
                check(denied, "Sandbox denies ungranted outside-container write")
            }
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
            let request = Data("GET /authorize?state=fixture HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
            var fragmented = true
            for split in 1..<request.count {
                var buffer = FixtureHTTPRequestBuffer()
                fragmented = fragmented && buffer.append(Data(request.prefix(split)), complete: false) == .incomplete
                fragmented = fragmented && buffer.append(Data(request.dropFirst(split)), complete: false)
                    == .request(String(bytes: request, encoding: .utf8)!)
            }
            check(fragmented, "Every partial-header split waits for complete HTTP framing")
            var incomplete = FixtureHTTPRequestBuffer()
            check(incomplete.append(Data("GET /".utf8), complete: true) == .rejected, "Incomplete HTTP request rejected at EOF")
            var oversized = FixtureHTTPRequestBuffer()
            check(oversized.append(Data(repeating: 65, count: 8193), complete: false) == .rejected,
                  "Oversized HTTP request rejected")
            await model.connect(openBrowser: false)
            guard let url = model.authorization.authorizationURL else { throw CocoaError(.fileReadUnknown) }
            let (page, response) = try await URLSession.shared.data(from: url)
            let pageText = String(data: page, encoding: .utf8) ?? ""
            check((response as? HTTPURLResponse)?.statusCode == 200
                  && pageText.contains("<h1>Connect a fixture account</h1>") && pageText.contains("Select an account"),
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
            check(!model.busy && model.authorization.authorizationURL == nil
                  && model.status.contains("expired"), "Expired attempt ends authorization and enables retry")
            await model.connect(openBrowser: false)
            guard let retryURL = model.authorization.authorizationURL,
                  let retryState = URLComponents(url: retryURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else {
                throw CocoaError(.fileReadUnknown)
            }
            check(model.busy && retryState != secondState, "Retry starts a fresh authorization after expiry")
            let priorAccounts = model.connected
            let priorWork = try modelCredentials.read("fixture-work")
            let priorPersonal = try modelCredentials.read("fixture-personal")
            _ = model.authorization.respond("GET /callback?state=\(retryState)&cancel=1 HTTP/1.1\r\n")
            check(!model.busy && model.connected == priorAccounts, "Browser cancel preserves preexisting connected accounts")
            check(try modelCredentials.read("fixture-work") == priorWork && modelCredentials.read("fixture-personal") == priorPersonal,
                  "Browser cancel preserves preexisting Work and Personal credentials")
            try await checkExpiry(check)
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

    private static func checkExpiry(_ check: (Bool, String) -> Void) async throws {
        let authorization = FixtureAuthorization(timeout: 0.15)
        let credentials = FixtureCredentials(service: "com.hemsoft.qualification.mac476.timeout.\(UUID().uuidString)")
        let model = QualificationModel(authorization: authorization, credentials: credentials)
        defer { model.cancel(); try? credentials.remove("fixture-personal") }
        await model.connect(openBrowser: false)
        let expiredURL = authorization.authorizationURL
        try await Task.sleep(for: .milliseconds(250))
        check(expiredURL != nil && !model.busy && authorization.authorizationURL == nil && model.status.contains("expired"),
              "No-request timeout clears busy and authorization URL")
        if let expiredURL {
            do {
                _ = try await URLSession.shared.data(from: expiredURL)
                check(false, "No-request timeout closes loopback listener")
            } catch { check(true, "No-request timeout closes loopback listener") }
        }
        await model.connect(openBrowser: false)
        model.cancel()
        let canceledStatus = model.status
        try await Task.sleep(for: .milliseconds(200))
        check(model.status == canceledStatus && !model.busy, "Canceled timer never reports expiry")
        await model.connect(openBrowser: false)
        let canceledURL = authorization.authorizationURL!
        let canceledState = URLComponents(url: canceledURL, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
        _ = authorization.respond("GET /callback?state=\(canceledState)&cancel=1 HTTP/1.1\r\n")
        let browserCanceledStatus = model.status
        try await Task.sleep(for: .milliseconds(200))
        check(model.status == browserCanceledStatus && !model.busy && authorization.authorizationURL == nil,
              "Browser cancellation clears URL and cancels expiry timer")
        await model.connect(openBrowser: false)
        let url = authorization.authorizationURL!
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
        _ = authorization.respond("GET /callback?state=\(state)&account=fixture-personal HTTP/1.1\r\n")
        let completedStatus = model.status
        try await Task.sleep(for: .milliseconds(200))
        check(model.status == completedStatus && authorization.authorizationURL == nil && !model.busy,
              "Completed timer never reports expiry and clears URL")
        await model.connect(openBrowser: false)
        try await Task.sleep(for: .milliseconds(90))
        await model.connect(openBrowser: false)
        let newURL = authorization.authorizationURL
        try await Task.sleep(for: .milliseconds(90))
        check(model.busy && authorization.authorizationURL == newURL && newURL != nil,
              "Old attempt timer cannot expire replacement attempt")
        try await Task.sleep(for: .milliseconds(150))
        check(!model.busy && authorization.authorizationURL == nil && model.status.contains("expired"),
              "Replacement attempt expires at its own deadline")
    }

}
