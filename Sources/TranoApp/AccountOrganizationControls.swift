import AppKit
import SwiftUI
import TerminalCore

@MainActor enum AccountOrganizationValidation {
    static func selection(uuid: String, name: String) throws -> ClaudeOrganizationSelection? {
        let uuid = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uuid.isEmpty else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try ClaudeOrganizationSelection(uuid: uuid, name: name.isEmpty ? nil : name)
    }
}

@MainActor final class AccountOrganizationDraft: ObservableObject {
    let profileID: String
    let bindingID: String
    let knownOrganizations: [ClaudeOrganizationSelection]
    @Published var organizationUUID: String
    @Published var organizationName: String
    @Published private(set) var usesManualEntry = false
    @Published private(set) var state: AccountOrganizationState?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSaving = false
    @Published private(set) var isClosed = false
    @Published private(set) var errorMessage: String?
    private let isCurrent: @MainActor (String, String) -> Bool
    private let refreshOrganization: @MainActor (String, String) async throws -> AccountOrganizationState?
    private let saveOrganization: @MainActor (String, String, ClaudeOrganizationSelection?) async throws -> Void
    private let onCancel: @MainActor () -> Void
    private var revision = 0
    private var retired = false
    private var refreshTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(profileID: String, state: AccountOrganizationState?, knownOrganizations: [ClaudeOrganizationSelection],
         isCurrent: @escaping @MainActor (String, String) -> Bool = { _, _ in true },
         refresh: @escaping @MainActor (String, String) async throws -> AccountOrganizationState?,
         save: @escaping @MainActor (String, String, ClaudeOrganizationSelection?) async throws -> Void,
         cancel: @escaping @MainActor () -> Void = {}) {
        self.profileID = profileID
        self.bindingID = state?.bindingID ?? ""
        self.state = state
        self.organizationUUID = state?.selection?.uuid ?? ""
        self.organizationName = state?.selection?.name ?? ""
        var seen: Set<String> = []
        self.knownOrganizations = (knownOrganizations + [state?.selection].compactMap { $0 })
            .filter { seen.insert($0.uuid).inserted }
        self.isCurrent = isCurrent
        self.refreshOrganization = refresh
        self.saveOrganization = save
        self.onCancel = cancel
    }

    func choose(_ selection: ClaudeOrganizationSelection?) {
        guard !retired, !isSaving, !isClosed else { return }
        organizationUUID = selection?.uuid ?? ""
        organizationName = selection?.name ?? ""
        usesManualEntry = false
        errorMessage = nil
    }

    func chooseOther() {
        guard !retired, !isSaving, !isClosed else { return }
        usesManualEntry = true
        errorMessage = nil
    }

    func refresh() {
        guard !retired, !isRefreshing, !isSaving, !isClosed, isCurrent(profileID, bindingID) else { return }
        revision += 1
        let request = revision
        let profileID = profileID, bindingID = bindingID, refresh = refreshOrganization
        isRefreshing = true
        errorMessage = nil
        refreshTask = Task { [weak self] in
            do {
                let state = try await refresh(profileID, bindingID)
                guard let self, self.revision == request, !self.isClosed else { return }
                self.isRefreshing = false
                self.refreshTask = nil
                guard self.isCurrent(profileID, bindingID), state?.bindingID ?? "" == bindingID else { return }
                self.state = state
            } catch {
                guard let self, self.revision == request, !self.isClosed else { return }
                self.isRefreshing = false
                self.refreshTask = nil
                if self.isCurrent(profileID, bindingID) { self.errorMessage = "Organization refresh failed." }
            }
        }
    }

    func save() {
        guard !retired, !isSaving, !isClosed else { return }
        guard isCurrent(profileID, bindingID) else {
            errorMessage = "The account changed. Reopen its organization settings."
            return
        }
        let selection: ClaudeOrganizationSelection?
        do {
            selection = try AccountOrganizationValidation.selection(uuid: organizationUUID, name: organizationName)
            if usesManualEntry && selection == nil { throw CocoaError(.validationMissingMandatoryProperty) }
        } catch {
            errorMessage = "Enter a valid organization UUID."
            return
        }
        revision += 1
        let request = revision
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        isSaving = true
        errorMessage = nil
        let profileID = profileID, bindingID = bindingID, save = saveOrganization
        saveTask = Task { [weak self] in
            do {
                guard let owner = self, owner.revision == request, !owner.isClosed,
                      owner.isCurrent(profileID, bindingID) else {
                    self?.isSaving = false
                    return
                }
                try await save(profileID, bindingID, selection)
                guard let self, self.revision == request, !self.isClosed else { return }
                self.isSaving = false
                self.isClosed = true
                self.saveTask = nil
            } catch {
                guard let self, self.revision == request, !self.isClosed else { return }
                self.isSaving = false
                self.saveTask = nil
                self.errorMessage = "Organization could not be saved."
            }
        }
    }

