import Foundation
@testable import CodexBarIOS

func makeHistoryResult(
    accountID: String,
    providerID: ProviderID = .codex,
    fetchedAt: Date,
    used: Double? = nil,
    bars: [UsageBar]? = nil,
    creditsRemaining: Double? = nil
) -> ProviderUsageResult {
    ProviderUsageResult(
        accountID: accountID,
        providerID: providerID,
        title: providerID.displayName,
        subtitle: "Test data",
        bars: bars ?? used.map { [UsageBar(label: "Usage", used: $0, limit: 100)] } ?? [],
        creditsRemaining: creditsRemaining,
        fetchedAt: fetchedAt
    )
}

struct EmptySecretStore: SecretStore {
    func readSecret(account: String) throws -> String? {
        nil
    }

    func saveSecret(_ secret: String, account: String) throws {
    }

    func deleteSecret(account: String) throws {
    }
}

struct FailingReadSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? {
        throw FailingReadSecretStoreError.unavailable
    }

    func saveSecret(_ secret: String, account: String) throws {
    }

    func deleteSecret(account: String) throws {
    }
}

enum FailingReadSecretStoreError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Keychain unavailable"
    }
}

final class RecordingFileProtectionManager: FileManager, @unchecked Sendable {
    var shouldFail = false
    private(set) var recordedAttributes: [FileAttributeKey: Any]?
    private(set) var recordedPath: String?

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        recordedAttributes = attributes
        recordedPath = path
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

actor StubAppStoreReleaseFetcher: AppStoreReleaseFetching {
    private var result: Result<AppStoreRelease, AppStoreReleaseError>
    private var fetchCount = 0

    init(result: Result<AppStoreRelease, AppStoreReleaseError>) {
        self.result = result
    }

    func fetchRelease() async throws -> AppStoreRelease {
        fetchCount += 1
        return try result.get()
    }

    func setResult(_ result: Result<AppStoreRelease, AppStoreReleaseError>) {
        self.result = result
    }

    func currentFetchCount() -> Int {
        fetchCount
    }
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
}

final class FailingSaveSecretStore: SecretStore, @unchecked Sendable {
    private let secret: String

    init(secret: String) {
        self.secret = secret
    }

    func readSecret(account: String) throws -> String? {
        secret
    }

    func saveSecret(_ secret: String, account: String) throws {
        throw KeychainError.unhandledStatus(-25308)
    }

    func deleteSecret(account: String) throws {}
}

struct FailingDeleteSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? {
        "existing-token"
    }

    func saveSecret(_ secret: String, account: String) throws {}

    func deleteSecret(account: String) throws {
        throw KeychainError.unhandledStatus(-25308)
    }
}

final class RetriableDeleteSecretStore: SecretStore, @unchecked Sendable {
    var shouldFailDelete = true
    var failingAccount: String?
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailDelete || failingAccount == account {
            throw KeychainError.unhandledStatus(-25308)
        }
        secrets.removeValue(forKey: account)
    }
}

final class SelectiveReadFailureSecretStore: SecretStore, @unchecked Sendable {
    var failingAccount: String?
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if account == failingAccount {
            throw KeychainError.unhandledStatus(-25308)
        }
        return secrets[account]
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
}

final class StaleThirdReadSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let initialSecret: String
    private var currentSecret: String
    private var readCount = 0

    init(initialSecret: String) {
        self.initialSecret = initialSecret
        self.currentSecret = initialSecret
    }

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return readCount == 3 ? initialSecret : currentSecret
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        currentSecret = secret
    }

    func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        currentSecret = ""
    }
}

final class ReplacingThirdReadSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let initialSecret: String
    private let replacementSecret: String
    private var readCount = 0
    private var storedSaveCount = 0

    init(initialSecret: String, replacementSecret: String) {
        self.initialSecret = initialSecret
        self.replacementSecret = replacementSecret
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSaveCount
    }

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return readCount >= 3 ? replacementSecret : initialSecret
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storedSaveCount += 1
    }

    func deleteSecret(account: String) throws {}
}

func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer {
        stream.close()
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let byteCount = stream.read(&buffer, maxLength: buffer.count)
        guard byteCount > 0 else {
            break
        }
        data.append(contentsOf: buffer.prefix(byteCount))
    }
    return data
}

typealias TestURLProtocolHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

final class TestURLProtocolHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: TestURLProtocolHandler?

    var handler: TestURLProtocolHandler? {
        get {
            lock.withLock { storedHandler }
        }
        set {
            lock.withLock { storedHandler = newValue }
        }
    }
}

class TestURLProtocol: URLProtocol, @unchecked Sendable {
    class var handlerStore: TestURLProtocolHandlerStore {
        preconditionFailure("Concrete test URL protocols must provide a handler store.")
    }

