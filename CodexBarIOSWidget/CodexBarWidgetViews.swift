import SwiftUI
import WidgetKit

struct CodexBarWidgetView: View {
    let entry: CodexBarWidgetEntry
    @Environment(\.widgetFamily) private var family
    private var appearance = WidgetRenderingAppearance()

    init(entry: CodexBarWidgetEntry) {
        self.entry = entry
    }

    @ViewBuilder
    var body: some View {
        if appearance.isVibrant {
            content.foregroundStyle(.white)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if entry.isProLocked {
            ProLockedWidget(family: family)
                .widgetURL(CodexBarDeepLink.proURL)
        } else {
            usageContent
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        switch family {
        case .accessoryInline:
            AccessoryInlineWidget(tiles: selectedTiles.map(\.tile))
                .widgetURL(selectedTiles.first?.tile.deepLinkURL)
        case .accessoryCircular:
            AccessoryCircularWidget(tile: selectedTiles.first?.tile)
                .widgetURL(selectedTiles.first?.tile.deepLinkURL)
        case .accessoryRectangular:
            AccessoryRectangularWidget(tile: selectedTiles.first?.tile)
                .widgetURL(selectedTiles.first?.tile.deepLinkURL)
        default:
            TileWidget(
                tiles: selectedTiles,
                generatedAt: entry.snapshot.generatedAt,
                family: family
            )
        }
    }

    private var selectedTiles: [CodexBarWidgetRenderedTile] {
        let allTiles = scopedSelectableTiles
        let builderConfiguration = WidgetSnapshotStore.loadBuilderConfiguration(forPreview: entry.isPreview)
        let usesBuilderDefaults = usesBuilderDefaults(builderConfiguration)
        let configuredChoices = [
            entry.configuration.tile1,
            entry.configuration.tile2,
            entry.configuration.tile3,
            entry.configuration.tile4,
            entry.configuration.tile5,
            entry.configuration.tile6,
        ]
        let configuredDisplayModes = [
            entry.configuration.tile1DisplayMode,
            entry.configuration.tile2DisplayMode,
            entry.configuration.tile3DisplayMode,
            entry.configuration.tile4DisplayMode,
            entry.configuration.tile5DisplayMode,
            entry.configuration.tile6DisplayMode,
        ]

        let maximumTiles = tileCount(
            builderConfiguration: builderConfiguration,
            usesBuilderDefaults: usesBuilderDefaults
        )
        let fallbackTiles = Array(defaultTiles.prefix(maximumTiles))

        if configuredChoices.contains(where: { $0 != nil }) {
            return (0..<maximumTiles).compactMap { index in
                guard configuredChoices.indices.contains(index), let choice = configuredChoices[index] else {
                    return nil
                }

                return CodexBarWidgetRenderedTile(
                    tile: resolvedTile(for: choice, in: allTiles),
                    displayMode: CodexBarWidgetTileDisplayMode.mode(
                        at: index,
                        in: configuredDisplayModes
                    )
                )
            }
        }

        if usesBuilderDefaults {
            return (0..<maximumTiles).compactMap { index in
                let tile: CodexBarWidgetTile?
                if let tileID = builderConfiguration.tileID(at: index) {
                    tile = resolvedTile(for: tileID, in: allTiles)
                } else if fallbackTiles.indices.contains(index) {
                    tile = fallbackTiles[index]
                } else {
                    tile = nil
                }

                guard let tile else {
                    return nil
                }

                return CodexBarWidgetRenderedTile(
                    tile: tile,
                    displayMode: CodexBarWidgetTileDisplayMode(
                        builderDisplayMode: builderConfiguration.displayMode(at: index)
                    )
                )
            }
        }

        return fallbackTiles.enumerated().map { index, tile in
            CodexBarWidgetRenderedTile(
                tile: tile,
                displayMode: CodexBarWidgetTileDisplayMode.mode(
                    at: index,
                    in: configuredDisplayModes
                )
            )
        }
    }

    private func usesBuilderDefaults(_ configuration: CodexBarWidgetBuilderConfiguration) -> Bool {
        !entry.isPreview
            && configuration.hasCustomizations
            && entry.configuration.focus == .dashboardOrder
            && entry.configuration.group == nil
    }

    private var defaultTiles: [CodexBarWidgetTile] {
        scopedProviders.map(\.summaryTile)
    }

    private var scopedSelectableTiles: [CodexBarWidgetTile] {
        entry.snapshot.selectableTiles(group: selectedGroup, focus: selectedFocus)
    }

    private var scopedProviders: [CodexBarWidgetProviderSnapshot] {
        entry.snapshot.scopedProviders(group: selectedGroup, focus: selectedFocus)
    }

    private var selectedGroup: CodexBarWidgetGroupChoice? {
        entry.isPreview ? nil : entry.configuration.group
    }

    private var selectedFocus: CodexBarWidgetFocus {
        entry.configuration.focus
    }

    private func resolvedTile(
        for choice: CodexBarWidgetTileChoice,
        in allTiles: [CodexBarWidgetTile]
    ) -> CodexBarWidgetTile {
        if let exactMatch = allTiles.first(where: { $0.id == choice.id }) {
            return exactMatch
        }

        if let legacyMatch = legacySummaryTile(for: choice.id) ?? legacyBarTile(for: choice.id) {
            return legacyMatch
        }

        if choice.id.contains("antigravity.") { return .unavailable(choice: choice) }
        let titleMatches = allTiles.filter {
            $0.choiceTitle.localizedCaseInsensitiveCompare(choice.title) == .orderedSame
        }
        if titleMatches.count == 1, let titleMatch = titleMatches.first {
            return titleMatch
        }

        if entry.isPreview, let previewFallback = allTiles.first {
            return previewFallback
        }

        return .unavailable(choice: choice)
    }

    private func resolvedTile(
        for tileID: String,
        in allTiles: [CodexBarWidgetTile]
    ) -> CodexBarWidgetTile {
        if let exactMatch = allTiles.first(where: { $0.id == tileID }) {
            return exactMatch
        }

        if let legacyMatch = legacySummaryTile(for: tileID) ?? legacyBarTile(for: tileID) {
            return legacyMatch
        }

        return .unavailable(
            choice: CodexBarWidgetTileChoice(
                id: tileID,
                title: "Saved Tile",
                subtitle: "Open CodexBar to refresh"
            )
        )
    }

    private func legacySummaryTile(for tileID: String) -> CodexBarWidgetTile? {
        scopedProviders.first { provider in
            (provider.legacyAccountIDs ?? []).contains { tileID == "provider.\($0)" }
        }?.summaryTile
    }

    private func legacyBarTile(for choiceID: String) -> CodexBarWidgetTile? {
        guard choiceID.hasPrefix("bar.") else {
            return nil
        }

        let savedBarID = String(choiceID.dropFirst("bar.".count))
        let providers = scopedProviders
            .filter { provider in
                ([provider.accountID] + (provider.legacyAccountIDs ?? [])).contains {
                    savedBarID == $0 || savedBarID.hasPrefix("\($0).")
                }
            }
            .sorted { $0.accountID.count > $1.accountID.count }

        for provider in providers {
            let identityMatches = provider.bars.filter {
                $0.matchesSavedBuilderTileID(choiceID, accountID: provider.accountID, legacyAccountIDs: provider.legacyAccountIDs ?? [])
            }
            if identityMatches.count == 1, let identityMatch = identityMatches.first {
                return provider.barTile(identityMatch)
            }
            if let indexedBar = provider.bars.enumerated().first(where: {
                $0.element.matchesSavedBuilderTileID(
                    choiceID,
                    accountID: provider.accountID,
                    legacyAccountIDs: provider.legacyAccountIDs ?? [],
                    currentIndex: $0.offset
                )
            }) {
                return provider.barTile(indexedBar.element)
            }

            if provider.bars.count == 1, let onlyBar = provider.bars.first,
               !(provider.legacyAccountIDs ?? []).contains(where: { savedBarID.hasPrefix("\($0).") }) {
                return provider.barTile(onlyBar)
            }
        }

        return nil
    }

    private func tileCount(
        builderConfiguration: CodexBarWidgetBuilderConfiguration,
        usesBuilderDefaults: Bool
    ) -> Int {
        if entry.configuration.layout == .automatic, usesBuilderDefaults {
            return builderConfiguration.layout.tileCount(
                maximum: maximumTileCount,
                automaticCount: automaticTileCount
            )
        }

        switch entry.configuration.layout {
        case .automatic:
            return automaticTileCount
        case .oneTile:
            return 1
        case .twoTiles:
            return min(maximumTileCount, 2)
        case .fourTiles:
            return min(maximumTileCount, 4)
        }
    }

    private var automaticTileCount: Int {
        switch family {
        case .systemSmall:
            1
        case .systemMedium:
            2
        case .systemLarge:
            4
        case .systemExtraLarge:
            6
        default:
            1
        }
    }

    private var maximumTileCount: Int {
        switch family {
        case .systemSmall:
            1
        case .systemMedium:
            2
        case .systemLarge:
            4
        case .systemExtraLarge:
            6
        default:
            1
        }
    }
}

private struct ProLockedWidget: View {
    let family: WidgetFamily
    private var appearance = WidgetRenderingAppearance()

    init(family: WidgetFamily) {
        self.family = family
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Unlock widgets with CodexBar Pro")
            .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            Label("CodexBar Pro", systemImage: "lock.fill")
        case .accessoryCircular:
            VStack(spacing: 2) {
                Image(systemName: "lock.fill")
                Text("Pro").font(.caption2)
            }
        case .accessoryRectangular:
            Label {
                Text("Unlock widgets with CodexBar Pro")
                    .font(.caption)
                    .minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: "lock.fill")
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                Label("CodexBar Pro", systemImage: "lock.fill")
                    .font(.headline)
                Text("Unlock widgets with CodexBar Pro")
                    .font(.subheadline)
                    .foregroundStyle(appearance.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct TileWidget: View {
    private var appearance = WidgetRenderingAppearance()

    let tiles: [CodexBarWidgetRenderedTile]
    let generatedAt: Date
    let family: WidgetFamily

    init(tiles: [CodexBarWidgetRenderedTile], generatedAt: Date, family: WidgetFamily) {
        self.tiles = tiles
        self.generatedAt = generatedAt
        self.family = family
    }

    var body: some View {
        Group {
            if tiles.isEmpty {
                EmptyWidgetState()
            } else if usesDenseGrid {
                DenseTileWidget(tiles: tiles, generatedAt: generatedAt, family: family)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                            if family == .systemSmall {
                                ProviderWidgetTile(renderedTile: tile, style: .small)
                            } else {
                                LinkedProviderWidgetTile(renderedTile: tile, style: .standard)
                            }
                        }
                    }

                    if family != .systemSmall {
                        Text("Updated \(freshnessDate, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(appearance.secondaryForeground)
                            .lineLimit(1)
                    }
                }
            }
        }
        .widgetURL(family == .systemSmall ? tiles.first?.tile.deepLinkURL : nil)
        .containerBackground(.background, for: .widget)
    }

    private var usesDenseGrid: Bool {
        switch family {
        case .systemLarge, .systemExtraLarge:
            tiles.count >= 4
        default:
            false
        }
    }

    private var freshnessDate: Date {
        tiles.freshnessDate(fallback: generatedAt)
    }

    private var columns: [GridItem] {
        switch family {
        case .systemSmall:
            [GridItem(.flexible(), spacing: 8)]
        case .systemMedium:
            [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        default:
            [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        }
    }
}

struct DenseTileWidget: View {
    private var appearance = WidgetRenderingAppearance()

    let tiles: [CodexBarWidgetRenderedTile]
    let generatedAt: Date
    let family: WidgetFamily

    init(tiles: [CodexBarWidgetRenderedTile], generatedAt: Date, family: WidgetFamily) {
        self.tiles = tiles
        self.generatedAt = generatedAt
        self.family = family
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Updated \(freshnessDate, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(appearance.secondaryForeground)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(displayedTiles.enumerated()), id: \.offset) { _, tile in
                    LinkedProviderWidgetTile(renderedTile: tile, style: .dense)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var displayedTiles: [CodexBarWidgetRenderedTile] {
        switch family {
        case .systemExtraLarge:
            Array(tiles.prefix(6))
        default:
            Array(tiles.prefix(4))
        }
    }

    private var freshnessDate: Date {
        displayedTiles.freshnessDate(fallback: generatedAt)
    }

    private var columns: [GridItem] {
        let columnCount = family == .systemExtraLarge && displayedTiles.count > 4 ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
    }
}

private struct LinkedProviderWidgetTile: View {
    let renderedTile: CodexBarWidgetRenderedTile
    let style: ProviderWidgetTile.Style

    var body: some View {
        if let destination = renderedTile.tile.deepLinkURL {
            Link(destination: destination) {
                ProviderWidgetTile(renderedTile: renderedTile, style: style)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this account in CodexBar")
        } else {
            ProviderWidgetTile(renderedTile: renderedTile, style: style)
        }
    }
}

struct ProviderWidgetTile: View {
    private var appearance = WidgetRenderingAppearance()

    enum Style {
        case small
        case standard
        case dense
    }

    let renderedTile: CodexBarWidgetRenderedTile
    let style: Style

    init(renderedTile: CodexBarWidgetRenderedTile, style: Style) {
        self.renderedTile = renderedTile
        self.style = style
    }

    private var tile: CodexBarWidgetTile {
        renderedTile.tile
    }

    var body: some View {
        Group {
            if renderedTile.displayMode == .automatic {
                switch style {
                case .dense:
                    automaticDenseBody
                case .small, .standard:
                    automaticStandardBody
                }
            } else {
                configuredModeBody
            }
        }
        .padding(padding)
        .frame(
            maxWidth: .infinity,
            maxHeight: style == .dense ? .infinity : nil,
            alignment: .topLeading
        )
        .frame(minHeight: minimumHeight, alignment: .topLeading)
        // Keep the material's foreground treatment in full color. WidgetKit
        // otherwise tints this nested background as if it were foreground content.
        .background(
            appearance.showsDecorations ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var automaticStandardBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let bar = tile.bar, tile.monetaryValueText == nil {
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 5) {
                        header(font: .caption.weight(.semibold), logoSize: 22)
                        metricHeading(bar)
                    }
                    if usesSideVisualization(bar) {
                        WidgetMetricVisualization(bar: bar, layoutStyle: style)
                    }
                }
                if bar.allowsAutomaticVisualization, !usesSideVisualization(bar) {
                    WidgetMetricVisualization(bar: bar, layoutStyle: style)
                }
                detailLine(bar, limit: 2)
            } else {
                header(font: .caption.weight(.semibold), logoSize: 22)
                if let monetaryValueText = tile.monetaryValueText {
                    Text(monetaryValueText)
                        .font(.system(size: style == .standard ? 22 : 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                } else {
                    Text(tile.subtitle)
                        .font(.caption2)
                        .foregroundStyle(appearance.secondaryForeground)
                        .lineLimit(style == .standard ? 2 : 1)
                }
            }
        }
    }

    private func usesSideVisualization(_ bar: CodexBarWidgetUsageBarSnapshot) -> Bool {
        guard bar.allowsAutomaticVisualization else { return false }
        switch bar.visualizationStyle {
        case .circularRing, .semicircularDial, .largeNumeric:
            return true
        default:
            return false
        }
    }

    private func metricHeading(_ bar: CodexBarWidgetUsageBarSnapshot) -> some View {
        HStack {
            Text(bar.label)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 4)
            Text(bar.usageText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .font(.caption2)
        .foregroundStyle(appearance.secondaryForeground)
    }

    @ViewBuilder
    private func detailLine(_ bar: CodexBarWidgetUsageBarSnapshot, limit: Int) -> some View {
        if let detail = bar.localizedProjectionDescription() ?? bar.localizedResetDescription() {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(appearance.secondaryForeground)
                .lineLimit(limit)
                .minimumScaleFactor(0.65)
        }
    }

    private var automaticDenseBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(font: .caption2.weight(.semibold), logoSize: 18)

            if let monetaryValueText = tile.monetaryValueText {
                Text(monetaryValueText)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                Text(tile.title)
                    .font(.caption2)
                    .foregroundStyle(appearance.secondaryForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if let bar = tile.bar {
                Text(tile.metricText(for: bar))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(bar.label)
                    .font(.caption2)
                    .foregroundStyle(appearance.secondaryForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                if bar.allowsAutomaticVisualization {
                    WidgetMetricVisualization(bar: bar, layoutStyle: style)
                }

                detailLine(bar, limit: 1)
            } else {
                Text(tile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(appearance.secondaryForeground)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)
        }
    }

    private var configuredModeBody: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            header(font: headerFont, logoSize: logoSize)

            switch renderedTile.displayMode {
            case .automatic:
                EmptyView()
            case .compactPercent:
                compactPercentContent
            case .fullBar:
                fullBarContent
            case .balanceOnly:
                balanceOnlyContent
            case .urgentStatus:
                urgentStatusContent
            }

            if style == .dense {
                Spacer(minLength: 0)
            }
        }
    }

    private var compactPercentContent: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            Text(primaryMetric)
                .font(primaryMetricFont)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            Text(compactDetail)
                .font(.caption2)
                .foregroundStyle(appearance.secondaryForeground)
                .lineLimit(style == .dense ? 2 : 1)
                .minimumScaleFactor(0.65)

            if let bar = tile.bar, renderedTile.allowsUsageGauge {
                WidgetUsageProgressBar(bar: bar)
            }
        }
    }

    private var fullBarContent: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            if let bar = tile.bar {
                HStack(alignment: .firstTextBaseline) {
                    Text(bar.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Spacer(minLength: 4)
                    Text(bar.usageText)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(appearance.secondaryForeground)

                if renderedTile.allowsUsageGauge {
                    WidgetUsageProgressBar(bar: bar)
                }

                detailLine(bar, limit: 1)
            } else if let monetaryValueText = tile.monetaryValueText {
                Text(monetaryValueText)
                    .font(primaryMetricFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                Text(tile.title)
                    .font(.caption2)
                    .foregroundStyle(appearance.secondaryForeground)
                    .lineLimit(1)
            } else {
                Text(tile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(appearance.secondaryForeground)
                    .lineLimit(style == .dense ? 3 : 2)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private var balanceOnlyContent: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            if let monetaryValueText = tile.monetaryValueText {
                Text(monetaryValueText)
                    .font(primaryMetricFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Text(tile.monetaryMetric?.label ?? "Balance")
                    .font(.caption2)
                    .foregroundStyle(appearance.secondaryForeground)
                    .lineLimit(1)
            } else {
                Text("No balance data")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(appearance.tint(for: tile.severity))
                    .widgetAccentable()
                    .lineLimit(1)

                Text(tile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(appearance.secondaryForeground)
                    .lineLimit(style == .dense ? 2 : 1)
            }
        }
    }

    private var urgentStatusContent: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            Text(statusLabel)
                .font(primaryMetricFont)
                .foregroundStyle(appearance.tint(for: tile.severity))
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.58)

            Text(statusDetail)
                .font(.caption2)
                .foregroundStyle(appearance.secondaryForeground)
                .lineLimit(style == .dense ? 3 : 2)
                .minimumScaleFactor(0.65)
        }
    }

    private func header(font: Font, logoSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            if appearance.showsDecorations {
                CodexBarProviderLogo(
                    providerID: tile.providerID,
                    size: logoSize,
                    background: Color(.systemBackground),
                    fallbackSystemName: "arrow.clockwise"
                )
            }

            Text(tile.providerTitle)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)
        }
    }

    private var padding: CGFloat {
        switch style {
        case .dense:
            renderedTile.displayMode == .automatic ? 8 : 7
        case .small, .standard:
            10
        }
    }

    private var minimumHeight: CGFloat {
        switch style {
        case .small:
            110
        case .standard:
            86
        case .dense:
            0
        }
    }

    private var modeSpacing: CGFloat {
        style == .dense ? 5 : 6
    }

    private var headerFont: Font {
        style == .dense ? .caption2.weight(.semibold) : .caption.weight(.semibold)
    }

    private var logoSize: CGFloat {
        style == .dense ? 18 : 22
    }

    private var primaryMetricFont: Font {
        switch style {
        case .dense:
            .system(size: 24, weight: .semibold, design: .rounded)
        case .standard:
            .system(size: 22, weight: .semibold, design: .rounded)
        case .small:
            .system(size: 20, weight: .semibold, design: .rounded)
        }
    }

    private var primaryMetric: String {
        if let bar = tile.bar {
            return tile.metricText(for: bar)
        }

        if let monetaryValueText = tile.monetaryValueText {
            return monetaryValueText
        }

        return statusLabel
    }

    private var compactDetail: String {
        if let bar = tile.bar {
            return bar.label
        }

        if tile.monetaryValueText != nil {
            return tile.title
        }

        return tile.subtitle
    }

    private var statusLabel: String {
        switch tile.severity {
        case .normal:
            "OK"
        case .warning:
            "Warning"
        case .critical:
            "Critical"
        }
    }

    private var statusDetail: String {
        if let bar = tile.bar {
            return tile.urgentStatusDetail(for: bar)
        }

        if let metric = tile.monetaryMetric {
            return "\(metric.formattedAmount) - \(metric.label)"
        }

        if let creditsRemaining = tile.creditsRemaining {
            let balance = CodexBarCurrencyText.format(creditsRemaining)
            return "\(balance) balance"
        }

        return tile.subtitle
    }
}

// Keep provider colors in full color, including StandBy, but let the system
// choose readable foreground colors in tinted and vibrant presentations.
struct WidgetRenderingAppearance: DynamicProperty {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsContainerBackground

    var isFullColor: Bool {
        renderingMode == .fullColor
    }

    var isVibrant: Bool {
        renderingMode == .vibrant
    }

    var showsDecorations: Bool {
        isFullColor && showsContainerBackground
    }

    var primaryForeground: Color {
        isVibrant ? .white : .primary
    }

    var secondaryForeground: AnyShapeStyle {
        isFullColor ? AnyShapeStyle(.secondary) : AnyShapeStyle(primaryForeground)
    }

    var trackColor: Color {
        // Vibrant rendering maps opaque grayscale to adaptive material, while
        // accented rendering preserves alpha and discards source colors.
        isVibrant ? Color(white: 0.2) : .primary.opacity(isFullColor ? 0.12 : 0.2)
    }

    var projectedFillColor: Color? {
        guard !isFullColor else { return nil }
        return isVibrant ? Color(white: 0.55) : .primary.opacity(0.45)
    }

    func tint(for severity: CodexBarWidgetSeverity) -> Color {
        isFullColor ? severity.tint : primaryForeground
    }
}

private struct WidgetUsageProgressBar: View {
    private var appearance = WidgetRenderingAppearance()

    let bar: CodexBarWidgetUsageBarSnapshot

    init(bar: CodexBarWidgetUsageBarSnapshot) {
        self.bar = bar
    }

    var body: some View {
        CodexBarUsageProgressBar(
            fractionUsed: bar.fractionUsed,
            projectedFraction: bar.projectedFraction,
            severity: bar.severity,
            projectedSeverity: bar.effectiveSeverity,
            fillColor: appearance.isFullColor ? nil : appearance.primaryForeground,
            projectedFillColor: appearance.projectedFillColor,
            trackColor: appearance.trackColor,
            accessibilityText: "\(bar.label) \(bar.usageText)"
        )
        .widgetAccentable()
    }
}

private struct WidgetMetricVisualization: View {
    private var appearance = WidgetRenderingAppearance()

    let bar: CodexBarWidgetUsageBarSnapshot
    let layoutStyle: ProviderWidgetTile.Style

    init(bar: CodexBarWidgetUsageBarSnapshot, layoutStyle: ProviderWidgetTile.Style) {
        self.bar = bar
        self.layoutStyle = layoutStyle
    }

    var body: some View {
        Group {
            switch resolvedStyle {
            case .automatic, .linearBar:
                WidgetUsageProgressBar(bar: bar)
            case .segmentedBar:
                HStack(spacing: 2) {
                    ForEach(0..<10, id: \.self) { index in
                        Capsule()
                            .fill(index < filledSegments ? appearance.tint(for: bar.effectiveSeverity) : appearance.trackColor)
                            .widgetAccentable(index < filledSegments)
                    }
                }
                .frame(height: 6)
            case .circularRing:
                ZStack {
                    Circle()
                        .stroke(appearance.trackColor, lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: clampedFraction)
                        .stroke(
                            appearance.tint(for: bar.effectiveSeverity),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .widgetAccentable()
                        .rotationEffect(.degrees(-90))
                    Text(bar.usageText)
                        .font(.system(size: 9, weight: .semibold))
                        .minimumScaleFactor(0.6)
                }
                .frame(width: 42, height: 42)
            case .semicircularDial:
                ZStack(alignment: .bottom) {
                    WidgetSemicircleShape()
                        .stroke(appearance.trackColor, lineWidth: 5)
                    WidgetSemicircleShape()
                        .trim(from: 0, to: clampedFraction)
                        .stroke(
                            appearance.tint(for: bar.effectiveSeverity),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .widgetAccentable()
                    Text(bar.usageText)
                        .font(.system(size: 8, weight: .semibold))
                }
                .frame(width: 52, height: 28)
            case .largeNumeric:
                Text(bar.usageText)
                    .font(.system(size: layoutStyle == .dense ? 20 : 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(appearance.tint(for: bar.effectiveSeverity))
                    .widgetAccentable()
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .accessibilityLabel("\(bar.label), \(bar.usageText)")
    }

    private var resolvedStyle: MetricVisualizationStyle {
        if bar.allowsGauge == false {
            return .largeNumeric
        }
        return (bar.visualizationStyle ?? .automatic).resolvedForWidget(
            allowsGauge: layoutStyle != .dense
        )
    }

    private var clampedFraction: Double {
        min(max(bar.fractionUsed, 0), 1)
    }

    private var filledSegments: Int {
        Int((clampedFraction * 10).rounded(.up))
    }
}

private struct WidgetSemicircleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.maxY),
            radius: min(rect.width / 2, rect.height),
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        return path
    }
}

#Preview(as: .systemMedium) {
    CodexBarIOSWidget()
} timeline: {
    CodexBarWidgetEntry(
        date: Date(),
        snapshot: .preview,
        configuration: CodexBarWidgetConfigurationIntent(),
        isPreview: true
    )
}
