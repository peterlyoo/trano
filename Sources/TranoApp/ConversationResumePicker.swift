import AppKit
import Combine
import SwiftUI
import TerminalCore

enum ConversationResumeProvider: Int, CaseIterable { case all, claude, codex }

@MainActor final class ConversationResumeModel: ObservableObject {
    typealias LoadCompletion = @MainActor (Result<ConversationHistorySnapshot, Error>) -> Void
    typealias Loader = (@escaping LoadCompletion) -> Void
    @Published private(set) var conversations: [AgentConversation] = []
    @Published private(set) var query = ""
    @Published private(set) var provider = ConversationResumeProvider.all
    @Published private(set) var selectedID: String?
    @Published private(set) var loading = false
    @Published private(set) var resuming = false
    @Published private(set) var error: String?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var truncated = false
    let livePaneIDs: () -> [String: String]
    let canInteract: () -> Bool
    private let load: Loader
    private let onActivate: (AgentConversation) -> Void
    private let hasMarkedText: () -> Bool
    private var loadGeneration: UInt64 = 0
    var nativeMarkedText: () -> Bool = { false }
    init(load: @escaping Loader, onActivate: @escaping (AgentConversation) -> Void,
         livePaneIDs: @escaping () -> [String: String] = { [:] }, canInteract: @escaping () -> Bool = { true },
         hasMarkedText: @escaping () -> Bool = { false }) {
        self.load = load; self.onActivate = onActivate; self.livePaneIDs = livePaneIDs
        self.canInteract = canInteract; self.hasMarkedText = hasMarkedText
    }
    var filteredConversations: [AgentConversation] {
        conversations.filter { entry in
            let matchesProvider = provider == .all || (provider == .claude && entry.source.provider == .claude)
                || (provider == .codex && entry.source.provider == .codex)
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesProvider && (text.isEmpty || [entry.title, entry.cwd, entry.source.label,
                entry.source.accountID ?? "", entry.providerSessionID, entry.id].contains { $0.localizedStandardContains(text) })
        }
    }
    var selected: AgentConversation? { filteredConversations.first { $0.id == selectedID } }
    var permitsInteraction: Bool { canInteract() && !hasMarkedText() && !nativeMarkedText() }
    var canSubmit: Bool {
        guard !loading, !resuming, permitsInteraction, let selected else { return false }
        return selected.source.enabled || livePaneIDs()[selected.id] != nil
    }
    @discardableResult func refresh() -> Bool {
        guard !loading, !resuming, permitsInteraction else { return false }
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true; error = nil
        load { [weak self] result in
            guard let self, self.loading, self.loadGeneration == generation else { return }
            switch result {
            case .success(let snapshot):
                self.conversations = snapshot.conversations.sorted {
                    $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
                }
                self.warnings = snapshot.warnings; self.truncated = snapshot.truncated
                self.reconcileSelection()
            case .failure(let error): self.error = error.localizedDescription
            }
            self.loading = false
        }
        return true
    }
    @discardableResult func setQuery(_ value: String) -> Bool {
        guard !resuming, permitsInteraction else { return false }
        query = value; reconcileSelection(); return true
    }
    @discardableResult func setProvider(_ value: ConversationResumeProvider) -> Bool {
        guard !resuming, permitsInteraction else { return false }
        provider = value; reconcileSelection(); return true
    }
    @discardableResult func choose(id: String) -> Bool {
        guard !loading, !resuming, permitsInteraction, filteredConversations.contains(where: { $0.id == id }) else { return false }
        if selectedID != id { selectedID = id; error = nil }
        return true
    }
    @discardableResult func move(_ delta: Int) -> Bool {
        guard !loading, !resuming, permitsInteraction else { return false }
        let rows = filteredConversations
        guard !rows.isEmpty else { return false }
        let current = rows.firstIndex { $0.id == selectedID } ?? 0
        let next = delta > 0 ? min(rows.count - 1, current + min(delta, rows.count)) : max(0, current + max(delta, -rows.count))
        return choose(id: rows[next].id)
    }
    @discardableResult func submit() -> Bool {
        guard canSubmit, let entry = selected else { return false }
        resuming = true; error = nil
        onActivate(entry)
        return true
    }
    @discardableResult func finishActivation(error: Error?) -> Bool {
        guard resuming else { return false }
        resuming = false; self.error = error?.localizedDescription
        return error == nil
    }
    @discardableResult func dismiss() -> Bool {
        guard !resuming, permitsInteraction else { return false }
        loadGeneration &+= 1; loading = false
        return true
    }
    private func reconcileSelection() {
        let rows = filteredConversations
        if let selectedID, rows.contains(where: { $0.id == selectedID }) { return }
        selectedID = rows.first?.id
    }
}