    class var handler: TestURLProtocolHandler? {
        get { handlerStore.handler }
        set { handlerStore.handler = newValue }
    }

    class func handler(for request: URLRequest) -> TestURLProtocolHandler? {
        handler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = type(of: self).handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class AppAndWidgetMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    // URLProtocol requires an overridable class property.
    // swiftlint:disable:next static_over_final_class
    override class var handlerStore: TestURLProtocolHandlerStore { store }
}

final class ConfigurationAndAuthMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    // URLProtocol requires an overridable class property.
    // swiftlint:disable:next static_over_final_class
    override class var handlerStore: TestURLProtocolHandlerStore { store }
}

final class ProviderParsingMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    // URLProtocol requires an overridable class property.
    // swiftlint:disable:next static_over_final_class
    override class var handlerStore: TestURLProtocolHandlerStore { store }
}

final class ProviderNetworkMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    // URLProtocol requires an overridable class property.
    // swiftlint:disable:next static_over_final_class
    override class var handlerStore: TestURLProtocolHandlerStore { store }

    // Legacy usage/token scenarios exclude optional profile and billing reads, which have isolated coverage.
    override func startLoading() {
        guard ["/api/oauth/profile", "/backend-api/subscriptions"].contains(request.url?.path ?? "") else { super.startLoading(); return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class DashboardAndSettingsMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    // URLProtocol requires an overridable class property.
    // swiftlint:disable:next static_over_final_class
    override class var handlerStore: TestURLProtocolHandlerStore { store }
}

final class IsolatedTestURLProtocol: TestURLProtocol, @unchecked Sendable {
    static let handlerIDHeader = "X-CodexBar-Test-Handler-ID"

    private static let lock = NSLock()
    private static var handlers: [String: TestURLProtocolHandler] = [:]

    static func register(_ handler: @escaping TestURLProtocolHandler, for handlerID: String) {
        lock.withLock {
            handlers[handlerID] = handler
        }
    }

    static func unregister(handlerID: String) {
        _ = lock.withLock {
            handlers.removeValue(forKey: handlerID)
        }
    }

    // URLProtocol requires overridable class methods.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: handlerIDHeader) != nil
    }

    // URLProtocol requires overridable class methods.
    // swiftlint:disable:next static_over_final_class
    override class func handler(for request: URLRequest) -> TestURLProtocolHandler? {
        guard
            let handlerID = request.value(forHTTPHeaderField: handlerIDHeader)
        else {
            return nil
        }
        return lock.withLock { handlers[handlerID] }
    }
}

final class IsolatedTestURLSession: @unchecked Sendable {
    let session: URLSession

    private let handlerID = UUID().uuidString
    private let lock = NSLock()
    private var isInvalidated = false

    init(handler: @escaping TestURLProtocolHandler) {
        IsolatedTestURLProtocol.register(handler, for: handlerID)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            IsolatedTestURLProtocol.handlerIDHeader: handlerID
        ]
        configuration.protocolClasses = [IsolatedTestURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        let shouldInvalidate = lock.withLock {
            guard !isInvalidated else { return false }
            isInvalidated = true
            return true
        }
        guard shouldInvalidate else { return }

        session.invalidateAndCancel()
        IsolatedTestURLProtocol.unregister(handlerID: handlerID)
    }
}

final class TestRequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let requestStarted = TestSignal()
    private var released = false

    func blockUntilReleased() {
        condition.lock()
        requestStarted.signal()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() async {
        await requestStarted.wait()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class TestSignal: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
    }

    func signal() {
        continuation.yield()
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }
}

struct TestWatchdogError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private final class TestWatchdogStartLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !isOpen else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let pendingWaiters = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private final class TestWatchdogTaskCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var isTerminated = false
    private var tasks: [Task<Void, Never>] = []

    func install(_ tasks: [Task<Void, Never>]) {
        let shouldCancel = lock.withLock {
            guard !isTerminated else { return true }
            self.tasks = tasks
            return false
        }
        guard shouldCancel else { return }

        for task in tasks {
            task.cancel()
        }
    }

    func terminate() {
        let tasksToCancel = lock.withLock {
            isTerminated = true
            defer { tasks.removeAll() }
            return tasks
        }
        for task in tasksToCancel {
            task.cancel()
        }
    }
}

final class TestWatchdogOutcomeCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var didChooseOutcome = false

    func claimOperation() -> Bool {
        claimOutcome()
    }

    func claimTimeout() -> Bool {
        claimOutcome()
    }

    private func claimOutcome() -> Bool {
        lock.withLock {
            guard !didChooseOutcome else { return false }
            didChooseOutcome = true
            return true
        }
    }
}

