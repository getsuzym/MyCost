import Foundation
import SwiftData

/// All `Account` reads/writes go through here so name matching (trimmed,
/// case-insensitive) and the "remember the type per account" behaviour live in
/// one place. Mirrors `CategoryService` / `MerchantRuleService`.
struct AccountService {
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func account(named name: String, in accounts: [Account]) -> Account? {
        let key = Self.normalizedName(name)
        guard !key.isEmpty else { return nil }
        return accounts.first { Self.normalizedName($0.name) == key }
    }

    /// The remembered type for `name`, or `.other` when the account is new.
    func resolveType(for name: String, in accounts: [Account]) -> AccountType {
        account(named: name, in: accounts)?.accountType ?? .other
    }

    /// Guess how an account shows purchases from a batch of detected amounts,
    /// so the import sheet can pre-fill the account-type step. Credit-card
    /// statements run mostly positive (purchases +, payments −); chequing/debit
    /// statements run mostly negative (purchases −, deposits +). An unclear or
    /// tiny sample yields `.other` with `isConfident == false`.
    static func guessAccountType(fromAmounts amounts: [Decimal]) -> AccountTypeSuggestion {
        let nonZero = amounts.filter { $0 != 0 }
        guard nonZero.count >= 2 else {
            return AccountTypeSuggestion(type: .other, isConfident: false)
        }

        let positives = nonZero.filter { $0 > 0 }.count
        let negatives = nonZero.count - positives
        let total = Double(nonZero.count)

        if Double(positives) / total >= 0.75 {
            return AccountTypeSuggestion(type: .creditCard, isConfident: nonZero.count >= 3)
        }
        if Double(negatives) / total >= 0.75 {
            return AccountTypeSuggestion(type: .debit, isConfident: nonZero.count >= 3)
        }
        return AccountTypeSuggestion(type: .other, isConfident: false)
    }

    /// Creates the account if it doesn't exist, or updates its type. Does not
    /// call `save()` unless `saveImmediately` (the caller usually saves once).
    @MainActor
    @discardableResult
    func upsert(
        name: String,
        type: AccountType,
        in accounts: [Account],
        modelContext: ModelContext,
        saveImmediately: Bool = false
    ) -> Account? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let result: Account
        if let existing = account(named: trimmed, in: accounts) {
            if existing.accountType != type {
                existing.accountType = type
                existing.updatedAt = .now
            }
            result = existing
        } else {
            let created = Account(name: trimmed, accountType: type)
            modelContext.insert(created)
            result = created
        }

        if saveImmediately { modelContext.saveOrLog("upsert account") }
        return result
    }

    @MainActor
    func updateAccount(_ account: Account, name: String, type: AccountType, modelContext: ModelContext) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountError.emptyName }
        account.name = trimmed
        account.accountType = type
        account.updatedAt = .now
        try modelContext.save()
    }
}

struct AccountTypeSuggestion: Equatable {
    var type: AccountType
    /// The amount signs pointed clearly one way on a large-enough sample. When
    /// `false`, the import sheet asks the user to confirm rather than assert.
    var isConfident: Bool
}

enum AccountError: LocalizedError, Equatable {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter an account name."
        }
    }
}
