import Foundation

/// Transient provider grants. Never include grant identifiers in snapshots or diagnostics.
public struct ClaudeUsageResetGrant: Equatable, Sendable {
    public let id: String
    public let title: String
    public let remainingCount: Int
    public let startsAt: Date?
    public let expiresAt: Date?
    public let clears: [String]
    public let isPaused: Bool
    public let isUsableNow: Bool
    public let requiresLimit: Bool

    public func isCurrent(at date: Date) -> Bool {
        remainingCount > 0 && !isPaused
            && (startsAt.map { $0 <= date } ?? true)
            && (expiresAt.map { $0 > date } ?? true)
    }

    /// What one reset restores, from the windows Claude lists in `clears`. An identifier this app does
    /// not know keeps the general wording, so the sheet never names an effect Claude did not report.
    public var restorationDescription: String {
        let windows = clears.map { value in
            switch value {
            case "five_hour": "five-hour usage"
            case "seven_day": "weekly usage"
            case "seven_day_opus": "Opus weekly usage"
            case "seven_day_sonnet": "Sonnet weekly usage"
            case "seven_day_overage_included": "Fable weekly usage"
            default: "provider-scoped usage"
            }
        }
        return "Resets \(Array(Set(windows)).sorted().joined(separator: " and "))."
    }
}

public struct ClaudeUsageResetInventory: Equatable, Sendable {
    public let isEligible: Bool
    public let grants: [ClaudeUsageResetGrant]
    public let selectedGrantID: String?
    public let cooldownUntil: Date?
    public let credentialBinding: String?
    /// Claude's stated reason when the account is not eligible, kept only for that case.
    public let ineligibilityReason: String?

    public init(isEligible: Bool, grants: [ClaudeUsageResetGrant], selectedGrantID: String?,
                cooldownUntil: Date?, credentialBinding: String? = nil, ineligibilityReason: String? = nil) {
        self.isEligible = isEligible
        self.grants = grants
        self.selectedGrantID = selectedGrantID
        self.cooldownUntil = cooldownUntil
        self.credentialBinding = credentialBinding
        self.ineligibilityReason = isEligible ? nil : ineligibilityReason
    }

    public func bound(toAccessToken token: String) -> Self {
        Self(isEligible: isEligible, grants: grants, selectedGrantID: selectedGrantID,
             cooldownUntil: cooldownUntil, credentialBinding: ClaudeUsageResetClient.credentialBinding(for: token),
             ineligibilityReason: ineligibilityReason)
    }

    /// Claude answered "not eligible" with the reason `surface`. Public reports tie that reason to
    /// the client making the request, not to the account, so it is shown as "not offered to
    /// CodexBar" instead of an empty balance. That reading is unverified (#589).
    public var isUnavailableInThisApp: Bool {
        !isEligible && ineligibilityReason == "surface"
    }

    public func availableCount(at date: Date) -> Int {
        guard isEligible else { return 0 }
        return grants.filter { $0.isCurrent(at: date) }.reduce(0) { $0 + $1.remainingCount }
    }

    public func matchesConfirmation(grant: ClaudeUsageResetGrant, binding: String, at date: Date) -> Bool {
        credentialBinding == binding && redeemableGrants(at: date).contains(grant)
    }

    /// The reset Claude lists as next, when it can be used now.
    public func redeemableGrant(at date: Date) -> ClaudeUsageResetGrant? {
        redeemableGrants(at: date).first { $0.id == selectedGrantID }
    }

    /// Every saved reset Claude marks usable now, so a Fable reset and a weekly reset stay separate
    /// choices. Claude can still decline one it does not want used first.
    public func redeemableGrants(at date: Date) -> [ClaudeUsageResetGrant] {
        guard isEligible, cooldownUntil.map({ $0 <= date }) ?? true else { return [] }
        return grants.filter { $0.isUsableNow && $0.isCurrent(at: date) }
    }
}

