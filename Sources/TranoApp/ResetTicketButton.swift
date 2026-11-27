import AppKit
import SwiftUI
import TerminalCore

extension AppStore {
    func availableResetCount(now: Date = Date()) -> Int {
        state.accounts.filter(\.enabled).reduce(0) { total, account in
            guard let snapshot = accountUsageSnapshots.first(where: { $0.accountID == account.id && $0.provider == account.provider }),
                  let count = snapshot.freshAvailableResetCount(now: now) else { return total }
            let sum = total.addingReportingOverflow(count)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }

    func openResetTickets() {
        guard decisionPaneID == nil, followUpPaneID == nil else { return }
        picker = nil
        showActivity = false
        showAccounts = true
    }
}

struct ResetTicketButton: NSViewRepresentable {
    let count: Int
    let action: () -> Void

    func makeNSView(context: Context) -> ResetTicketNativeButton {
        let button = ResetTicketNativeButton()
        button.target = button
        button.action = #selector(ResetTicketNativeButton.invoke(_:))
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "ticket", accessibilityDescription: nil)
        button.symbolConfiguration = WorkspaceToolbarStyle.symbolConfiguration
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .labelColor
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: ResetTicketNativeButton, context: Context) {
        button.identifier = NSUserInterfaceItemIdentifier("reset-ticket-button")
        button.title = String(count)
        button.setAccessibilityLabel("Available resets")
        button.setAccessibilityValue("\(count) available")
        button.toolTip = "\(count) usage limit \(count == 1 ? "reset" : "resets") available"
        button.isEnabled = context.environment.isEnabled
        button.onAction = action
    }
}

final class ResetTicketNativeButton: NSButton {
    var onAction: (() -> Void)?
    @objc func invoke(_ sender: Any?) { onAction?() }
}
