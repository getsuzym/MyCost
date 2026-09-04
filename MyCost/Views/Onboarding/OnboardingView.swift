import SwiftData
import SwiftUI

/// One-time first-run intro. Ends by optionally recording the user's main
/// account type on a "Default" `Account`, so the first screenshot import can
/// skip the guess-and-confirm step.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var accounts: [Account]

    @State private var page = 0
    @State private var selection: AccountChoice?

    private let accountService = AccountService()

    private enum AccountChoice: Hashable {
        case credit, debit, skip

        var accountType: AccountType? {
            switch self {
            case .credit: .creditCard
            case .debit: .debit
            case .skip: nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                infoPage(
                    icon: "chart.pie.fill",
                    title: "Track what you spend",
                    message: "MyCost keeps a private, on-device picture of your month — by category, recurring vs. not, budgets, income vs. spending. Nothing leaves your phone."
                )
                .tag(0)

                infoPage(
                    icon: "photo.badge.plus",
                    title: "Import from screenshots",
                    message: "Screenshot your banking app's transaction list and tap the import button on the Dashboard. MyCost reads the rows on-device; you review and de-dupe, then save."
                )
                .tag(1)

                VStack(spacing: 24) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.accent)
                    Text("Your main account")
                        .font(.title2.bold())
                    Text("How does your usual account show purchases? This just sets a sensible default — you can change it any time.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                    VStack(spacing: 10) {
                        choiceRow("Credit card", "Purchases show as positive", .credit)
                        choiceRow("Chequing / debit", "Purchases show as negative", .debit)
                        choiceRow("Skip for now", "Decide later", .skip)
                    }
                }
                .padding(28)
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button(page < 2 ? "Continue" : "Get Started") {
                if page < 2 {
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .accessibilityIdentifier("onboarding.primary")
        }
        .overlay(alignment: .topTrailing) {
            Button("Skip") { finish() }
                .padding()
                .accessibilityIdentifier("onboarding.skip")
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func infoPage(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
        .padding(28)
    }

    @ViewBuilder
    private func choiceRow(_ title: String, _ subtitle: String, _ choice: AccountChoice) -> some View {
        Button {
            selection = choice
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selection == choice ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection == choice ? Theme.accent : .secondary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func finish() {
        if let type = selection?.accountType {
            accountService.upsert(name: "Default", type: type, in: accounts, modelContext: modelContext, saveImmediately: true)
        }
        dismiss()
    }
}
