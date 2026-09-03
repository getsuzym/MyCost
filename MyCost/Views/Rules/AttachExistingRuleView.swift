import SwiftUI

/// Pick one of your saved merchant rules to apply to the transaction in hand.
/// Rules whose match text is found in the merchant name **or** the bank's
/// original description are listed under "Matching rules"; every other rule
/// (including disabled ones, and ones whose text no longer matches after a
/// rename) is under "Other rules". Either way, one tap attaches it.
struct AttachExistingRuleView: View {
    let merchantName: String
    /// The bank's raw description — rules are often learned from this, so it's
    /// checked even when the visible merchant name has been hand-edited.
    let originalDescription: String
    let rules: [MerchantRule]
    let onAttach: (MerchantRule) -> Void

    @Environment(\.dismiss) private var dismiss
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

    /// Everything not already in `matching` — including disabled rules, so a
    /// rule you turned off is still reachable here.
    private var others: [MerchantRule] {
        let matchIDs = Set(matching.map(\.id))
        return rules.filter { !matchIDs.contains($0.id) }.alphabetizedByName()
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

            if rules.isEmpty {
                Section {
                    Text("You have no saved rules yet.")
                        .foregroundStyle(.secondary)
                }
            }

            if !matching.isEmpty {
                Section {
                    ForEach(matching) { rule in
                        attachButton(for: rule, id: "attachRule.match")
                    }
                } header: {
                    Text("Matching rules")
                }
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { rule in
                        attachButton(for: rule, id: "attachRule.other")
                    }
                } header: {
                    Text(matching.isEmpty ? "Rules" : "Other rules")
                } footer: {
                    Text("The rule's match text isn't found in this transaction (or the rule is disabled), but tapping still applies it \u{2014} handy after you've renamed the transaction.")
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
    }

    private func attachButton(for rule: MerchantRule, id: String) -> some View {
        Button {
            onAttach(rule)
            dismiss()
        } label: {
            RuleSummaryRow(rule: rule)
        }
        .accessibilityIdentifier(id)
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
