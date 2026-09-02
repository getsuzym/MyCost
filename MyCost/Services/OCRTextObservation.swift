import CoreGraphics
import Foundation

/// One piece of text recognized by OCR, with its position on screen.
///
/// `frame` is normalized to `0...1` on both axes with a **top-left origin and y
/// increasing downward**, so sorting by `frame.minY` then `frame.minX` yields
/// natural reading order. (Apple Vision reports boxes with a bottom-left origin;
/// see ``init(block:)`` for the flip.)
struct OCRTextObservation: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    let confidence: Double
    let frame: CGRect

    init(id: UUID = UUID(), text: String, confidence: Double, frame: CGRect) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.frame = frame
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var centerX: CGFloat { frame.midX }
    var centerY: CGFloat { frame.midY }

    func candidateObservation() -> TransactionCandidateObservation {
        TransactionCandidateObservation(text: text, frame: frame, confidence: confidence)
    }
}

extension OCRTextObservation {
    /// Bridge from the Vision-layer DTO. Vision boxes use a bottom-left origin
    /// with y up; flip y so downstream code can reason in screen coordinates.
    init(block: RecognizedTextBlock) {
        self.init(
            id: block.id,
            text: block.text,
            confidence: Double(block.confidence),
            frame: CGRect(
                x: block.boundingBox.minX,
                y: 1 - block.boundingBox.maxY,
                width: block.boundingBox.width,
                height: block.boundingBox.height
            )
        )
    }
}
