import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct CodexBarWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CodexBarWidgetSnapshot
    let configuration: CodexBarWidgetConfigurationIntent
    let isPreview: Bool
    var accessContext = WidgetAccessContext()

    var isProLocked: Bool {
        !isPreview && (snapshot.isProLocked || accessContext.effectiveDate(for: snapshot) == nil)
    }
}

struct CodexBarWidgetTimelinePlan {
    let entry: CodexBarWidgetEntry
    let expirationEntry: CodexBarWidgetEntry?
    let nextRefreshDate: Date

    var entries: [CodexBarWidgetEntry] {
        [entry] + (expirationEntry.map { [$0] } ?? [])
    }

    var timeline: Timeline<CodexBarWidgetEntry> {
        Timeline(entries: entries, policy: .after(nextRefreshDate))
    }
}

struct CodexBarWidgetTimelineLoader: Sendable {
    private let now: @Sendable () -> Date
    private let loadSnapshot: @Sendable (Bool) -> CodexBarWidgetSnapshot
    private let loadRefreshInterval: @Sendable () -> WidgetRefreshInterval
    private let accessContext: WidgetAccessContext

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        loadSnapshot: @escaping @Sendable (Bool) -> CodexBarWidgetSnapshot = {
            WidgetSnapshotStore.loadSnapshot(forPreview: $0)
        },
        loadRefreshInterval: @escaping @Sendable () -> WidgetRefreshInterval = {
            WidgetSnapshotStore.loadRefreshInterval()
        },
        accessContext: WidgetAccessContext = WidgetAccessContext()
    ) {
        self.now = now
        self.loadSnapshot = loadSnapshot
        self.loadRefreshInterval = loadRefreshInterval
        self.accessContext = accessContext
    }

    func placeholder(configuration: CodexBarWidgetConfigurationIntent) -> CodexBarWidgetEntry {
        CodexBarWidgetEntry(
            date: now(),
            snapshot: .preview,
            configuration: configuration,
            isPreview: true
        )
    }

    func snapshot(
        configuration: CodexBarWidgetConfigurationIntent,
        isPreview: Bool
    ) -> CodexBarWidgetEntry {
        CodexBarWidgetEntry(
            date: now(),
            snapshot: loadSnapshot(isPreview),
            configuration: configuration,
            isPreview: isPreview,
            accessContext: accessContext
        )
    }

    func timeline(
        configuration: CodexBarWidgetConfigurationIntent
    ) -> Timeline<CodexBarWidgetEntry> {
        timelinePlan(configuration: configuration).timeline
    }

    func timelinePlan(
        configuration: CodexBarWidgetConfigurationIntent
    ) -> CodexBarWidgetTimelinePlan {
        let date = now()
        let snapshot = loadSnapshot(false)
        let interval = configuration.refreshPolicy.interval(fallback: loadRefreshInterval())
        let expirationEntry: CodexBarWidgetEntry?
        if let effectiveDate = accessContext.effectiveDate(for: snapshot), let deadline = snapshot.proAccessEndsAt {
            let projectedDeadline = date.addingTimeInterval(max(0, deadline.timeIntervalSince(effectiveDate)))
            // A reload request may be deferred by WidgetKit. Keep the access boundary
            // in the timeline even when the ordinary refresh is requested sooner.
            expirationEntry = CodexBarWidgetEntry(
                date: projectedDeadline,
                snapshot: CodexBarWidgetSnapshot(
                    generatedAt: snapshot.generatedAt,
                    results: [],
                    isProLocked: true,
                    proAccessEndsAt: deadline
                ),
                configuration: configuration,
                isPreview: false
            )
        } else {
            expirationEntry = nil
        }
        return CodexBarWidgetTimelinePlan(
            entry: CodexBarWidgetEntry(
                date: date,
                snapshot: snapshot,
                configuration: configuration,
                isPreview: false,
                accessContext: accessContext
            ),
            expirationEntry: expirationEntry,
            nextRefreshDate: min(
                date.addingTimeInterval(interval.seconds),
                expirationEntry?.date ?? .distantFuture
            )
        )
    }
}

struct CodexBarWidgetProvider: AppIntentTimelineProvider {
    private let loader: CodexBarWidgetTimelineLoader

    init(loader: CodexBarWidgetTimelineLoader = CodexBarWidgetTimelineLoader()) {
        self.loader = loader
    }

    func placeholder(in context: Context) -> CodexBarWidgetEntry {
        loader.placeholder(configuration: CodexBarWidgetConfigurationIntent())
    }

    func snapshot(
        for configuration: CodexBarWidgetConfigurationIntent,
        in context: Context
    ) async -> CodexBarWidgetEntry {
        loader.snapshot(configuration: configuration, isPreview: context.isPreview)
    }

    func timeline(
        for configuration: CodexBarWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<CodexBarWidgetEntry> {
        loader.timeline(configuration: configuration)
    }
}

struct CodexBarWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "CodexBar Widget"
    static let description = IntentDescription("Choose the CodexBar tiles and refresh preference for this widget.")