struct ConversationResumeOverlay: View {
    @ObservedObject var model: ConversationResumeModel
    let onDismiss: () -> Void
    @Environment(\.toolPanelTheme) private var theme
    static func panelSize(in parent: CGSize) -> CGSize {
        CGSize(width: min(560, max(0, parent.width - 24)), height: min(540, max(0, parent.height - 24)))
    }
    var body: some View {
        GeometryReader { geometry in
            let size = Self.panelSize(in: geometry.size)
            ZStack(alignment: .topTrailing) {
                ConversationResumeBackdrop(model: model, onDismiss: onDismiss)
                ConversationResumeSurface(model: model, theme: theme, onDismiss: onDismiss)
                    .frame(width: size.width, height: size.height)
                    .dismissOnOutsideClick("conversation-resume", canDismiss: { !model.resuming && model.permitsInteraction }, perform: onDismiss)
                    .toolPanelSurface(theme)
                    .padding(12)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.clipped().accessibilityIdentifier("conversation-resume-overlay")
    }
}

private struct ConversationResumeSurface: NSViewRepresentable {
    @ObservedObject var model: ConversationResumeModel
    let theme: ToolPanelTheme
    let onDismiss: () -> Void
    func makeNSView(context: Context) -> ConversationResumeNativeView { ConversationResumeNativeView(model: model, onDismiss: onDismiss, theme: theme) }
    func updateNSView(_ view: ConversationResumeNativeView, context: Context) { view.configure(model: model, onDismiss: onDismiss, theme: theme) }
}

final class ConversationResumeNativeView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let searchField = PickerSearchTextField(frame: .zero)
    let table = ConversationResumeTable(frame: .zero)
    let providers = ConversationResumeSegments(frame: .zero)
    var editorProvider: (() -> NSTextView?)?
    private(set) var model: ConversationResumeModel
    private(set) var theme: ToolPanelTheme
    let header = NSView()
    private let headerSeparator = NSView()
    private var onDismiss: () -> Void
    private let scroll = NSScrollView()
    private let heading = NSTextField(labelWithString: "Resume")
    private let history = NSImageView(image: NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil) ?? NSImage())
    private let close = ConversationResumeButton(frame: .zero)
    private let reload = ConversationResumeButton(frame: .zero)
    private let spinner = NSProgressIndicator()
    private let searchIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
    private let empty = NSTextField(labelWithString: "No conversations yet")
    private let failure = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private var rows: [AgentConversation] = []
    private var live: [String: String] = [:]
    private var observation: AnyCancellable?
    private var scheduled = false
    private var updating = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { true }
    private var composing: Bool {
        (editorProvider?() ?? searchField.currentEditor() as? NSTextView)?.hasMarkedText() == true
            || (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }
    init(model: ConversationResumeModel, onDismiss: @escaping () -> Void, theme: ToolPanelTheme = .defaultDark) {
        self.model = model; self.onDismiss = onDismiss; self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = ToolPanelMetrics.cornerRadius; layer?.masksToBounds = true
        header.identifier = NSUserInterfaceItemIdentifier("tool-panel-header")
        header.wantsLayer = true; headerSeparator.wantsLayer = true
        heading.font = .systemFont(ofSize: ToolPanelMetrics.titleSize, weight: .semibold)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Resume")
        close.image = close.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        close.isBordered = false; close.toolTip = "Close Resume"; close.setAccessibilityLabel("Close Resume")
        close.handler = { [weak self] in self?.dismiss() }
        reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh conversations")
        reload.isBordered = false; reload.toolTip = "Refresh conversations"
        reload.handler = { [weak self] in _ = self?.model.refresh() }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        searchField.delegate = self; searchField.isBordered = false; searchField.isBezeled = false
        searchField.drawsBackground = false; searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: ToolPanelMetrics.bodySize)
        searchField.placeholderString = "Search title, project, account or ID"
        searchField.usesSingleLineMode = true; searchField.cell?.isScrollable = true
        searchField.setAccessibilityLabel("Search conversations")
        searchField.onTextChange = { [weak self] in _ = self?.model.setQuery($0) }
        searchField.onMove = { [weak self] in _ = self?.model.move($0) }
        searchField.onSubmit = { [weak self] in _ = self?.model.submit() }
        searchField.onCancel = { [weak self] in self?.dismiss() }
        providers.segmentCount = 3; providers.segmentStyle = .rounded; providers.font = .systemFont(ofSize: ToolPanelMetrics.bodySize)
        for (index, title) in ["All", "Claude", "Codex"].enumerated() { providers.setLabel(title, forSegment: index); providers.setWidth(index == 0 ? 60 : 90, forSegment: index) }
        providers.setImage(ConversationResumeArtwork.image(.claude), forSegment: 1)
        providers.setImage(ConversationResumeArtwork.image(.codex), forSegment: 2)
        providers.handler = { [weak self] in
            guard let self, let value = ConversationResumeProvider(rawValue: self.providers.selectedSegment) else { return }
            _ = self.model.setProvider(value); self.refresh()
        }
        let column = NSTableColumn(identifier: .init("conversation")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 64
        table.intercellSpacing = .zero; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false
        table.target = self; table.doubleAction = #selector(submitSelected)
        table.gate = { [weak self] in self?.model.permitsInteraction == true && self?.model.loading == false && self?.model.resuming == false }
        scroll.documentView = table; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        empty.font = .systemFont(ofSize: ToolPanelMetrics.bodySize); empty.alignment = .center
        failure.font = .systemFont(ofSize: ToolPanelMetrics.captionSize); failure.textColor = .systemOrange; failure.maximumNumberOfLines = 2
        footer.font = .systemFont(ofSize: ToolPanelMetrics.captionSize)
        for view in [history, heading, close, reload, spinner, headerSeparator] { header.addSubview(view) }
        for view in [header, searchIcon, searchField, providers, scroll, empty, failure, footer] { addSubview(view) }
        setAccessibilityIdentifier("conversation-resume-panel")
        configure(model: model, onDismiss: onDismiss, theme: theme)
    }
    required init?(coder: NSCoder) { nil }
    func configure(model: ConversationResumeModel, onDismiss: @escaping () -> Void, theme: ToolPanelTheme? = nil) {
        apply(theme: theme ?? self.theme)
        if self.model !== model { self.model.nativeMarkedText = { false }; self.model = model; observation = nil }
        self.onDismiss = onDismiss
        model.nativeMarkedText = { [weak self] in self?.composing ?? false }
        if observation == nil { observation = model.objectWillChange.sink { [weak self] in self?.scheduleRefresh() } }
        refresh()
    }
    func apply(theme: ToolPanelTheme) {
        self.theme = theme; appearance = theme.appearance
        layer?.backgroundColor = theme.backgroundNS.cgColor
        header.layer?.backgroundColor = theme.backgroundNS.cgColor; headerSeparator.layer?.backgroundColor = theme.borderNS.cgColor
        heading.textColor = theme.foregroundNS
        history.contentTintColor = theme.accentNS
        close.contentTintColor = theme.foregroundNS; reload.contentTintColor = theme.secondaryNS
        searchIcon.contentTintColor = theme.secondaryNS
        searchField.apply(theme: theme)
        providers.selectedSegmentBezelColor = theme.accentNS
        table.backgroundColor = theme.backgroundNS; scroll.backgroundColor = theme.backgroundNS
        scroll.contentView.backgroundColor = theme.backgroundNS
        empty.textColor = theme.secondaryNS; footer.textColor = theme.secondaryNS
        for index in 0..<rows.count {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ConversationResumeCell)?.apply(theme: theme)
            (table.rowView(atRow: index, makeIfNecessary: false) as? ConversationResumeSelectionRow)?.theme = theme
        }
        needsDisplay = true
    }
    private func scheduleRefresh() {
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in self?.scheduled = false; self?.refresh() }
    }
    func refresh() {
        updating = true; defer { updating = false }
        if !composing, Data(searchField.stringValue.utf8) != Data(model.query.utf8) { searchField.stringValue = model.query }
        searchField.isEnabled = !model.resuming
        providers.selectedSegment = model.provider.rawValue; providers.isEnabled = !model.resuming && model.permitsInteraction
        close.isEnabled = !model.resuming; reload.isEnabled = !model.loading && !model.resuming && model.permitsInteraction
        if model.loading || model.resuming { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        live = model.livePaneIDs()
        let next = model.filteredConversations
        if next != rows { rows = next; table.reloadData() }
        table.isEnabled = !model.loading && !model.resuming
        if let index = rows.firstIndex(where: { $0.id == model.selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index)
        } else { table.deselectAll(nil) }
        for index in 0..<rows.count {
            if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ConversationResumeCell { configure(cell, row: index) }
        }
        empty.isHidden = !rows.isEmpty
        empty.stringValue = model.loading ? "Loading conversations…" : model.error != nil ? "Couldn't load conversations" : model.conversations.isEmpty ? "No conversations yet" : "No matching conversations"
        failure.stringValue = model.error ?? ""; failure.toolTip = model.error; failure.isHidden = model.error == nil
        footer.stringValue = "\(rows.count) conversations" + (model.truncated ? " · recent history" : "") + (model.warnings.isEmpty ? "" : " · Some history couldn't be read")
        footer.toolTip = model.warnings.joined(separator: "\n")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let inset = ToolPanelMetrics.contentInset, headerHeight = ToolPanelMetrics.headerHeight
        let control = ToolPanelMetrics.closeControlSize, controlY = (headerHeight - control) / 2
        header.frame = NSRect(x: 0, y: 0, width: width, height: min(headerHeight, height))
        headerSeparator.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        history.frame = NSRect(x: inset, y: (headerHeight - 16) / 2, width: 16, height: 16)
        heading.frame = NSRect(x: inset + 24, y: (headerHeight - 20) / 2, width: max(0, width - inset * 2 - 112), height: 20)
        close.frame = NSRect(x: max(0, width - inset - control), y: controlY, width: control, height: control)
        reload.frame = NSRect(x: max(0, close.frame.minX - control - 4), y: controlY, width: control, height: control)
        spinner.frame = NSRect(x: max(0, reload.frame.minX - 22), y: (headerHeight - 14) / 2, width: 14, height: 14)
        let searchY = headerHeight + inset
        searchIcon.frame = NSRect(x: inset, y: searchY + 5, width: 14, height: 14)
        searchField.frame = NSRect(x: inset + 22, y: searchY, width: max(0, width - inset * 2 - 22), height: control)
        let providersY = searchY + control + ToolPanelMetrics.sectionSpacing
        providers.frame = NSRect(x: inset, y: providersY, width: min(260, max(0, width - inset * 2)), height: control)
        let listY = providersY + control + ToolPanelMetrics.sectionSpacing
        let errorHeight: CGFloat = failure.isHidden ? 0 : 40
        let footerY = max(0, height - inset - 18)
        let bottom = max(0, footerY - ToolPanelMetrics.sectionSpacing)
        scroll.frame = NSRect(x: inset, y: listY, width: max(0, width - inset * 2), height: max(0, bottom - listY - errorHeight))
        if let column = table.tableColumns.first { column.width = max(0, scroll.contentSize.width) }
        empty.frame = NSRect(x: inset, y: listY + max(0, scroll.frame.height / 2 - 13), width: max(0, width - inset * 2), height: 26)
        failure.frame = NSRect(x: inset, y: max(listY, bottom - errorHeight), width: max(0, width - inset * 2), height: errorHeight)
        footer.frame = NSRect(x: inset, y: footerY, width: max(0, width - inset * 2), height: 18)
    }
    override func draw(_ dirtyRect: NSRect) { theme.backgroundNS.setFill(); dirtyRect.fill() }
    func controlTextDidChange(_ notification: Notification) {
        guard !composing else { return }; searchField.controlTextDidChange(notification)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        searchField.control(control, textView: textView, doCommandBy: selector)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("resume-row"), owner: self) as? ConversationResumeCell ?? ConversationResumeCell(frame: .zero)
        cell.identifier = .init("resume-row"); configure(cell, row: row); return cell
    }
    private func configure(_ cell: ConversationResumeCell, row: Int) {
        guard rows.indices.contains(row) else { return }
        let entry = rows[row]
        cell.configure(entry, live: live[entry.id] != nil, enabled: !model.loading && !model.resuming && (entry.source.enabled || live[entry.id] != nil), theme: theme) { [weak self] in
            guard let self, self.model.choose(id: entry.id) else { return }; _ = self.model.submit()
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, rows.indices.contains(table.selectedRow) else { return }
        _ = model.choose(id: rows[table.selectedRow].id); refresh()
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ConversationResumeSelectionRow(); view.theme = theme; return view
    }
    @objc private func submitSelected() { _ = model.submit() }
    private func dismiss() { if model.dismiss() { onDismiss() } }
}

