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
                            Button("Open Billing Settings") { onConnect?() }
                                .accessibilityIdentifier("subscription-billing-settings")
                        }
                    }
                }
            }
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
