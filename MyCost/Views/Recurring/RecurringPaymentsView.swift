import SwiftData
import SwiftUI

struct RecurringPaymentsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \RecurringPayment.merchantName) private var recurringPayments: [RecurringPayment]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var editingPayment: RecurringPayment?
    @State private var paymentPendingDeletion: RecurringPayment?
    @State private var selectedSuggestion: RecurringPaymentSuggestion?
    @State private var monthAnchor = Date()

    private let suggestionService = RecurringPaymentSuggestionService()
    private let recurringPaymentService = RecurringPaymentService()
    private let monthly = MonthlyTransactionsService()

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    /// Every transaction in the selected month flagged `isRecurring`, any
    /// category, newest first.
    private var monthRecurringTransactions: [Transaction] {
        monthly.transactions(inMonthContaining: monthAnchor, from: transactions)
            .filter(\.isRecurring)
    }

    private var recurringMonthTotal: Decimal {
        monthRecurringTransactions
            .filter { !$0.isExcluded }
            .reduce(Decimal.zero) { $0 + $1.spendingAmount }
    }

    private var suggestions: [RecurringPaymentSuggestion] {
        let activeKeys = Set(recurringPayments.filter(\.isActive).map {
            normalizedKey(accountName: $0.accountName, merchantName: $0.merchantName)
        })
        return suggestionService.suggestions(from: transactions).filter { suggestion in
            !activeKeys.contains(normalizedKey(accountName: suggestion.accountName, merchantName: suggestion.merchantName))
        }
    }

    /// The selected month is the single source of truth. Everything shown for
    /// "this month" — expected occurrences, expected/actual/remaining totals,
    /// occurrence counts — is generated strictly within `monthAnchor`'s calendar
    /// month and regenerates whenever the month picker moves.
    private var monthExpectation: RecurringMonthExpectation {
        suggestionService.monthlyExpectation(
            activeSeries: recurringPayments.filter(\.isActive),
            recurringTransactions: monthRecurringTransactions.filter { !$0.isExcluded },
            inMonthContaining: monthAnchor
        )
    }

    /// One unified row per recurring series (schedule): active first then paused,
    /// each alphabetical, carrying this month's expected occurrences + whether
    /// each has happened. This is the combined "expected / transactions /
    /// payments" table.
    private var seriesRows: [SeriesMonthRow] {
        let occurrencesBySeries = Dictionary(grouping: monthExpectation.occurrences, by: \.seriesID)
        func rows(_ payments: [RecurringPayment]) -> [SeriesMonthRow] {
            payments
                .map { payment in
                    SeriesMonthRow(
                        series: payment,
                        occurrences: (occurrencesBySeries[payment.id] ?? []).sorted { $0.date < $1.date }
                    )
                }
                .sorted { $0.series.merchantName.localizedCaseInsensitiveCompare($1.series.merchantName) == .orderedAscending }
        }
        return rows(recurringPayments.filter(\.isActive)) + rows(recurringPayments.filter { !$0.isActive })
    }

    /// Recurring transactions in the month that belong to no series (a one-off
    /// the user flagged, not covered by any active schedule). They already
    /// happened, so they show a green check.
    private var looseRecurringTransactions: [Transaction] {
        let seriesKeys = Set(recurringPayments.filter(\.isActive).map {
            normalizedKey(accountName: $0.accountName, merchantName: $0.merchantName)
        })
        return monthRecurringTransactions.filter { transaction in
            transaction.recurringPayment == nil
                && !seriesKeys.contains(normalizedKey(accountName: transaction.accountName, merchantName: transaction.merchantName))
        }
    }

    var body: some View {
        let expectation = monthExpectation
        let monthName = Formatters.month.string(from: monthAnchor)
        return List {
            Section {
                HStack {
                    Button { stepMonth(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous month")
                        .accessibilityIdentifier("recurringMonth.previous")
                    Text(monthName)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Showing \(monthName)")
                    Button { stepMonth(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(isCurrentMonth)
                        .accessibilityLabel("Next month")
                        .accessibilityIdentifier("recurringMonth.next")
                }
                .buttonStyle(.borderless)

                RecurringMetricRow(
                    title: "Expected This Month",
                    value: Formatters.currencyString(for: expectation.expectedTotal),
                    systemImage: "calendar.badge.clock"
                )
                .accessibilityIdentifier("recurringMonth.expected")
                RecurringMetricRow(
                    title: "Actual This Month",
                    value: Formatters.currencyString(for: recurringMonthTotal),
                    systemImage: "repeat"
                )
                .accessibilityIdentifier("recurringMonth.total")
                RecurringMetricRow(
                    title: "Remaining This Month",
                    value: Formatters.currencyString(for: expectation.remainingTotal),
                    systemImage: "hourglass"
                )
                .accessibilityIdentifier("recurringMonth.remaining")
                RecurringMetricRow(
                    title: "Occurrences",
                    value: "\(expectation.completedCount) of \(expectation.expectedCount)",
                    systemImage: "number"
                )
                .accessibilityIdentifier("recurringMonth.occurrences")
            } header: {
                Text("This Month")
            }

            Section {
                if seriesRows.isEmpty, looseRecurringTransactions.isEmpty {
                    Text("No recurring payments. Create one from a suggestion below, or mark a transaction recurring.")
                        .foregroundStyle(.secondary)
                }

                ForEach(seriesRows) { row in
                    Button {
                        editingPayment = row.series
                    } label: {
                        HStack {
                            UnifiedSeriesRow(row: row, monthName: monthName)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recurring.seriesRow")
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            setActive(!row.series.isActive, for: row.series)
                        } label: {
                            Label(
                                row.series.isActive ? "Pause" : "Resume",
                                systemImage: row.series.isActive ? "pause.circle" : "play.circle"
                            )
                        }
                        .tint(row.series.isActive ? .orange : .green)
                        .accessibilityIdentifier("recurring.togglePause")
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            paymentPendingDeletion = row.series
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("recurring.deleteSeries")
                    }
                }

                if !looseRecurringTransactions.isEmpty {
                    Text("Not linked to a series")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(looseRecurringTransactions) { transaction in
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            UnifiedLooseTransactionRow(transaction: transaction)
                        }
                        .accessibilityIdentifier("recurring.looseRow")
                    }
                }
            } header: {
                Text("Recurring \u{2014} \(monthName)")
            } footer: {
                Text("One row per schedule. The dots show each expected payment this month; green means it has happened. Tap to edit the schedule, swipe to pause or delete it \u{2014} your transactions are never changed.")
            }

            Section("Suggestions") {
                if suggestions.isEmpty {
                    ContentUnavailableView("No suggestions", systemImage: "sparkle.magnifyingglass")
                } else {
                    ForEach(suggestions) { suggestion in
                        RecurringSuggestionRow(suggestion: suggestion) {
                            selectedSuggestion = suggestion
                        }
                    }
                }
            }
        }
        .navigationTitle("Recurring")
        .refreshable {
            // Occurrence / paid status is recomputed on every render from live
            // @Query data; this gives the pull-down its spinner.
            try? await Task.sleep(for: .milliseconds(400))
        }
        .sheet(item: $editingPayment) { payment in
            NavigationStack {
                RecurringPaymentEditorView(payment: payment, categories: categories)
            }
        }
        .confirmationDialog(
            "Mark as recurring?",
            isPresented: Binding(
                get: { selectedSuggestion != nil },
                set: { if !$0 { selectedSuggestion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Create Recurring Payment") {
                confirmSelectedSuggestion()
            }
            Button("Cancel", role: .cancel) {
                selectedSuggestion = nil
            }
        } message: {
            Text("This will mark the matching transactions as recurring and create a series.")
        }
        .confirmationDialog(
            "Delete this recurring payment?",
            isPresented: Binding(
                get: { paymentPendingDeletion != nil },
                set: { if !$0 { paymentPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let paymentPendingDeletion { deletePayment(paymentPendingDeletion) }
                paymentPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { paymentPendingDeletion = nil }
        } message: {
            Text("Only the schedule is removed. Its transactions stay exactly as they are \u{2014} amounts, categories and recurring flags are untouched.")
        }
    }

    private func setActive(_ isActive: Bool, for payment: RecurringPayment) {
        do {
            try recurringPaymentService.setActive(isActive, for: payment, modelContext: modelContext)
            ToastCenter.shared.success(CRUDFeedback.updated("recurring payment"))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.saveFailure("recurring payment"))
        }
    }

    private func deletePayment(_ payment: RecurringPayment) {
        do {
            try recurringPaymentService.delete(payment, modelContext: modelContext)
            ToastCenter.shared.success(CRUDFeedback.deleted("recurring payment"))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.saveFailure("recurring payment"))
        }
    }

    private func confirmSelectedSuggestion() {
        guard let selectedSuggestion else { return }
        let matchingTransactions = transactions.filter { selectedSuggestion.transactionIDs.contains($0.id) }
        let category = matchingTransactions.first?.category
        let payment = RecurringPayment(
            accountName: selectedSuggestion.accountName,
            merchantName: selectedSuggestion.merchantName,
            expectedAmount: selectedSuggestion.expectedAmount,
            frequency: selectedSuggestion.frequency,
            customIntervalDays: selectedSuggestion.customIntervalDays,
            nextExpectedDate: selectedSuggestion.nextExpectedDate,
            category: category
        )
        modelContext.insert(payment)

        for transaction in matchingTransactions {
            transaction.isRecurring = true
            transaction.recurringPayment = payment
            transaction.updatedAt = .now
        }

        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.added("recurring payment"))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.saveFailure("recurring payment"))
        }
        self.selectedSuggestion = nil
    }

    private func normalizedKey(accountName: String?, merchantName: String) -> String {
        "\(accountName?.lowercased() ?? "")|\(MerchantRuleNormalizer.normalizedMerchantKey(for: merchantName))"
    }

    private func stepMonth(_ delta: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        monthAnchor = moved > Date() ? Date() : moved
    }
}

/// One recurring series plus this month's expected occurrences (each carrying
/// whether it has already happened).
struct SeriesMonthRow: Identifiable {
    let series: RecurringPayment
    let occurrences: [RecurringMonthExpectation.Occurrence]

    var id: UUID { series.id }
    var expectedThisMonth: Decimal { occurrences.reduce(Decimal.zero) { $0 + $1.amount } }
    var completed: Int { occurrences.filter(\.isMatched).count }
}

private struct UnifiedSeriesRow: View {
    let row: SeriesMonthRow
    let monthName: String

    private var series: RecurringPayment { row.series }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(series.merchantName).font(.headline).lineLimit(1)
                Spacer()
                if series.isActive {
                    Text(Formatters.currencyString(for: row.occurrences.isEmpty ? series.expectedAmount : row.expectedThisMonth))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Paused").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 6) {
                Text(series.schedule().label)
                Text("·")
                Text(series.accountName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if row.occurrences.isEmpty {
                Text(series.isActive ? "Not due in \(monthName)" : "Paused \u{2014} no payments expected")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 12) {
                    ForEach(row.occurrences) { occurrence in
                        HStack(spacing: 4) {
                            Image(systemName: occurrence.isMatched ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(occurrence.isMatched ? Color.green : Color.secondary)
                                .accessibilityLabel(occurrence.isMatched ? "Paid" : "Due")
                            Text(Formatters.shortDate.string(from: occurrence.date))
                        }
                        .font(.caption2)
                    }
                    Spacer(minLength: 0)
                    Text("\(row.completed)/\(row.occurrences.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(series.isActive ? 1 : 0.6)
    }
}

private struct UnifiedLooseTransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Paid")
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchantName).font(.body).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Formatters.shortDate.string(from: transaction.transactionDate))
                    Text("·")
                    Text("One-off recurring")
                    if let categoryName = transaction.category?.name {
                        Text("·")
                        Text(categoryName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Formatters.currencyString(for: transaction.amount))
                .font(.body.monospacedDigit())
                .foregroundStyle(transaction.amount < 0 ? .green : .primary)
        }
        .opacity(transaction.isExcluded ? 0.5 : 1)
    }
}

private struct RecurringMetricRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecurringSuggestionRow: View {
    let suggestion: RecurringPaymentSuggestion
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(suggestion.merchantName)
                    .font(.headline)
                Spacer()
                Text("\(Int(suggestion.confidence * 100))%")
                    .foregroundStyle(.secondary)
            }

            Text("\(suggestion.frequency.label) • \(Formatters.currencyString(for: suggestion.expectedAmount))")
                .foregroundStyle(.secondary)

            Text(suggestion.reason)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Mark Recurring", action: onConfirm)
                .accessibilityIdentifier("recurring.confirmSuggestion")
        }
        .padding(.vertical, 4)
    }
}

