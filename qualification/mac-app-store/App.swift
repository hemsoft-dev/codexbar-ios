import AppKit
import SwiftUI

@MainActor
final class QualificationModel: ObservableObject {
    @Published var screen = "Dashboard"
    @Published var status = "Choose Connect fixture to begin."
    @Published var connected: Set<String> = []
    @Published var restored = false
    @Published var busy = false
    let authorization: FixtureAuthorization
    let credentials: FixtureCredentials
    let restore = SyntheticRestore()

    init(authorization: FixtureAuthorization = FixtureAuthorization(), credentials: FixtureCredentials = FixtureCredentials()) {
        self.authorization = authorization
        self.credentials = credentials
        for account in ["fixture-personal", "fixture-work"] where (try? credentials.read(account)) != nil {
            connected.insert(account)
        }
        authorization.onResult = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let account):
                do {
                    try self.credentials.save(account, token: Data("synthetic-only-\(UUID().uuidString)".utf8))
                    self.connected.insert(account)
                    self.status = "Connected \(account). Synthetic credential saved in Keychain."
                    self.screen = "Dashboard"
                } catch {
                    self.status = "Credential save failed. Account remains disconnected: \(error.localizedDescription)"
                }
            case .failure(let error):
                self.status = "Authorization ended: \(error.localizedDescription)"
            }
            self.busy = false
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func connect(openBrowser: Bool = true) async {
        busy = true
        do {
            try authorization.start()
            for _ in 0..<100 {
                if let url = authorization.authorizationURL {
                    status = "Waiting for approval in your browser. This attempt expires in two minutes."
                    if openBrowser { NSWorkspace.shared.open(url) }
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CocoaError(.fileReadUnknown)
        } catch {
            cancel()
            status = "Could not start local authorization: \(error.localizedDescription)"
        }
    }

    func cancel() {
        authorization.cancel()
        busy = false
        status = "Authorization canceled. No credential was saved."
    }

    func disconnect(_ account: String) {
        do {
            try credentials.remove(account)
            connected.remove(account)
            status = "Disconnected \(account); its fixture credential was removed."
        } catch { status = "Could not remove fixture credential: \(error.localizedDescription)" }
    }

    func restoreFixture(seed: Bool) async {
        busy = true
        defer { busy = false }
        do {
            try restore.prepare()
            if seed { try await restore.seedLifetime() }
            restored = await restore.restore()
            status = restored ? "Restored synthetic lifetime fixture. Native test results are recorded separately."
                : "No verified lifetime in the synthetic fixture."
        } catch { status = "Synthetic restore unavailable: \(error.localizedDescription)" }
    }
}

struct QualificationView: View {
    @ObservedObject var model: QualificationModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Label("CodexBar", systemImage: "chart.bar.xaxis").font(.title2.bold())
                Text("DESKTOP QUALIFICATION").font(.caption).foregroundStyle(.secondary)
                ForEach(["Dashboard", "Settings"], id: \.self) { screen in
                    Button { model.screen = screen } label: {
                        Label(screen, systemImage: screen == "Dashboard" ? "rectangle.grid.2x2" : "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.screen == screen ? .accentColor : .secondary)
                    .accessibilityIdentifier(screen)
                }
                Spacer()
                Text("PROVISIONAL\nMac App Store route\nShipping choice pending Franz")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(width: 220).background(.quaternary.opacity(0.3))
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                Text(model.screen).font(.largeTitle.bold())
                Text("Local fixtures only · No provider accounts · No checkout")
                    .foregroundStyle(.secondary)
                Divider()
                if model.screen == "Dashboard" { dashboard } else { settings }
                Spacer(minLength: 0)
                Divider()
                Text(model.status).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("Status")
            }
            .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider accounts").font(.title2.bold())
                    Text("Connect a synthetic account to inspect fixture usage.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect fixture") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
            }
            if model.connected.isEmpty {
                Label("No fixture accounts connected", systemImage: "person.crop.circle.badge.plus")
                    .font(.headline).padding(.vertical, 30)
            }
            ForEach(model.connected.sorted(), id: \.self) { account in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(account == "fixture-personal" ? "Personal fixture" : "Work fixture", systemImage: "person.crop.circle")
                            .font(.headline)
                        Spacer()
                        Text("SYNTHETIC").font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: account == "fixture-personal" ? 0.38 : 0.64)
                    Text(account == "fixture-personal" ? "38% of a sample five-hour quota" : "64% of a sample five-hour quota")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.busy { Button("Cancel authorization") { model.cancel() } }
            Text("These fixed values are fixtures. Live quota and provider-account testing remain pending.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Account isolation").font(.title2.bold())
            Text("Each fixture account has a separate Keychain item. Disconnect removes only that item.")
            ForEach(model.connected.sorted(), id: \.self) { account in
                HStack {
                    Text(account)
                    Spacer()
                    Button("Disconnect \(account)") { model.disconnect(account) }
                }
            }
            Divider()
            Text("Synthetic restore rehearsal").font(.title2.bold())
            Text(model.restored ? "Test lifetime restored" : "No test entitlement restored").font(.headline)
            HStack {
                Button("Seed synthetic lifetime") { Task { await model.restoreFixture(seed: true) } }
                Button("Restore synthetic purchases") { Task { await model.restoreFixture(seed: false) } }
            }.disabled(model.busy)
            Text("Uses the copied StoreKit catalog and an in-memory receipt fixture. "
                 + "This rehearsal does not verify native StoreKit or purchase portability. Run test.sh for native test evidence.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("Distribution").font(.title2.bold())
            Text("Local ad hoc signature · App Sandbox enabled\nStore signing and App Store updates have not run.")
                .foregroundStyle(.secondary)
        }
    }
}

@main
@MainActor
final class QualificationApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private lazy var model = QualificationModel()

    static func main() {
        let app = NSApplication.shared
        let delegate = QualificationApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1040, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CodexBar Qualification · PROVISIONAL"
        window.contentView = NSHostingView(rootView: QualificationView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        print("WINDOW_ID=\(window.windowNumber)")
        fflush(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--evidence") {
            Task {
                await model.connect(openBrowser: false)
                print("AUTH_URL=\(model.authorization.authorizationURL?.absoluteString ?? "unavailable")")
                fflush(nil)
            }
        }
        if CommandLine.arguments.contains("--settings") { model.screen = "Settings" }
        if CommandLine.arguments.contains("--self-test") {
            Task {
                let passed = await QualificationChecks.run(window: window)
                exit(passed ? 0 : 1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
