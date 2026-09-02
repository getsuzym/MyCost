import CoreGraphics
import Foundation

/// A horizontal rule detected in the screenshot (e.g. a row separator). `y` is
/// normalized with a top-left origin. Supplying these lets the detector split
/// transactions exactly on the divider instead of guessing from spacing.
struct DividerLine: Equatable {
    var y: CGFloat
}

/// A run of OCR observations that sit on the same visual row, ordered
/// left-to-right. Multi-line merchant descriptions become several `TextLine`s
/// inside one ``TransactionRegion``.
struct TextLine: Equatable {
    var observations: [OCRTextObservation]
    var frame: CGRect

    var text: String {
        observations.map(\.text).joined(separator: " ")
    }
    var minY: CGFloat { frame.minY }
    var maxY: CGFloat { frame.maxY }
    var centerY: CGFloat { frame.midY }
}

/// One transaction's worth of OCR — every observation that fell between two
/// boundaries — kept with its geometry for the grouper and the debug overlay.
struct TransactionRegion: Identifiable, Equatable {
    let id: UUID
    var lines: [TextLine]
    var frame: CGRect

    init(id: UUID = UUID(), lines: [TextLine], frame: CGRect) {
        self.id = id
        self.lines = lines
        self.frame = frame
    }

    /// Observations flattened back into reading order.
    var observations: [OCRTextObservation] {
        lines.flatMap(\.observations)
    }

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

/// Turns a flat list of positioned OCR observations into transaction regions
/// using screen geometry: sort by position, cluster into rows, then cut into
/// regions on divider lines when available and otherwise on abnormally large
/// vertical gaps (with an amount-bearing-row fallback when spacing is uniform).
struct TransactionRegionDetector {
    struct Configuration {
        /// Two observations belong to the same row if their vertical spans
        /// overlap by at least this ratio, or their centers are closer than
        /// `rowCenterHeightFactor` × median text height. Compared against the
        /// row's first (anchor) observation, not the growing union.
        var rowOverlapRatio: CGFloat = 0.30
        var rowCenterHeightFactor: CGFloat = 0.60
        /// Rows closer than this × median height are one tightly-packed block
        /// (a wrapped description) and never split.
        var tightGapFactor: CGFloat = 0.6
        /// A gap starts a new region when it exceeds `gapMultiple` × the typical
        /// inter-row gap and is also at least `gapHeightFactor` × median height.
        var gapMultiple: CGFloat = 2.2
        var gapHeightFactor: CGFloat = 0.9
        /// A divider cuts at its nearest row gap only if within this distance.
        var dividerSnapDistance: CGFloat = 0.04

        static let `default` = Configuration()
    }

    private let configuration: Configuration
    private let containsAmount: (String) -> Bool
    private let isSectionHeader: (String) -> Bool
    private let isDetailContinuation: (String) -> Bool

    init(
        configuration: Configuration = .default,
        containsAmount: @escaping (String) -> Bool = { TransactionTextHeuristics().containsAmount(in: $0) },
        isSectionHeader: @escaping (String) -> Bool = { TransactionTextHeuristics().dateOnlyHeader(in: $0) != nil },
        isDetailContinuation: @escaping (String) -> Bool = { TransactionTextHeuristics().isDetailContinuationLine($0) }
    ) {
        self.configuration = configuration
        self.containsAmount = containsAmount
        self.isSectionHeader = isSectionHeader
        self.isDetailContinuation = isDetailContinuation
    }

    func detectRegions(
        from observations: [OCRTextObservation],
        dividers: [DividerLine] = []
    ) -> [TransactionRegion] {
        let usable = observations.filter { !$0.trimmedText.isEmpty }
        guard !usable.isEmpty else { return [] }

        let lines = clusterIntoLines(usable)
        guard lines.count > 1 else {
            return lines.isEmpty ? [] : [region(from: lines)]
        }

        let boundaries = regionBoundaries(between: lines, dividers: dividers)
        return sliceLines(lines, at: boundaries).map(region(from:))
    }

    // MARK: Row clustering