func withTestWatchdog<Result: Sendable>(
    timeout: Duration,
    failureMessage: String,
    onTimeout: @escaping @Sendable () -> Void,
    waitForTimeout: @escaping @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
    },
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    let outcomes = AsyncThrowingStream(Result.self) { continuation in
        let startLatch = TestWatchdogStartLatch()
        let taskCoordinator = TestWatchdogTaskCoordinator()
        let outcomeCoordinator = TestWatchdogOutcomeCoordinator()
        continuation.onTermination = { _ in
            taskCoordinator.terminate()
        }

        let operationTask = Task {
            await startLatch.wait()
            do {
                let result = try await operation()
                guard outcomeCoordinator.claimOperation() else { return }
                continuation.yield(result)
                continuation.finish()
            } catch {
                guard outcomeCoordinator.claimOperation() else { return }
                continuation.finish(throwing: error)
            }
        }
        let timeoutTask = Task {
            await startLatch.wait()
            do {
                try await waitForTimeout(timeout)
                try Task.checkCancellation()
            } catch {
                return
            }

            guard outcomeCoordinator.claimTimeout() else { return }
            onTimeout()
            continuation.finish(throwing: TestWatchdogError(message: failureMessage))
        }
        taskCoordinator.install([operationTask, timeoutTask])
        startLatch.open()
    }

    for try await result in outcomes {
        return result
    }
    throw CancellationError()
}

final class TestDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            date.addTimeInterval(interval)
        }
    }
}

struct HangingUsageProvider: UsageProvider {
    let providerID: ProviderID

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        try await Task.sleep(for: .seconds(60))
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: providerID.displayName,
            subtitle: "Unexpected",
            bars: [],
            fetchedAt: Date()
        )
    }
}

actor UsageProviderGate {
    private var shouldBlock = true
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard shouldBlock else {
            return
        }
        shouldBlock = false
        isBlocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        while !isBlocked {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

actor AsyncFlag {
    private var value = false

    func set() {
        value = true
    }

    func currentValue() -> Bool {
        value
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    func currentValue() -> Bool {
        lock.withLock { value }
    }
}

actor UsageProviderRecorder {
    private var labels: [String] = []

    func record(_ label: String) {
        labels.append(label)
    }

    func recordedLabels() -> [String] {
        labels
    }
}

struct GatedUsageProvider: UsageProvider {
    let providerID: ProviderID
    let blockedAccountID: String
    let gate: UsageProviderGate
    let recorder: UsageProviderRecorder?

    init(
        providerID: ProviderID,
        blockedAccountID: String,
        gate: UsageProviderGate,
        recorder: UsageProviderRecorder? = nil
    ) {
        self.providerID = providerID
        self.blockedAccountID = blockedAccountID
        self.gate = gate
        self.recorder = recorder
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        if let recorder {
            await recorder.record(configuration.accountLabel)
        }
        if configuration.id == blockedAccountID {
            await gate.wait()
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Fresh usage",
            bars: [UsageBar(label: "Usage", used: 20, limit: 100)],
            fetchedAt: Date()
        )
    }
}

struct StaleCompletionTestUsageProvider: UsageProvider {
    let providerID: ProviderID
    let gate: UsageProviderGate
    let fails: Bool

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        await gate.wait()
        if fails {
            throw TestUsageProviderError.failed
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Fresh usage",
            bars: [UsageBar(label: "Usage", used: 95, limit: 100)],
            fetchedAt: Date()
        )
    }
}

struct AccountGatedUsageProvider: UsageProvider {
    let providerID: ProviderID
    let gates: [String: UsageProviderGate]
    let recorder: UsageProviderRecorder

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        await recorder.record(configuration.accountLabel)
        if let gate = gates[configuration.id] {
            await gate.wait()
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Fresh usage",
            bars: [],
            fetchedAt: Date()
        )
    }
}

enum TestUsageProviderError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Refresh failed"
    }
}

struct SelectivelyFailingUsageProvider: UsageProvider {
    let providerID: ProviderID
    let failedAccountID: String

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        if configuration.id == failedAccountID {
            throw TestUsageProviderError.failed
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Fresh usage",
            bars: [],
            fetchedAt: Date()
        )
    }
}

struct ReturningFailureUsageProvider: UsageProvider {
    let providerID: ProviderID
    var allowsUnscopedCacheReuse = false

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Credential expired",
            bars: [],
            failureMessage: "Credential expired",
            allowsUnscopedCacheReuse: allowsUnscopedCacheReuse,
            fetchedAt: Date()
        )
    }
}

struct ReturningPartialFailureUsageProvider: UsageProvider {
    let providerID: ProviderID
    var allowsUnscopedCacheReuse = false

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Partial refresh failed",
            bars: [UsageBar(label: "Latest usage", used: 25, limit: 100)],
            failureMessage: "Partial refresh failed",
            allowsUnscopedCacheReuse: allowsUnscopedCacheReuse,
            fetchedAt: Date()
        )
    }
}

