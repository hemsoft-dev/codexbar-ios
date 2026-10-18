#if DEBUG
import SwiftUI

/// A fixture presenter cannot open account management or change a real subscription.
struct ProCommerceFixtureManagementView: View {
    let fixture: ProCommerceFixture
    @Environment(\.dismiss) private var dismiss
    @State private var isUpdating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Isolated subscription-management fixture")
                    Text("These controls update synthetic renewal evidence only. Apple Account settings are unchanged.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Turn off auto-renew") { setAutoRenew(false) }
                        .accessibilityIdentifier("fixture-commerce-renewal-off")
                    Button("Turn on auto-renew") { setAutoRenew(true) }
                        .accessibilityIdentifier("fixture-commerce-renewal-on")
                }
                .disabled(isUpdating)
            }
            .navigationTitle("Manage Subscription")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("fixture-commerce-management")
    }

    private func setAutoRenew(_ enabled: Bool) {
        isUpdating = true
        Task {
            await fixture.setAutoRenew(enabled)
            isUpdating = false
            dismiss()
        }
    }
}
#endif
