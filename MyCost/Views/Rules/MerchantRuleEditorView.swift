import SwiftData
import SwiftUI

/// Reusable MerchantRule create/edit sheet. Presented from the Merchant Rules
/// tab and inline from the Review Transactions screen.
///
/// - `onSaved` receives the affected (already-persisted) rule so the caller can
///   re-apply it immediately.
/// - `onDeleted`, when non-nil, adds a Delete button.
/// - `initial*` pre-fill a brand-new rule; `previewExample` seeds the live
///   "This rule matches: …" check with the transaction in hand.
struct MerchantRuleEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let rule: MerchantRule?
    let categories: [Category]
    var initialMatchText: String = ""
    var initialDisplayName: String = ""
    var initialCategoryID: UUID?
    var initialIsRecurring: Bool = false
    var previewExample: String = ""
    var onSaved: (MerchantRule) -> Void = { _ in }
    var onDeleted: (() -> Void)?

    @State private var matchText = ""
    @State private var matchType: MerchantRuleMatchType = .contains
    @State private var displayName = ""
    @State private var selectedCategoryID: UUID?
    @State private var priority = 0
    @State private var isEnabled = true
    @State private var isRecurring = false
    @State private var recurringFrequency: RecurrenceFrequency = .monthly
    @State private var exampleDescription = ""
    @State private var validationMessage: String?
    @State private var didLoad = false

    private let merchantRuleService = MerchantRuleService()

    private var title: String { rule == nil ? "New Rule" : "Edit Rule" }

    private var visibleCategories: [Category] {
        categories.filter { $0.isActive || $0.id == selectedCategoryID }.alphabetizedByName()
    }

    private var probeRule: MerchantRule {
        MerchantRule(
            matchText: matchText,
            displayName: displayName.isEmpty ? "Preview" : displayName,
            matchType: matchType,
            priority: priority
        )
    }

    private var trimmedExample: String {
        exampleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewMatches: Bool {
        guard !trimmedExample.isEmpty else { return false }
        return merchantRuleService.matches(probeRule, merchantName: trimmedExample, originalDescription: trimmedExample)
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

                Toggle("Active", isOn: $isEnabled)
                    .accessibilityIdentifier("merchantRule.enabled")
            } header: {
                Text("Match")
            } footer: {
                Text("Matched case-insensitively against the merchant name and the bank's original description. Higher priority wins a conflict; otherwise Exact beats Starts/Ends With beats Contains.")
            }

            Section("Result") {
                TextField("Normalized merchant name", text: $displayName)
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

                Toggle("Mark matching transactions recurring", isOn: $isRecurring)
                    .accessibilityIdentifier("merchantRule.recurring")
                if isRecurring {
                    Picker("Frequency", selection: $recurringFrequency) {
                        ForEach(RecurrenceFrequency.allCases.filter { $0 != .none }) { frequency in
                            Text(frequency.label).tag(frequency)
                        }
                    }
                    .accessibilityIdentifier("merchantRule.frequency")
                }
            }

            Section("Preview") {
                TextField("Example transaction description", text: $exampleDescription)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("merchantRule.example")
                if !trimmedExample.isEmpty {
                    Label(
                        previewMatches ? "This rule matches: \(trimmedExample)" : "Does not match this example.",
                        systemImage: previewMatches ? "checkmark.circle.fill" : "xmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(previewMatches ? .green : .secondary)
                    .accessibilityIdentifier("merchantRule.previewResult")
                }
            }

            if rule != nil, let onDeleted {
                Section {
                    Button("Delete Rule", role: .destructive) { deleteRule(onDeleted) }
                        .accessibilityIdentifier("merchantRule.delete")
                }
            }

            if let validationMessage {
                Section { Text(validationMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).accessibilityIdentifier("merchantRule.save")
            }
        }
        .onAppear(perform: loadOnce)
    }

    private var matchTextPlaceholder: String {
        switch matchType {
        case .exact: "Exact description or merchant"
        case .contains: "Text the description contains (e.g. NETFLIX)"
        case .startsWith: "Text the description starts with"
        case .endsWith: "Text the description ends with"
        }
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        exampleDescription = previewExample
        if let rule {
            matchText = rule.matchText
            matchType = rule.matchType
            displayName = rule.normalizedMerchantName
            selectedCategoryID = rule.category?.id
            priority = rule.priority
            isEnabled = rule.isActive
            isRecurring = rule.isRecurring
            recurringFrequency = rule.recurringFrequency
        } else {
            matchText = initialMatchText
            displayName = initialDisplayName
            selectedCategoryID = initialCategoryID
            isRecurring = initialIsRecurring
        }
    }

    private func deleteRule(_ onDeleted: () -> Void) {
        guard let rule else { return }
        modelContext.delete(rule)
        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.deleted("rule"))
            onDeleted()
            dismiss()
        } catch {
            validationMessage = "Delete failed: \(error.localizedDescription)"
            ToastCenter.shared.error(CRUDFeedback.deleteFailure("rule"))
        }
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
            validationMessage = "Enter a normalized merchant name."
            return
        }

        let category = categories.first { $0.id == selectedCategoryID }
        let isEditing = rule != nil
        let affected: MerchantRule
        if let rule {
            merchantRuleService.updateRule(
                rule,
                matchText: trimmedMatch,
                displayName: trimmedDisplayName,
                matchType: matchType,
                priority: priority,
                isRecurring: isRecurring,
                recurringFrequency: recurringFrequency,
                category: category,
                isEnabled: isEnabled
            )
            affected = rule
        } else {
            let newRule = MerchantRule(
                matchText: trimmedMatch,
                displayName: trimmedDisplayName,
                matchType: matchType,
                priority: priority,
                isRecurring: isRecurring,
                recurringFrequency: recurringFrequency,
                isEnabled: isEnabled,
                category: category
            )
            modelContext.insert(newRule)
            affected = newRule
        }

        do {
            try modelContext.save()
            ToastCenter.shared.success(isEditing ? CRUDFeedback.updated("rule") : CRUDFeedback.added("rule"))
            onSaved(affected)
            dismiss()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
            ToastCenter.shared.error(CRUDFeedback.saveFailure("rule"))
        }
    }
}
