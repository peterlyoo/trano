import AppKit
import SwiftUI

enum WorkspaceToolbarStyle {
    static let pointSize: CGFloat = 14
    static let buttonSize: CGFloat = 24
    static let symbolSize: CGFloat = 18
    static var symbolConfiguration: NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
    }
}

struct WorkspaceToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: WorkspaceToolbarStyle.pointSize, weight: .regular))
            .imageScale(.medium)
            .symbolRenderingMode(.monochrome)
            .frame(width: WorkspaceToolbarStyle.buttonSize, height: WorkspaceToolbarStyle.buttonSize)
    }
}

struct DecisionCountIcon: NSViewRepresentable {
    let count: Int

    func makeNSView(context: Context) -> DecisionCountIconView { DecisionCountIconView() }
    func updateNSView(_ view: DecisionCountIconView, context: Context) {
        view.count.stringValue = String(count)
        view.needsLayout = true
        let theme = context.environment.toolPanelTheme
        view.appearance = theme.appearance
        view.outline.contentTintColor = theme.foregroundNS; view.count.textColor = theme.foregroundNS
    }
}

final class DecisionCountIconView: NSView {
    let outline = NSImageView()
    let count = NSTextField(labelWithString: "0")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("decision-count-icon")
        outline.image = NSImage(systemSymbolName: "bubble", accessibilityDescription: nil)
        outline.symbolConfiguration = WorkspaceToolbarStyle.symbolConfiguration
        outline.imageScaling = .scaleProportionallyDown
        outline.contentTintColor = .labelColor
        outline.setAccessibilityElement(false)
        count.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        count.textColor = .labelColor
        count.alignment = .center
        count.lineBreakMode = .byClipping
        count.setAccessibilityElement(false)
        addSubview(outline)
        addSubview(count)
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: WorkspaceToolbarStyle.buttonSize, height: WorkspaceToolbarStyle.buttonSize)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let size = WorkspaceToolbarStyle.symbolSize
        outline.frame = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        let width = size - 5
        count.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        var pointSize: CGFloat = 8
        while count.attributedStringValue.size().width > width - 4, pointSize > 1 {
            pointSize -= 0.25
            count.font = .monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)
        }
        count.frame = NSRect(x: bounds.midX - width / 2, y: bounds.midY - 5, width: width, height: 11)
    }
}

struct QueuedInputButton: NSViewRepresentable {
    let paneID: String
    let count: Int
    let shortcut: String
    let selected: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> QueuedInputNativeButton {
        let button = QueuedInputNativeButton()
        button.target = button
        button.action = #selector(QueuedInputNativeButton.invoke(_:))
        button.isBordered = false
        button.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        button.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        button.imageScaling = .scaleProportionallyDown
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: QueuedInputNativeButton, context: Context) {
        button.identifier = NSUserInterfaceItemIdentifier("queued-input-button-" + paneID)
        button.title = count == 0 ? "" : String(count)
        button.imagePosition = count == 0 ? .imageOnly : .imageLeading
        button.contentTintColor = selected ? NSColor(red: 133/255, green: 215/255, blue: 193/255, alpha: 1) : .secondaryLabelColor
        button.toolTip = "Queued Input" + (shortcut.isEmpty ? "" : " · " + shortcut)
        button.setAccessibilityLabel("Queued Input")
        button.setAccessibilityValue("\(count) queued")
        button.onAction = action
    }
}

final class QueuedInputNativeButton: NSButton {
    var onAction: (() -> Void)?
    @objc func invoke(_ sender: Any?) { onAction?() }
}

struct WorkspaceCloseButton: NSViewRepresentable {
    let id: String
    let workspaceTitle: String
    let action: () -> Void

    func makeNSView(context: Context) -> WorkspaceCloseNativeButton {
        let button = WorkspaceCloseNativeButton()
        button.target = button
        button.action = #selector(WorkspaceCloseNativeButton.closeWorkspace(_:))
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: WorkspaceCloseNativeButton, context: Context) {
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityLabel("Close Workspace")
        button.setAccessibilityValue(workspaceTitle)
        button.toolTip = "Close " + workspaceTitle
        button.isEnabled = context.environment.isEnabled
        button.onClose = action
    }
}

final class WorkspaceCloseNativeButton: NSButton {
    var onClose: (() -> Void)?
    @objc func closeWorkspace(_ sender: Any?) { onClose?() }
}
