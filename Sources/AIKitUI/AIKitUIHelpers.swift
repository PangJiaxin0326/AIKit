import Foundation

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

func aiKitContextualFollowUpInstruction(
    previous: String,
    reason: String?,
    followUp: String
) -> String {
    var parts = ["This is a follow-up to a request you could not complete."]
    if !previous.isEmpty {
        parts.append("Your earlier request was: \"\(previous)\"")
    }
    if let reason, !reason.isEmpty {
        parts.append("It could not be completed because: \(reason)")
    }
    parts.append("Clarification / new instruction: \(followUp)")
    parts.append("Treat the earlier request and this clarification as one request.")
    return parts.joined(separator: "\n")
}
