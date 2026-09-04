import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DataPortabilityView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var merchantRules: [MerchantRule]
    @Query private var recurringPayments: [RecurringPayment]
    @Query private var budgets: [Budget]

    @State private var share: ShareURL?
    @State private var isImporting = false
    @State private var pendingRestore: DataPortabilityService.Backup?
    @State private var message: String?

    private let service = DataPortabilityService()

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: .now)
    }

    var body: some View {
        List {
            Section {
                Button {
                    exportCSV()
                } label: {
                    Label("Export transactions (CSV)", systemImage: "tablecells")
                }
                .accessibilityIdentifier("data.exportCSV")

                Button {
                    exportBackup()
                } label: {
                    Label("Export full backup (JSON)", systemImage: "arrow.up.doc")
                }
                .accessibilityIdentifier("data.exportBackup")
            } header: {
                Text("Export")
            } footer: {
                Text("\(transactions.count) transaction\(transactions.count == 1 ? "" : "s"). The CSV is for spreadsheets; the JSON backup restores everything (categories, rules, recurring, budgets).")
            }

            Section {
                Button(role: .destructive) {
                    isImporting = true
                } label: {
                    Label("Restore from backup\u{2026}", systemImage: "arrow.down.doc")
                }
                .accessibilityIdentifier("data.restore")
            } header: {
                Text("Restore")
            } footer: {
                Text("Replaces everything currently in the app with the contents of a JSON backup file. This can't be undone \u{2014} export a backup first.")
            }

            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Export & Backup")
        .themedListBackground()
        .sheet(item: $share) { item in
            ActivityView(items: [item.url])
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .confirmationDialog(
            "Replace all data with this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace Everything", role: .destructive) { runRestore() }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            if let b = pendingRestore {
                Text("The backup has \(b.transactions.count) transactions, \(b.categories.count) categories, \(b.merchantRules.count) rules. Everything in the app now will be removed.")
            }
        }
    }

    private func writeTemp(_ data: Data, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            share = ShareURL(url: url)
        } catch {
            message = "Couldn't prepare the file: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        let csv = service.transactionsCSV(transactions)
        writeTemp(Data(csv.utf8), name: "MyCost-transactions-\(timestamp).csv")
    }

    private func exportBackup() {
        let backup = service.makeBackup(
            transactions: transactions, categories: categories, accounts: accounts,
            merchantRules: merchantRules, recurringPayments: recurringPayments, budgets: budgets
        )
        do {
            writeTemp(try service.encode(backup), name: "MyCost-backup-\(timestamp).json")
        } catch {
            message = "Couldn't build the backup: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        message = nil
        switch result {
        case .failure(let error):
            message = "Couldn't open the file: \(error.localizedDescription)"
        case .success(let url):
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            do {
                pendingRestore = try service.decode(Data(contentsOf: url))
            } catch {
                message = "That doesn't look like a MyCost backup: \(error.localizedDescription)"
            }
        }
    }

    private func runRestore() {
        guard let backup = pendingRestore else { return }
        pendingRestore = nil
        do {
            let summary = try service.restore(backup, into: modelContext)
            message = "Restored \(summary.transactions) transactions, \(summary.categories) categories, \(summary.rules) rules."
            ToastCenter.shared.success("Backup restored")
        } catch {
            message = "Restore failed: \(error.localizedDescription)"
            ToastCenter.shared.error("Restore failed")
        }
    }
}

private struct ShareURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