    @Parameter(title: "Layout", default: .automatic)
    var layout: CodexBarWidgetLayout

    @Parameter(title: "Focus", default: .dashboardOrder)
    var focus: CodexBarWidgetFocus

    @Parameter(title: "Group")
    var group: CodexBarWidgetGroupChoice?

    @Parameter(title: "Tile 1")
    var tile1: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 1 Display", default: .automatic)
    var tile1DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 2")
    var tile2: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 2 Display", default: .automatic)
    var tile2DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 3")
    var tile3: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 3 Display", default: .automatic)
    var tile3DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 4")
    var tile4: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 4 Display", default: .automatic)
    var tile4DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 5")
    var tile5: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 5 Display", default: .automatic)
    var tile5DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 6")
    var tile6: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 6 Display", default: .automatic)
    var tile6DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Update Preference", default: .appDefault)
    var refreshPolicy: CodexBarWidgetRefreshPolicy
}

enum CodexBarWidgetLayout: String, AppEnum {
    case automatic
    case oneTile
    case twoTiles
    case fourTiles

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Layout")
    static let caseDisplayRepresentations: [CodexBarWidgetLayout: DisplayRepresentation] = [
        .automatic: "Automatic",
        .oneTile: "One Tile",
        .twoTiles: "Two Tiles",
        .fourTiles: "Four Tiles",
    ]
}

enum CodexBarWidgetFocus: String, AppEnum {
    case dashboardOrder
    case codex
    case copilot
    case claude
    case grok
    case xSubscription
    case cursor
    case moonshot
    case openCodeZen
    case openRouter
    case greptile
    case gemini
    case antigravity

    // Keep saved Antigravity values decodable while offering only current account choices.
    // WidgetConfigurationTests checks this list against every display representation.
    static var allCases: [Self] {
        [.dashboardOrder, .codex, .copilot, .claude, .grok, .xSubscription, .cursor, .moonshot, .openCodeZen, .openRouter, .greptile, .gemini]
    }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Focus")
    static let caseDisplayRepresentations: [CodexBarWidgetFocus: DisplayRepresentation] = [
        .dashboardOrder: "Dashboard Order",
        .codex: "ChatGPT / Codex",
        .copilot: "GitHub Copilot",
        .claude: "Claude",
        .grok: "Grok",
        .xSubscription: "X Subscription",
        .cursor: "Cursor",
        .moonshot: "Moonshot (Kimi)",
        .openCodeZen: "OpenCode Go + Zen",
        .openRouter: "OpenRouter",
        .greptile: "Greptile",
        .gemini: "Google Gemini",
        .antigravity: "Google Gemini",
    ]

    var providerID: String? {
        switch self {
        case .dashboardOrder:
            nil
        case .codex:
            "codex"
        case .copilot:
            "copilot"
        case .claude:
            "claude"
        case .grok:
            "grok"
        case .xSubscription:
            "xSubscription"
        case .cursor:
            "cursor"
        case .moonshot:
            "moonshot"
        case .openCodeZen:
            "openCodeZen"
        case .openRouter:
            "openRouter"
        case .greptile:
            "greptile"
        case .gemini:
            "gemini"
        case .antigravity:
            "antigravity"
        }
    }
}

enum CodexBarWidgetRefreshPolicy: String, AppEnum {
    case appDefault
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case threeHours

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Update Preference")
    static let caseDisplayRepresentations: [CodexBarWidgetRefreshPolicy: DisplayRepresentation] = [
        .appDefault: "App Default",
        .fifteenMinutes: "Every 15 Minutes",
        .thirtyMinutes: "Every 30 Minutes",
        .oneHour: "Every Hour",
        .threeHours: "Every 3 Hours",
    ]

    func interval(fallback: WidgetRefreshInterval) -> WidgetRefreshInterval {
        switch self {
        case .appDefault:
            fallback
        case .fifteenMinutes:
            .fifteenMinutes
        case .thirtyMinutes:
            .thirtyMinutes
        case .oneHour:
            .oneHour
        case .threeHours:
            .threeHours
        }
    }
}

enum CodexBarWidgetTileDisplayMode: String, AppEnum {
    case automatic
    case compactPercent
    case fullBar
    case balanceOnly
    case urgentStatus

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tile Display")
    static let caseDisplayRepresentations: [CodexBarWidgetTileDisplayMode: DisplayRepresentation] = [
        .automatic: "Automatic",
        .compactPercent: "Compact Percent",
        .fullBar: "Full Bar",
        .balanceOnly: "Balance Only",
        .urgentStatus: "Urgent Status",
    ]

    static func mode(
        at index: Int,
        in displayModes: [CodexBarWidgetTileDisplayMode]
    ) -> CodexBarWidgetTileDisplayMode {
        displayModes.indices.contains(index) ? displayModes[index] : .automatic
    }

