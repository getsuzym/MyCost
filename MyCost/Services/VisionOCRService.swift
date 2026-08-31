import CoreGraphics
import UIKit
import Vision

struct RecognizedTextBlock: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

enum OCRServiceError: LocalizedError, Equatable {
    case imageMissingCGImage
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageMissingCGImage:
            "The selected image could not be read."
        case .recognitionFailed(let message):
            "Text recognition failed: \(message)"
        }
    }
}

protocol OCRServicing {
    func recognizeText(in image: UIImage) async throws -> [RecognizedTextBlock]
}

struct VisionOCRService: OCRServicing {
    func recognizeText(in image: UIImage) async throws -> [RecognizedTextBlock] {
        guard let cgImage = image.cgImage else {
            throw OCRServiceError.imageMissingCGImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRServiceError.recognitionFailed(error.localizedDescription))
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let blocks = observations.compactMap { observation -> RecognizedTextBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedTextBlock(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        boundingBox: observation.boundingBox
                    )
                }
                .sorted { lhs, rhs in
                    if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 0.02 {
                        return lhs.boundingBox.minY > rhs.boundingBox.minY
                    }
                    return lhs.boundingBox.minX < rhs.boundingBox.minX
                }

                continuation.resume(returning: blocks)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.cgImagePropertyOrientation)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRServiceError.recognitionFailed(error.localizedDescription))
            }
        }
    }
}

private extension UIImage {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

