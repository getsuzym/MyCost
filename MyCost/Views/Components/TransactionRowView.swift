import SwiftUI

struct TransactionRowView: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.category?.symbolName ?? "tag")
                .frame(width: 32, height: 32)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchantName)
                    .font(.headline)
                    .accessibilityIdentifier("transactionRow.merchant")

                Text("\(transaction.category?.name ?? "Uncategorized") • \(Formatters.shortDate.string(from: transaction.transactionDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.currencyString(for: transaction.amount))
                    .font(.headline)

                Text(transaction.status.label)
                    .font(.caption)
                    .foregroundStyle(transaction.status == .pending ? .orange : .secondary)
            }
        }
    }
}
