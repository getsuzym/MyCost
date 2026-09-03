import SwiftData
import SwiftUI

struct CategoryManagementView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var transactions: [Transaction]
    @Query private var merchantRules: [MerchantRule]
    @Query private var recurringPayments: [RecurringPayment]

    @State private var editingCategory: Category?
    @State private var isAddingCategory = false
    @State private var deletionTarget: Category?
    @State private var errorMessage: String?

    private let service = CategoryService()

    /// Rows are shown in localized, case-insensitive alphabetical order — not
    /// SwiftData fetch / creation order.
    private var sortedCategories: [Category] {
        categories.alphabetizedByName()
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                ForEach(sortedCategories) { category in
                    Button {
                        editingCategory = category
                    } label: {
                        CategoryRow(category: category, counts: counts(for: category))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if !category.isFallback {
                            Button(role: .destructive) {
                                beginDeletion(of: category)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        if !category.isFallback {
                            Button {
                                toggleActive(category)
                            } label: {
                                Label(category.isActive ? "Hide" : "Show",
                                      systemImage: category.isActive ? "eye.slash" : "eye")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Shown alphabetically. Hidden categories stay on existing transactions but aren't offered when categorizing. Uncategorized is always available and can't be removed.")
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingCategory = true
                } label: {
                    Label("Add Category", systemImage: "plus")
                }
                .accessibilityIdentifier("categories.add")
            }
        }
        .sheet(isPresented: $isAddingCategory) {
            NavigationStack {
                CategoryEditorView(category: nil, existingCategories: categories)
            }
        }
        .sheet(item: $editingCategory) { category in
            NavigationStack {
                CategoryEditorView(category: category, existingCategories: categories)
            }
        }
        .sheet(item: $deletionTarget) { category in
            NavigationStack {
                CategoryDeletionView(
                    category: category,
                    counts: counts(for: category),
                    otherCategories: categories.filter { $0.id != category.id },
                    onDelete: { target in performDeletion(of: category, reassigningTo: target) }
                )
            }
        }
    }

    private func counts(for category: Category) -> CategoryReferenceCounts {
        service.referenceCounts(
            for: category,
            transactions: transactions,
            merchantRules: merchantRules,
            recurringPayments: recurringPayments
        )
    }

    private func beginDeletion(of category: Category) {
        errorMessage = nil
        if counts(for: category).isInUse {
            deletionTarget = category
        } else {
            performDeletion(of: category, reassigningTo: nil)
        }
    }

    private func performDeletion(of category: Category, reassigningTo target: Category?) {
        let counts = counts(for: category)
        do {
            try service.deleteCategory(
                category,
                reassigningTo: target,
                transactions: transactions,
                merchantRules: merchantRules,
                recurringPayments: recurringPayments,
                modelContext: modelContext
            )
            deletionTarget = nil
            if counts.isInUse {
                let destination = target.map { "moved to \($0.name)" } ?? "moved to Uncategorized"
                ToastCenter.shared.success("Category deleted — \(counts.total) item\(counts.total == 1 ? "" : "s") \(destination)")
            } else {
                ToastCenter.shared.success(CRUDFeedback.deleted("category"))
            }
        } catch {
            errorMessage = error.localizedDescription
            ToastCenter.shared.error(CRUDFeedback.deleteFailure("category"))
        }
    }

    private func toggleActive(_ category: Category) {
        errorMessage = nil
        let willHide = category.isActive
        do {
            try service.setActive(category, !category.isActive, modelContext: modelContext)
            ToastCenter.shared.success(willHide ? "Category hidden" : "Category shown")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

private struct CategoryRow: View {
    let category: Category
    let counts: CategoryReferenceCounts

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbolName.isEmpty ? "tag" : category.symbolName)
                .foregroundStyle(Color(hex: category.colorHex) ?? .accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(category.name)
                    if category.isFallback {
                        Text("Fallback").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !category.isActive {
                        Text("Hidden").font(.caption2).foregroundStyle(.orange)
                    }
                }
                if counts.isInUse {
                    Text(usageSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usageSummary: String {
        var parts: [String] = []
        if counts.transactions > 0 { parts.append("\(counts.transactions) tx") }
        if counts.merchantRules > 0 { parts.append("\(counts.merchantRules) rule\(counts.merchantRules == 1 ? "" : "s")") }
        if counts.recurringPayments > 0 { parts.append("\(counts.recurringPayments) recurring") }
        return parts.joined(separator: " · ")
    }
}

private struct CategoryDeletionView: View {
    let category: Category
    let counts: CategoryReferenceCounts
    let otherCategories: [Category]
    let onDelete: (Category?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTargetID: UUID?

    private var reassignChoices: [Category] {
        otherCategories.filter { $0.isActive || $0.isFallback }.alphabetizedByName()
    }

    var body: some View {
        Form {
            Section {
                Text("\u{201C}\(category.name)\u{201D} is used by:")
                if counts.transactions > 0 { Text("• \(counts.transactions) transaction\(counts.transactions == 1 ? "" : "s")") }
                if counts.merchantRules > 0 { Text("• \(counts.merchantRules) merchant rule\(counts.merchantRules == 1 ? "" : "s")") }
                if counts.recurringPayments > 0 { Text("• \(counts.recurringPayments) recurring payment\(counts.recurringPayments == 1 ? "" : "s")") }
            }

            Section("Move those items to") {
                Picker("Category", selection: $selectedTargetID) {
                    Text("Uncategorized").tag(UUID?.none)
                    ForEach(reassignChoices) { candidate in
                        Text(candidate.name).tag(Optional(candidate.id))
                    }
                }
                .accessibilityIdentifier("categoryDeletion.target")
            }

            Section {
                Button(role: .destructive) {
                    let target = reassignChoices.first { $0.id == selectedTargetID }
                    onDelete(target)
                    dismiss()
                } label: {
                    Text("Delete and Move Items")
                }
                .accessibilityIdentifier("categoryDeletion.confirm")
            }
        }
        .navigationTitle("Delete Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

private struct CategoryEditorView: View {
    let category: Category?
    let existingCategories: [Category]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var symbolName = "tag"
    @State private var colorHex = CategoryEditorView.palette[0]
    @State private var errorMessage: String?

    private let service = CategoryService()

    static let palette = [
        "#2A9D8F", "#E76F51", "#457B9D", "#B56576",
        "#6D597A", "#3A86FF", "#4D908E", "#F4A261", "#6C757D"
    ]

    var body: some View {
        Form {
            Section("Category") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("categoryEditor.name")

                TextField("SF Symbol", text: $symbolName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("categoryEditor.symbol")

                HStack {
                    Text("Preview")
                    Spacer()
                    Image(systemName: symbolName.isEmpty ? "tag" : symbolName)
                        .foregroundStyle(Color(hex: colorHex) ?? .accentColor)
                }
            }

            Section("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(Self.palette, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 30, height: 30)
                            .overlay {
                                if hex == colorHex {
                                    Circle().stroke(Color.primary, lineWidth: 2)
                                }
                            }
                            .onTapGesture { colorHex = hex }
                    }
                }
                .padding(.vertical, 4)
            }

            if category?.isFallback == true {
                Section {
                    Text("This is the fallback category. You can restyle it, but it can't be removed or hidden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(category == nil ? "Add Category" : "Edit Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .accessibilityIdentifier("categoryEditor.save")
            }
        }
        .onAppear(perform: loadInitialValues)
    }

    private func loadInitialValues() {
        guard let category else { return }
        name = category.name
        symbolName = category.symbolName
        colorHex = category.colorHex
    }

    private func save() {
        errorMessage = nil
        let isEditing = category != nil
        do {
            if let category {
                try service.updateCategory(
                    category,
                    name: name,
                    symbolName: symbolName,
                    colorHex: colorHex,
                    in: existingCategories,
                    modelContext: modelContext
                )
            } else {
                try service.createCategory(
                    name: name,
                    symbolName: symbolName,
                    colorHex: colorHex,
                    in: existingCategories,
                    modelContext: modelContext
                )
            }
            ToastCenter.shared.success(isEditing ? CRUDFeedback.updated("category") : CRUDFeedback.added("category"))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            if (error as? CategoryError) == nil {
                ToastCenter.shared.error(CRUDFeedback.saveFailure("category"))
            }
        }
    }
}

extension Color {
    /// `#RRGGBB` → Color, or nil if unparseable.
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value & 0xFF0000) >> 16) / 255,
            green: Double((value & 0x00FF00) >> 8) / 255,
            blue: Double(value & 0x0000FF) / 255
        )
    }
}
