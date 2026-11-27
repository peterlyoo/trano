import Foundation

public struct TwinSourceExpectation: Equatable, Sendable {
    public let generation: String
    public let conversationID: String
    public let cwd: String
    public init(generation: String, conversationID: String, cwd: String) {
        self.generation = generation; self.conversationID = conversationID; self.cwd = cwd
    }
    public func matches(_ source: TwinSourceBinding) -> Bool {
        generation == source.generation && conversationID == source.conversationID && cwd == source.cwd
    }
}
