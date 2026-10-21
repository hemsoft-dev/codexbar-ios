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

    private static func checkExpiry(_ check: @escaping (Bool, String) -> Void) async throws {
        var deadlines: [@MainActor () -> Void] = []
        var scheduledTimeouts: [TimeInterval] = []
        let authorization = FixtureAuthorization(scheduleExpiry: { timeout, expire in
            scheduledTimeouts.append(timeout)
            deadlines.append(expire)
            return Task {}
        })
        let credentials = FixtureCredentials(service: "com.hemsoft.qualification.mac476.timeout.\(UUID().uuidString)")
        var opens = false
        let model = QualificationModel(authorization: authorization, credentials: credentials, browserOpener: { _ in opens })
        defer { model.cancel(); try? credentials.remove("fixture-personal") }
        func ready() async throws -> (URL, String) {
            await model.connect(openBrowser: false)
            guard let url = authorization.authorizationURL,
                  let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Listener did not become ready"])
            }
            return (url, state)
        }
        let (expiredURL, _) = try await ready()
        deadlines[deadlines.count - 1]()
        check(!model.busy && authorization.authorizationURL == nil && model.status.contains("expired"),
              "No-request timeout clears busy and authorization URL")
        check(!authorization.hasListener, "No-request timeout releases listener ownership")
        var request = URLRequest(url: expiredURL)
        request.timeoutInterval = 5
        do {
            _ = try await URLSession.shared.data(for: request)
            check(false, "No-request timeout closes loopback listener")
        } catch {
            check(isConnectionRefused(error), "No-request timeout closes loopback listener")
        }
        check(!isConnectionRefused(URLError(.timedOut)) && !isConnectionRefused(URLError(.appTransportSecurityRequiresSecureConnection)),
              "Timeout and transport policy errors cannot qualify listener closure")
        check(isConnectionRefused(URLError(.cannotConnectToHost)), "Cannot-connect error qualifies listener closure")
        _ = try await ready()
        let canceledDeadline = deadlines[deadlines.count - 1]
        model.cancel()
        let canceledStatus = model.status
        canceledDeadline()
        check(model.status == canceledStatus && !model.busy, "Canceled timer never reports expiry")
        let (_, canceledState) = try await ready()
        let browserDeadline = deadlines[deadlines.count - 1]
        _ = authorization.respond("GET /callback?state=\(canceledState)&cancel=1 HTTP/1.1\r\n")
        let browserCanceledStatus = model.status
        browserDeadline()
        check(model.status == browserCanceledStatus && !model.busy && authorization.authorizationURL == nil,
              "Browser cancellation clears URL and cancels expiry timer")
        let (_, state) = try await ready()
        let completedDeadline = deadlines[deadlines.count - 1]
        _ = authorization.respond("GET /callback?state=\(state)&account=fixture-personal HTTP/1.1\r\n")
        let completedStatus = model.status
        completedDeadline()
        check(model.status == completedStatus && authorization.authorizationURL == nil && !model.busy,
              "Completed timer never reports expiry and clears URL")
        _ = try await ready()
        let oldDeadline = deadlines[deadlines.count - 1]
        let (newURL, _) = try await ready()
        oldDeadline()
        check(model.busy && authorization.authorizationURL == newURL,
              "Old attempt timer cannot expire replacement attempt")
        deadlines[deadlines.count - 1]()
        check(!model.busy && authorization.authorizationURL == nil && model.status.contains("expired"),
              "Replacement attempt expires at its own deadline")
        await model.connect()
        check(!model.busy && !authorization.hasListener && authorization.authorizationURL == nil
              && model.status.contains("Could not open the browser"), "Failed browser opener cleans up immediately")
        opens = true
        await model.connect()
        check(model.busy && authorization.authorizationURL != nil, "Failed browser opener allows immediate retry")
        check(scheduledTimeouts.allSatisfy { $0 == 120 }, "Production authorization deadline remains 120 seconds")
    }

    private static func isConnectionRefused(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSURLErrorDomain && error.code == URLError.cannotConnectToHost.rawValue)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ECONNREFUSED))
    }
}
