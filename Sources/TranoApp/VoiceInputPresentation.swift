import AppKit
import SwiftUI

@MainActor final class VoiceInputPresentation: ObservableObject {
    private(set) var id = UUID()
    weak var window: NSWindow?
    @Published private(set) var target: DeferredTerminalInputTarget?
    func begin(store: AppStore, id: UUID) {
        guard store.voiceInputPresentationID == id else { return }
        self.id = id
        target = store.voiceInputTarget
    }
    func permitsRecording(store: AppStore) -> Bool {
        store.showVoice && store.voiceInputPresentationID == id && target?.permitsVoicePreparation(in: window) == true
    }
}

struct VoiceInputWindowAnchor: NSViewRepresentable {
    let presentation: VoiceInputPresentation
    func makeNSView(context: Context) -> VoiceInputWindowView {
        let view = VoiceInputWindowView(); view.presentation = presentation; return view
    }
    func updateNSView(_ view: VoiceInputWindowView, context: Context) { view.presentation = presentation; presentation.window = view.window }
}

final class VoiceInputWindowView: NSView {
    weak var presentation: VoiceInputPresentation?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); presentation?.window = window }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
