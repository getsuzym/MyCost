import SwiftData
import SwiftUI

struct MerchantRulesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var merchantRules: [MerchantRule]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var editingRule: MerchantRule?
    @State private var isAddingRule = false
    @State private var searchText = ""

    /// Alphabetical by normalized merchant name (priority still governs which
    /// rule wins a conflict), filtered by the search field.
    private var displayedRules: [MerchantRule] {
        let sorted = merchantRules.alphabetizedByName()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { rule in
            rule.normalizedMerchantName.localizedCaseInsensitiveContains(query)
                || rule.matchText.localizedCaseInsensitiveContains(query)
                || (rule.category?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        List {
            if merchantRules.isEmpty {
                ContentUnavailableView("No merchant rules", systemImage: "wand.and.stars")
            } else if displayedRules.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ForEach(displayedRules) { rule in
                    Button {
                        editingRule = rule
                    } label: {
                        MerchantRuleRow(rule: rule)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            delete(rule)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            toggle(rule)
                        } label: {
                            Label(rule.isActive ? "Disable" : "Enable",
                                  systemImage: rule.isActive ? "pause" : "play")
                        }
                        .tint(rule.isActive ? .orange : .green)
                    }
                }
                .onDelete(perform: deleteRules)
            }
        }
        .navigationTitle("Merchant Rules")
        .themedListBackground()
        .searchable(text: $searchText, prompt: "Search rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingRule = true
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .accessibilityIdentifier("merchantRules.add")
            }
        }
        .sheet(item: $editingRule) { rule in
            NavigationStack {
                MerchantRuleEditorView(rule: rule, categories: categories)
            }
        }
        .sheet(isPresented: $isAddingRule) {
            NavigationStack {
                MerchantRuleEditorView(rule: nil, categories: categories)
            }
        }
    }

    private func toggle(_ rule: MerchantRule) {
        rule.isActive.toggle()
        rule.updatedAt = .now
        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.updated("rule"))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.saveFailure("rule"))
        }
    }

    private func delete(_ rule: MerchantRule) {
        modelContext.delete(rule)
        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.deleted("rule"))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.deleteFailure("rule"))
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        let toDelete = displayedRules.elements(at: offsets)
        guard !toDelete.isEmpty else { return }
        toDelete.forEach(modelContext.delete)
        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.deleted("rule", count: toDelete.count))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.deleteFailure("rule"))
        }
    }
}

private struct MerchantRuleRow: View {
    let rule: MerchantRule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(rule.normalizedMerchantName)
                    .font(.headline)
                Spacer()
                Text(rule.isActive ? "Enabled" : "Disabled")
                    .font(.caption)
                    .foregroundStyle(rule.isActive ? .green : .secondary)
            }

            HStack(spacing: 6) {
                Text(rule.matchType.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                Text("\u{201C}\(rule.matchText)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Text("Priority \(rule.priority)")
                Spacer()
                if let category = rule.category {
                    Label(category.name, systemImage: category.symbolName.isEmpty ? "tag" : category.symbolName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
