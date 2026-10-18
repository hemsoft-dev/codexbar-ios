import Combine
import Foundation
import OSLog
import WatchConnectivity
import WidgetKit

enum WatchConnectivityDelegateEvent: Sendable {
    case activation(
        sequence: UInt64,
        activationState: WCSessionActivationState,
        applicationContext: WatchDashboardApplicationContext,
        isPhoneReachable: Bool,
        hadError: Bool
    )
    case applicationContext(
        sequence: UInt64,
        applicationContext: WatchDashboardApplicationContext
    )
    case reachability(sequence: UInt64, isPhoneReachable: Bool)
    case userInfoTransferFinished(
        sequence: UInt64,
        wasSnapshotRequest: Bool,
        failed: Bool,
        hasOtherOutstandingSnapshotRequest: Bool
    )

    var sequence: UInt64 {
        switch self {
        case let .activation(sequence, _, _, _, _),
             let .applicationContext(sequence, _),
             let .reachability(sequence, _),
             let .userInfoTransferFinished(sequence, _, _, _):
            sequence
        }
    }
}

// `nextSequence` is accessed only under `lock`. `nextEvent` also invokes its
// nonescaping factory while holding that lock, making extraction and sequence
// assignment atomic without allowing a non-Sendable callback value to escape.
private final class WatchConnectivityEventSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0

    func nextEvent(
        _ makeEvent: (UInt64) -> WatchConnectivityDelegateEvent
    ) -> WatchConnectivityDelegateEvent {
        lock.lock()
        defer { lock.unlock() }
        defer { nextSequence &+= 1 }
        return makeEvent(nextSequence)
    }
}

enum WatchSnapshotRequestFailure: Equatable, Sendable {
    case sessionInactive
    case phoneUnreachable
    case timedOut
    case pairingUnavailable
    case deliveryFailed

    init(_ error: Error) {
        let nsError = error as NSError
        guard nsError.domain == WCErrorDomain,
              let code = WCError.Code(rawValue: nsError.code)
        else {
            self = .deliveryFailed
            return
        }
        switch code {
        case .sessionNotActivated:
            self = .sessionInactive
        case .notReachable:
            self = .phoneUnreachable
        case .messageReplyTimedOut, .transferTimedOut:
            self = .timedOut
        case .deviceNotPaired, .companionAppNotInstalled, .watchAppNotInstalled:
            self = .pairingUnavailable
        default:
            self = .deliveryFailed
        }
    }

    var recoveryMessage: String {
        switch self {
        case .sessionInactive:
            "Connecting to iPhone. Keep CodexBar open on both devices"
        case .phoneUnreachable:
            "iPhone unavailable. Open CodexBar there; update queued"
        case .timedOut:
            "iPhone did not respond. Open CodexBar there; update queued"
        case .pairingUnavailable:
            "Install and open CodexBar on the paired iPhone"
        case .deliveryFailed:
            "Update queued. Open CodexBar on iPhone to finish"
        }
    }
}

private struct WatchOrderingRecoverySignature: Equatable {
    let sequence: UInt64
    let semanticData: Data
}

@MainActor
struct WatchAccessTiming {
    typealias Scheduler = (Date, @escaping @MainActor @Sendable () -> Void) -> AnyCancellable
    let now: () -> Date
    let schedule: Scheduler
    let sample: () -> ProEntitlementClockSample

    init(now: @escaping () -> Date, schedule: @escaping Scheduler, sample: (() -> ProEntitlementClockSample)? = nil) {
        self.now = now
        self.schedule = schedule
        self.sample = sample ?? { ProEntitlementSystemClock.sample(at: now()) }
    }

    static var live: WatchAccessTiming {
        live(clock: ContinuousClock(), now: { Date() })
    }

