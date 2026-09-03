import SwiftData
import SwiftUI

struct TransactionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var transaction: Transaction
    @State private var isEditing = false
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
                    LabeledContent("Frequency", value: recurringPayment.frequency.label)
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
        modelContext.delete(transaction)
        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.deleted("transaction"))
            dismiss()
        } catch {
            ToastCenter.shared.error(CRUDFeedback.deleteFailure("transaction"))
        }
    }
}