private struct RecurringPaymentEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let payment: RecurringPayment
    let categories: [Category]

    @State private var merchantName = ""
    @State private var accountName = "Default"
    @State private var amountText = ""
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var customIntervalDays = 30
    @State private var monthInterval = 1
    @State private var weekdayOrdinal = 1
    @State private var weekday = 2
    @State private var selectedCategoryID: UUID?
    @State private var isActive = true
    @State private var validationMessage: String?

    private var visibleCategories: [Category] {
        categories.filter { $0.isActive || $0.id == selectedCategoryID }.alphabetizedByName()
    }

    var body: some View {
        Form {
            Section("Series") {
                TextField("Account", text: $accountName)
                    .textInputAutocapitalization(.words)
                TextField("Merchant", text: $merchantName)
                    .textInputAutocapitalization(.words)
                TextField("Expected Amount", text: $amountText)
                    .keyboardType(.decimalPad)

                RecurrenceRuleEditor(
                    frequency: $frequency,
                    customIntervalDays: $customIntervalDays,
                    monthInterval: $monthInterval,
                    weekdayOrdinal: $weekdayOrdinal,
                    weekday: $weekday
                )

                Picker("Category", selection: $selectedCategoryID) {
                    Text("No category").tag(UUID?.none)
                    ForEach(visibleCategories) { category in
                        Label(category.name, systemImage: category.symbolName.isEmpty ? "tag" : category.symbolName)
                            .tag(Optional(category.id))
                    }
                }

                Toggle("Active", isOn: $isActive)
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Recurring Payment")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onAppear(perform: loadInitialValues)
    }

    private func loadInitialValues() {
        merchantName = payment.merchantName
        accountName = payment.accountName
        amountText = NSDecimalNumber(decimal: payment.expectedAmount).stringValue
        frequency = payment.frequency
        customIntervalDays = payment.customIntervalDays
        monthInterval = max(1, payment.monthInterval)
        weekdayOrdinal = payment.weekdayOrdinal == 0 ? 1 : payment.weekdayOrdinal
        weekday = (1...7).contains(payment.weekday) ? payment.weekday : 2
        selectedCategoryID = payment.category?.id
        isActive = payment.isActive
    }

    private func save() {
        let trimmedMerchantName = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMerchantName.isEmpty else {
            validationMessage = "Enter a merchant name."
            return
        }
        guard let expectedAmount = Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = "Enter a valid amount."
            return
        }

        payment.merchantName = trimmedMerchantName
        let trimmedAccountName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        payment.accountName = trimmedAccountName.isEmpty ? "Default" : trimmedAccountName
        payment.expectedAmount = expectedAmount
        payment.frequency = frequency
        payment.customIntervalDays = customIntervalDays
        payment.monthInterval = monthInterval
        payment.weekdayOrdinal = weekdayOrdinal
        payment.weekday = weekday

        let schedule = RecurrenceSchedule(
            frequency: frequency,
            anchorDate: payment.occurrenceAnchor,
            customIntervalDays: customIntervalDays,
            monthInterval: monthInterval,
            weekdayOrdinal: weekdayOrdinal,
            weekday: weekday
        )
        let lastPaid = payment.transactions.map(\.transactionDate).max()
        payment.nextExpectedDate = schedule.nextOccurrence(after: lastPaid ?? Date())

        payment.category = categories.first { $0.id == selectedCategoryID }
        payment.isActive = isActive
        payment.updatedAt = .now

        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.updated("recurring payment"))
            dismiss()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
            ToastCenter.shared.error(CRUDFeedback.saveFailure("recurring payment"))
        }
    }
}
