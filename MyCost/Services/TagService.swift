import Foundation
import SwiftData

extension Sequence where Element == Tag {
    /// Localized, case-insensitive alphabetical order by `name` — the order for
    /// every tag list and picker.
    func alphabetizedByName() -> [Tag] {
        sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum TagError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a tag name."
        case .duplicateName(let name): "A tag named \u{201C}\(name)\u{201D} already exists."
        }
    }
}

/// All `Tag` mutations go through here so name matching (trimmed,
/// case-insensitive) and create-or-reuse live in one place. Mirrors
/// `CategoryService` / `AccountService`.
struct TagService {
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func tag(named name: String, in tags: [Tag]) -> Tag? {
        let key = Self.normalizedName(name)
        guard !key.isEmpty else { return nil }
        return tags.first { Self.normalizedName($0.name) == key }
    }

    func isNameAvailable(_ name: String, in tags: [Tag], excluding: Tag? = nil) -> Bool {
        let key = Self.normalizedName(name)
        guard !key.isEmpty else { return false }
        return !tags.contains { $0.id != excluding?.id && Self.normalizedName($0.name) == key }
    }

    /// Returns the existing tag with this name (case-insensitive) or creates one.
    @MainActor
    @discardableResult
    func upsert(name: String, colorHex: String? = nil, in tags: [Tag], modelContext: ModelContext, saveImmediately: Bool = false) -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let result: Tag
        if let existing = tag(named: trimmed, in: tags) {
            result = existing
        } else {
            let created = Tag(name: trimmed, colorHex: colorHex)
            modelContext.insert(created)
            result = created
        }
        if saveImmediately { modelContext.saveOrLog("upsert tag") }
        return result
    }

    @MainActor
    func rename(_ tag: Tag, to newName: String, in tags: [Tag], modelContext: ModelContext) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagError.emptyName }
        guard isNameAvailable(trimmed, in: tags, excluding: tag) else { throw TagError.duplicateName(trimmed) }
        tag.name = trimmed
        try modelContext.save()
    }

    /// Removes the tag from every transaction it's on, then deletes it.
    @MainActor
    func delete(_ tag: Tag, modelContext: ModelContext) {
        for transaction in tag.transactions {
            transaction.tags.removeAll { $0.id == tag.id }
        }
        modelContext.delete(tag)
        modelContext.saveOrLog("delete tag")
    }

    /// Adds `tag` to `transaction` if not already present.
    func attach(_ tag: Tag, to transaction: Transaction) {
        guard !transaction.tags.contains(where: { $0.id == tag.id }) else { return }
        transaction.tags.append(tag)
    }

    func detach(_ tag: Tag, from transaction: Transaction) {
        transaction.tags.removeAll { $0.id == tag.id }
    }

    /// Reconciles a transaction's tags to exactly `desiredTagIDs`, creating no
    /// tags (all ids must already resolve in `allTags`).
    func setTags(_ desiredTagIDs: Set<UUID>, on transaction: Transaction, allTags: [Tag]) {
        transaction.tags.removeAll { !desiredTagIDs.contains($0.id) }
        let present = Set(transaction.tags.map(\.id))
        for id in desiredTagIDs where !present.contains(id) {
            if let tag = allTags.first(where: { $0.id == id }) {
                transaction.tags.append(tag)
            }
        }
    }
}