final class ConversationResumeButton: NSButton {
    var handler: () -> Void = {}
    override var acceptsFirstResponder: Bool { false }
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(fire); bezelStyle = .rounded; controlSize = .small }
    required init?(coder: NSCoder) { nil }
    @objc private func fire() { handler() }
}
final class ConversationResumeSegments: NSSegmentedControl {
    var handler: () -> Void = {}
    override var acceptsFirstResponder: Bool { false }
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(fire) }
    required init?(coder: NSCoder) { nil }
    @objc private func fire() { handler() }
}
final class ConversationResumeTable: NSTableView {
    var gate: () -> Bool = { true }
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) { if gate() { super.mouseDown(with: event) } }
}
private final class ConversationResumeSelectionRow: NSTableRowView {
    var theme = ToolPanelTheme.defaultDark { didSet { needsDisplay = true } }
    override func drawSelection(in dirtyRect: NSRect) {
        theme.accentNS.withAlphaComponent(0.16).setFill(); bounds.fill()
    }
}
private final class ConversationResumeCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let cwd = NSTextField(labelWithString: "")
    private let account = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let button = ConversationResumeButton(frame: .zero)
    private static let formatter: DateFormatter = { let value = DateFormatter(); value.dateStyle = .short; value.timeStyle = .short; return value }()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: ToolPanelMetrics.bodySize, weight: .medium)
        for field in [cwd, account, date] { field.font = .systemFont(ofSize: ToolPanelMetrics.captionSize) }
        button.font = .systemFont(ofSize: ToolPanelMetrics.bodySize)
        date.alignment = .right
        for field in [name, cwd, account, date] { field.lineBreakMode = .byTruncatingMiddle; field.maximumNumberOfLines = 1 }
        name.lineBreakMode = .byTruncatingTail
        for view in [icon, name, cwd, account, date, button] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    func apply(theme: ToolPanelTheme) {
        appearance = theme.appearance
        name.textColor = theme.foregroundNS
        for field in [cwd, account, date] { field.textColor = theme.secondaryNS }
        button.contentTintColor = theme.accentNS
    }
    func configure(_ entry: AgentConversation, live: Bool, enabled: Bool, theme: ToolPanelTheme, action: @escaping () -> Void) {
        apply(theme: theme)
        icon.image = ConversationResumeArtwork.image(entry.source.provider)
        name.stringValue = entry.title.isEmpty ? "Untitled conversation" : entry.title
        name.toolTip = entry.providerSessionID; cwd.stringValue = entry.cwd
        account.stringValue = entry.source.label; account.toolTip = entry.source.accountID
        date.stringValue = Self.formatter.string(from: entry.updatedAt)
        button.title = live ? "Open" : "Resume"; button.isEnabled = enabled; button.handler = action
        button.toolTip = live ? "Open the running session" : entry.source.enabled ? "Resume this conversation" : "This account is disabled"
    }
    override func layout() {
        super.layout(); let width = bounds.width
        icon.frame = NSRect(x: 8, y: 8, width: 14, height: 14)
        name.frame = NSRect(x: 32, y: 6, width: max(0, width - 122), height: 18)
        cwd.frame = NSRect(x: 32, y: 26, width: max(0, width - 122), height: 15)
        account.frame = NSRect(x: 32, y: 44, width: max(0, width - 190), height: 15)
        date.frame = NSRect(x: max(32, width - 146), y: 44, width: min(132, max(0, width - 40)), height: 15)
        button.frame = NSRect(x: max(0, width - 76), y: 12, width: 66, height: 26)
    }
}
private enum ConversationResumeArtwork {
    static func image(_ provider: AgentKind) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let path = NSBezierPath(); path.lineWidth = 1.6
            if provider == .claude {
                NSColor(calibratedRed: 0.87, green: 0.58, blue: 0.44, alpha: 1).setStroke()
                for index in 0..<12 {
                    let angle = CGFloat(index) * .pi / 6
                    path.move(to: NSPoint(x: 7 + cos(angle) * 2, y: 7 + sin(angle) * 2))
                    path.line(to: NSPoint(x: 7 + cos(angle) * 6, y: 7 + sin(angle) * 6))
                }
            } else {
                NSColor.labelColor.setStroke()
                path.move(to: NSPoint(x: 2, y: 11)); path.line(to: NSPoint(x: 7, y: 7)); path.line(to: NSPoint(x: 2, y: 3))
                path.move(to: NSPoint(x: 8, y: 3)); path.line(to: NSPoint(x: 13, y: 3))
            }
            path.stroke(); return true
        }
        image.isTemplate = provider != .claude
        return image
    }
}
private struct ConversationResumeBackdrop: NSViewRepresentable {
    let model: ConversationResumeModel
    let onDismiss: () -> Void
    func makeNSView(context: Context) -> ConversationResumeBackdropView { ConversationResumeBackdropView(frame: .zero) }
    func updateNSView(_ view: ConversationResumeBackdropView, context: Context) {
        view.dismiss = { if model.dismiss() { onDismiss() } }
    }
}
private final class ConversationResumeBackdropView: NSView {
    var dismiss: () -> Void = {}
    override var acceptsFirstResponder: Bool { false }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.withAlphaComponent(0.14).setFill(); dirtyRect.fill() }
    override func mouseDown(with event: NSEvent) { dismiss() }
}
