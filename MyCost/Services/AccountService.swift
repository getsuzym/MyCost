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

        if saveImmediately { try? modelContext.save() }
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

enum AccountError: LocalizedError, Equatable {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter an account name."
        }
    }
}
