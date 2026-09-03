import SwiftUI

/// Pick one of your existing merchant rules to apply to the transaction in
/// hand. Rules whose match text matches (the merchant name **or** the bank's
/// original description) are listed first and attach with one tap; the rest can
/// still be force-attached after a confirmation, for when a name was cleaned up
/// so much that the rule text no longer appears in it.
struct AttachExistingRuleView: View {
    let merchantName: String
    /// The bank's raw description. Rules are often learned from this, so it's
    /// checked even when the visible merchant name has been hand-edited.
    let originalDescription: String
    let rules: [MerchantRule]
    let onAttach: (MerchantRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var forceAttachCandidate: MerchantRule?
    private let service = MerchantRuleService()

    private var showsOriginalDescription: Bool {
        !originalDescription.isEmpty && originalDescription != merchantName
    }

    private var matching: [MerchantRule] {
        service.rulesMatching(
            merchantName: merchantName,
            originalDescription: originalDescription.isEmpty ? merchantName : originalDescription,
            in: rules
        ).alphabetizedByName()
    }

    private var others: [MerchantRule] {
        let matchIDs = Set(matching.map(\.id))
        return rules.filter { $0.isEnabled && !matchIDs.contains($0.id) }.alphabetizedByName()
    }

    var body: some View {
        List {
            Section {
                Text("\u{201C}\(merchantName)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if showsOriginalDescription {
                    Text("Bank text: \u{201C}\(originalDescription)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Transaction text")
            }

            Section {
                if matching.isEmpty {
                    Text("No rule's match text matches this transaction. Pick one below to attach it anyway.")
                        .foregroundStyle(.secondary)
                }
                ForEach(matching) { rule in
                    Button {
                        onAttach(rule)
                        dismiss()
                    } label: {
                        RuleSummaryRow(rule: rule)
                    }
                    .accessibilityIdentifier("attachRule.match")
                }
            } header: {
                Text("Matching rules")
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { rule in
                        Button {
                            forceAttachCandidate = rule
                        } label: {
                            RuleSummaryRow(rule: rule)
                        }
                        .accessibilityIdentifier("attachRule.other")
                    }
                } header: {
                    Text("Other rules")
                } footer: {
                    Text("These rules\u{2019} match text isn\u{2019}t found in this transaction. Tap one to attach it anyway \u{2014} useful when you\u{2019}ve renamed the transaction.")
                }
            }
        }
        .navigationTitle("Attach Rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .confirmationDialog(
            "Attach this rule anyway?",
            isPresented: Binding(
                get: { forceAttachCandidate != nil },
                set: { if !$0 { forceAttachCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Attach Rule") {
                if let rule = forceAttachCandidate {
                    onAttach(rule)
                    forceAttachCandidate = nil
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { forceAttachCandidate = nil }
        } message: {
            if let rule = forceAttachCandidate {
                Text("\u{201C}\(rule.matchText)\u{201D} isn\u{2019}t found in this transaction, but the rule will still be applied to it.")
            }
        }
    }
}

private struct RuleSummaryRow: View {
    let rule: MerchantRule

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(rule.normalizedMerchantName).font(.body)
                if rule.isRecurring {
                    Text("Recurring")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                }
                if !rule.isActive {
                    Text("Disabled").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(rule.matchType.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                Text("\u{201C}\(rule.matchText)\u{201D}").lineLimit(1)
                if let category = rule.category {
                    Text("\u{00B7} \(category.name)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
