import Charts
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \RecurringPayment.merchantName) private var recurringPayments: [RecurringPayment]

    /// Which month the dashboard is showing. Starts at the current month; the
    /// user can step back to see an imported historical statement.
    @State private var monthAnchor = Date()

    private let analytics = SpendingAnalytics()
    private let monthly = MonthlyTransactionsService()

    private var summary: MonthlySpendingSummary {
        analytics.monthlySummary(for: monthAnchor, transactions: transactions, recurringPayments: recurringPayments)
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    /// Month-start dates that actually have transactions, newest first.
    private var monthsWithTransactions: [Date] {
        monthly.monthsRepresented(in: transactions)
    }

    var body: some View {
        // Compute once per render — `summary` builds fresh CategorySpend values,
        // and the ForEach over them needs a single, stable set to diff against.
        let summary = summary
        let months = monthsWithTransactions
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            stepMonth(-1)
                        } label: { Image(systemName: "chevron.left") }
                            .accessibilityIdentifier("dashboard.previousMonth")

                        Text(Formatters.month.string(from: summary.month))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)

                        Button {
                            stepMonth(1)
                        } label: { Image(systemName: "chevron.right") }
                            .disabled(isCurrentMonth)
                            .accessibilityIdentifier("dashboard.nextMonth")
                    }
                    .buttonStyle(.borderless)

                    Text(Formatters.currencyString(for: summary.total))
                        .font(.largeTitle.bold())
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("dashboard.monthlyTotal")

                    if !isCurrentMonth {
                        Button("Back to this month") { monthAnchor = Date() }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }

                    NavigationLink {
                        MonthDetailView(month: monthAnchor)
                    } label: {
                        Label("Open \(Formatters.month.string(from: summary.month))", systemImage: "list.bullet.rectangle")
                            .font(.callout)
                    }
                    .accessibilityIdentifier("dashboard.openMonth")
                }
                .padding(.vertical, 8)
            } header: {
                Text("Monthly Spending")
            }

            Section("Months") {
                if months.isEmpty {
                    Text("No transactions yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(months, id: \.self) { monthStart in
                    NavigationLink {
                        MonthDetailView(month: monthStart)
                    } label: {
                        let monthTx = monthly.transactions(inMonthContaining: monthStart, from: transactions)
                        let monthTotal = monthTx.filter { !$0.isExcluded }.reduce(Decimal.zero) { $0 + $1.spendingAmount }
                        HStack {
                            Text(Formatters.month.string(from: monthStart))
                            Spacer()
                            Text("\(monthTx.count) · \(Formatters.currencyString(for: monthTotal))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Status") {
                MetricRow(title: "Posted", value: Formatters.currencyString(for: summary.postedTotal), systemImage: "checkmark.circle")
                    .accessibilityIdentifier("dashboard.postedTotal")
                MetricRow(title: "Pending", value: Formatters.currencyString(for: summary.pendingTotal), systemImage: "clock")
                    .accessibilityIdentifier("dashboard.pendingTotal")
            }

            Section("Recurring") {
                MetricRow(
                    title: "Expected Monthly",
                    value: Formatters.currencyString(for: summary.expectedMonthlyRecurringTotal),
                    systemImage: "calendar.badge.clock"
                )
                .accessibilityIdentifier("dashboard.expectedRecurring")
                MetricRow(
                    title: "Recurring This Month",
                    value: Formatters.currencyString(for: summary.recurringTotal),
                    systemImage: "repeat"
                )
                MetricRow(
                    title: "Non-Recurring This Month",
                    value: Formatters.currencyString(for: summary.nonRecurringTotal),
                    systemImage: "cart"
                )
            }

            Section("Categories") {
                if summary.categoryTotals.isEmpty {
                    Text("No spending this month")
                        .foregroundStyle(.secondary)
                }

                if !summary.categoryTotals.isEmpty {
                    SpendingDistributionChart(categories: summary.categoryTotals)
                        .frame(height: 170)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("dashboard.categoryChart")
                }

                ForEach(summary.categoryTotals) { categoryTotal in
                    NavigationLink {
                        CategoryDetailView(categoryName: categoryTotal.categoryName, month: monthAnchor)
                    } label: {
                        CategoryBreakdownRow(category: categoryTotal)
                    }
                    .accessibilityIdentifier("dashboard.category")
                }
            }

            Section("Range") {
                MetricRow(
                    title: "Highest",
                    value: summary.highestCategory.map { "\($0.categoryName) • \(Formatters.currencyString(for: $0.amount))" } ?? "None",
                    systemImage: "arrow.up.circle"
                )
                MetricRow(
                    title: "Lowest",
                    value: summary.lowestCategory.map { "\($0.categoryName) • \(Formatters.currencyString(for: $0.amount))" } ?? "None",
                    systemImage: "arrow.down.circle"
                )
            }
        }
        .navigationTitle("Dashboard")
    }

    private func stepMonth(_ delta: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        // Never step past the current month.
        monthAnchor = moved > Date() ? Date() : moved
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Category name · amount spent · percentage of eligible monthly spending.
/// All three stay visible as text (VoiceOver-friendly); the chart above is
/// supplementary.
private struct CategoryBreakdownRow: View {
    let category: CategorySpend

    var body: some View {
        HStack {
            Label(category.categoryName, systemImage: "tag")
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Formatters.currencyString(for: category.amount))
                Text(Formatters.percentString(category.percentageOfTotal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.categoryName), \(Formatters.currencyString(for: category.amount)), \(Formatters.percentString(category.percentageOfTotal)) of spending")
    }
}

/// Native SwiftUI donut chart of category spending. Only positive-amount
/// categories get a slice; the full list (including net-refund categories) and
/// every exact dollar amount + percentage stay in the text rows below.
private struct SpendingDistributionChart: View {
    let categories: [CategorySpend]

    private var slices: [CategorySpend] {
        categories.filter { $0.amount > 0 }
    }

    var body: some View {
        if slices.isEmpty {
            Text("No positive spending to chart this month.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Chart(slices) { category in
                SectorMark(
                    angle: .value("Amount", NSDecimalNumber(decimal: category.amount).doubleValue),
                    innerRadius: .ratio(0.55),
                    angularInset: 1.5
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value("Category", category.categoryName))
            }
            .chartLegend(position: .trailing, alignment: .center, spacing: 8)
        }
    }
}