    static func live<C: Clock>(
        clock: C, now: @escaping () -> Date, sample: (() -> ProEntitlementClockSample)? = nil
    ) -> WatchAccessTiming where C.Duration == Duration {
        WatchAccessTiming(now: now, schedule: { deadline, action in
            let delay = max(0, deadline.timeIntervalSince(now()))
            let boundary = clock.now.advanced(by: .seconds(delay))
            let task = Task { @MainActor in
                do {
                    try await clock.sleep(until: boundary, tolerance: .zero)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                action()
            }
            return AnyCancellable { task.cancel() }
        }, sample: sample)
    }
}

@MainActor
final class WatchDashboardStore: NSObject, ObservableObject {
    typealias SnapshotRequester = (
        @escaping @MainActor (WatchDashboardSnapshotResponse) -> Void,
        @escaping @MainActor (WatchSnapshotRequestFailure) -> Void
    ) -> Void
    typealias SequencedSnapshotRequester = (
        UInt64?,
        @escaping @MainActor (WatchDashboardSnapshotResponse) -> Void,
        @escaping @MainActor (WatchSnapshotRequestFailure) -> Void
    ) -> Void
    typealias SnapshotRequestQueuer = () -> Void
    typealias OutstandingSnapshotRequestProvider = () -> Bool

    private static let logger = Logger(
        subsystem: "com.hemsoft.CodexBarIOS",
        category: "WatchConnectivity.Watch"
    )
    private var sourceSnapshot: WatchDashboardSnapshot?
    private var pendingAccessPublication: WatchAccessPublication?
    @Published private(set) var snapshot: WatchDashboardSnapshot?
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var decodingError: String?

    private static let persistedSnapshotKey = "watch.dashboard.last-good-snapshot"

    private let defaults: UserDefaults
    private let complicationStore: WatchComplicationSnapshotStore
    private let reloadComplications: () -> Void
    private let session: WCSession?
    private let requestSnapshot: SequencedSnapshotRequester?
    private let queueSnapshotRequest: ((UInt64?) -> Void)?
    private let hasOutstandingSnapshotRequest: OutstandingSnapshotRequestProvider
    private let requestCoalescingDelay: Duration
    private let accessTiming: WatchAccessTiming
    private var orderingRecoverySignatures: [WatchOrderingRecoverySignature] = []
    private var accessBoundaryCancellation: AnyCancellable?
    private var scheduledAccessDeadline: Date?
    private var scheduledAccessSample: ProEntitlementClockSample?
    private var activationState: WCSessionActivationState
    nonisolated private let delegateEventSequencer = WatchConnectivityEventSequencer()
    private var nextDelegateEventSequence: UInt64 = 0
    private var pendingDelegateEvents: [UInt64: WatchConnectivityDelegateEvent] = [:]
    private var snapshotRequestTask: Task<Void, Never>?
    private var hasQueuedSnapshotRequest = false
    private var nextSnapshotRequestID: UInt64 = 0
    private var activeSnapshotRequestID: UInt64?