actor ResetConsumptionTestProvider: CodexBankedResetConsuming {
    nonisolated let providerID = ProviderID.codex
    private let outcome: CodexBankedResetConsumptionOutcome
    private let fetchFails: Bool
    private let fetchedUsed: Double
    private let consumeGate: UsageProviderGate?
    private let consumeErrorCode: URLError.Code?
    private var fetchCount = 0
    private var consumedKeys: [String] = []
    private var consumedCreditIDs: [String?] = []

    init(
        outcome: CodexBankedResetConsumptionOutcome,
        fetchFails: Bool,
        fetchedUsed: Double = 0,
        consumeGate: UsageProviderGate? = nil,
        consumeErrorCode: URLError.Code? = nil
    ) {
        self.outcome = outcome
        self.fetchFails = fetchFails
        self.fetchedUsed = fetchedUsed
        self.consumeGate = consumeGate
        self.consumeErrorCode = consumeErrorCode
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        fetchCount += 1
        if fetchFails {
            throw TestUsageProviderError.failed
        }
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Fresh usage",
            bars: [UsageBar(label: "Usage", used: fetchedUsed, limit: 100)],
            fetchedAt: Date()
        )
    }

    func consumeBankedReset(
        for configuration: ProviderAccountConfiguration,
        creditID: String?,
        idempotencyKey: String
    ) async throws -> CodexBankedResetConsumptionOutcome {
        consumedKeys.append(idempotencyKey)
        consumedCreditIDs.append(creditID)
        if let consumeGate {
            await consumeGate.wait()
        }
        if let consumeErrorCode {
            throw URLError(consumeErrorCode)
        }
        return outcome
    }

    func recordedFetchCount() -> Int {
        fetchCount
    }

    func recordedConsumedKeys() -> [String] {
        consumedKeys
    }

    func recordedConsumedCreditIDs() -> [String?] {
        consumedCreditIDs
    }
}

@MainActor
final class StubUsageAlertNotifier: UsageAlertNotifying {
    func requestAuthorization() async -> Bool {
        true
    }

    func deliver(_ notification: UsageAlertNotification) async throws {}
}

@MainActor
final class RecordingUsageAlertNotifier: UsageAlertNotifying {
    private(set) var deliveredNotifications: [UsageAlertNotification] = []

    func requestAuthorization() async -> Bool {
        true
    }

    func deliver(_ notification: UsageAlertNotification) async throws {
        deliveredNotifications.append(notification)
    }
}

extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

extension String {
    func base64URLEncodedForTest() -> String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class StalledCursorRequestEvents: @unchecked Sendable {
    enum Event {
        case primaryCompleted, optionalStarted, timeoutStarted, timeoutFired, optionalCancelled, fetchReturned
    }

    let primaryCompleted = TestSignal()
    let optionalStarted = TestSignal()
    let optionalCancelled = TestSignal()
    private let lock = NSLock()
    private var events: [Event] = []

    var recorded: [Event] { lock.withLock { events } }

    func record(_ event: Event) {
        lock.withLock { events.append(event) }
        switch event {
        case .primaryCompleted: primaryCompleted.signal()
        case .optionalStarted: optionalStarted.signal()
        case .optionalCancelled: optionalCancelled.signal()
        default: break
        }
    }
}

final class StalledCursorTaskObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    var optionalTask: URLSessionTask? { lock.withLock { task } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        if task.originalRequest?.url?.lastPathComponent == "GetSandUsageStatus" {
            lock.withLock { self.task = task }
        }
    }

}

final class StalledCursorGrokBotURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [String: StalledCursorRequestEvents] = [:]

    static func register(_ events: StalledCursorRequestEvents, for host: String) {
        lock.withLock { requests[host] = events }
    }

    static func unregister(host: String) {
        _ = lock.withLock { requests.removeValue(forKey: host) }
    }

    private var events: StalledCursorRequestEvents? {
        Self.lock.withLock { Self.requests[request.url?.host ?? ""] }
    }

    // URLProtocol requires overridable class methods.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    // URLProtocol requires overridable class methods.
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let events else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if request.url?.lastPathComponent == "full_stripe_profile" {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        guard request.url?.lastPathComponent == "GetCurrentPeriodUsage" else {
            events.record(.optionalStarted)
            return
        }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"planUsage":{"autoPercentUsed":25,"apiPercentUsed":5}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
        events.record(.primaryCompleted)
    }

    override func stopLoading() {
        if request.url?.lastPathComponent == "GetSandUsageStatus" {
            events?.record(.optionalCancelled)
        }
    }
}
