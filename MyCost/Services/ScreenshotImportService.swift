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
    /// Positioned OCR observations (top-left origin), kept for the debug overlay.
    let observations: [OCRTextObservation]
    /// Transaction regions found by spatial grouping, for the debug overlay.
    let regions: [TransactionRegion]
    let transactionCandidates: [TransactionCandidate]
    /// Whether `transactionCandidates` came from spatial grouping (`true`) or
    /// the flat-text fallback (`false`).
    let usedSpatialGrouping: Bool
    /// The date used for year inference — pass to `replaceCandidates` so drafts
    /// resolve dates the same way.
    let referenceDate: Date
    /// Which layout profile configured the parser (`Generic` unless a bank
    /// signature was recognized).
    let layoutProfileName: String
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
    private let regionDetector: TransactionRegionDetector
    private let now: () -> Date

    init(
        ocrService: OCRServicing = VisionOCRService(),
        regionDetector: TransactionRegionDetector = TransactionRegionDetector(),
        now: @escaping () -> Date = Date.init
    ) {
        self.ocrService = ocrService
        self.regionDetector = regionDetector
        self.now = now
    }

    /// - Parameter referenceDateOverride: when a batch of screenshots is
    ///   processed together, pass one shared date so an undated "Aug 28" lands
    ///   in the same year across every screenshot. Defaults to `now()`.
    func processScreenshot(_ image: UIImage, referenceDateOverride: Date? = nil) async throws -> ScreenshotImportResult {
        do {
            let textBlocks = try await ocrService.recognizeText(in: image)
            guard !textBlocks.isEmpty else {
                throw ScreenshotImportError.noRecognizedText
            }

            // One reference date for the whole extraction so a screenshot date
            // with no year ("Aug 28") is consistently placed in the current
            // statement year everywhere it's parsed.
            let referenceDate = referenceDateOverride ?? now()

            let observations = textBlocks.map(OCRTextObservation.init(block:))
            let regions = regionDetector.detectRegions(from: observations)
            let originalOCRText = observations.map(\.text).joined(separator: "\n")

            // Pick a layout profile from a bank signature in the text; unknown
            // layouts get the generic configuration.
            let profile = BankLayoutProfile.identify(in: originalOCRText)
            let grouper = TransactionGrouper(
                referenceDate: referenceDate,
                configuration: profile.grouperConfiguration
            )
            let flatParser = TransactionCandidateParser(referenceDate: referenceDate)

            // Primary path: use the OCR bounding boxes to reconstruct the
            // statement's visual rows and group each transaction spatially.
            var candidates = grouper.candidates(from: regions, originalOCRText: originalOCRText)
            var usedSpatialGrouping = true

            // Fallback: if geometry told us nothing (degenerate boxes, or a
            // layout the grouper couldn't split), parse the flat text.
            if candidates.isEmpty {
                candidates = flatParser.parse(lines: textBlocks.map(\.text))
                usedSpatialGrouping = false
            }

            return ScreenshotImportResult(
                imageSize: image.size,
                recognizedTextBlocks: textBlocks,
                observations: observations,
                regions: regions,
                transactionCandidates: candidates,
                usedSpatialGrouping: usedSpatialGrouping,
                referenceDate: referenceDate,
                layoutProfileName: profile.name
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
