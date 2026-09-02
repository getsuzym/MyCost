import SwiftData
import SwiftUI

struct DashboardView: View {
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \RecurringPayment.merchantName) private var recurringPayments: [RecurringPayment]

    /// Which month the dashboard is showing. Starts at the current month; the
    /// user can step back to see an imported historical statement.
    @State private var monthAnchor = Date()

    private let analytics = SpendingAnalytics()
    private var summary: MonthlySpendingSummary {
        analytics.monthlySummary(for: monthAnchor, transactions: transactions, recurringPayments: recurringPayments)
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    var body: some View {
        List {
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
                            .contentTransition(.numericText())

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
                }
                .padding(.vertical, 8)
            } header: {
                Text("Monthly Spending")
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
                    ContentUnavailableView("No spending this month", systemImage: "chart.pie")
                } else {
                    ForEach(summary.categoryTotals) { categoryTotal in
                        MetricRow(
                            title: categoryTotal.categoryName,
                            value: Formatters.currencyString(for: categoryTotal.amount),
                            systemImage: "tag"
                        )
                    }
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
