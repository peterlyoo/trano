import AppKit
import TerminalCore

@MainActor struct QuickLookHoverPane {
    let paneID: String
    let cwd: URL
    let isRemote: Bool
    let ownerID: ObjectIdentifier
    let visible: Bool
    let pointInView: (NSPoint) -> NSPoint
    let containsPoint: (NSPoint) -> Bool
    let hoveredLink: (NSPoint) -> String?
    let selectedText: () -> String?
}

struct QuickLookHoverResult: Equatable {
    let paneID: String
    let cwd: URL
    let target: QuickLookLinkTarget
}

@MainActor enum QuickLookHoverHost {
    @discardableResult static func handle(preferences: DeveloperPreferences, ownerID: ObjectIdentifier,
        ownerIsRegistered: Bool, firstResponderPaneID: String?, focusedPaneID: String?,
        hasMarkedText: Bool, hasModal: Bool, inputBusy: Bool, configuredSingleAction: ActionID? = nil, pointerInOwner: NSPoint?,
        panes: [QuickLookHoverPane], deliver: (QuickLookHoverResult) -> Void) -> Bool {
        guard ownerIsRegistered, configuredSingleAction == nil,
              DeveloperActionPolicy.mayPreviewLink(preferences: preferences, hasMarkedText: hasMarkedText, hasModal: hasModal, inputBusy: inputBusy),
              let focusedPaneID, firstResponderPaneID == focusedPaneID else { return false }
        let eligible = panes.filter { $0.ownerID == ownerID && $0.visible }
        guard Set(eligible.map(\.paneID)).count == eligible.count,
              let focused = eligible.first(where: { $0.paneID == focusedPaneID }) else { return false }
        if let pointerInOwner, pointerInOwner.x.isFinite, pointerInOwner.y.isFinite {
            for pane in eligible {
                let point = pane.pointInView(pointerInOwner)
                guard point.x.isFinite, point.y.isFinite, pane.containsPoint(point),
                      let link = pane.hoveredLink(point), let result = resolve(link, in: pane) else { continue }
                deliver(result); return true
            }
        }
        guard let text = focused.selectedText(), let result = resolve(text, in: focused) else { return false }
        deliver(result); return true
    }

    private static func resolve(_ text: String, in pane: QuickLookHoverPane) -> QuickLookHoverResult? {
        if pane.isRemote {
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 16_384 else { return nil }
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            // Remote paths must never be resolved against this Mac's filesystem.
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        }
        guard let target = QuickLookLinkTarget.parse(text, cwd: pane.cwd) else { return nil }
        return QuickLookHoverResult(paneID: pane.paneID, cwd: pane.cwd, target: target)
    }
}
