import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DataPortabilityView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var ocrReviewStore: OCRTransactionReviewStore
    @EnvironmentObject private var nav: AppNavigationModel

    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var merchantRules: [MerchantRule]
    @Query private var recurringPayments: [RecurringPayment]
    @Query private var budgets: [Budget]
    @Query private var tags: [Tag]

    @State private var share: ShareURL?
    @State private var isImporting = false
    @State private var pendingRestore: DataPortabilityService.Backup?
    @State private var isImportingCSV = false
    @State private var pendingCSVImport: [DataPortabilityService.CSVImportRow]?
    @State private var isImportingBank = false
    @State private var pendingBank: PendingBankImport?
    @State private var message: String?
    /// Seconds since the reference date — 0 means "never". Set whenever a
    /// backup export is prepared (Export CSV doesn't count; only the full
    /// JSON backup is a real safety net).
    @AppStorage("mycost.lastBackupExportAt") private var lastBackupExportTimestamp: Double = 0

    private let service = DataPortabilityService()
    private let bankService = BankStatementImportService()

    private var lastBackupDate: Date? {
        lastBackupExportTimestamp == 0 ? nil : Date(timeIntervalSinceReferenceDate: lastBackupExportTimestamp)
    }

    private var lastBackupSummary: String {
        guard let lastBackupDate else { return "Never backed up" }
        return "Last backup: \(Formatters.shortDate.string(from: lastBackupDate))"
    }

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
                Text("\(transactions.count) transaction\(transactions.count == 1 ? "" : "s"). The CSV is for spreadsheets; the JSON backup restores everything (categories, rules, recurring, budgets). \(lastBackupSummary).")
            }

            Section {
                Button {
                    isImportingBank = true
                } label: {
                    Label("Import bank statement\u{2026}", systemImage: "building.columns")
                }
                .accessibilityIdentifier("data.importBank")
            } header: {
                Text("Import from your bank")
            } footer: {
                Text("Download your transactions from RBC or TD online banking \u{2014} CSV, \u{201C}Quicken (QFX)\u{201D}, an OFX/QFX file from any other bank, or a PDF statement \u{2014} and import them here, no screenshots. A CSV/OFX file imports directly (merchant rules applied, already-seen rows skipped); a PDF opens the review screen first so you can check the parsed rows.")
            }

            Section {
                Button {
                    isImportingCSV = true
                } label: {
                    Label("Import transactions (CSV)\u{2026}", systemImage: "tablecells")
                }
                .accessibilityIdentifier("data.importCSV")
            } header: {
                Text("Import a spreadsheet")
            } footer: {
                Text("Adds transactions from a CSV matching the export above, or any spreadsheet with Date / Merchant / Amount columns. Categories, tags, and accounts named in the file are created if they don't exist yet. Likely duplicates of existing transactions are skipped.")
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
        .fileImporter(isPresented: $isImportingCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            handleCSVImport(result)
        }
        .fileImporter(
            isPresented: $isImportingBank,
            allowedContentTypes: [
                .commaSeparatedText, .plainText, .text, .pdf,
                UTType(filenameExtension: "ofx") ?? .data,
                UTType(filenameExtension: "qfx") ?? .data,
                .data
            ]
        ) { result in
            handleBankImport(result)
        }
        .sheet(item: $pendingBank) { pending in
            BankImportConfirmView(
                statement: pending.statement,
                initialName: pending.accountName,
                initialType: pending.accountType,
                onImport: { name, type in
                    runBankImport(statement: pending.statement, accountName: name, accountType: type)
                    pendingBank = nil
                },
                onCancel: { pendingBank = nil }
            )
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
        .confirmationDialog(
            "Import these transactions?",
            isPresented: Binding(get: { pendingCSVImport != nil }, set: { if !$0 { pendingCSVImport = nil } }),
            titleVisibility: .visible
        ) {
            Button("Import") { runCSVImport() }
            Button("Cancel", role: .cancel) { pendingCSVImport = nil }
        } message: {
            if let rows = pendingCSVImport {
                Text("Found \(rows.count) transaction\(rows.count == 1 ? "" : "s") in the file. Likely duplicates of what's already here will be skipped.")
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
            merchantRules: merchantRules, recurringPayments: recurringPayments, budgets: budgets, tags: tags
        )
        do {
            writeTemp(try service.encode(backup), name: "MyCost-backup-\(timestamp).json")
            lastBackupExportTimestamp = Date.now.timeIntervalSinceReferenceDate
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

    private func handleCSVImport(_ result: Result<URL, Error>) {
        message = nil
        switch result {
        case .failure(let error):
            message = "Couldn't open the file: \(error.localizedDescription)"
        case .success(let url):
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let rows = try service.parseTransactionsCSV(text)
                guard !rows.isEmpty else {
                    message = "No transaction rows found in that file."
                    return
                }
                pendingCSVImport = rows
            } catch {
                message = (error as? DataPortabilityService.CSVImportError)?.errorDescription
                    ?? "Couldn't read that file: \(error.localizedDescription)"
            }
        }
    }

    private func runCSVImport() {
        guard let rows = pendingCSVImport else { return }
        pendingCSVImport = nil
        let outcome = service.importCSVRows(
            rows, categories: categories, tags: tags, accounts: accounts,
            existingTransactions: transactions, modelContext: modelContext
        )
        var summary = "\(outcome.imported) transaction\(outcome.imported == 1 ? "" : "s") imported"
        if outcome.duplicatesSkipped > 0 {
            summary += " \u{00B7} \(outcome.duplicatesSkipped) duplicate\(outcome.duplicatesSkipped == 1 ? "" : "s") skipped"
        }
        message = summary
        ToastCenter.shared.success(summary)
    }

    private static func readText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for encoding: String.Encoding in [.utf8, .isoLatin1, .windowsCP1252, .ascii] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    private func handleBankImport(_ result: Result<URL, Error>) {
        message = nil
        switch result {
        case .failure(let error):
            message = "Couldn't open the file: \(error.localizedDescription)"
        case .success(let url):
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

            if url.pathExtension.lowercased() == "pdf",
               let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) {
                handlePDFStatement(document)
                return
            }

            guard let text = Self.readText(from: url) else {
                message = "Couldn't read that file as text."
                return
            }
            do {
                let statement = try bankService.parse(contents: text, fileName: url.lastPathComponent)
                let type = statement.accountType ?? (statement.format == .tdCSV ? .debit : .other)
                pendingBank = PendingBankImport(
                    statement: statement,
                    accountName: statement.suggestedAccountName,
                    accountType: type
                )
            } catch {
                message = (error as? BankStatementImportService.ImportError)?.errorDescription
                    ?? "Couldn't read that statement: \(error.localizedDescription)"
            }
        }
    }

    /// A PDF statement is far less structured than CSV/OFX, so its rows go
    /// through the same **Review** screen a screenshot import uses rather than
    /// being saved directly.
    private func handlePDFStatement(_ document: PDFDocument) {
        let parser = PDFStatementParser(ocr: { image in
            let blocks = try await VisionOCRService().recognizeText(in: image)
            return Self.linesFromOCR(blocks)
        })
        Task { @MainActor in
            let result = await parser.parse(document)
            let candidates = parser.candidates(from: result)
            guard !candidates.isEmpty else {
                message = result.charactersExtracted < 40
                    ? "Couldn't read any text from that PDF. If it's a scanned statement, try a clearer scan."
                    : "No transactions were recognized in that PDF."
                return
            }
            ocrReviewStore.pendingDefaultAccountType = result.detectedAccountType
            ocrReviewStore.replaceCandidates(candidates, merchantRules: merchantRules)
            message = "Found \(candidates.count) transaction\(candidates.count == 1 ? "" : "s") \u{2014} check them on the review screen."
            nav.openReview()
        }
    }

    /// Vision blocks → newline-separated rows (blocks on roughly the same
    /// baseline joined left-to-right), so the statement line parser can run.
    private static func linesFromOCR(_ blocks: [RecognizedTextBlock]) -> String {
        let bucket = { (y: CGFloat) in (y / 0.012).rounded() }
        let sorted = blocks.sorted { a, b in
            let ay = bucket(a.boundingBox.midY), by = bucket(b.boundingBox.midY)
            if ay != by { return ay > by }           // Vision's Y is bottom-up, so higher = earlier
            return a.boundingBox.minX < b.boundingBox.minX
        }
        var lines: [String] = []
        var currentBucket: CGFloat?
        for block in sorted {
            let b = bucket(block.boundingBox.midY)
            if b == currentBucket, !lines.isEmpty {
                lines[lines.count - 1] += "  " + block.text
            } else {
                lines.append(block.text)
                currentBucket = b
            }
        }
        return lines.joined(separator: "\n")
    }

    private func runBankImport(
        statement: BankStatementImportService.ParsedStatement,
        accountName: String,
        accountType: AccountType
    ) {
        let name = accountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let outcome = bankService.importStatement(
            statement, accountName: name, accountType: accountType,
            categories: categories, accounts: accounts, merchantRules: merchantRules,
            existingTransactions: transactions, modelContext: modelContext
        )
        var summary = "\(outcome.imported) transaction\(outcome.imported == 1 ? "" : "s") imported"
        if outcome.duplicatesSkipped > 0 {
            summary += " \u{00B7} \(outcome.duplicatesSkipped) duplicate\(outcome.duplicatesSkipped == 1 ? "" : "s") skipped"
        }
        if outcome.needsReview > 0 {
            summary += " \u{00B7} \(outcome.needsReview) to review"
        }
        message = summary
        ToastCenter.shared.success(summary)
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

private struct PendingBankImport: Identifiable {
    let id = UUID()
    var statement: BankStatementImportService.ParsedStatement
    var accountName: String
    var accountType: AccountType
}

/// Confirms which account a parsed statement's transactions go into (and its
/// type, which decides how amounts are read) before the import runs.
private struct BankImportConfirmView: View {
    let statement: BankStatementImportService.ParsedStatement
    var onImport: (String, AccountType) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var type: AccountType

    init(
        statement: BankStatementImportService.ParsedStatement,
        initialName: String,
        initialType: AccountType,
        onImport: @escaping (String, AccountType) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.statement = statement
        self.onImport = onImport
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
        _type = State(initialValue: initialType)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Transactions", value: "\(statement.transactions.count)")
                    LabeledContent("Format", value: statement.format.label)
                    if let currency = statement.currency {
                        LabeledContent("Currency", value: currency)
                    }
                    if let range = dateRange {
                        LabeledContent("Dates", value: range)
                    }
                }

                Section {
                    TextField("Account name", text: $name)
                        .accessibilityIdentifier("bankImport.accountName")
                    Picker("Account type", selection: $type) {
                        ForEach(AccountType.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("bankImport.accountType")
                } header: {
                    Text("Account")
                } footer: {
                    Text("Transactions are added to this account (created if it doesn't exist yet). The type sets how the file's amounts are read \u{2014} it's remembered for next time.")
                }
            }
            .navigationTitle("Import statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onImport(name, type) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("bankImport.confirm")
                }
            }
        }
    }

    private var dateRange: String? {
        let dates = statement.transactions.map(\.date).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let f = Formatters.shortDate
        return first == last ? f.string(from: first) : "\(f.string(from: first)) \u{2013} \(f.string(from: last))"
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
