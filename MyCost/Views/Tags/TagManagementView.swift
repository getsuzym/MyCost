import SwiftData
import SwiftUI

/// More → Tags. Create, rename, and delete the free-form labels. Deleting a tag
/// only detaches it from transactions (`TagService.delete`); the transactions
/// themselves are untouched.
struct TagManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var tags: [Tag]

    @State private var newTagName = ""
    @State private var renaming: Tag?
    @State private var renameText = ""
    @State private var pendingDelete: Tag?
    @State private var errorMessage: String?

    private let service = TagService()

    private var sortedTags: [Tag] { tags.alphabetizedByName() }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("New tag", text: $newTagName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(addTag)
                        .accessibilityIdentifier("tags.newTag")
                    Button("Add", action: addTag)
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                if sortedTags.isEmpty {
                    Text("No tags yet. Add one above, or create tags while editing a transaction.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedTags) { tag in
                        Button {
                            renaming = tag
                            renameText = tag.name
                        } label: {
                            HStack {
                                Label(tag.name, systemImage: "tag")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(tag.transactions.count)")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("\(tag.transactions.count) transactions")
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = tag } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Tags")
            } footer: {
                Text("The number is how many transactions carry the tag. Deleting a tag removes it from those transactions but keeps the transactions.")
            }
        }
        .navigationTitle("Tags")
        .themedListBackground()
        .alert("Rename tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.never)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "Delete tag?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let tag = pendingDelete { service.delete(tag, modelContext: modelContext) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let tag = pendingDelete, !tag.transactions.isEmpty {
                Text("It's on \(tag.transactions.count) transaction\(tag.transactions.count == 1 ? "" : "s"), which stay as they are.")
            }
        }
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard service.isNameAvailable(name, in: tags) else {
            errorMessage = TagError.duplicateName(name).errorDescription
            return
        }
        service.upsert(name: name, in: tags, modelContext: modelContext, saveImmediately: true)
        newTagName = ""
        errorMessage = nil
    }

    private func commitRename() {
        guard let tag = renaming else { return }
        do {
            try service.rename(tag, to: renameText, in: tags, modelContext: modelContext)
            errorMessage = nil
        } catch {
            errorMessage = (error as? TagError)?.errorDescription ?? error.localizedDescription
        }
        renaming = nil
    }
}