    func cancel() {
        guard !retired, !isSaving, !isClosed else { return }
        invalidate()
        onCancel()
    }

    var acceptsCancellation: Bool { !retired && !isSaving && !isClosed }

    func invalidate() { retire(); publishRetirement() }

    func invalidateForTeardown() {
        retire()
        let request = revision
        // SwiftUI may destroy this view while its observation graph is already invalidating.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == request else { return }
            self.publishRetirement()
        }
    }
    private func retire() {
        retired = true
        revision += 1
        refreshTask?.cancel(); saveTask?.cancel()
        refreshTask = nil; saveTask = nil
    }
    private func publishRetirement() {
        if isRefreshing { isRefreshing = false }
        if isSaving { isSaving = false }
        if !isClosed { isClosed = true }
    }
}

@MainActor final class AccountOrganizationControlsView: NSView, NSTextFieldDelegate {
    let organizationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let uuidField = NSTextField()
    let nameField = NSTextField()
    let configuredLabel = NSTextField(wrappingLabelWithString: "")
    let observedLabel = NSTextField(wrappingLabelWithString: "")
    let verificationLabel = NSTextField(labelWithString: "")
    let manualFields = NSStackView()
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var draft: AccountOrganizationDraft
    func apply(theme: ToolPanelTheme) {
        appearance = theme.appearance
        func paint(_ view: NSView) {
            if let field = view as? NSTextField {
                field.textColor = field === errorLabel ? .systemOrange : theme.foregroundNS
                if field.font?.pointSize != ToolPanelMetrics.bodySize { field.font = .systemFont(ofSize: ToolPanelMetrics.bodySize) }
                if let editor = field.currentEditor() as? NSTextView {
                    editor.textColor = theme.foregroundNS; editor.insertionPointColor = theme.foregroundNS
                }
            }
            for child in view.subviews { paint(child) }
        }
        paint(self)
        for field in [configuredLabel, observedLabel, verificationLabel] { field.textColor = theme.secondaryNS }
        for control in [organizationPopUp, refreshButton, cancelButton, saveButton] as [NSControl] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: ToolPanelMetrics.captionSize)
        }
    }

    init(draft: AccountOrganizationDraft) {
        self.draft = draft
        super.init(frame: .zero)
        let selectionRow = NSStackView(views: [NSTextField(labelWithString: "Organization"), organizationPopUp])
        selectionRow.spacing = 12
        organizationPopUp.setAccessibilityLabel("Organization")
        organizationPopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        organizationPopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        organizationPopUp.target = self
        organizationPopUp.action = #selector(chooseOrganization(_:))
        for field in [uuidField, nameField] {
            field.delegate = self
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        uuidField.placeholderString = "Organization UUID"
        uuidField.setAccessibilityLabel("Organization UUID")
        nameField.placeholderString = "Name (optional)"
        nameField.setAccessibilityLabel("Organization name")
        manualFields.orientation = .vertical
        manualFields.alignment = .leading
        manualFields.spacing = 6
        manualFields.addArrangedSubview(uuidField)
        manualFields.addArrangedSubview(nameField)
        uuidField.widthAnchor.constraint(equalTo: manualFields.widthAnchor).isActive = true
        nameField.widthAnchor.constraint(equalTo: manualFields.widthAnchor).isActive = true
        let status = NSGridView(views: [
            [NSTextField(labelWithString: "Configured"), configuredLabel],
            [NSTextField(labelWithString: "Observed"), observedLabel],
            [NSTextField(labelWithString: "Status"), verificationLabel]
        ])
        status.columnSpacing = 12
        status.rowSpacing = 6
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshOrganization(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelEditing(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveEditing(_:))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [refreshButton, spinner, NSView(), cancelButton, saveButton])
        buttons.spacing = 8
        errorLabel.textColor = .systemRed
        let stack = NSStackView(views: [selectionRow, manualFields, status, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for row in [selectionRow, manualFields, status, errorLabel, buttons] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)
        ])
        rebuildChoices()
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 460, height: draft.usesManualEntry ? 290 : 228) }

    func configure(draft: AccountOrganizationDraft) {
        if self.draft !== draft {
            self.draft.invalidate()
            self.draft = draft
            rebuildChoices()
        }
        render()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              !draft.isSaving, !draft.isClosed else { return }
        if field === uuidField { draft.organizationUUID = field.stringValue }
        if field === nameField { draft.organizationName = field.stringValue }
    }

    private func rebuildChoices() {
        organizationPopUp.removeAllItems()
        func append(_ title: String, id: String) {
            organizationPopUp.addItem(withTitle: title)
            organizationPopUp.lastItem?.representedObject = id
        }
        append("Unbound", id: "unbound")
        for organization in draft.knownOrganizations {
            append(Self.summary(organization), id: organization.uuid)
        }
        append("Other UUID…", id: "other")
    }

    private func selectDraftOrganization() {
        let selected = draft.usesManualEntry ? "other" : draft.organizationUUID.isEmpty ? "unbound" : draft.organizationUUID
        organizationPopUp.select(organizationPopUp.itemArray.first { $0.representedObject as? String == selected })
    }

    private func render() {
        selectDraftOrganization()
        manualFields.isHidden = !draft.usesManualEntry
        for (field, value) in [(uuidField, draft.organizationUUID), (nameField, draft.organizationName)] {
            if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != value { field.stringValue = value }
        }
        configuredLabel.stringValue = Self.summary(draft.state?.selection)
        observedLabel.stringValue = draft.state?.observed.map(Self.summary) ?? "Not observed"
        let status: String
        switch draft.state?.verification ?? .unbound {
        case .unbound: status = "Unbound"
        case .unverified: status = "Unverified"
        case .verified: status = "Verified"
        case .mismatch: status = "Mismatch"
        case .missing: status = "Missing organization"
        case .unavailable: status = "Unavailable"
        }
        verificationLabel.stringValue = status + (draft.state?.checkedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
        let editable = !draft.isSaving && !draft.isClosed
        for control in [organizationPopUp, uuidField, nameField, saveButton] as [NSControl] { control.isEnabled = editable }
        refreshButton.isEnabled = editable && !draft.isRefreshing
        cancelButton.isEnabled = editable
        saveButton.title = draft.isSaving ? "Saving…" : "Save"
        spinner.isHidden = !draft.isRefreshing && !draft.isSaving
        if spinner.isHidden { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        errorLabel.stringValue = draft.errorMessage ?? ""
        errorLabel.isHidden = draft.errorMessage == nil
        invalidateIntrinsicContentSize()
    }

    private static func summary(_ organization: ClaudeOrganizationSelection?) -> String {
        guard let organization else { return "Unbound" }
        return organization.name.map { $0 + " · " + organization.uuid } ?? organization.uuid
    }

    private var hasMarkedText: Bool {
        if (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return true }
        return [uuidField, nameField].contains { ($0.currentEditor() as? NSTextInputClient)?.hasMarkedText() == true }
    }

    @objc private func chooseOrganization(_ sender: NSPopUpButton) {
        guard !hasMarkedText else { selectDraftOrganization(); return }
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        if id == "other" { draft.chooseOther() }
        else { draft.choose(draft.knownOrganizations.first { $0.uuid == id }) }
        render()
    }
    @objc private func refreshOrganization(_ sender: NSButton) {
        guard !hasMarkedText else { return }
        draft.refresh(); render()
    }
    var canCancel: Bool { draft.acceptsCancellation && !hasMarkedText }

    @objc private func cancelEditing(_ sender: NSButton) {
        guard canCancel else { return }
        draft.cancel(); render()
    }
    @objc private func saveEditing(_ sender: NSButton) {
        guard !hasMarkedText else { return }
        draft.save(); render()
    }
}

@MainActor final class AccountOrganizationCancellation: ObservableObject {
    weak var controls: AccountOrganizationControlsView?
    var canCancel: Bool { controls?.window != nil && controls?.canCancel == true }
    func cancel() { if canCancel { controls?.cancelButton.performClick(nil) } }
}

struct OrganizationSelectionControls: NSViewRepresentable {
    @ObservedObject var draft: AccountOrganizationDraft
    var cancellation: AccountOrganizationCancellation? = nil
    var theme: ToolPanelTheme = .defaultDark
    func makeNSView(context: Context) -> AccountOrganizationControlsView {
        let view = AccountOrganizationControlsView(draft: draft)
        view.apply(theme: theme)
        cancellation?.controls = view
        return view
    }
    func updateNSView(_ view: AccountOrganizationControlsView, context: Context) { view.apply(theme: theme); view.configure(draft: draft); cancellation?.controls = view }
    static func dismantleNSView(_ view: AccountOrganizationControlsView, coordinator: ()) { view.draft.invalidateForTeardown() }
}