    init(
        defaults: UserDefaults = .standard,
        complicationStore: WatchComplicationSnapshotStore = WatchComplicationSnapshotStore(),
        reloadComplications: @escaping () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationConstants.widgetKind)
        },
        session: WCSession? = WCSession.isSupported() ? .default : nil,
        requestSnapshot: SnapshotRequester? = nil,
        queueSnapshotRequest: SnapshotRequestQueuer? = nil,
        hasOutstandingSnapshotRequest: OutstandingSnapshotRequestProvider? = nil,
        initialActivationState: WCSessionActivationState? = nil,
        requestCoalescingDelay: Duration = .milliseconds(100),
        accessTiming: WatchAccessTiming? = nil,
        requestSnapshotAfterSequence: SequencedSnapshotRequester? = nil
    ) {
        self.defaults = defaults
        self.complicationStore = complicationStore
        self.reloadComplications = reloadComplications
        self.session = session
        self.requestCoalescingDelay = requestCoalescingDelay
        self.accessTiming = accessTiming ?? .live
        if let hasOutstandingSnapshotRequest {
            self.hasOutstandingSnapshotRequest = hasOutstandingSnapshotRequest
        } else if let session {
            self.hasOutstandingSnapshotRequest = {
                session.outstandingUserInfoTransfers.contains {
                    WatchDashboardSnapshot.isSnapshotRequest($0.userInfo)
                }
            }
        } else {
            self.hasOutstandingSnapshotRequest = { false }
        }
        hasQueuedSnapshotRequest = self.hasOutstandingSnapshotRequest()
        activationState = initialActivationState
            ?? session?.activationState
            ?? (requestSnapshot == nil && requestSnapshotAfterSequence == nil ? .notActivated : .activated)
        if let requestSnapshotAfterSequence {
            self.requestSnapshot = requestSnapshotAfterSequence
        } else if let requestSnapshot {
            self.requestSnapshot = { _, reply, failure in requestSnapshot(reply, failure) }
        } else if let session {
            self.requestSnapshot = { sequence, replyHandler, errorHandler in
                session.sendMessage(
                    WatchDashboardSnapshot.snapshotRequestMessage(after: sequence),
                    replyHandler: { reply in
                        let response = WatchDashboardSnapshotResponse(reply)
                        Task { @MainActor in
                            replyHandler(response)
                        }
                    },
                    errorHandler: { error in
                        let failure = WatchSnapshotRequestFailure(error)
                        Task { @MainActor in
                            errorHandler(failure)
                        }
                    }
                )
            }
        } else {
            self.requestSnapshot = nil
        }
        if let queueSnapshotRequest {
            self.queueSnapshotRequest = { _ in queueSnapshotRequest() }
        } else if let session {
            self.queueSnapshotRequest = { sequence in
                session.transferUserInfo(WatchDashboardSnapshot.snapshotRequestMessage(after: sequence))
            }
        } else {
            self.queueSnapshotRequest = nil
        }
        let legacyData = defaults.data(forKey: Self.persistedSnapshotKey)
        let legacySnapshot = legacyData.flatMap { try? WatchDashboardSnapshot.decode($0) }
        let sharedSnapshot = complicationStore.load()
        let selected: WatchDashboardSnapshot?
        if let legacySnapshot, sharedSnapshot.map({ legacySnapshot.isNewer(than: $0) }) ?? true {
            selected = legacySnapshot
        } else {
            selected = sharedSnapshot
        }
        sourceSnapshot = selected
        snapshot = selected
        var migratedSnapshotNeedsReload = false
        if let selected, let encoded = try? selected.encoded() {
            let sample = self.accessTiming.sample()
            let origin = WatchAccessPublication(selected, sample: sample)
            let publication = try? complicationStore.publish(selected, encodedData: encoded, sample: sample, origin: origin)
            migratedSnapshotNeedsReload = publication?.changed == true
            pendingAccessPublication = publication?.accessInstalled == true ? nil : origin
            if legacySnapshot != selected { defaults.set(encoded, forKey: Self.persistedSnapshotKey) }
        }
        super.init()
        reevaluateAccess(retryPending: false)

        if migratedSnapshotNeedsReload {
            reloadComplications()
        }

        guard let session else { return }
        session.delegate = self
        isPhoneReachable = session.isReachable
        Self.logger.info(
            "Starting Watch session state=\(session.activationState.rawValue, privacy: .public) reachable=\(session.isReachable, privacy: .public)"
        )
        session.activate()
        if !session.receivedApplicationContext.isEmpty {
            receive(session.receivedApplicationContext)
        }
    }

    func state(at date: Date = Date()) -> WatchDashboardState {
        let current = sourceSnapshot.map { complicationStore.accessDecision(for: $0, sample: accessTiming.sample()).snapshot }
        return WatchDashboardState(
            snapshot: current,
            now: date,
            isPhoneReachable: isPhoneReachable,
            decodingError: decodingError
        )
    }

    @discardableResult
    func receive(_ applicationContext: [String: Any]) -> Bool {
        receive(WatchDashboardApplicationContext(applicationContext))
    }

    @discardableResult
    func receive(_ applicationContext: WatchDashboardApplicationContext) -> Bool {
        do {
            let decoded = try applicationContext.decode()
            guard sourceSnapshot.map({ decoded == $0 || decoded.isNewer(than: $0) }) ?? true else {
                Self.logger.notice("Ignored older snapshot delivery")
                requestOrderingRecovery(afterRejecting: decoded)
                return false
            }
            let encoded = try decoded.encoded()
            let sample = accessTiming.sample()
            let origin = WatchAccessPublication(decoded, sample: sample, previous: pendingAccessPublication)
            let publication = try complicationStore.publish(
                decoded,
                encodedData: encoded,
                sample: sample, origin: origin
            )
            defaults.set(encoded, forKey: Self.persistedSnapshotKey)
            sourceSnapshot = decoded
            pendingAccessPublication = publication.accessInstalled ? nil : origin
            reevaluateAccess(retryPending: false)
            decodingError = nil
            activeSnapshotRequestID = nil
            hasQueuedSnapshotRequest = hasOutstandingSnapshotRequest()
            if publication.changed {
                reloadComplications()
            }
            return true
        } catch {
            decodingError = "Couldn’t read the latest iPhone update"
            Self.logger.error(
                "Snapshot context decode failed domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)"
            )
            return false
        }
    }

    // A temporary denial is a display decision, never a persisted phone payload or expiry receipt.
    func reevaluateAccess() {
        reevaluateAccess(retryPending: true)
    }

    private func reevaluateAccess(retryPending: Bool) {
        guard let sourceSnapshot else { return }
        let wasLocked = snapshot?.isProLocked == true
        let sample = accessTiming.sample()
        // Retry only the accepted pending payload, once per foreground reevaluation, using its original clock evidence.
        if retryPending, pendingAccessPublication != nil {
            let origin = WatchAccessPublication(sourceSnapshot, sample: sample, previous: pendingAccessPublication)
            let installed = complicationStore.installAccess(for: sourceSnapshot, sample: sample, origin: origin)
            pendingAccessPublication = installed ? nil : origin
        }
        let decision = complicationStore.accessDecision(for: sourceSnapshot, sample: sample)
        if decision.hasExpired {
            lockExpiredSnapshot(sourceSnapshot)
            return
        }
        snapshot = decision.snapshot
        if retryPending, wasLocked, !decision.isLocked { reloadComplications() }
        if !decision.isLocked, sourceSnapshot.proAccessEndsAt == scheduledAccessDeadline,
           let remaining = decision.remaining, let scheduled = scheduledAccessSample,
           let continuityID = sample.continuityID, continuityID == scheduled.continuityID,
           scheduled.continuousSeconds <= sample.continuousSeconds + remaining,
           accessBoundaryCancellation != nil { return }
        accessBoundaryCancellation?.cancel()
        accessBoundaryCancellation = nil
        scheduledAccessDeadline = nil
        scheduledAccessSample = nil
        guard let deadline = sourceSnapshot.proAccessEndsAt, let remaining = decision.remaining else { return }
        scheduledAccessDeadline = deadline
        scheduledAccessSample = ProEntitlementClockSample(
            wallDate: sample.wallDate, continuousSeconds: sample.continuousSeconds + remaining,
            continuityID: sample.continuityID
        )
        let projectedBoundary = sample.wallDate.addingTimeInterval(remaining)
        accessBoundaryCancellation = accessTiming.schedule(projectedBoundary) { [weak self] in
            guard let self, let current = self.sourceSnapshot, !current.isProLocked,
                  current.proAccessEndsAt == deadline else { return }
            self.lockExpiredSnapshot(current)
        }
    }

    private func lockExpiredSnapshot(_ snapshot: WatchDashboardSnapshot) {
        accessBoundaryCancellation?.cancel()
        accessBoundaryCancellation = nil
        scheduledAccessDeadline = nil
        scheduledAccessSample = nil
        let locked = snapshot.lockingAccess()
        sourceSnapshot = locked
        self.snapshot = locked
        if let deadline = snapshot.proAccessEndsAt { complicationStore.recordExpiration(deadline) }
        if let encoded = try? locked.encoded() {
            defaults.set(encoded, forKey: Self.persistedSnapshotKey)
            let sample = accessTiming.sample()
            let origin = WatchAccessPublication(locked, sample: sample, previous: pendingAccessPublication)
            let publication = try? complicationStore.publish(locked, encodedData: encoded, sample: sample, origin: origin)
            pendingAccessPublication = publication?.accessInstalled == true ? nil : origin
            if publication?.changed == true { reloadComplications() }
        }
    }

    private func requestOrderingRecovery(afterRejecting rejected: WatchDashboardSnapshot) {
        guard let current = snapshot?.publicationSequence,
              let rejectedSequence = rejected.publicationSequence, rejectedSequence <= current,
              let semanticData = try? rejected.semanticData() else { return }
        let signature = WatchOrderingRecoverySignature(sequence: rejectedSequence, semanticData: semanticData)
        guard !orderingRecoverySignatures.contains(signature) else { return }
        orderingRecoverySignatures.append(signature)
        if orderingRecoverySignatures.count > 16 {
            orderingRecoverySignatures.removeFirst()
        }
        scheduleCurrentSnapshotRequest()
    }

    func updateReachability(_ isReachable: Bool) {
        let becameReachable = !isPhoneReachable && isReachable
        isPhoneReachable = isReachable
        if becameReachable {
            scheduleCurrentSnapshotRequest()
        }
    }

    func activationCompleted(
        activationState: WCSessionActivationState,
        applicationContext: WatchDashboardApplicationContext,
        isPhoneReachable: Bool,
        hadError: Bool
    ) {
        self.activationState = activationState
        self.isPhoneReachable = isPhoneReachable
        Self.logger.info(
            "Activation completed state=\(activationState.rawValue, privacy: .public) reachable=\(isPhoneReachable, privacy: .public) hadError=\(hadError, privacy: .public)"
        )
        if !applicationContext.isEmpty {
            receive(applicationContext)
        } else if hadError || activationState != .activated, snapshot == nil {
            decodingError = WatchSnapshotRequestFailure.sessionInactive.recoveryMessage
        }
        if !hadError, activationState == .activated {
            scheduleCurrentSnapshotRequest()
        }
    }

    func receiveDelegateEvent(_ event: WatchConnectivityDelegateEvent) {
        guard event.sequence >= nextDelegateEventSequence else { return }
        pendingDelegateEvents[event.sequence] = event
        while let nextEvent = pendingDelegateEvents.removeValue(
            forKey: nextDelegateEventSequence
        ) {
            nextDelegateEventSequence &+= 1
            switch nextEvent {
            case let .activation(
                _,
                activationState,
                applicationContext,
                isPhoneReachable,
                hadError
            ):
                activationCompleted(
                    activationState: activationState,
                    applicationContext: applicationContext,
                    isPhoneReachable: isPhoneReachable,
                    hadError: hadError
                )
            case let .applicationContext(_, applicationContext):
                receive(applicationContext)
            case let .reachability(_, isPhoneReachable):
                updateReachability(isPhoneReachable)
            case let .userInfoTransferFinished(
                _,
                wasSnapshotRequest,
                failed,
                hasOtherOutstandingSnapshotRequest
            ):
                guard wasSnapshotRequest else { break }
                hasQueuedSnapshotRequest = hasOtherOutstandingSnapshotRequest
                Self.logger.notice(
                    "Queued snapshot transfer completed failed=\(failed, privacy: .public) remainingRequest=\(hasOtherOutstandingSnapshotRequest, privacy: .public)"
                )
            }
        }
    }

    func scheduleCurrentSnapshotRequest() {
        snapshotRequestTask?.cancel()
        let delay = requestCoalescingDelay
        snapshotRequestTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.requestCurrentSnapshot()
        }
    }

    func requestCurrentSnapshot() {
        let requestID = nextSnapshotRequestID
        nextSnapshotRequestID &+= 1
        activeSnapshotRequestID = requestID
        guard activationState == .activated else {
            activeSnapshotRequestID = nil
            decodingError = WatchSnapshotRequestFailure.sessionInactive.recoveryMessage
            Self.logger.notice("Snapshot request deferred because session is not activated")
            session?.activate()
            return
        }
        guard isPhoneReachable else {
            activeSnapshotRequestID = nil
            queueSnapshotRequest(failure: .phoneUnreachable)
            return
        }
        guard let requestSnapshot else {
            activeSnapshotRequestID = nil
            queueSnapshotRequest(failure: .deliveryFailed)
            return
        }
        Self.logger.info("Requesting immediate snapshot from reachable iPhone")
        requestSnapshot(
            snapshot?.publicationSequence,
            { [weak self] response in
                self?.receiveSnapshotResponse(response, requestID: requestID)
            },
            { [weak self] failure in
                self?.receiveSnapshotRequestFailure(failure, requestID: requestID)
            }
        )
    }

    private func receiveSnapshotResponse(
        _ response: WatchDashboardSnapshotResponse,
        requestID: UInt64
    ) {
        guard activeSnapshotRequestID == requestID else {
            Self.logger.notice("Ignored superseded snapshot response")
            return
        }
        activeSnapshotRequestID = nil
        switch response {
        case let .snapshot(data):
            if receive(.snapshot(data)) {
                Self.logger.info("Received immediate snapshot reply from iPhone")
            }
        case .unavailable:
            decodingError = "No dashboard update is available yet. Refresh CodexBar on iPhone"
            Self.logger.notice("iPhone replied without an available dashboard snapshot")
        case .malformed:
            decodingError = "Couldn’t read the iPhone update. Refresh CodexBar on iPhone"
            Self.logger.error("iPhone returned a malformed snapshot reply")
        }
    }

    private func receiveSnapshotRequestFailure(
        _ failure: WatchSnapshotRequestFailure,
        requestID: UInt64
    ) {
        guard activeSnapshotRequestID == requestID else {
            Self.logger.notice("Ignored superseded snapshot request failure")
            return
        }
        activeSnapshotRequestID = nil
        queueSnapshotRequest(failure: failure)
    }

    private func queueSnapshotRequest(failure: WatchSnapshotRequestFailure) {
        if failure != .pairingUnavailable,
           !hasQueuedSnapshotRequest,
           let queueSnapshotRequest {
            queueSnapshotRequest(snapshot?.publicationSequence)
            hasQueuedSnapshotRequest = true
        }
        decodingError = failure.recoveryMessage
        Self.logger.notice(
            "Snapshot request recovery reason=\(String(describing: failure), privacy: .public) queued=\(self.hasQueuedSnapshotRequest, privacy: .public)"
        )
    }

    deinit {
        snapshotRequestTask?.cancel()
    }
}

