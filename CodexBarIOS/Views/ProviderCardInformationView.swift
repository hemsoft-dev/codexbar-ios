import SwiftUI

struct ProviderCardInformationView: View {
    let sections: [ProviderCardInformationSection]
    let greptileRenewal: GreptileAllowanceRenewal?
    var onConnect: (() -> Void)?
    var showsBillingSettings = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let greptileRenewal {
                    Section {
                        GreptileRenewalView(renewal: greptileRenewal, onConnect: onConnect)
                    }
                }
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            LabeledContent {
                                Text(item.detail)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            } label: {
                                Text(item.label)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(item.label), \(item.detail)")
                        }
                        if section.id == "subscription-renewal", showsBillingSettings {
                            ClaudeBillingAccessView()
                            Text(ClaudeBillingAccess.purchasePlatformGuidance).font(.footnote)
                        }
                    }
                }
            }
            .accessibilityIdentifier("provider-information-list")
            .navigationTitle("More Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

enum ClaudeBillingAccess {
    static let url = URL(string: "https://claude.ai/settings/billing")!
    static let purchasePlatformGuidance = "If you subscribed through Claude for iOS or Android, "
        + "manage the subscription through the store where you purchased it. "
        + "In Claude for iOS, open your profile, then Billing."

    @MainActor
    static func open(using action: OpenURLAction) { action(url) }
}

struct ClaudeBillingAccessView: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button("View billing in Claude") { ClaudeBillingAccess.open(using: openURL) }
            .accessibilityIdentifier("subscription-billing-view")
        Text("Open Claude to see your plan and billing. CodexBar cannot currently verify this renewal date.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
