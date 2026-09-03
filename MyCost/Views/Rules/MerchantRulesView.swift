import SwiftData
import SwiftUI

struct MerchantRulesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \MerchantRule.updatedAt, order: .reverse) private var merchantRules: [MerchantRule]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var editingRule: MerchantRule?
    @State private var isAddingRule = false

    var body: some View {
        List {
            if merchantRules.isEmpty {
                ContentUnavailableView("No merchant rules", systemImage: "wand.and.stars")
            } else {
                ForEach(merchantRules) { rule in
                    Button {
                        editingRule = rule
                    } label: {
                        MerchantRuleRow(rule: rule)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteRules)
            }
        }
        .navigationTitle("Merchant Rules")
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

    private func deleteRules(at offsets: IndexSet) {
        let toDelete = merchantRules.elements(at: offsets)
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
                Text(rule.displayName)
                    .font(.headline)
                Spacer()
                Text(rule.isEnabled ? "Enabled" : "Disabled")
                    .font(.caption)
                    .foregroundStyle(rule.isEnabled ? .green : .secondary)
            }

            Text(rule.matchText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Text(rule.normalizedMatchText)
                Spacer()
                if let category = rule.category {
                    Label(category.name, systemImage: category.symbolName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct MerchantRuleEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let rule: MerchantRule?
    let categories: [Category]

    @State private var matchText = ""
    @State private var displayName = ""
    @State private var selectedCategoryID: UUID?
    @State private var isEnabled = true
    @State private var validationMessage: String?

    private let merchantRuleService = MerchantRuleService()

    private var title: String {
        rule == nil ? "Add Rule" : "Edit Rule"
    }

    private var visibleCategories: [Category] {
        categories.filter { $0.isActive || $0.id == selectedCategoryID }
    }

    var body: some View {
        Form {
            Section("Rule") {
                TextField("Match Text", text: $matchText)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("merchantRule.matchText")

                TextField("Merchant Name", text: $displayName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("merchantRule.displayName")

                Picker("Category", selection: $selectedCategoryID) {
                    Text("No category").tag(UUID?.none)
                    ForEach(visibleCategories) { category in
                        Label(category.name, systemImage: category.symbolName.isEmpty ? "tag" : category.symbolName)
                            .tag(Optional(category.id))
                    }
                }
                .accessibilityIdentifier("merchantRule.category")

                Toggle("Enabled", isOn: $isEnabled)
                    .accessibilityIdentifier("merchantRule.enabled")
            }

            Section("Normalized Match") {
                Text(MerchantRuleNormalizer.normalizedMerchantKey(for: matchText))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .accessibilityIdentifier("merchantRule.save")
            }
        }
        .onAppear(perform: loadInitialValues)
    }

    private func loadInitialValues() {
        guard let rule else { return }
        matchText = rule.matchText
        displayName = rule.displayName
        selectedCategoryID = rule.category?.id
        isEnabled = rule.isEnabled
    }

    private func save() {
        let normalizedMatch = MerchantRuleNormalizer.normalizedMerchantKey(for: matchText)
        guard !normalizedMatch.isEmpty else {
            validationMessage = "Enter match text with a merchant name."
            return
        }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayName.isEmpty else {
            validationMessage = "Enter a merchant name."
            return
        }

        let category = categories.first { $0.id == selectedCategoryID }
        let isEditing = rule != nil
        if let rule {
            merchantRuleService.updateRule(
                rule,
                matchText: matchText,
                displayName: trimmedDisplayName,
                category: category,
                isEnabled: isEnabled
            )
        } else {
            let rule = MerchantRule(
                matchText: matchText.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedMatchText: normalizedMatch,
                displayName: trimmedDisplayName,
                isEnabled: isEnabled,
                category: category
            )
            modelContext.insert(rule)
        }

        do {
            try modelContext.save()
            ToastCenter.shared.success(isEditing ? CRUDFeedback.updated("rule") : CRUDFeedback.added("rule"))
            dismiss()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
            ToastCenter.shared.error(CRUDFeedback.saveFailure("rule"))
        }
    }
}
