import SwiftUI

/// Confirmation is separate from the irreversible provider request. Only a verified, selected grant is actionable.
struct ClaudeUsageResetInventoryView: View {
    let inventory: ClaudeUsageResetInventory
    let accountName: String
    let canRedeem: Bool
    let onUseReset: ((ClaudeUsageResetGrant, String) async -> ClaudeUsageResetFeedback)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedGrant: ClaudeUsageResetGrant?
    @State private var confirmationBinding: String?
    @State private var isConfirming = false
    @State private var isSubmitting = false
    @State private var feedback: ClaudeUsageResetFeedback?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                inventoryList(at: context.date)
                    .onChange(of: context.date) { invalidateExpiredConfirmation(at: context.date) }
            }
            .navigationTitle("Claude resets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(isSubmitting)
                }
            }
            .alert("Use one Claude reset?", isPresented: $isConfirming) {
                Button("Cancel", role: .cancel) {
                    selectedGrant = nil
                    confirmationBinding = nil
                }
                Button("Use reset") { redeemSelectedGrant() }
            } message: {
                if let grant = selectedGrant {
                    Text("This uses one saved reset for \(accountName). \(windowDescription(grant)) \(expiration(grant)) This cannot be undone.")
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onChange(of: inventory.credentialBinding) {
            guard !isSubmitting else { return }
            isConfirming = false
            selectedGrant = nil
            confirmationBinding = nil
            feedback = ClaudeUsageResetFeedback(message: "Claude authorization changed. Review the refreshed reset details.", isSuccess: false)
        }
    }

    private func inventoryList(at date: Date) -> some View {
        List {
            Section {
                Text(accountName)
                Text(summary(at: date))
                    .accessibilityIdentifier("claude-reset-summary")
                if !inventory.isEligible {
                    Text("Claude has not made usage resets available for this account.")
                }
                if !canRedeem {
                    Text("Refresh Claude usage before using a reset.")
                }
            }
            Section("Saved usage resets") {
                if inventory.grants.isEmpty {
                    Text("No saved usage resets.")
                }
                ForEach(inventory.grants, id: \.id) { grant in
                    grantRow(grant, at: date)
                }
            }
            if let feedback {
                Section {
                    Label(feedback.message, systemImage: feedback.isSuccess ? "checkmark.circle" : "info.circle")
                        .accessibilityIdentifier("claude-reset-feedback")
                }
            }
        }
    }

    private func summary(at date: Date) -> String {
        let count = inventory.availableCount(at: date)
        return count == 1 ? "1 reset available" : "\(count) resets available"
    }

    private func invalidateExpiredConfirmation(at date: Date) {
        guard !isSubmitting, let grant = selectedGrant, let binding = confirmationBinding,
              !inventory.matchesConfirmation(grant: grant, binding: binding, at: date) else { return }
        isConfirming = false
        selectedGrant = nil
        confirmationBinding = nil
        feedback = ClaudeUsageResetFeedback(message: "These reset details changed. Review them before confirming again.", isSuccess: false)
    }

    private func grantRow(_ grant: ClaudeUsageResetGrant, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(grant.title).font(.headline)
            Text(grant.remainingCount == 1 ? "1 saved reset" : "\(grant.remainingCount) saved resets")
            Text(windowDescription(grant))
            Text(expiration(grant)).font(.subheadline).foregroundStyle(.secondary)
            if grant.isPaused {
                Text("Paused by Claude").foregroundStyle(.secondary)
            } else if !grant.isCurrent(at: date) {
                Text("Not currently available").foregroundStyle(.secondary)
            } else if let cooldown = inventory.cooldownUntil, cooldown > date {
                Text("Claude reset cooldown ends \(cooldown.formatted(date: .abbreviated, time: .shortened)).")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("claude-reset-cooldown")
            } else if inventory.selectedGrantID != grant.id {
                Text("CodexBar can currently use only the reset selected by Claude.").foregroundStyle(.secondary)
            } else if inventory.redeemableGrant(at: date)?.id != grant.id {
                Text(grant.requiresLimit
                     ? "Claude may require a usage limit to be reached before this reset can be used."
                     : "Claude has not enabled this reset for use now.").foregroundStyle(.secondary)
            }
            if isSubmitting && selectedGrant?.id == grant.id
                || (canRedeem && onUseReset != nil && inventory.credentialBinding != nil
                    && inventory.redeemableGrant(at: date)?.id == grant.id) {
                Button {
                    selectedGrant = grant
                    confirmationBinding = inventory.credentialBinding
                    isConfirming = true
                } label: {
                    if isSubmitting { ProgressView("Using reset…") } else { Text("Use one reset") }
                }
                .buttonStyle(.bordered)
                .disabled(isSubmitting || !canRedeem)
                .accessibilityIdentifier("claude-use-reset")
            }
        }
        .padding(.vertical, 4)
    }

    private func windowDescription(_ grant: ClaudeUsageResetGrant) -> String {
        let windows = grant.clears.map { value in
            switch value {
            case "five_hour": "five-hour usage"
            case "seven_day": "weekly usage"
            case "seven_day_opus": "Opus weekly usage"
            case "seven_day_sonnet": "Sonnet weekly usage"
            default: "provider-scoped usage"
            }
        }
        return "Resets \(Array(Set(windows)).sorted().joined(separator: " and "))."
    }

    private func expiration(_ grant: ClaudeUsageResetGrant) -> String {
        guard let date = grant.expiresAt else { return "Expiration not provided by Claude." }
        return "Expires \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    private func redeemSelectedGrant() {
        guard !isSubmitting else { return }
        guard canRedeem, let onUseReset, let selectedGrant, let binding = confirmationBinding,
              inventory.matchesConfirmation(grant: selectedGrant, binding: binding, at: Date())
        else {
            feedback = ClaudeUsageResetFeedback(message: "These reset details changed. Review them before confirming again.", isSuccess: false)
            self.selectedGrant = nil
            confirmationBinding = nil
            return
        }
        isSubmitting = true
        Task { @MainActor in
            feedback = await onUseReset(selectedGrant, binding)
            self.selectedGrant = nil
            confirmationBinding = nil
            isSubmitting = false
        }
    }
}
