import SwiftUI

struct ProLifetimeConfirmationView: View {
    let product: ProCatalogProduct
    let subscriptionEndsAt: Date?
    let canPurchase: Bool
    let onPurchase: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(product.displayName)
                        .font(.title2.weight(.semibold))
                    Text("\(product.displayPrice) once")
                        .font(.title.weight(.semibold))
                    Text("Lifetime access to every Pro feature.")
                }
                Section {
                    if let end = subscriptionEndsAt {
                        Text("Your current subscription period ends \(end.formatted(date: .long, time: .omitted)).")
                    } else {
                        Text("Your subscription end date is unavailable. Check Manage Subscription for details.")
                    }
                    Text("Buying lifetime does not refund the remaining paid subscription period.")
                    Text(
                        "If you later restart a CodexBar Pro subscription in your Apple Account settings, "
                            + "Apple will charge for it even though you have lifetime Pro."
                    )
                        .accessibilityIdentifier("pro-lifetime-restart-warning")
                }
                Section {
                    Button("Buy lifetime for \(product.displayPrice)", action: onPurchase)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canPurchase)
                        .accessibilityIdentifier("pro-confirm-lifetime")
                    if !canPurchase {
                        Text("Your purchase information changed. Close this confirmation and check your subscription before buying lifetime.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("pro-lifetime-confirmation-unavailable")
                    }
                }
            }
            .navigationTitle("Switch to lifetime")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("pro-cancel-lifetime")
                }
            }
        }
        .accessibilityIdentifier("pro-lifetime-confirmation")
    }
}
