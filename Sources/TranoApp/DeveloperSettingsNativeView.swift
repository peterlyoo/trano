import AppKit
import SwiftUI
import TerminalCore

@MainActor final class DeveloperSettingsTextField: NSTextField {
    var editorProvider: (() -> NSTextView?)?
    private var draftEditor: NSTextView? { editorProvider?() ?? currentEditor() as? NSTextView }
    func synchronize(_ value: String) {
        guard draftEditor == nil, stringValue != value else { return }
        stringValue = value
    }
    var committedInput: String? {
        guard draftEditor?.hasMarkedText() != true else { return nil }
        return draftEditor?.string ?? stringValue
    }
    func clearCommittedInput() {
        guard draftEditor?.hasMarkedText() != true else { return }
        if let editor = draftEditor { editor.string = ""; editor.setSelectedRange(NSRange(location: 0, length: 0)) }
        stringValue = ""
    }
}

@MainActor final class DeveloperSettingsNativeView: NSView {
    var onChange: (DeveloperPreferences) -> Void = { _ in }
    var onOriginsChange: ([String]) throws -> Void = { _ in }
    var onChooseSource: () -> Void = {}
    var onRefresh: () -> Void = {}
    private let stack = NSStackView()
    private let options = NSStackView()
    private let originsStack = NSStackView()
    private var controls: [String: NSControl] = [:]
    private var preferences = DeveloperPreferences()
    private var origins: [String] = []
    private var sourceRow: NSView?
    private let errorLabel = NSTextField(labelWithString: "")
    private struct OriginRow {
        let view: NSStackView
        let remove: NSButton
    }
    private var originRows: [String: OriginRow] = [:]
    private var originForButton: [ObjectIdentifier: String] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }

    private func build() {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.detachesHiddenViews = true; stack.translatesAutoresizingMaskIntoConstraints = false
        options.orientation = .vertical; options.alignment = .leading; options.spacing = 10; options.detachesHiddenViews = true
        options.identifier = NSUserInterfaceItemIdentifier("developer.options")
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 4), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)])
        stack.addArrangedSubview(check("Developer Mode", id: "developer.enabled"))
        stack.addArrangedSubview(options)
        options.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        section("Experimental")
        options.addArrangedSubview(check("Download new updates when available", id: "developer.download"))
        options.addArrangedSubview(check("Install updates automatically", id: "developer.install"))
        options.addArrangedSubview(valueLabel("", id: "developer.update.status"))
        row("Terminal anchoring", popup(["Top", "Bottom"], id: "developer.anchoring"))
        row("Cursor shaders", popup(["None", "Warp", "Comet", "Blaze"], id: "developer.effect"))
        options.addArrangedSubview(check("New quick switcher", id: "developer.switcher"))
        options.addArrangedSubview(check("Quick Look links", id: "developer.quicklook"))
        section("App Version")
        row("Update Channel", popup(["Preview", "Bleeding Edge"], id: "developer.channel"))
        section("Trano Installation")
        row("Location", popup(["Bundled server", "Source checkout"], id: "developer.location"))
        let source = NSStackView(views: [valueLabel("", id: "developer.source.path"), button("Choose…", id: "developer.source.choose")])
        source.orientation = .horizontal; source.spacing = 8
        sourceRow = row("Source Directory", source)
        let installation = NSStackView(views: [valueLabel("", id: "developer.installation.status"), button("Refresh", id: "developer.refresh")])
        installation.orientation = .horizontal; installation.spacing = 8
        row("Installation status", installation)
        row("Version", valueLabel("Unavailable", id: "developer.version"))
        row("Commit", copyable(id: "developer.commit"))
        row("Final SHA-256", copyable(id: "developer.hash"))
        section("Local API")
        row("Local API URL", copyable(id: "developer.api.url"))
        section("Web Client Origins")
        originsStack.orientation = .vertical; originsStack.alignment = .leading; originsStack.spacing = 6
        row("Allowed origins", originsStack)
        let pattern = DeveloperSettingsTextField(string: "")
        pattern.identifier = NSUserInterfaceItemIdentifier("developer.origin.pattern")
        pattern.placeholderString = "https://*.example.com"; pattern.font = .systemFont(ofSize: 12)
        controls["developer.origin.pattern"] = pattern
        let add = NSStackView(views: [pattern, button("Add", id: "developer.origin.add")]); add.orientation = .horizontal; add.spacing = 8
        row("Origin pattern", add)
        errorLabel.identifier = NSUserInterfaceItemIdentifier("developer.origin.error")
        errorLabel.textColor = .systemOrange; errorLabel.font = .systemFont(ofSize: 11); errorLabel.isHidden = true
        options.addArrangedSubview(errorLabel)
    }

    func configure(preferences: DeveloperPreferences, readiness: DeveloperUpdateReadiness, metadata: DeveloperInstallationMetadata?, installationStatus: String, localAPIURL: String, origins: [String]) {
        self.preferences = preferences; self.origins = origins
        options.isHidden = !preferences.enabled
        setCheck("developer.enabled", preferences.enabled)
        setCheck("developer.download", preferences.installUpdatesAutomatically || (preferences.downloadUpdatesAutomatically ?? readiness.automaticDownloads))
        setCheck("developer.install", preferences.installUpdatesAutomatically)
        setCheck("developer.switcher", preferences.newQuickSwitcher)
        setCheck("developer.quicklook", preferences.quickLookLinks)
        select("developer.anchoring", preferences.terminalAnchoring == .top ? 0 : 1)
        select("developer.effect", DeveloperCursorEffect.allCases.firstIndex(of: preferences.cursorEffect) ?? 0)
        select("developer.channel", preferences.updateChannel == .preview ? 0 : 1)
        select("developer.location", preferences.installationLocation == .bundled ? 0 : 1)
        for id in ["developer.download", "developer.install", "developer.channel"] { controls[id]?.isEnabled = readiness.available }
        setText("developer.update.status", readiness.reason)
        setText("developer.source.path", preferences.sourceDirectory.isEmpty ? "Not selected" : preferences.sourceDirectory)
        sourceRow?.isHidden = preferences.installationLocation != .sourceCheckout
        setText("developer.installation.status", installationStatus)
        setText("developer.version", metadata?.version ?? "Unavailable")
        setText("developer.commit", metadata?.commit ?? "Unavailable")
        setText("developer.hash", metadata?.finalSHA256 ?? "Unavailable")
        setText("developer.api.url", localAPIURL)
        renderOrigins()
        invalidateIntrinsicContentSize(); needsLayout = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: stack.fittingSize.height + 8) }

    private func check(_ title: String, id: String) -> NSButton {
        let control = NSButton(checkboxWithTitle: title, target: self, action: #selector(changed(_:)))
        control.identifier = NSUserInterfaceItemIdentifier(id); control.font = .systemFont(ofSize: 12)
        controls[id] = control
        return control
    }
    private func button(_ title: String, id: String) -> NSButton {
        let control = NSButton(title: title, target: self, action: #selector(changed(_:)))
        control.identifier = NSUserInterfaceItemIdentifier(id); control.bezelStyle = .rounded; control.controlSize = .small
        control.setContentHuggingPriority(.required, for: .horizontal)
        controls[id] = control
        return control
    }
    private func popup(_ items: [String], id: String) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.addItems(withTitles: items); control.target = self; control.action = #selector(changed(_:)); control.controlSize = .small
        control.identifier = NSUserInterfaceItemIdentifier(id); controls[id] = control
        return control
    }
    private func valueLabel(_ text: String, id: String) -> NSTextField {
        let control = DeveloperSettingsTextField(labelWithString: text)
        control.identifier = NSUserInterfaceItemIdentifier(id); control.font = .systemFont(ofSize: 12)
        control.lineBreakMode = .byTruncatingMiddle; control.isSelectable = true
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls[id] = control
        return control
    }
    private func copyable(id: String) -> NSView {
        let control = valueLabel("Unavailable", id: id)
        let copy = button("Copy", id: id + ".copy")
        let row = NSStackView(views: [control, copy]); row.orientation = .horizontal; row.spacing = 8
        return row
    }
    @discardableResult private func row(_ title: String, _ content: NSView) -> NSView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let row = NSStackView(views: [label, content]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        options.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
        return row
    }
    private func section(_ title: String) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: .semibold)
        options.addArrangedSubview(label)
        options.setCustomSpacing(4, after: label)
    }
    private func setCheck(_ id: String, _ value: Bool) {
        guard let button = controls[id] as? NSButton, button.state != (value ? .on : .off) else { return }
        button.state = value ? .on : .off
    }
    private func select(_ id: String, _ value: Int) {
        guard let popup = controls[id] as? NSPopUpButton, popup.indexOfSelectedItem != value else { return }
        popup.selectItem(at: value)
    }
    private func setText(_ id: String, _ value: String) { (controls[id] as? DeveloperSettingsTextField)?.synchronize(value) }

    private func renderOrigins() {
        let values = Set(origins)
        for value in Array(originRows.keys) where !values.contains(value) {
            guard let row = originRows.removeValue(forKey: value) else { continue }
            originForButton.removeValue(forKey: ObjectIdentifier(row.remove))
            originsStack.removeArrangedSubview(row.view); row.view.removeFromSuperview()
        }
        for (index, origin) in origins.enumerated() {
            let row: OriginRow
            if let existing = originRows[origin] { row = existing }
            else {
                let label = DeveloperSettingsTextField(labelWithString: origin); label.font = .systemFont(ofSize: 11); label.lineBreakMode = .byTruncatingMiddle
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove origin") ?? NSImage(), target: self, action: #selector(removeOrigin(_:)))
                remove.isBordered = false; remove.toolTip = "Remove origin"
                let view = NSStackView(views: [label, remove]); view.orientation = .horizontal; view.spacing = 8
                row = OriginRow(view: view, remove: remove); originRows[origin] = row
                originForButton[ObjectIdentifier(remove)] = origin
            }
            row.remove.identifier = NSUserInterfaceItemIdentifier("developer.origin.remove.\(index)")
            let currentIndex = originsStack.arrangedSubviews.firstIndex(where: { $0 === row.view })
            if currentIndex != index {
                if currentIndex != nil { originsStack.removeArrangedSubview(row.view) }
                originsStack.insertArrangedSubview(row.view, at: min(index, originsStack.arrangedSubviews.count))
            }
        }
    }

    @objc private func removeOrigin(_ sender: NSButton) {
        guard let origin = originForButton[ObjectIdentifier(sender)], let index = origins.firstIndex(of: origin) else { return }
        var next = origins; next.remove(at: index)
        do { try onOriginsChange(next); origins = next; errorLabel.isHidden = true; renderOrigins() }
        catch { errorLabel.stringValue = error.localizedDescription; errorLabel.isHidden = false }
    }

    @objc private func changed(_ sender: NSControl) {
        guard let id = sender.identifier?.rawValue else { return }
        let checked = (sender as? NSButton)?.state == .on
        let selection = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0
        switch id {
        case "developer.enabled": preferences.enabled = checked; options.isHidden = !checked
        case "developer.download": preferences.downloadUpdatesAutomatically = checked; if !checked { preferences.installUpdatesAutomatically = false }
        case "developer.install": preferences.installUpdatesAutomatically = checked; if checked { preferences.downloadUpdatesAutomatically = true }
        case "developer.anchoring": preferences.terminalAnchoring = selection == 0 ? .top : .bottom
        case "developer.effect": preferences.cursorEffect = DeveloperCursorEffect.allCases[max(0, min(selection, DeveloperCursorEffect.allCases.count - 1))]
        case "developer.switcher": preferences.newQuickSwitcher = checked
        case "developer.quicklook": preferences.quickLookLinks = checked
        case "developer.channel": preferences.updateChannel = selection == 0 ? .preview : .bleedingEdge
        case "developer.location": preferences.installationLocation = selection == 0 ? .bundled : .sourceCheckout; sourceRow?.isHidden = selection == 0
        case "developer.source.choose": onChooseSource(); return
        case "developer.refresh": onRefresh(); return
        case "developer.origin.add":
            guard let field = controls["developer.origin.pattern"] as? DeveloperSettingsTextField, let input = field.committedInput else { return }
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            do {
                let next = origins.contains(value) ? origins : origins + [value]
                try onOriginsChange(next); origins = next; field.clearCommittedInput(); errorLabel.isHidden = true; renderOrigins()
            } catch { errorLabel.stringValue = error.localizedDescription; errorLabel.isHidden = false }
            return
        default:
            if id.hasSuffix(".copy"), let field = controls[String(id.dropLast(5))] as? NSTextField {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(field.stringValue, forType: .string)
            }
            return
        }
        invalidateIntrinsicContentSize()
        onChange(preferences)
    }
}

struct DeveloperSettingsSection: NSViewRepresentable {
    @Binding var preferences: DeveloperPreferences
    @Binding var origins: [String]
    let readiness: DeveloperUpdateReadiness
    let metadata: DeveloperInstallationMetadata?
    let installationStatus: String
    let localAPIURL: String
    let validateOrigins: ([String]) throws -> Void
    let chooseSource: () -> Void
    let refresh: () -> Void

    func makeNSView(context: Context) -> DeveloperSettingsNativeView { DeveloperSettingsNativeView(frame: .zero) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DeveloperSettingsNativeView, context: Context) -> CGSize? {
        let width = proposal.width ?? 580
        if nsView.frame.width != width { nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height)) }
        nsView.layoutSubtreeIfNeeded()
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }
    func updateNSView(_ view: DeveloperSettingsNativeView, context: Context) {
        view.onChange = { preferences = $0 }
        view.onOriginsChange = { values in try validateOrigins(values); origins = values }
        view.onChooseSource = chooseSource; view.onRefresh = refresh
        view.configure(preferences: preferences, readiness: readiness, metadata: metadata, installationStatus: installationStatus, localAPIURL: localAPIURL, origins: origins)
    }
}
