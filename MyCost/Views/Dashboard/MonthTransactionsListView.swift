import SwiftData
import SwiftUI

/// All / Recurring / Non-Recurring filter, reused by the History list and the
/// month-scoped drill-downs.
enum RecurringFilter: String, CaseIterable, Identifiable {
    case all
    case recurring
    case nonRecurring

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .recurring: "Recurring"
        case .nonRecurring: "Non-Recurring"
        }
    }

    func includes(_ transaction: Transaction) -> Bool {
        switch self {
        case .all: true
        case .recurring: transaction.isRecurring
        case .nonRecurring: !transaction.isRecurring
        }
    }
}

/// One month's transactions filtered by recurring status — the drill-down
/// behind the Dashboard's "Recurring This Month" / "Non-Recurring This Month"
/// rows. `@Query`-driven, so marking/unmarking recurring, editing, deleting, or
/// moving a transaction updates the list and total immediately.
struct MonthTransactionsListView: View {
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var allTransactions: [Transaction]

    @State private var monthAnchor: Date
    @State private var scope: RecurringFilter

    private let monthly = MonthlyTransactionsService()

    init(month: Date, scope: RecurringFilter) {
        _monthAnchor = State(initialValue: month)
        _scope = State(initialValue: scope)
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    private var rows: [Transaction] {
        monthly.transactions(inMonthContaining: monthAnchor, from: allTransactions)
            .filter { scope.includes($0) }
    }

    private var total: Decimal {
        rows.filter { !$0.isExcluded }.reduce(Decimal.zero) { $0 + $1.spendingAmount }
    }

    private var navTitle: String {
        switch scope {
        case .all: "Transactions"
        case .recurring: "Recurring"
        case .nonRecurring: "Non-Recurring"
        }
    }

    var body: some View {
        let items = rows
        return List {
            Section {
                Picker("Filter", selection: $scope) {
                    ForEach(RecurringFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("monthList.filter")

                HStack {
                    Button { stepMonth(-1) } label: { Image(systemName: "chevron.left") }
                    Text(Formatters.month.string(from: monthAnchor))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Button { stepMonth(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(isCurrentMonth)
                }
                .buttonStyle(.borderless)

                HStack {
                    Text("\(items.count) transaction\(items.count == 1 ? "" : "s")")
                    Spacer()
                    Text(Formatters.currencyString(for: total))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("monthList.total")
            }

            Section {
                if items.isEmpty {
                    Text("Nothing here for \(Formatters.month.string(from: monthAnchor)).")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        MonthListRow(transaction: transaction)
                    }
                }
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stepMonth(_ delta: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        monthAnchor = moved > Date() ? Date() : moved
    }
}

private struct MonthListRow: View {
    let transaction: Transaction

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transaction.merchantName).font(.body).lineLimit(1)
                Spacer()
                Text(Formatters.currencyString(for: transaction.amount))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(transaction.amount < 0 ? .green : .primary)
            }
            HStack(spacing: 6) {
                Text(Formatters.shortDate.string(from: transaction.transactionDate))
                Text("·")
                Text(transaction.category?.name ?? "Uncategorized")
                if transaction.isRecurring {
                    Text("·")
                    Text(transaction.recurringPayment?.frequency.label ?? "Recurring")
                        .foregroundStyle(.blue)
                }
                if transaction.isExcluded {
                    Text("· Excluded").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .opacity(transaction.isExcluded ? 0.5 : 1)
    }
}