    init(builderDisplayMode: CodexBarWidgetBuilderDisplayMode) {
        self = Self(rawValue: builderDisplayMode.rawValue) ?? .automatic
    }
}

struct CodexBarWidgetTileChoice: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tile")
    static let defaultQuery = CodexBarWidgetTileChoiceQuery()

    let id: String
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

struct CodexBarWidgetGroupChoice: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Group")
    static let defaultQuery = CodexBarWidgetGroupChoiceQuery()
    static let ungroupedID = "__ungrouped"

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct CodexBarWidgetGroupChoiceQuery: EntityStringQuery {
    private let loadSnapshot: @Sendable () -> CodexBarWidgetSnapshot
    private let accessContext: WidgetAccessContext

    init() {
        loadSnapshot = { WidgetSnapshotStore.loadSnapshot() }
        accessContext = WidgetAccessContext()
    }

    init(
        loadSnapshot: @escaping @Sendable () -> CodexBarWidgetSnapshot,
        accessContext: WidgetAccessContext = WidgetAccessContext()
    ) {
        self.loadSnapshot = loadSnapshot
        self.accessContext = accessContext
    }

    func entities(for identifiers: [CodexBarWidgetGroupChoice.ID]) async throws -> [CodexBarWidgetGroupChoice] {
        let choices = choices()
        return identifiers.map { identifier in
            choices.first { $0.id == identifier }
                ?? CodexBarWidgetGroupChoice(id: identifier, title: "Saved Group")
        }
    }

    func entities(matching string: String) async throws -> [CodexBarWidgetGroupChoice] {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return choices()
        }

        return choices().filter { choice in
            choice.title.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [CodexBarWidgetGroupChoice] {
        choices()
    }

    private func choices() -> [CodexBarWidgetGroupChoice] {
        accessContext.readable(loadSnapshot()).groupChoices
    }
}

struct CodexBarWidgetTileChoiceQuery: EntityStringQuery {
    @IntentParameterDependency<CodexBarWidgetConfigurationIntent>(\.$group, \.$focus)
    var intent
    private let loadSnapshot: @Sendable () -> CodexBarWidgetSnapshot
    private let accessContext: WidgetAccessContext
    private let groupOverride: CodexBarWidgetGroupChoice?
    private let focusOverride: CodexBarWidgetFocus?

    init() {
        loadSnapshot = { WidgetSnapshotStore.loadSnapshot() }
        accessContext = WidgetAccessContext()
        groupOverride = nil
        focusOverride = nil
    }

    init(
        loadSnapshot: @escaping @Sendable () -> CodexBarWidgetSnapshot,
        accessContext: WidgetAccessContext = WidgetAccessContext(),
        group: CodexBarWidgetGroupChoice? = nil,
        focus: CodexBarWidgetFocus? = nil
    ) {
        self.loadSnapshot = loadSnapshot
        self.accessContext = accessContext
        self.groupOverride = group
        self.focusOverride = focus
    }

    func entities(for identifiers: [CodexBarWidgetTileChoice.ID]) async throws -> [CodexBarWidgetTileChoice] {
        let snapshot = accessContext.readable(loadSnapshot())
        let choices = Self.choices(
            snapshot: snapshot,
            group: groupOverride ?? intent?.group,
            focus: focusOverride ?? intent?.focus ?? .dashboardOrder
        )
        return identifiers.map { identifier in
            if let exactMatch = choices.first(where: { $0.id == identifier }) {
                return exactMatch
            }
            if let migratedID = snapshot.builderTile(resolvingSavedID: identifier)?.id,
               let migratedChoice = choices.first(where: { $0.id == migratedID }) {
                return migratedChoice
            }
            return CodexBarWidgetTileChoice(
                id: identifier,
                title: "Saved Tile",
                subtitle: "Open CodexBar to refresh"
            )
        }
    }

    func entities(matching string: String) async throws -> [CodexBarWidgetTileChoice] {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return choices()
        }

        return choices().filter { choice in
            choice.title.localizedCaseInsensitiveContains(string)
                || choice.subtitle.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [CodexBarWidgetTileChoice] {
        choices()
    }

    private func choices() -> [CodexBarWidgetTileChoice] {
        Self.choices(
            snapshot: accessContext.readable(loadSnapshot()),
            group: groupOverride ?? intent?.group,
            focus: focusOverride ?? intent?.focus ?? .dashboardOrder
        )
    }

    private static func choices(
        snapshot: CodexBarWidgetSnapshot,
        group: CodexBarWidgetGroupChoice? = nil,
        focus: CodexBarWidgetFocus = .dashboardOrder
    ) -> [CodexBarWidgetTileChoice] {
        snapshot.selectableTiles(group: group, focus: focus).map { tile in
            CodexBarWidgetTileChoice(
                id: tile.id,
                title: tile.choiceTitle,
                subtitle: tile.choiceSubtitle
            )
        }
    }
}
