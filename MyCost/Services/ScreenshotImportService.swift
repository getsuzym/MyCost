import Foundation
import UIKit

struct ExtractedTransaction: Identifiable {
    let id = UUID()
    var merchantName: String
    var amount: Decimal
    var transactionDate: Date
    var status: TransactionStatus
}

struct ScreenshotImportResult {
    let imageSize: CGSize
    let recognizedTextBlocks: [RecognizedTextBlock]
    let transactionCandidates: [TransactionCandidate]
}

enum ScreenshotImportError: LocalizedError, Equatable {
    case noRecognizedText
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecognizedText:
            "No text was recognized in this screenshot."
        case .processingFailed(let message):
            "Screenshot import failed: \(message)"
        }
    }
}

struct ScreenshotImportService {
    private let ocrService: OCRServicing
    private let transactionParser: TransactionCandidateParser

    init(
        ocrService: OCRServicing = VisionOCRService(),
        transactionParser: TransactionCandidateParser = TransactionCandidateParser()
    ) {
        self.ocrService = ocrService
        self.transactionParser = transactionParser
    }

    func processScreenshot(_ image: UIImage) async throws -> ScreenshotImportResult {
        do {
            let textBlocks = try await ocrService.recognizeText(in: image)
            guard !textBlocks.isEmpty else {
                throw ScreenshotImportError.noRecognizedText
            }
            let transactionCandidates = transactionParser.parse(lines: textBlocks.map(\.text))

            return ScreenshotImportResult(
                imageSize: image.size,
                recognizedTextBlocks: textBlocks,
                transactionCandidates: transactionCandidates
            )
        } catch let error as ScreenshotImportError {
            throw error
        } catch {
            throw ScreenshotImportError.processingFailed(error.localizedDescription)
        }
    }

    func extractPlaceholderTransactions(fromScreenshotCount screenshotCount: Int) -> [ExtractedTransaction] {
        guard screenshotCount > 0 else { return [] }

        let calendar = Calendar.current
        return [
            ExtractedTransaction(
                merchantName: "Trader Joe's",
                amount: 64.22,
                transactionDate: calendar.date(byAdding: .day, value: -1, to: .now) ?? .now,
                status: .posted
            ),
            ExtractedTransaction(
                merchantName: "City Transit",
                amount: 2.90,
                transactionDate: calendar.date(byAdding: .day, value: -2, to: .now) ?? .now,
                status: .posted
            ),
            ExtractedTransaction(
                merchantName: "Cloud Storage",
                amount: 9.99,
                transactionDate: .now,
                status: .pending
            )
        ]
    }
}
