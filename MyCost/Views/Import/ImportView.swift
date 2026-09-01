import SwiftUI

struct ImportView: View {
    @State private var isShowingImagePicker = false
    @State private var selectedImage: UIImage?
    @State private var recognizedTextBlocks: [RecognizedTextBlock] = []
    @State private var statusMessage = "Select a banking screenshot to prepare it for OCR review."
    @State private var errorMessage: String?
    @State private var isProcessing = false

    private let importService = ScreenshotImportService()

    var body: some View {
        List {
            Section {
                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("import.preview")
                } else {
                    ContentUnavailableView("No screenshot selected", systemImage: "photo")
                        .frame(minHeight: 220)
                }

                Button {
                    isShowingImagePicker = true
                } label: {
                    Label("Select Screenshot", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("import.selectScreenshot")
            }

            Section("Import Status") {
                if isProcessing {
                    ProgressView("Recognizing text")
                } else {
                    Text(statusMessage)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("Recognized Text") {
                if recognizedTextBlocks.isEmpty {
                    Text("No recognized text yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recognizedTextBlocks) { block in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.text)
                            Text("\(Int(block.confidence * 100))% confidence")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Import")
        .sheet(isPresented: $isShowingImagePicker) {
            ImagePicker { result in
                switch result {
                case .success(let pickedImage):
                    selectedImage = pickedImage.image
                    recognizedTextBlocks = []
                    statusMessage = "Screenshot selected."
                    errorMessage = nil
                    processSelectedImage(pickedImage.image)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    statusMessage = "Image selection failed."
                }
            } onCancel: {
                statusMessage = "Image selection cancelled."
                errorMessage = nil
            }
        }
    }

    private func processSelectedImage(_ image: UIImage) {
        isProcessing = true
        Task {
            do {
                let result = try await importService.processScreenshot(image)
                await MainActor.run {
                    recognizedTextBlocks = result.recognizedTextBlocks
                    statusMessage = "Recognized \(result.recognizedTextBlocks.count) text blocks and detected \(result.transactionCandidates.count) transaction candidates. Transactions were not saved."
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    recognizedTextBlocks = []
                    errorMessage = error.localizedDescription
                    statusMessage = "Screenshot processed with errors."
                    isProcessing = false
                }
            }
        }
    }
}