extension WatchDashboardStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let event = delegateEventSequencer.nextEvent { sequence in
            WatchConnectivityDelegateEvent.activation(
                sequence: sequence,
                activationState: activationState,
                applicationContext: WatchDashboardApplicationContext(
                    session.receivedApplicationContext
                ),
                isPhoneReachable: session.isReachable,
                hadError: error != nil
            )
        }
        Task { @MainActor [weak self] in
            self?.receiveDelegateEvent(event)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let event = delegateEventSequencer.nextEvent { sequence in
            WatchConnectivityDelegateEvent.applicationContext(
                sequence: sequence,
                applicationContext: WatchDashboardApplicationContext(applicationContext)
            )
        }
        Task { @MainActor [weak self] in
            self?.receiveDelegateEvent(event)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let event = delegateEventSequencer.nextEvent { sequence in
            WatchConnectivityDelegateEvent.reachability(
                sequence: sequence,
                isPhoneReachable: session.isReachable
            )
        }
        Task { @MainActor [weak self] in
            self?.receiveDelegateEvent(event)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        let event = delegateEventSequencer.nextEvent { sequence in
            WatchConnectivityDelegateEvent.userInfoTransferFinished(
                sequence: sequence,
                wasSnapshotRequest: WatchDashboardSnapshot.isSnapshotRequest(
                    userInfoTransfer.userInfo
                ),
                failed: error != nil,
                hasOtherOutstandingSnapshotRequest:
                    session.outstandingUserInfoTransfers.contains {
                        $0 !== userInfoTransfer
                            && WatchDashboardSnapshot.isSnapshotRequest($0.userInfo)
                    }
            )
        }
        Task { @MainActor [weak self] in
            self?.receiveDelegateEvent(event)
        }
    }
}
