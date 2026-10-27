import Foundation

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case copilot
    case githubBilling
    case claude
    case grok
    case xSubscription
    case openRouter
    case openCodeZen
    case moonshot
    case cursor
    case greptile
    case gemini
    case antigravity
    case museCode

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .codex:
            "ChatGPT / Codex"
        case .copilot:
            "GitHub Copilot"
        case .githubBilling:
            "GitHub Billing"
        case .claude:
            "Claude"
        case .grok:
            "Grok"
        case .xSubscription:
            "X Subscription"
        case .openRouter:
            "OpenRouter"
        case .openCodeZen:
            "OpenCode Go + Zen"
        case .moonshot:
            "Moonshot (Kimi)"
        case .cursor:
            "Cursor"
        case .greptile:
            "Greptile"
        case .gemini:
            "Google Gemini"
        case .antigravity:
            "Antigravity"
        case .museCode:
            "Muse Code"
        }
    }

    public var supportsPlanBadge: Bool {
        switch self {
        case .codex, .copilot, .githubBilling, .claude, .grok, .xSubscription, .museCode:
            true
        case .openRouter, .openCodeZen, .moonshot, .cursor, .greptile, .gemini, .antigravity:
            false
        }
    }

    /// Why this provider can't be connected on iPhone, or nil when it has a supported sign-in.
    /// Add Account names it with this reason; it can't be added, refreshed or hold an account slot (MUSE-CODE.md).
    public var phoneUnavailableReason: String? {
        self == .museCode ? MuseCodeAllowance.phoneAcquisitionUnavailableReason : nil
    }

    public var isAvailableOnIPhone: Bool {
        phoneUnavailableReason == nil
    }

    /// Providers signed in through xAI's Grok CLI device authorization. They share the credential
    /// format, Keychain lock, subject verification and generated-label rules, but not billing reads.
    public var usesXAIConsumerAuth: Bool {
        self == .grok || self == .xSubscription
    }
}
