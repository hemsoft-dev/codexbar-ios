import SwiftUI

private struct OriginalPurchaserNoticeKey: EnvironmentKey {
    static let defaultValue: OriginalPurchaserNotice? = nil
}

extension EnvironmentValues {
    var originalPurchaserNotice: OriginalPurchaserNotice? {
        get { self[OriginalPurchaserNoticeKey.self] }
        set { self[OriginalPurchaserNoticeKey.self] = newValue }
    }
}

/// Inline presentation keeps account setup, authentication and existing sheets uninterrupted.
struct OriginalPurchaserNoticeView: View {
    @EnvironmentObject private var entitlement: ProEntitlement
    @ObservedObject var notice: OriginalPurchaserNotice

    var body: some View {
        if notice.shouldShow(value: entitlement.value, isResolved: entitlement.isResolved) {
            TimelineView(.explicit([ProOriginalPurchaserPolicy.cutover])) { _ in
                VStack(alignment: .leading, spacing: 16) {
                    Label("Lifetime Pro", systemImage: "gift.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityAddTraits(.isHeader)

                    Text(OriginalPurchaserNotice.message)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("original-purchaser-thank-you")

                    if let message = notice.familyMessage() {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("original-purchaser-family-deadline")
                    }

                    Button("Got it", action: notice.acknowledge)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("original-purchaser-acknowledge")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.primary.opacity(0.1))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("original-purchaser-notice")
            }
        }
    }
}
