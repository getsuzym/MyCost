import Charts
import SwiftData
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var ocrReviewStore: OCRTransactionReviewStore
    @EnvironmentObject private var nav: AppNavigationModel

    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \RecurringPayment.merchantName) private var recurringPayments: [RecurringPayment]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var budgets: [Budget]

    /// Which month the dashboard is showing. Starts at the current month; the
    /// user can step back to see an imported historical statement.
    @State private var monthAnchor = Date()
    /// The "Months" list is collapsed by default and remembers its state.
    @AppStorage("dashboard.monthsExpanded") private var monthsExpanded = false

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

    private func color(forCategory name: String) -> Color {
        if let hex = categories.first(where: { $0.name == name })?.colorHex,
           let color = Color(hex: hex) {
            return color
        }
        return Theme.accent
    }

    private func symbol(forCategory name: String) -> String {
        let symbol = categories.first(where: { $0.name == name })?.symbolName ?? ""
        return symbol.isEmpty ? "tag.fill" : symbol
    }

    var body: some View {
        // Compute once per render — `summary` builds fresh CategorySpend values,
        // and the ForEach over them needs a single, stable set to diff against.
        let summary = summary
        let months = monthsWithTransactions
        let budgetRows = BudgetService().progress(for: budgets, in: summary)
        return List {
            Section {
                heroCard(summary: summary)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if budgetRows.isEmpty {
                    NavigationLink { BudgetsView() } label: {
                        Label("Set a monthly budget", systemImage: "chart.bar.doc.horizontal")
                            .font(.callout)
                    }
                    .accessibilityIdentifier("dashboard.addBudget")
                } else {
                    ForEach(budgetRows.prefix(4)) { row in
                        NavigationLink { BudgetsView() } label: { BudgetProgressRow(progress: row) }
                            .accessibilityIdentifier("dashboard.budgetRow")
                    }
                }
            } header: {
                Text("Budget")
            }

            Section("This Month") {
                let recurringCount = monthly.transactions(inMonthContaining: monthAnchor, from: transactions)
                    .filter { $0.isRecurring && !$0.isExcluded && $0.contributesToSpending }.count

                NavigationLink {
                    MonthTransactionsListView(month: monthAnchor, scope: .recurring)
                } label: {
                    MetricTile(
                        title: "Recurring",
                        value: Formatters.currencyString(for: summary.recurringTotal),
                        systemImage: "repeat",
                        tint: Theme.accent,
                        caption: "\(recurringCount) transaction\(recurringCount == 1 ? "" : "s")"
                    )
                }
                .accessibilityIdentifier("dashboard.recurringThisMonth")

                NavigationLink {
                    MonthTransactionsListView(month: monthAnchor, scope: .nonRecurring)
                } label: {
                    MetricTile(
                        title: "Non-Recurring",
                        value: Formatters.currencyString(for: summary.nonRecurringTotal),
                        systemImage: "cart.fill",
                        tint: Color(light: 0x0E7C86, dark: 0x4FD1DB)
                    )
                }
                .accessibilityIdentifier("dashboard.nonRecurringThisMonth")
            }

            Section("Trend") {
                let trend = analytics.trailingMonths(6, endingAt: monthAnchor, transactions: transactions)
                if trend.allSatisfy({ $0.spent == 0 && $0.income == 0 }) {
                    Text("Not enough history yet.")
                        .foregroundStyle(.secondary)
                } else {
                    SpendingTrendChart(months: trend, highlightedMonth: monthAnchor)
                        .frame(height: 170)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("dashboard.trendChart")
                }
            }

            Section("Categories") {
                if summary.categoryTotals.isEmpty {
                    Text("No spending this month")
                        .foregroundStyle(.secondary)
                }

                if !summary.categoryTotals.isEmpty {
                    SpendingDistributionChart(
                        categories: summary.categoryTotals,
                        colorForName: color(forCategory:)
                    )
                    .frame(height: 190)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("dashboard.categoryChart")
                }

                ForEach(summary.categoryTotals) { categoryTotal in
                    NavigationLink {
                        CategoryDetailView(categoryName: categoryTotal.categoryName, month: monthAnchor)
                    } label: {
                        CategoryBreakdownRow(
                            category: categoryTotal,
                            tint: color(forCategory: categoryTotal.categoryName),
                            symbol: symbol(forCategory: categoryTotal.categoryName)
                        )
                    }
                    .accessibilityIdentifier("dashboard.category")
                }
            }

            Section {
                if months.isEmpty {
                    Text("No transactions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup(isExpanded: $monthsExpanded) {
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
                                        .monospacedDigit()
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("All Months")
                            Spacer()
                            Text("\(months.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityIdentifier("dashboard.monthsDisclosure")
                    }
                }
            } header: {
                Text("Months")
            }
        }
        .navigationTitle("Dashboard")
        .themedListBackground()
        .refreshable {
            // Totals are @Query-derived and always live; this just gives the
            // pull-down gesture its spinner and a fresh recompute.
            try? await Task.sleep(for: .milliseconds(400))
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    nav.requestImport(session: ocrReviewStore)
                } label: {
                    Label("Import Screenshots", systemImage: "photo.badge.plus")
                }
                .accessibilityIdentifier("dashboard.importScreenshots")
            }
        }
    }

    @ViewBuilder
    private func heroCard(summary: MonthlySpendingSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { stepMonth(-1) } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                }
                .accessibilityLabel("Previous month")
                .accessibilityIdentifier("dashboard.previousMonth")

                Spacer()
                Text(Formatters.month.string(from: summary.month))
                    .font(.subheadline.weight(.medium))
                    .accessibilityLabel("Showing \(Formatters.month.string(from: summary.month))")
                Spacer()

                Button { stepMonth(1) } label: {
                    Image(systemName: "chevron.right").font(.body.weight(.semibold))
                }
                .disabled(isCurrentMonth)
                .accessibilityLabel("Next month")
                .accessibilityIdentifier("dashboard.nextMonth")
            }
            .buttonStyle(.borderless)
            .tint(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Total spent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(Formatters.currencyString(for: summary.total))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .accessibilityIdentifier("dashboard.monthlyTotal")
            }

            if summary.incomeTotal > 0 {
                HStack(spacing: 14) {
                    Label(Formatters.currencyString(for: summary.incomeTotal), systemImage: "arrow.down.left")
                        .foregroundStyle(Theme.positive)
                    Label(Formatters.currencyString(for: summary.netTotal), systemImage: "equal")
                        .foregroundStyle(summary.netTotal >= 0 ? Theme.positive : Theme.warning)
                    Spacer(minLength: 0)
                }
                .font(.footnote.weight(.medium).monospacedDigit())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Earned \(Formatters.currencyString(for: summary.incomeTotal)), net \(Formatters.currencyString(for: summary.netTotal))")
                .accessibilityIdentifier("dashboard.incomeNet")
            }

            HStack(spacing: 10) {
                NavigationLink {
                    MonthDetailView(month: monthAnchor)
                } label: {
                    Label("Open \(Formatters.month.string(from: summary.month))", systemImage: "list.bullet.rectangle")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dashboard.openMonth")

                if !isCurrentMonth {
                    Button("This month") { monthAnchor = Date() }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.borderless)
                }
            }
        }
        .cardSurface(20)
    }

    private func stepMonth(_ delta: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        // Never step past the current month.
        monthAnchor = moved > Date() ? Date() : moved
    }
}

