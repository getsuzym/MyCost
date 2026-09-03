import SwiftData
import SwiftUI

/// Batch screenshot import: Select Screenshots → Preview Selection → Process
/// Screenshots → (hand off to the Review tab) → Import → Confirmation.
///
/// Full-resolution `UIImage`s live only in `queued` and only until processing
/// finishes; after that the review session keeps just downscaled thumbnails.
struct ImportView: View {
    @EnvironmentObject private var ocrReviewStore: OCRTransactionReviewStore

    @Query(sort: \MerchantRule.updatedAt, order: .reverse) private var merchantRules: [MerchantRule]

    private enum Phase: Equatable {
        case idle
        case preview
        case processing
        case done
    }

    @State private var phase: Phase = .idle
    @State private var queued: [BatchScreenshotInput] = []
    @State private var isShowingPicker = false
    @State private var progress: (completed: Int, total: Int)?
    @State private var summaryMessage: String?
    @State private var failures: [BatchScreenshotFailure] = []
    @State private var errorMessage: String?

    private let batchService = ScreenshotBatchImportService()

    var body: some View {
        List {
            switch phase {
            case .idle:
                idleSection
            case .preview:
                previewSection
            case .processing:
                processingSection
            case .done:
                doneSection
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Import")
        .sheet(isPresented: $isShowingPicker) {
            ImagePicker { result in
                handlePicker(result)
            } onCancel: {
                if queued.isEmpty { phase = .idle }
            }
        }
    }

    // MARK: - Phases

    @ViewBuilder
    private var idleSection: some View {
        Section {
            ContentUnavailableView(
                "No screenshots selected",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Pick one or more banking screenshots. Each is processed on its own, then all detected transactions are combined into one review.")
            )
            .frame(minHeight: 220)

            Button {
                isShowingPicker = true
            } label: {
                Label("Select Screenshots", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("import.selectScreenshots")
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(queued) { input in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: input.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            queued.removeAll { $0.id == input.id }
                            if queued.isEmpty { phase = .idle }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .font(.title3)
                                .padding(4)
                        }
                        .accessibilityIdentifier("import.removeScreenshot")
                        .accessibilityLabel("Remove screenshot")
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("\(queued.count) screenshot\(queued.count == 1 ? "" : "s") selected")
        }

        Section {
            Button {
                isShowingPicker = true
            } label: {
                Label("Add More", systemImage: "plus")
            }
            .accessibilityIdentifier("import.addMore")

            Button {
                startProcessing()
            } label: {
                Label("Process \(queued.count) Screenshot\(queued.count == 1 ? "" : "s")", systemImage: "wand.and.stars")
            }
            .disabled(queued.isEmpty)
            .accessibilityIdentifier("import.process")

            Button(role: .destructive) {
                queued = []
                phase = .idle
            } label: {
                Label("Clear Selection", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var processingSection: some View {
        Section("Processing") {
            if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    Text("Processing screenshot \(progress.completed) of \(progress.total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("import.progress")
                }
            } else {
                ProgressView("Preparing…")
            }
        }
    }

    @ViewBuilder
    private var doneSection: some View {
        Section {
            Label(summaryMessage ?? "Processing complete.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.primary)
                .accessibilityIdentifier("import.summary")

            if ocrReviewStore.drafts.isEmpty {
                Text("No transactions were detected. Try clearer screenshots of the transaction list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Open the Review tab to check and import \(ocrReviewStore.drafts.count) detected transaction\(ocrReviewStore.drafts.count == 1 ? "" : "s").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Detected")
        }

        if !failures.isEmpty {
            Section("Couldn\u{2019}t be read") {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.label).font(.callout.weight(.medium))
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section {
            Button {
                resetToIdle()
            } label: {
                Label("Import More Screenshots", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("import.importMore")
        }
    }

    // MARK: - Actions

    private func handlePicker(_ result: Result<[PickedImage], ImagePickerError>) {
        switch result {
        case .success(let picked):
            let new = picked.map { BatchScreenshotInput(image: $0.image) }
            queued.append(contentsOf: new)
            errorMessage = nil
            if !queued.isEmpty { phase = .preview }
        case .failure(let error):
            errorMessage = error.localizedDescription
            if queued.isEmpty { phase = .idle }
        }
    }

    private func startProcessing() {
        guard !queued.isEmpty else { return }
        let inputs = queued
        phase = .processing
        progress = (0, inputs.count)
        errorMessage = nil

        Task {
            let result = await batchService.process(inputs) { completed, total in
                progress = (completed, total)
            }

            ocrReviewStore.replaceBatch(
                candidates: result.candidates,
                thumbnails: result.thumbnails,
                info: OCRBatchSessionInfo(
                    screenshotCount: result.succeededScreenshotCount,
                    failedScreenshots: result.failures.map(\.label)
                ),
                merchantRules: merchantRules,
                referenceDate: result.referenceDate
            )

            // Release the full-resolution images now that OCR is done.
            queued = []
            failures = result.failures
            summaryMessage = result.summaryMessage
            progress = nil
            phase = .done
            ToastCenter.shared.info(result.summaryMessage)
        }
    }

    private func resetToIdle() {
        queued = []
        failures = []
        summaryMessage = nil
        progress = nil
        errorMessage = nil
        phase = .idle
    }
}
