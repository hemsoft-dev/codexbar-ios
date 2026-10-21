import Foundation
import Network

@MainActor
final class FixtureAuthorization {
    struct Attempt {
        let state: String
        let expires: Date
    }

    private var listener: NWListener?
    private var pending: Attempt?
    var onResult: ((Result<String, Error>) -> Void)?
    private(set) var authorizationURL: URL?
    private(set) var lastAccount: String?

    func start() throws {
        cancel()
        pending = Attempt(state: UUID().uuidString, expires: Date().addingTimeInterval(120))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = state, let port = server.port, let pending = self.pending {
                    self.authorizationURL = URL(string: "http://127.0.0.1:\(port)/authorize?state=\(pending.state)")
                }
                if case .failed(let error) = state { self.onResult?(.failure(error)) }
            }
        }
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            Task { @MainActor in self?.receiveRequest(connection) }
        }
        server.start(queue: .main)
    }

    private func receiveRequest(_ connection: NWConnection, buffer: FixtureHTTPRequestBuffer = FixtureHTTPRequestBuffer()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, error == nil else { connection.cancel(); return }
                var next = buffer
                switch next.append(data ?? Data(), complete: complete) {
                case .incomplete:
                    self.receiveRequest(connection, buffer: next)
                case .rejected:
                    self.send(("400 Bad Request", "Incomplete or oversized fixture request"), to: connection)
                case .request(let request):
                    self.send(self.respond(request), to: connection)
                }
            }
        }
    }

    private func send(_ response: (String, String), to connection: NWConnection) {
        let body = Data(response.1.utf8)
        let header = "HTTP/1.1 \(response.0)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    func cancel() {
        pending = nil
        authorizationURL = nil
        listener?.cancel()
        listener = nil
    }

    /// Tiny fixture-only HTTP parser; production providers must use their registered OAuth contract.
    func respond(_ request: String, now: Date = Date()) -> (String, String) {
        let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard parts.count == 3, parts[0] == "GET",
              let url = URLComponents(string: String(parts[1])), url.scheme == nil, url.host == nil,
              let pending, now < pending.expires else { return ("410 Gone", "Attempt expired or canceled") }
        let items = url.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == pending.state else {
            return ("403 Forbidden", "Invalid authorization state")
        }
        if url.path == "/authorize" {
            return ("200 OK", page(state: pending.state))
        }
        guard url.path == "/callback" else { return ("404 Not Found", "Unknown fixture route") }
        if items.contains(where: { $0.name == "cancel" && $0.value == "1" }) {
            self.pending = nil
            onResult?(.failure(CocoaError(.userCancelled)))
            return ("200 OK", "<h1>Authorization canceled</h1><p>Return to CodexBar Qualification.</p>")
        }
        guard items.filter({ $0.name == "account" }).count == 1,
              let account = items.first(where: { $0.name == "account" })?.value,
              ["fixture-personal", "fixture-work"].contains(account) else {
            return ("400 Bad Request", "Choose a fixture account")
        }
        self.pending = nil
        lastAccount = account
        onResult?(.success(account))
        return ("200 OK", "<h1>Fixture authorization returned</h1><p>The app is now active. No provider was contacted.</p>")
    }

    private func page(state: String) -> String {
        """
        <!doctype html><html lang="en"><meta charset="utf-8"><title>CodexBar fixture authorization</title>
        <style>body{font:18px system-ui;max-width:560px;margin:80px auto;padding:24px}select,button{font:inherit;padding:12px;margin:12px 0}</style>
        <h1>Connect a fixture account</h1><p>PROVISIONAL desktop qualification. Synthetic data only.</p>
        <p>This local page never contacts a provider. Select an account and approve to return to the app.</p>
        <form action="/callback"><input type="hidden" name="state" value="\(state)">
        <label>Account <select name="account"><option value="fixture-personal">Personal fixture</option>
        <option value="fixture-work">Work fixture</option></select></label><br><button>Approve fixture connection</button></form>
        <form action="/callback"><input type="hidden" name="state" value="\(state)">
        <input type="hidden" name="cancel" value="1"><button>Cancel</button></form></html>
        """
    }
}

/// Bounded transport framing, shared by the real loopback receiver and fragmentation regressions.
struct FixtureHTTPRequestBuffer: Sendable {
    enum Result: Equatable { case incomplete, rejected, request(String) }
    private var data = Data()

    mutating func append(_ chunk: Data, complete: Bool) -> Result {
        guard data.count + chunk.count <= 8192 else { return .rejected }
        data.append(chunk)
        if let end = data.range(of: Data("\r\n\r\n".utf8)) {
            guard let request = String(data: data[..<end.upperBound], encoding: .utf8) else { return .rejected }
            return .request(request)
        }
        return complete ? .rejected : .incomplete
    }
}
