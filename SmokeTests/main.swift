import CodexBarIOS
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Smoke test failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

@main
struct SmokeTests {
    @MainActor
    static func main() async {
        expect(UsageSeverity(fractionUsed: 0.74) == .normal, "0.74 should be normal")
        expect(UsageSeverity(fractionUsed: 0.75) == .warning, "0.75 should be warning")
        expect(UsageSeverity(fractionUsed: 0.90) == .critical, "0.90 should be critical")

        let bar = UsageBar(label: "Weekly", used: 125, limit: 100)
        expect(bar.fractionUsed == 1, "usage fraction should clamp at 1")
        expect(bar.severity == .critical, "over-limit usage should be critical")
        expect(
            ProviderAccountConfiguration.defaultConfiguration(for: .codex).authMethod == .browserSession,
            "Codex should default to browser sign-in"
        )

        let service = UsageRefreshService.demo()
        await service.refresh()

        expect(
            Set(service.results.map(\.providerID)) == Set(ProviderID.allCases.filter { $0 != .antigravity && $0.isAvailableOnIPhone }),
            "demo refresh should include every visible provider"
        )
        expect(service.isRefreshing == false, "refresh flag should reset")
        expect(service.lastRefreshError == nil, "demo refresh should not fail")

        print("CodexBarIOS smoke tests passed")
    }
}
