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
        }
    }

    public var supportsPlanBadge: Bool {
        switch self {
        case .codex, .copilot, .githubBilling, .claude, .grok, .xSubscription:
            true
        case .openRouter, .openCodeZen, .moonshot, .cursor, .greptile, .gemini, .antigravity:
            false
        }
    }

    /// Providers signed in through xAI's Grok CLI device authorization. They share the credential
    /// format, Keychain lock, subject verification and generated-label rules, but not billing reads.
    public var usesXAIConsumerAuth: Bool {
        self == .grok || self == .xSubscription
    }
}