public enum ClaudeUsageResetInventoryParser {
    /// Missing, malformed and unsupported responses remain unknown, never a claimed zero balance.
    public static func parse(_ data: Data) -> ClaudeUsageResetInventory? {
        guard data.count <= 1_048_576,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = envelope.inventory,
              !payload.eligible || payload.grants != nil,
              (payload.grants?.count ?? 0) <= 200
        else { return nil }
        do {
            let grants = try (payload.grants ?? []).map(makeGrant)
            guard Set(grants.map(\.id)).count == grants.count else { return nil }
            if let selected = payload.nextGrantID, !validIdentifier(selected, maximumLength: 40) { return nil }
            return try ClaudeUsageResetInventory(
                isEligible: payload.eligible,
                grants: grants,
                selectedGrantID: payload.nextGrantID,
                cooldownUntil: date(payload.cooldownUntil),
                ineligibilityReason: payload.ineligibleReason.flatMap { validIdentifier($0, maximumLength: 40) ? $0 : nil }
            )
        } catch {
            return nil
        }
    }

    private static func makeGrant(_ raw: Grant) throws -> ClaudeUsageResetGrant {
        guard validIdentifier(raw.id, maximumLength: 40), (0...1_000).contains(raw.resetsLeft),
              !raw.clears.isEmpty, raw.clears.count <= 50,
              raw.clears.allSatisfy({ validIdentifier($0, maximumLength: 80) })
        else { throw InvalidPayload.malformed }
        let label = raw.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (label?.count ?? 0) <= 120 else { throw InvalidPayload.malformed }
        let start = try date(raw.startsAt)
        let end = try date(raw.endsAt)
        if let start, let end, start >= end { throw InvalidPayload.malformed }
        return ClaudeUsageResetGrant(
            id: raw.id,
            title: label.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude usage reset",
            remainingCount: raw.resetsLeft,
            startsAt: start,
            expiresAt: end,
            clears: Array(Set(raw.clears)).sorted(),
            isPaused: raw.paused ?? false,
            isUsableNow: raw.usableNow ?? false,
            requiresLimit: raw.useRequiresLimit ?? true
        )
    }

    private static func validIdentifier(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }
    }

    private static func date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let parsed = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            throw InvalidPayload.malformed
        }
        return parsed
    }

    private enum InvalidPayload: Error { case malformed }

    private struct Envelope: Decodable {
        let inventory: Inventory?
        enum CodingKeys: String, CodingKey { case inventory = "cedar_ember" }
    }

    private struct Inventory: Decodable {
        let eligible: Bool
        let grants: [Grant]?
        let nextGrantID: String?
        let cooldownUntil: String?
        let ineligibleReason: String?
        enum CodingKeys: String, CodingKey {
            case eligible, grants
            case nextGrantID = "next_grant_id"
            case cooldownUntil = "cooldown_until"
            case ineligibleReason = "ineligible_reason"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            eligible = try container.decode(Bool.self, forKey: .eligible)
            grants = try container.decodeIfPresent([Grant].self, forKey: .grants)
            nextGrantID = try container.decodeIfPresent(String.self, forKey: .nextGrantID)
            cooldownUntil = try container.decodeIfPresent(String.self, forKey: .cooldownUntil)
            // Optional wording only: a malformed reason never makes the inventory unknown.
            ineligibleReason = try? container.decodeIfPresent(String.self, forKey: .ineligibleReason)
        }
    }

    private struct Grant: Decodable {
        let id: String
        let label: String?
        let resetsLeft: Int
        let startsAt: String?
        let endsAt: String?
        let clears: [String]
        let paused: Bool?
        let usableNow: Bool?
        let useRequiresLimit: Bool?
        enum CodingKeys: String, CodingKey {
            case id, label, clears, paused
            case resetsLeft = "resets_left"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
            case usableNow = "usable_now"
            case useRequiresLimit = "use_requires_limit"
        }
    }
}
