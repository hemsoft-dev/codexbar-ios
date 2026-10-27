import Foundation

public struct ProviderAccountConfiguration: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let providerID: ProviderID
    public var isEnabled: Bool
    public var accountLabel: String
    /// Last automatically generated Grok label. A different label belongs to the user.
    public var grokGeneratedLabel: String?
    public var groupID: String?
    public var showsHistory: Bool
    public var authMethod: ProviderAuthMethod
    public var oauthClientID: String?
    /// A subject supplied by a verified Google identity response, never an account label.
    public var verifiedGoogleSubject: String?
    public var copilotAccountScope: CopilotAccountScope
    public var githubOrganization: String
    public var githubEnterprise: String
    public var copilotTotalAllotment: Double?
    public var githubBillingAccountScope: GitHubBillingAccountScope
    public var githubBillingOwner: String
    public var openCodeWorkspaceId: String

    public init(
        id: String? = nil,
        providerID: ProviderID,
        isEnabled: Bool = true,
        accountLabel: String = "",
        grokGeneratedLabel: String? = nil,
        groupID: String? = nil,
        showsHistory: Bool = true,
        authMethod: ProviderAuthMethod,
        oauthClientID: String? = nil,
        verifiedGoogleSubject: String? = nil,
        copilotAccountScope: CopilotAccountScope = .personal,
        githubOrganization: String = "",
        githubEnterprise: String = "",
        copilotTotalAllotment: Double? = nil,
        githubBillingAccountScope: GitHubBillingAccountScope = .personal,
        githubBillingOwner: String = "",
        openCodeWorkspaceId: String = ""
    ) {
        self.id = id ?? providerID.rawValue
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.accountLabel = accountLabel
        self.grokGeneratedLabel = grokGeneratedLabel
        self.groupID = groupID
        self.showsHistory = showsHistory
        self.authMethod = authMethod
        self.oauthClientID = oauthClientID
        self.verifiedGoogleSubject = verifiedGoogleSubject
        self.copilotAccountScope = copilotAccountScope
        self.githubOrganization = githubOrganization
        self.githubEnterprise = githubEnterprise
        self.copilotTotalAllotment = copilotTotalAllotment
        self.githubBillingAccountScope = githubBillingAccountScope
        self.githubBillingOwner = githubBillingOwner
        self.openCodeWorkspaceId = openCodeWorkspaceId
    }

    public var requiresSecret: Bool {
        authMethod.requiresSecret
    }

    public var displayName: String {
        let label = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if
            providerID == .openCodeZen,
            let generatedDisplayName = normalizedOpenCodeGeneratedDisplayName(label) {
            return generatedDisplayName
        }
        return label.isEmpty ? providerID.displayName : label
    }

    public func openCodeDisplayName(
        hasGoUsage: Bool,
        hasZenBalance: Bool
    ) -> String {
        let label = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isCustomAccountLabel(label) else {
            return label
        }

        switch (hasGoUsage, hasZenBalance) {
        case (true, true):
            return "OpenCode Go + Zen"
        case (true, false):
            return "OpenCode Go"
        case (false, true):
            return "OpenCode Zen"
        case (false, false):
            return providerID.displayName
        }
    }

    public var hasCustomAccountLabel: Bool {
        isCustomAccountLabel(
            accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func isCustomAccountLabel(_ label: String) -> Bool {
        guard !label.isEmpty else {
            return false
        }
        return providerID != .openCodeZen
            || normalizedOpenCodeGeneratedDisplayName(label) == nil
    }

    private func normalizedOpenCodeGeneratedDisplayName(_ label: String) -> String? {
        for base in ["OpenCode ZEN", "OpenCode Go + Zen"] {
            if label == base {
                return providerID.displayName
            }

            let prefix = "\(base) "
            guard label.hasPrefix(prefix) else {
                continue
            }
            let suffix = String(label.dropFirst(prefix.count))
            guard
                let accountNumber = Int(suffix),
                accountNumber > 0,
                suffix == String(accountNumber)
            else {
                continue
            }
            return "\(providerID.displayName) \(accountNumber)"
        }
        return nil
    }

    public func withNewAccountID() -> ProviderAccountConfiguration {
        ProviderAccountConfiguration(
            id: "\(providerID.rawValue).\(UUID().uuidString)",
            providerID: providerID,
            isEnabled: isEnabled,
            accountLabel: accountLabel,
            grokGeneratedLabel: grokGeneratedLabel,
            groupID: groupID,
            showsHistory: showsHistory,
            authMethod: authMethod,
            oauthClientID: oauthClientID,
            verifiedGoogleSubject: verifiedGoogleSubject,
            copilotAccountScope: copilotAccountScope,
            githubOrganization: githubOrganization,
            githubEnterprise: githubEnterprise,
            copilotTotalAllotment: copilotTotalAllotment,
            githubBillingAccountScope: githubBillingAccountScope,
            githubBillingOwner: githubBillingOwner,
            openCodeWorkspaceId: openCodeWorkspaceId
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case isEnabled
        case accountLabel
        case grokGeneratedLabel
        case groupID
        case showsHistory
        case authMethod
        case oauthClientID
        case verifiedGoogleSubject
        case copilotAccountScope
        case githubOrganization
        case githubEnterprise
        case copilotTotalAllotment
        case githubBillingAccountScope
        case githubBillingOwner
        case openCodeWorkspaceId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let providerID = try container.decode(ProviderID.self, forKey: .providerID)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? providerID.rawValue
        self.providerID = providerID
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel) ?? ""
        self.grokGeneratedLabel = try container.decodeIfPresent(String.self, forKey: .grokGeneratedLabel)
        self.groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        self.showsHistory = try container.decodeIfPresent(Bool.self, forKey: .showsHistory) ?? true
        self.authMethod = try container.decode(ProviderAuthMethod.self, forKey: .authMethod)
        self.verifiedGoogleSubject = try container.decodeIfPresent(String.self, forKey: .verifiedGoogleSubject)
        self.oauthClientID = try container.decodeIfPresent(String.self, forKey: .oauthClientID)
        self.copilotAccountScope = try container.decodeIfPresent(CopilotAccountScope.self, forKey: .copilotAccountScope) ?? .personal
        self.githubOrganization = try container.decodeIfPresent(String.self, forKey: .githubOrganization) ?? ""
        self.githubEnterprise = try container.decodeIfPresent(String.self, forKey: .githubEnterprise) ?? ""
        self.copilotTotalAllotment = try container.decodeIfPresent(Double.self, forKey: .copilotTotalAllotment)
        self.githubBillingAccountScope = try container.decodeIfPresent(
            GitHubBillingAccountScope.self,
            forKey: .githubBillingAccountScope
        ) ?? .personal
        self.githubBillingOwner = try container.decodeIfPresent(String.self, forKey: .githubBillingOwner) ?? ""
        self.openCodeWorkspaceId = try container.decodeIfPresent(String.self, forKey: .openCodeWorkspaceId) ?? ""
    }
}

public struct ProviderAccountGroup: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    public static let ungroupedDisplayName = "Ungrouped"
}

