import Foundation
import UIKit

/// One screenshot queued for batch import. The `id` is stable for the life of
/// the workflow and is stamped onto every `TransactionCandidate` the screenshot
/// produces, so the Review screen can trace a transaction back to its source
/// image and duplicate detection can tell "same transaction seen twice" from
/// "two different transactions".
struct BatchScreenshotInput: Identifiable, Equatable {
    let id: UUID
    let image: UIImage

    init(id: UUID = UUID(), image: UIImage) {
        self.id = id
        self.image = image
    }
}

/// A screenshot that failed OCR / parsing. The batch keeps going; the caller
/// surfaces `label` + `reason` so the user knows which image to re-check.
struct BatchScreenshotFailure: Identifiable, Equatable {
    var id: UUID { screenshotID }
    let screenshotID: UUID
    let label: String
    let reason: String
}

struct ScreenshotBatchResult: Equatable {
    /// Every candidate from every screenshot, each tagged with its
    /// `sourceScreenshotID`, in screenshot order.
    var candidates: [TransactionCandidate] = []
    /// Downscaled preview per screenshot id — safe to retain through review.
    var thumbnails: [UUID: UIImage] = [:]
    var failures: [BatchScreenshotFailure] = []
    /// Shared reference date used for year inference across the whole batch.
    var referenceDate: Date = .now
    /// Screenshots the OCR pipeline ran to completion (attempted − failed).
    var succeededScreenshotCount: Int = 0
    /// Total screenshots submitted.
    var attemptedScreenshotCount: Int = 0

    var detectedCount: Int { candidates.count }

    /// "18 transactions detected from 5 screenshots." — plus a note about any
    /// screenshots that failed.
    var summaryMessage: String {
        let txn = "\(detectedCount) transaction\(detectedCount == 1 ? "" : "s")"
        let shots = "\(succeededScreenshotCount) screenshot\(succeededScreenshotCount == 1 ? "" : "s")"
        var message = "\(txn) detected from \(shots)."
        if !failures.isEmpty {
            let failed = failures.map(\.label).joined(separator: ", ")
            message += " \(failures.count) couldn\u{2019}t be read: \(failed)."
        }
        return message
    }
}

/// The single-screenshot step the batch runs once per image. `ScreenshotImportService`
/// is the production implementation; tests substitute a stub so the batch logic
/// (tagging, ordering, fault tolerance, thumbnails) is exercised on its own.
protocol SingleScreenshotProcessing {
    func processScreenshot(_ image: UIImage, referenceDateOverride: Date?) async throws -> ScreenshotImportResult
}

extension ScreenshotImportService: SingleScreenshotProcessing {}

/// Runs the **existing** single-screenshot pipeline
/// (`ScreenshotImportService.processScreenshot`) once per screenshot and
/// combines the results into one review session. Raw OCR text is never merged
/// across screenshots before grouping — each screenshot is parsed on its own,
/// then its candidates are appended. Fault tolerant: one screenshot's failure
/// is recorded and the batch continues.
struct ScreenshotBatchImportService {
    private let importService: SingleScreenshotProcessing
    private let now: () -> Date
    /// Longest edge (points) of the retained preview thumbnails.
    var thumbnailMaxDimension: CGFloat = 480

    init(
        importService: SingleScreenshotProcessing = ScreenshotImportService(),
        now: @escaping () -> Date = Date.init
    ) {
        self.importService = importService
        self.now = now
    }

    /// - Parameter progress: called on the main actor after each screenshot with
    ///   `(completed, total)` so the UI can show "Processing screenshot 2 of 5".
    func process(
        _ inputs: [BatchScreenshotInput],
        progress: @MainActor (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> ScreenshotBatchResult {
        let referenceDate = now()
        var result = ScreenshotBatchResult(referenceDate: referenceDate, attemptedScreenshotCount: inputs.count)
        let total = inputs.count

        for (offset, input) in inputs.enumerated() {
            let label = "Screenshot \(offset + 1)"
            do {
                let single = try await importService.processScreenshot(
                    input.image,
                    referenceDateOverride: referenceDate
                )
                let tagged = single.transactionCandidates.map { candidate -> TransactionCandidate in
                    var copy = candidate
                    copy.sourceScreenshotID = input.id
                    return copy
                }
                result.candidates.append(contentsOf: tagged)
                result.succeededScreenshotCount += 1
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                result.failures.append(
                    BatchScreenshotFailure(screenshotID: input.id, label: label, reason: reason)
                )
            }

            // Retain only a small preview; the full-resolution image is released
            // by the caller once processing finishes.
            result.thumbnails[input.id] = autoreleasepool {
                Self.downscale(input.image, maxDimension: thumbnailMaxDimension)
            }

            await progress(offset + 1, total)
        }

        return result
    }

    static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }

        let ratio = maxDimension / longest
        let target = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
