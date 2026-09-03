import SwiftUI

/// Pick one of your existing merchant rules to apply to the transaction in
/// hand. Only rules whose match text actually matches the transaction can be
/// attached; the rest are shown greyed-out for reference.
struct AttachExistingRuleView: View {
    /// The text the rule is checked against (merchant name / original description).
    let candidateText: String
    let rules: [MerchantRule]
    let onAttach: (MerchantRule) -> Void

    @Environment(\.dismiss) private var dismiss
    private let service = MerchantRuleService()

    private var matching: [MerchantRule] {
        service.rulesMatching(candidateText, in: rules).alphabetizedByName()
    }

    private var nonMatching: [MerchantRule] {
        let matchIDs = Set(matching.map(\.id))
        return rules.filter { $0.isEnabled && !matchIDs.contains($0.id) }.alphabetizedByName()
    }

    var body: some View {
        List {
            Section {
                Text("\u{201C}\(candidateText)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Transaction text")
            }

            Section {
                if matching.isEmpty {
                    Text("No existing rule matches this text.")
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

            if !nonMatching.isEmpty {
                Section {
                    ForEach(nonMatching) { rule in
                        RuleSummaryRow(rule: rule)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Doesn\u{2019}t match")
                } footer: {
                    Text("A rule can only be attached when its match text matches this transaction.")
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
