import Foundation

extension Collection {
    /// The element at `index`, or `nil` if it is out of bounds. Use instead of
    /// `self[index]` when the index comes from state that can go stale — a
    /// SwiftUI `.onDelete`/`.onMove` `IndexSet`, a remembered "selected index",
    /// or anything computed against an older snapshot of the collection.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Array {
    /// The elements at the given offsets, silently dropping any that are out of
    /// range. For `.onDelete` handlers where the `IndexSet` may no longer match
    /// the current array (async `@Query` update, rapid double-swipe).
    func elements(at offsets: IndexSet) -> [Element] {
        offsets.compactMap { self[safe: $0] }
    }
}
