import AppKit
import SwiftUI
import TerminalCore
import UniformTypeIdentifiers

struct WorkspaceDestinationDropTarget: ViewModifier {
    @ObservedObject var store: AppStore
    let workspaceID: String
    var onDrop: (() -> Void)? = nil
    var onTargetChanged: ((Bool) -> Void)? = nil
    @State private var targeted = false

    func body(content: Content) -> some View {
        content.contentShape(Rectangle())
            .background(WorkspaceRegion("workspace-drop-" + workspaceID))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(targeted && eligible ? Color.mint.opacity(0.8) : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [.tranoTab, .tranoPane], delegate: WorkspaceDestinationDropDelegate(
                store: store, workspaceID: workspaceID, targeted: $targeted, onDrop: onDrop, onTargetChanged: onTargetChanged))
    }

    private var eligible: Bool {
        store.state.layout.workspaces.contains { $0.id == workspaceID && !$0.closed } &&
            WorkspaceDrag.shared.hasActivePayload(in: store)
    }
}

private struct WorkspaceDestinationDropDelegate: DropDelegate {
    let store: AppStore
    let workspaceID: String
    @Binding var targeted: Bool
    let onDrop: (() -> Void)?
    let onTargetChanged: ((Bool) -> Void)?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.tranoTab, .tranoPane]) &&
            store.state.layout.workspaces.contains { $0.id == workspaceID && !$0.closed } &&
            WorkspaceDrag.shared.hasActivePayload(in: store)
    }

    func dropEntered(info: DropInfo) {
        targeted = validateDrop(info: info)
        onTargetChanged?(targeted)
    }

    func dropExited(info: DropInfo) {
        targeted = false
        onTargetChanged?(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let valid = validateDrop(info: info)
        targeted = valid
        onTargetChanged?(valid)
        return DropProposal(operation: valid ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        let accepted = WorkspaceDrag.shared.receive(info.itemProviders(for: [.tranoTab, .tranoPane]),
                                                    in: store, tabID: nil, workspaceID: workspaceID)
        if accepted { onDrop?() }
        return accepted
    }
}

@MainActor final class WorkspaceDragChooserState: ObservableObject {
    @Published private(set) var presented = false
    weak var destinationRegion: NSView?
    private var dismissal: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    deinit {
        dismissal?.cancel()
        polling?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func enter(in store: AppStore) {
        dismissal?.cancel()
        dismissal = nil
        guard WorkspaceDrag.shared.hasActivePayload(in: store) else { dismiss(); return }
        guard !presented else { return }
        presented = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        polling = Task { @MainActor [weak self, weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let store, self.presented else { return }
                if !WorkspaceDrag.shared.hasActivePayload(in: store) { self.dismiss(); return }
            }
        }
    }

    func leave() {
        guard presented else { return }
        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        polling?.cancel()
        polling = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        presented = false
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard presented else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53 { dismiss() }
        } else if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            guard let region = destinationRegion, region.window === event.window,
                  region.bounds.contains(region.convert(event.locationInWindow, from: nil)) else {
                dismiss()
                return event
            }
        }
        return event
    }
}

@MainActor struct WorkspaceDragChooser: ViewModifier {
    @ObservedObject var store: AppStore
    @StateObject private var interaction: WorkspaceDragChooserState

    init(store: AppStore, interaction: WorkspaceDragChooserState? = nil) {
        self.store = store
        _interaction = StateObject(wrappedValue: interaction ?? WorkspaceDragChooserState())
    }

    func body(content: Content) -> some View {
        content.contentShape(Rectangle())
            .background(WorkspaceRegion("workspace-drag-chooser"))
            .onDrop(of: [.tranoTab, .tranoPane], delegate: chooserDelegate)
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    if interaction.presented {
                        destinations
                            .onDrop(of: [.tranoTab, .tranoPane], delegate: chooserDelegate)
                            .offset(y: geometry.size.height)
                    }
                }
            }
            .onDisappear(perform: interaction.dismiss)
    }

    private var chooserDelegate: WorkspaceChooserDropDelegate {
        WorkspaceChooserDropDelegate(store: store, entered: { interaction.enter(in: store) },
                                     exited: interaction.leave, completed: interaction.dismiss)
    }

    private var destinations: some View {
        let workspaces = store.state.layout.workspaces.filter { !$0.closed }
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(workspaces) { workspace in
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(workspace.id == store.preferredWorkspaceID ? Color.mint : .secondary)
                        Text(workspace.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(store.state.layout.tabs.filter { $0.workspaceID == workspace.id }.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .modifier(WorkspaceDestinationDropTarget(store: store, workspaceID: workspace.id, onDrop: interaction.dismiss,
                                                            onTargetChanged: { value in
                        if value { interaction.enter(in: store) }
                        else { interaction.leave() }
                    }))
                }
            }.padding(6)
        }
        .frame(width: 260, height: min(300, CGFloat(workspaces.count) * 32 + 12))
        .background(Color(red: 20/255, green: 20/255, blue: 22/255))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .background(WorkspaceRegion("workspace-drag-destinations"))
        .background(WorkspaceChooserEventRegion(interaction: interaction))
    }
}

private struct WorkspaceChooserEventRegion: NSViewRepresentable {
    let interaction: WorkspaceDragChooserState

    func makeNSView(context: Context) -> NSView {
        let view = EventRegion()
        interaction.destinationRegion = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { interaction.destinationRegion = nsView }

    private final class EventRegion: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct WorkspaceChooserDropDelegate: DropDelegate {
    let store: AppStore
    let entered: () -> Void
    let exited: () -> Void
    let completed: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.tranoTab, .tranoPane]) && WorkspaceDrag.shared.hasActivePayload(in: store)
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { entered() }
    }

    func dropExited(info: DropInfo) { exited() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        entered()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        completed()
        return false
    }
}
