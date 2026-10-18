import SwiftUI

struct ProCurrentPlanView: View {
    let presentation: ProCommercePresentation
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.planTitle)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("pro-current-plan")
            Text(presentation.detail)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pro-plan-detail")
            if let end = presentation.periodEnd, let kind = presentation.dateKind {
                Text("\(dateLabel(kind)) \(end.formatted(date: .long, time: .omitted))")
                    .accessibilityIdentifier("pro-period-end")
            }
            if let product = presentation.nextRenewalProduct {
                Text("Next plan: \(product.proPlanName)")
                    .accessibilityIdentifier("pro-next-renewal-product")
            }
            if let price = presentation.renewalPriceText(locale: locale) {
                Text("Next charge: \(price)")
                    .accessibilityIdentifier("pro-next-renewal-price")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    private func dateLabel(_ kind: ProPlanDateKind) -> String {
        switch kind {
        case .renews: "Renews"
        case .expires: "Subscription ends"
        case .trialEnds: "Trial ends"
        }
    }
}

struct ProProductOptionView: View {
    let product: ProCatalogProduct
    let isBusy: Bool
    let actionTitle: String
    let onPurchase: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                title
                price
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    title
                    Spacer(minLength: 0)
                    price
                }
            }
            if product.offersSevenDayTrial {
                Text("7 days free, then \(product.displayPrice) per year")
                    .font(.subheadline)
                    .accessibilityIdentifier("pro-yearly-trial")
            }
            Button(actionTitle, action: onPurchase)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)
                .accessibilityIdentifier("pro-purchase-\(product.id.proIdentifier)")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pro-product-\(product.id.proIdentifier)")
    }

    private var title: some View {
        Text(product.displayName)
            .font(.headline)
    }

    private var price: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(product.displayPrice)
                .font(.title2.weight(.semibold))
            Text(product.periodDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProBenefitsView: View {
    var body: some View {
        Section("With Pro") {
            Label("Keep every account refreshing", systemImage: "person.2")
            Label("See your full saved history", systemImage: "chart.xyaxis.line")
            Label("Receive usage alerts", systemImage: "bell")
            Label("Check usage on widgets and Apple Watch", systemImage: "applewatch")
        }
        Section {
            Text(
                "Your saved accounts, credentials, history, and alert settings stay on this device when Pro ends. "
                    + "Pro restores access without setting up your accounts again."
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProPolicyLinksView: View {
    var body: some View {
        Section {
            Link("Privacy Policy", destination: ProCommerceLinks.privacy)
                .accessibilityIdentifier("pro-privacy-policy")
            Link("Terms of Use", destination: ProCommerceLinks.terms)
                .accessibilityIdentifier("pro-terms-of-use")
        } footer: {
            Text("Subscriptions renew automatically unless canceled in your Apple Account settings. Apple handles purchases and billing.")
        }
    }
}

struct ProCommerceFeedback {
    let title: String
    let detail: String
    var isError = false
}

struct ProCommerceFeedbackView: View {
    let feedback: ProCommerceFeedback

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(feedback.title, systemImage: feedback.isError ? "exclamationmark.circle" : "info.circle")
                .font(.headline)
            Text(feedback.detail)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pro-command-status")
    }
}

enum ProCommerceLinks {
    static let privacy = URL(string: "https://github.com/hemsoft-dev/codexbar-ios/blob/main/PRIVACY.md")!
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let billing = URL(string: "https://apps.apple.com/account/billing")!
}

extension ProProductID {
    var proIdentifier: String {
        switch self {
        case .monthly: "monthly"
        case .yearly: "yearly"
        case .lifetime: "lifetime"
        }
    }

    var proPlanName: String {
        switch self {
        case .monthly: "Monthly Pro"
        case .yearly: "Yearly Pro"
        case .lifetime: "Lifetime Pro"
        }
    }
}
