import SwiftData
import SwiftUI

struct DashboardView: View {
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]

    private let analytics = SpendingAnalytics()
    private var summary: MonthlySpendingSummary {
        analytics.monthlySummary(for: .now, transactions: transactions)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Formatters.month.string(from: summary.month))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(Formatters.currencyString(for: summary.total))
                        .font(.largeTitle.bold())
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("dashboard.monthlyTotal")
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
