import Foundation

struct VoiceInputRecoveryDraft {
    private var draft: (presentationID: UUID, text: String)?
    @discardableResult mutating func remember(_ text: String, presentationID: UUID, currentID: UUID?) -> Bool {
        guard currentID == presentationID, text.utf8.count <= 1_048_576 else { return false }
        draft = (presentationID, text)
        return true
    }
    mutating func clearInserted(presentationID: UUID, currentID: UUID?) {
        guard currentID == presentationID, draft?.presentationID == presentationID else { return }
        draft = nil
    }
    mutating func reviewOnNextOpen(currentID: UUID?) -> String? {
        defer { draft = nil }
        guard let draft, draft.presentationID == currentID else { return nil }
        return draft.text
    }
}
