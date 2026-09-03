import SwiftData
import SwiftUI

struct MerchantRulesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \MerchantRule.priority, order: .reverse) private var merchantRules: [MerchantRule]
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
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
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

private struct MerchantRuleEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let rule: MerchantRule?
    let categories: [Category]

    @State private var matchText = ""
    @State private var matchType: MerchantRuleMatchType = .contains
    @State private var displayName = ""
    @State private var selectedCategoryID: UUID?
    @State private var priority = 0
    @State private var isEnabled = true
    @State private var exampleDescription = ""
    @State private var validationMessage: String?

    private let merchantRuleService = MerchantRuleService()

    private var title: String { rule == nil ? "Add Rule" : "Edit Rule" }

    private var visibleCategories: [Category] {
        categories.filter { $0.isActive || $0.id == selectedCategoryID }
    }

    private var previewMatches: Bool {
        guard !exampleDescription.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let probe = MerchantRule(
            matchText: matchText, displayName: displayName.isEmpty ? "Preview" : displayName,
            matchType: matchType, priority: priority
        )
        return merchantRuleService.matches(probe, merchantName: exampleDescription, originalDescription: exampleDescription)
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $matchType) {
                    ForEach(MerchantRuleMatchType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .accessibilityIdentifier("merchantRule.matchType")

                TextField(matchTextPlaceholder, text: $matchText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("merchantRule.matchText")

                Stepper("Priority: \(priority)", value: $priority, in: 0...100)
                    .accessibilityIdentifier("merchantRule.priority")

                Toggle("Enabled", isOn: $isEnabled)
                    .accessibilityIdentifier("merchantRule.enabled")
            } header: {
                Text("Match")
            } footer: {
                Text("Matched case-insensitively against the merchant name and the bank's original description. Higher priority wins a conflict; otherwise Exact beats Starts/Ends With beats Contains.")
            }

            Section("Result") {
                TextField("Resulting merchant name", text: $displayName)
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
            }

            Section("Preview") {
                TextField("Example transaction description", text: $exampleDescription)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("merchantRule.example")
                Label(
                    previewMatches ? "Matches" : "No match",
                    systemImage: previewMatches ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(previewMatches ? .green : .secondary)
                .accessibilityIdentifier("merchantRule.previewResult")
            }

            if let validationMessage {
                Section { Text(validationMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).accessibilityIdentifier("merchantRule.save")
            }
        }
        .onAppear(perform: loadInitialValues)
    }

    private var matchTextPlaceholder: String {
        switch matchType {
        case .exact: "Exact description or merchant"
        case .contains: "Text the description contains (e.g. UBER EATS)"
        case .startsWith: "Text the description starts with"
        case .endsWith: "Text the description ends with"
        }
    }

    private func loadInitialValues() {
        guard let rule else { return }
        matchText = rule.matchText
        matchType = rule.matchType
        displayName = rule.normalizedMerchantName
        selectedCategoryID = rule.category?.id
        priority = rule.priority
        isEnabled = rule.isActive
    }

    private func save() {
        let trimmedMatch = matchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = MerchantRuleNormalizer.caseFolded(trimmedMatch)
        guard folded.count >= matchType.minimumMatchTextLength else {
            validationMessage = matchType == .exact
                ? "Enter match text."
                : "\(matchType.label) rules need at least \(matchType.minimumMatchTextLength) characters so they aren't overly broad."
            return
        }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayName.isEmpty else {
            validationMessage = "Enter a resulting merchant name."
            return
        }

        let category = categories.first { $0.id == selectedCategoryID }
        let isEditing = rule != nil
        if let rule {
            MerchantRuleService().updateRule(
                rule,
                matchText: trimmedMatch,
                displayName: trimmedDisplayName,
                matchType: matchType,
                priority: priority,
                category: category,
                isEnabled: isEnabled
            )
        } else {
            let rule = MerchantRule(
                matchText: trimmedMatch,
                displayName: trimmedDisplayName,
                matchType: matchType,
                priority: priority,
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
