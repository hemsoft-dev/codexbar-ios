import SwiftUI

@main
struct CodexBarWatchApp: App {
    private let screenshotScene = WatchAppStoreScreenshotScene.current()

    var body: some Scene {
        WindowGroup {
            if let screenshotScene {
                WatchDashboardView(state: screenshotScene.state)
                    .task {
                        let settleNanoseconds = UInt64(
                            WatchAppStoreScreenshotScene.settleDelay * 1_000_000_000
                        )
                        try? await Task.sleep(nanoseconds: settleNanoseconds)
                        screenshotScene.markReady()
                    }
            } else {
                ProductionWatchDashboardRoot()
            }
        }
    }
}

private struct ProductionWatchDashboardRoot: View {
    @StateObject private var dashboardStore = WatchDashboardStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            WatchDashboardView(state: dashboardStore.state(at: context.date))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dashboardStore.reevaluateAccess()
            }
        }
    }
}