/// Category name · amount spent · percentage of eligible monthly spending.
/// All three stay visible as text (VoiceOver-friendly); the chart above is
/// supplementary.
private struct CategoryBreakdownRow: View {
    let category: CategorySpend
    var tint: Color = Theme.accent
    var symbol: String = "tag.fill"

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: symbol, tint: tint, size: 30)
            Text(category.categoryName)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Formatters.currencyString(for: category.amount))
                    .monospacedDigit()
                Text(Formatters.percentString(category.percentageOfTotal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.categoryName), \(Formatters.currencyString(for: category.amount)), \(Formatters.percentString(category.percentageOfTotal)) of spending")
    }
}

/// 6-month spend bars with an income overlay line. The selected month's bar is
/// accented.
private struct SpendingTrendChart: View {
    let months: [MonthSpend]
    let highlightedMonth: Date

    private func isHighlighted(_ month: Date) -> Bool {
        Calendar.current.isDate(month, equalTo: highlightedMonth, toGranularity: .month)
    }

    var body: some View {
        Chart(months) { point in
            BarMark(
                x: .value("Month", point.shortLabel),
                y: .value("Spent", NSDecimalNumber(decimal: point.spent).doubleValue)
            )
            .foregroundStyle(isHighlighted(point.month) ? Theme.accent : Theme.accent.opacity(0.35))
            .cornerRadius(4)

            if months.contains(where: { $0.income > 0 }) {
                LineMark(
                    x: .value("Month", point.shortLabel),
                    y: .value("Income", NSDecimalNumber(decimal: point.income).doubleValue)
                )
                .foregroundStyle(Theme.positive)
                .symbol(.circle)
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYAxis {
            AxisMarks(format: .currency(code: Formatters.currency.currencyCode ?? "USD").precision(.fractionLength(0)))
        }
        .chartLegend(.hidden)
    }
}

/// Native SwiftUI donut chart of category spending. Only positive-amount
/// categories get a slice; the full list (including net-refund categories) and
/// every exact dollar amount + percentage stay in the text rows below.
private struct SpendingDistributionChart: View {
    let categories: [CategorySpend]
    var colorForName: (String) -> Color

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
                    innerRadius: .ratio(0.6),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(by: .value("Category", category.categoryName))
            }
            .chartForegroundStyleScale(
                domain: slices.map(\.categoryName),
                range: slices.map { colorForName($0.categoryName) }
            )
            .chartLegend(position: .trailing, alignment: .center, spacing: 8)
        }
    }
}
