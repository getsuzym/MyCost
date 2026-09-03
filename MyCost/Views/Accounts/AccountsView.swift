import SwiftData
import SwiftUI

/// Set up the accounts transactions are imported from and, crucially, each
/// account's **type** (Credit Card / Debit / Other). The type is remembered here
/// and reused on every future import so sign normalization is consistent.
struct AccountsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var transactions: [Transaction]

    @State private var editingAccount: Account?
    @State private var isAddingAccount = false

    private let service = AccountService()

    var body: some View {
        List {
            if accounts.isEmpty {
                ContentUnavailableView(
                    "No accounts yet",
                    systemImage: "creditcard",
                    description: Text("Add the accounts you import from and pick each one's type.")
                )
            } else {
                ForEach(accounts) { account in
                    Button {
                        editingAccount = account
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name).font(.headline)
                                Text(account.accountType.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(transactionCount(for: account))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("accounts.row")
                }
                .onDelete(perform: deleteAccounts)
            }
        }
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .accessibilityIdentifier("accounts.add")
            }
        }
        .sheet(isPresented: $isAddingAccount) {
            NavigationStack { AccountEditorView(account: nil) }
        }
        .sheet(item: $editingAccount) { account in
            NavigationStack { AccountEditorView(account: account) }
        }
    }

    private func transactionCount(for account: Account) -> Int {
        let key = AccountService.normalizedName(account.name)
        return transactions.filter { AccountService.normalizedName($0.accountName) == key }.count
    }

    private func deleteAccounts(at offsets: IndexSet) {
        let toDelete = accounts.elements(at: offsets)
        guard !toDelete.isEmpty else { return }
        toDelete.forEach(modelContext.delete)
        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.deleted("account", count: toDelete.count))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.deleteFailure("account"))
        }
    }
}

private struct AccountEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Account.name) private var accounts: [Account]

    let account: Account?

    @State private var name = ""
    @State private var accountType: AccountType = .other
    @State private var validationMessage: String?

    private let service = AccountService()

    private var title: String { account == nil ? "Add Account" : "Edit Account" }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("accountEditor.name")

                Picker("Type", selection: $accountType) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .accessibilityIdentifier("accountEditor.type")
            } header: {
                Text("Account")
            } footer: {
                Text("Credit Card: purchases positive, payments/refunds not spending. Debit/Chequing: purchases negative, deposits are income. Other: best-effort, ambiguous amounts flagged for review.")
            }

            if let validationMessage {
                Section { Text(validationMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).accessibilityIdentifier("accountEditor.save")
            }
        }
        .onAppear {
            if let account {
                name = account.name
                accountType = account.accountType
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "Enter an account name."
            return
        }
        let clashes = accounts.contains {
            $0.id != account?.id && AccountService.normalizedName($0.name) == AccountService.normalizedName(trimmed)
        }
        guard !clashes else {
            validationMessage = "An account named \u{201C}\(trimmed)\u{201D} already exists."
            return
        }

        do {
            if let account {
                try service.updateAccount(account, name: trimmed, type: accountType, modelContext: modelContext)
                ToastCenter.shared.success(CRUDFeedback.updated("account"))
            } else {
                let created = Account(name: trimmed, accountType: accountType)
                modelContext.insert(created)
                try modelContext.save()
                ToastCenter.shared.success(CRUDFeedback.added("account"))
            }
            dismiss()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
            ToastCenter.shared.error(CRUDFeedback.saveFailure("account"))
        }
    }
}
