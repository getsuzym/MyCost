import SwiftData
import SwiftUI

struct TransactionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var transaction: Transaction
    @State private var isEditing = false
    @State private var isShowingTagPicker = false
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        List {
            Section {
                LabeledContent("Merchant", value: transaction.merchantName)
                LabeledContent("Amount", value: Formatters.currencyString(for: transaction.amount))
                LabeledContent("Date", value: Formatters.shortDate.string(from: transaction.transactionDate))
                LabeledContent("Account", value: transaction.accountName)
                LabeledContent("Category", value: transaction.category?.name ?? "Uncategorized")
            }

            Section("Options") {
                LabeledContent("Type", value: transaction.isIncome ? "Income" : "Spending")
                LabeledContent("Excluded", value: transaction.isExcluded ? "Yes" : "No")
                if transaction.isExcluded, !transaction.excludedReason.isEmpty {
                    LabeledContent("Reason", value: transaction.excludedReason)
                }
                Toggle("Recurring", isOn: Binding(
                    get: { transaction.isRecurring },
                    set: { setRecurring($0) }
                ))
                .accessibilityIdentifier("transactionDetail.recurring")
                if let recurringPayment = transaction.recurringPayment {
                    LabeledContent("Frequency", value: recurringPayment.schedule().label)
                }
            }

            Section {
                if transaction.tags.isEmpty {
                    Text("No tags").foregroundStyle(.secondary)
                } else {
                    Text(transaction.tags.alphabetizedByName().map(\.name).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                Button {
                    isShowingTagPicker = true
                } label: {
                    Label("Edit Tags", systemImage: "tag")
                }
                .accessibilityIdentifier("transactionDetail.editTags")
            } header: {
                Text("Tags")
            }

            if transaction.isSplit {
                Section("Split") {
                    ForEach(transaction.splits.sorted { $0.amount > $1.amount }) { split in
                        LabeledContent(split.category?.name ?? "Uncategorized", value: Formatters.currencyString(for: split.amount))
                    }
                }
            }

            if !transaction.note.isEmpty {
                Section("Note") {
                    Text(transaction.note)
                }
            }

            Section {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Label("Delete Transaction", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Transaction")
        .themedListBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    isEditing = true
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                TransactionEditorView(mode: .edit(transaction))
            }
        }
        .sheet(isPresented: $isShowingTagPicker) {
            TransactionTagPickerView(transaction: transaction)
        }
        .confirmationDialog("Delete this transaction?", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteTransaction)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func setRecurring(_ value: Bool) {
        transaction.isRecurring = value
        // Unmarking detaches the transaction from any generated series.
        if !value { transaction.recurringPayment = nil }
        transaction.updatedAt = .now
        do {
            try modelContext.save()
            ToastCenter.shared.success("Recurring status updated")
        } catch {
            transaction.isRecurring = !value
            ToastCenter.shared.error(CRUDFeedback.saveFailure("transaction"))
        }
    }

    private func deleteTransaction() {
        // Leave right away — the actual delete is deferred (Undo), but there's
        // nothing left for this screen to show either way.
        dismiss()
        TrashBin.shared.deleteTransactions([transaction], modelContext: modelContext)
    }
}

/// Add/remove tags without opening the full transaction editor. Every tap
/// applies and saves immediately (same philosophy as `TransactionDetailView`'s
/// inline Recurring toggle) — there's no separate Save, just Done.
private struct TransactionTagPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var transaction: Transaction
    @Query private var allTags: [Tag]
    @State private var newTagName = ""

    private let tagService = TagService()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if allTags.isEmpty {
                        Text("No tags yet — add one below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(allTags.alphabetizedByName()) { tag in
                        Button {
                            toggle(tag)
                        } label: {
                            HStack {
                                Image(systemName: isApplied(tag) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isApplied(tag) ? Theme.accent : .secondary)
                                Text(tag.name).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("transactionDetail.tagRow")
                    }

                    HStack {
                        TextField("New tag", text: $newTagName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addTypedTag)
                            .accessibilityIdentifier("transactionDetail.newTag")
                        Button("Add", action: addTypedTag)
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Tap a tag to add or remove it — changes save right away.")
                }
            }
            .themedListBackground()
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func isApplied(_ tag: Tag) -> Bool {
        transaction.tags.contains { $0.id == tag.id }
    }

    private func toggle(_ tag: Tag) {
        if isApplied(tag) {
            tagService.detach(tag, from: transaction)
        } else {
            tagService.attach(tag, to: transaction)
        }
        transaction.updatedAt = .now
        modelContext.saveOrLog("toggle tag on transaction")
    }

    private func addTypedTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let tag = tagService.upsert(name: name, in: allTags, modelContext: modelContext) {
            tagService.attach(tag, to: transaction)
            transaction.updatedAt = .now
            modelContext.saveOrLog("add new tag to transaction")
        }
        newTagName = ""
    }
}