    private func clusterIntoLines(_ observations: [OCRTextObservation]) -> [TextLine] {
        let sorted = observations.sorted { lhs, rhs in
            if abs(lhs.frame.minY - rhs.frame.minY) > 0.004 {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }

        let medianHeight = median(sorted.map(\.frame.height)) ?? 0.02
        var lines: [[OCRTextObservation]] = []

        for observation in sorted {
            // Compare against the row's anchor (its first, left-most-topmost
            // observation), not the union — an amount that renders a little
            // lower must not stretch the row down onto the line below it.
            if let index = lines.indices.last, let anchor = lines[index].first {
                let overlap = verticalOverlapRatio(observation.frame, anchor.frame)
                let centerClose = abs(observation.centerY - anchor.centerY)
                    <= medianHeight * configuration.rowCenterHeightFactor
                if overlap >= configuration.rowOverlapRatio || centerClose {
                    lines[index].append(observation)
                    continue
                }
            }
            lines.append([observation])
        }

        return lines.map { group in
            let ordered = group.sorted { $0.frame.minX < $1.frame.minX }
            return TextLine(observations: ordered, frame: unionFrame(ordered))
        }
    }

    // MARK: Boundaries

    private func regionBoundaries(between lines: [TextLine], dividers: [DividerLine]) -> Set<Int> {
        var boundaries = Set<Int>()
        let gaps = zip(lines, lines.dropFirst()).map { max(0, $1.minY - $0.maxY) }
        guard !gaps.isEmpty else { return boundaries }
        let medianHeight = median(lines.map(\.frame.height)) ?? 0.02

        // 1. Divider lines: cut at the single nearest row gap.
        for divider in dividers {
            var nearest: (index: Int, penalty: CGFloat)?
            for index in gaps.indices {
                let low = lines[index].maxY
                let high = lines[index + 1].minY
                let penalty: CGFloat = divider.y < low ? low - divider.y
                    : divider.y > high ? divider.y - high
                    : 0
                if nearest == nil || penalty < nearest!.penalty {
                    nearest = (index, penalty)
                }
            }
            if let nearest, nearest.penalty <= configuration.dividerSnapDistance {
                boundaries.insert(nearest.index)
            }
        }

        // 2. Gap outliers: a row gap much larger than the typical one.
        if let typicalGap = median(gaps.filter { $0 > 0 }), typicalGap > 0 {
            let threshold = max(typicalGap * configuration.gapMultiple, medianHeight * configuration.gapHeightFactor)
            for (index, gap) in gaps.enumerated() where gap > threshold {
                boundaries.insert(index)
            }
        }

        // 3. Section-date headers ("Aug 29, 2026" on its own): isolate the header
        //    row so its date can be carried to every transaction below it.
        for index in lines.indices where isSectionHeader(lines[index].text) {
            if index < lines.count - 1 { boundaries.insert(index) }
            if index > 0 { boundaries.insert(index - 1) }
        }

        // 4. Sequential assembly. A row starts a new transaction only once the
        //    current one already has an amount and the row is neither tightly
        //    packed against the row above (a wrapped description) nor a detail
        //    continuation ("City, PROV", "Pay in Installments", bare amount).
        var regionHasAmount = false
        for index in lines.indices {
            let line = lines[index]
            if index > 0,
               !isSectionHeader(line.text),
               !isSectionHeader(lines[index - 1].text),
               regionHasAmount {
                let gapAbove = max(0, line.minY - lines[index - 1].maxY)
                let tight = gapAbove <= medianHeight * configuration.tightGapFactor
                if !tight, !isDetailContinuation(line.text) {
                    boundaries.insert(index - 1)
                    regionHasAmount = false
                }
            }
            if containsAmount(line.text) { regionHasAmount = true }
            if isSectionHeader(line.text) { regionHasAmount = false }
        }

        return boundaries
    }

    private func sliceLines(_ lines: [TextLine], at boundaries: Set<Int>) -> [[TextLine]] {
        var result: [[TextLine]] = []
        var current: [TextLine] = []
        for (index, line) in lines.enumerated() {
            current.append(line)
            if boundaries.contains(index) {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private func region(from lines: [TextLine]) -> TransactionRegion {
        TransactionRegion(lines: lines, frame: unionFrame(lines.flatMap(\.observations)))
    }

    // MARK: Geometry helpers

    private func unionFrame(_ observations: [OCRTextObservation]) -> CGRect {
        observations.dropFirst().reduce(observations.first?.frame ?? .zero) { $0.union($1.frame) }
    }

    private func verticalOverlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let top = max(a.minY, b.minY)
        let bottom = min(a.maxY, b.maxY)
        let overlap = max(0, bottom - top)
        let minHeight = max(min(a.height, b.height), 0.0001)
        return overlap / minHeight
    }

    private func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
