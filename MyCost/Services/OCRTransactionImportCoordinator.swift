import Foundation

struct OCRDuplicateScanResult: Equatable {
    let blockedCount: Int
    let mediumMatchCount: Int

    var needsUserDecision: Bool {
        blockedCount > 0 || mediumMatchCount > 0
    }

    var message: String {
        var messages: [String] = []
        if blockedCount > 0 {
            messages.append("\(blockedCount) duplicate\(blockedCount == 1 ? "" : "s") blocked.")
        }
        if mediumMatchCount > 0 {
            messages.append("Choose Merge, Keep Both, or Review for \(mediumMatchCount) possible match\(mediumMatchCount == 1 ? "" : "es").")
        }
        return messages.joined(separator: " ")
    }
}

struct OCRTransactionImportCoordinator {
    private let duplicateMatchingService: DuplicateMatchingService

    init(duplicateMatchingService: DuplicateMatchingService = DuplicateMatchingService()) {
        self.duplicateMatchingService = duplicateMatchingService
    }

    func flagDuplicateDrafts(
        drafts: inout [OCRTransactionDraft],
        existingTransactions: [DuplicateTransactionSnapshot]
    ) -> OCRDuplicateScanResult {
        var stagedSnapshots = existingTransactions
        var blockedCount = 0
        var mediumMatchCount = 0

        for index in drafts.indices {
            guard drafts[index].isSelected,
                  drafts[index].canImport,
                  let incomingSnapshot = drafts[index].duplicateSnapshot() else {
                continue
            }

            if let highMatch = duplicateMatchingService.highConfidenceDuplicate(
                for: incomingSnapshot,
                against: stagedSnapshots
            ) {
                drafts[index].isSelected = false
                drafts[index].duplicateMatchID = highMatch.existing.id
                drafts[index].duplicateSummary = "High-confidence duplicate was not selected for import."
                drafts[index].duplicateDecision = .review
                blockedCount += 1
                continue
            }

            if drafts[index].duplicateSummary == nil,
               let mediumMatch = duplicateMatchingService.bestMatch(for: incomingSnapshot, against: stagedSnapshots),
               mediumMatch.confidence == .medium {
                drafts[index].duplicateMatchID = mediumMatch.existing.id
                drafts[index].duplicateSummary = "Possible duplicate of \(mediumMatch.existing.merchantName) for \(NSDecimalNumber(decimal: mediumMatch.existing.amount).stringValue)."
                drafts[index].duplicateDecision = .review
                mediumMatchCount += 1
                continue
            }

            stagedSnapshots.append(incomingSnapshot)
        }

        return OCRDuplicateScanResult(blockedCount: blockedCount, mediumMatchCount: mediumMatchCount)
    }
}
