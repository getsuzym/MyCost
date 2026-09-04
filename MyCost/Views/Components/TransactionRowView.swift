import SwiftUI

struct TransactionRowView: View {
    let transaction: Transaction

    private var tint: Color {
        if let hex = transaction.category?.colorHex, let color = Color(hex: hex) {
            return color
        }
        return Theme.accent
    }

    private var isRefund: Bool { transaction.amount < 0 }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: transaction.category?.symbolName.isEmpty == false
                    ? transaction.category!.symbolName
                    : "tag.fill",
                tint: tint
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("transactionRow.merchant")

                HStack(spacing: 6) {
                    Text(transaction.category?.name ?? "Uncategorized")
                    Text("·")
                    Text(Formatters.shortDate.string(from: transaction.transactionDate))
                    if transaction.isExcluded {
                        Text("· Excluded").foregroundStyle(.secondary)
                    } else if transaction.isIncome {
                        Text("· Income").foregroundStyle(Theme.positive)
                    } else if !transaction.countsAsSpending {
                        Text("· Not counted").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Formatters.currencyString(for: transaction.amount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isRefund ? Theme.positive : Color.primary)

                if transaction.isRecurring {
                    Text(transaction.recurringPayment?.schedule().label ?? "Recurring")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(transaction.isExcluded ? 0.6 : 1)
    }
}