public enum GitHubBillingAccountScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case personal
    case organization

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .personal:
            "Personal account"
        case .organization:
            "Organization"
        }
    }
}

public enum CopilotAccountScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case personal
    case organization

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .personal:
            "Personal User"
        case .organization:
            "Organization"
        }
    }
}

public enum ProviderAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case apiKey
    case browserSession
    case cliToken

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .apiKey:
            "API Key"
        case .browserSession:
            "Browser Session"
        case .cliToken:
            "CLI Token"
        }
    }

    public var requiresSecret: Bool {
        switch self {
        case .apiKey, .cliToken:
            true
        case .browserSession:
            false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case "codexAuthJSON", "oauth":
            self = .browserSession
        default:
            guard let value = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown provider authentication method: \(rawValue)"
                )
            }
            self = value
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension ProviderAccountConfiguration {
    static func defaultConfiguration(for providerID: ProviderID) -> ProviderAccountConfiguration {
        switch providerID {
        case .codex:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        case .copilot:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        case .githubBilling:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        case .claude, .grok, .xSubscription:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        case .antigravity:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .cliToken)
        case .gemini:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        case .openRouter:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .apiKey)
        case .openCodeZen:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .apiKey)
        case .moonshot:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .apiKey)
        case .cursor:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        case .greptile, .museCode:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        }
    }
}
