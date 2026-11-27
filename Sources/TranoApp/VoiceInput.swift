import AppKit
import AVFoundation
import Speech
import SwiftUI

@MainActor final class VoiceInput: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    @Published var authorizing = false
    @Published var finishing = false
    @Published var error: String?
    var canBeginRecording: () -> Bool = { true }
    @Published var locale = "ko-KR"
    @Published var allowNetwork = false
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var boundPresentationID: UUID?
    private let authorizeSpeech: (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void
    private let authorizeMicrophone: (@escaping (Bool) -> Void) -> Void

    init(authorizeSpeech: @escaping (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = SFSpeechRecognizer.requestAuthorization,
         authorizeMicrophone: @escaping (@escaping (Bool) -> Void) -> Void = { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) }) {
        self.authorizeSpeech = authorizeSpeech; self.authorizeMicrophone = authorizeMicrophone
    }

    @discardableResult func bind(to presentationID: UUID) -> Bool {
        guard boundPresentationID != presentationID else { return false }
        stop()
        boundPresentationID = presentationID
        return true
    }
    func setDraft(_ value: String, for presentationID: UUID) {
        guard boundPresentationID == presentationID else { return }
        text = value
    }
    func stop(presentationID: UUID) {
        guard boundPresentationID == presentationID else { return }
        stop()
    }

    func start() {
        guard !listening, !authorizing, !finishing else { return }
        guard canBeginRecording() else { error = "The original terminal changed. Review or copy your draft before closing."; return }
        generation += 1
        let current = generation
        error = nil
        authorizing = true
        authorizeSpeech { [weak self] status in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                guard status == .authorized else {
                    self.authorizing = false; self.error = "Speech recognition permission is required in System Settings."; return
                }
                guard self.canBeginRecording() else {
                    self.error = "The original terminal changed. Review or copy your draft before closing."; self.stop(); return
                }
                self.authorizeMicrophone { [weak self] allowed in
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        self.authorizing = false
                        guard allowed else { self.error = "Microphone permission is required in System Settings."; return }
                        self.record(generation: current)
                    }
                }
            }
        }
    }

    private func record(generation current: Int) {
        guard canBeginRecording() else { error = "The original terminal changed. Review or copy your draft before closing."; stop(); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            error = "Speech recognition is unavailable for this language."; return
        }
        guard recognizer.supportsOnDeviceRecognition || allowNetwork else {
            error = "On-device recognition is unavailable. Enable network recognition or select another language."; return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = !allowNetwork
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { error = "No microphone is available."; return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        self.request = request
        self.engine = engine
        engine.prepare()
        do { try engine.start() } catch { self.error = error.localizedDescription; stop(); return }
        listening = true
        let prefix = text.isEmpty ? "" : text + " "
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.generation == current, self.listening || self.finishing else { return }
                if let result { self.text = prefix + result.bestTranscription.formattedString }
                if let error { self.error = error.localizedDescription; self.stop() }
                else if result?.isFinal == true { self.stop() }
            }
        }
    }

    func finish() {
        if authorizing { stop(); return }
        guard listening else { return }
        listening = false; finishing = true
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        request?.endAudio()
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.generation == current, self.finishing else { return }
            self.stop()
        }
    }

    func stop() {
        generation += 1
        listening = false
        authorizing = false; finishing = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
    }
}

struct VoiceInputView: View {
    @ObservedObject var store: AppStore
    @StateObject private var voice = VoiceInput()
    @StateObject private var presentation = VoiceInputPresentation()
    private let presentationID: UUID
    init(store: AppStore) { self.store = store; presentationID = store.voiceInputPresentationID ?? UUID() }
    private var busy: Bool { voice.listening || voice.authorizing || voice.finishing }
    var body: some View {
        VStack(spacing: 0) {
            ToolPanelHeader("Voice Input", symbol: voice.listening ? "waveform" : "mic", trailing: AnyView(
                Picker("Language", selection: $voice.locale) { Text("한국어").tag("ko-KR"); Text("English").tag("en-US") }.labelsHidden().frame(width: 120).disabled(busy)
            ), closeLabel: "Cancel", onClose: cancelVoiceInput)
            VStack(alignment: .leading, spacing: ToolPanelMetrics.sectionSpacing) {
                Text(store.voiceInputInitialDraft.isEmpty ? "Record, review, then insert into your terminal." : "Recovered voice draft. Review it before inserting into your terminal.").font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { voice.text }, set: { if store.voiceInputPresentationID == presentationID { voice.setDraft($0, for: presentationID) } })).font(.system(size: 14)).frame(height: 170).padding(8).overlay { RoundedRectangle(cornerRadius: ToolPanelMetrics.cornerRadius).stroke(store.toolPanelTheme.border) }.disabled(busy).accessibilityLabel("Voice transcript")
                Toggle("Allow Apple network recognition", isOn: $voice.allowNetwork).font(.system(size: 12)).disabled(busy)
                if let error = voice.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
                HStack {
                    Button(voice.authorizing ? "Requesting Permission…" : voice.finishing ? "Finishing…" : voice.listening ? "Stop Recording" : "Start Recording") { guard store.voiceInputPresentationID == presentationID else { return }; voice.listening ? voice.finish() : voice.start() }.disabled(voice.authorizing || voice.finishing)
                    Text("Hold to Talk").font(.callout).padding(.horizontal, 10).padding(.vertical, 5).background(store.toolPanelTheme.foreground.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: ToolPanelMetrics.cornerRadius))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if store.voiceInputPresentationID == presentationID { voice.start() } }.onEnded { _ in if store.voiceInputPresentationID == presentationID { voice.finish() } })
                        .accessibilityHidden(true)
                    Spacer()
                    Button("Cancel", action: cancelVoiceInput).keyboardShortcut(.cancelAction)
                    Button("Insert Text") {
                        guard store.voiceInputPresentationID == presentationID, presentation.id == presentationID,
                              presentation.permitsRecording(store: store), let target = presentation.target else {
                            voice.error = "The original terminal changed. Review or copy your draft before closing."; return
                        }
                        voice.stop()
                        let text = voice.text
                        guard store.voiceInputRecovery.remember(text, presentationID: presentationID, currentID: store.voiceInputPresentationID) else {
                            voice.error = "Voice input is limited to 1 MiB. Review or copy your draft before closing."; return
                        }
                        store.showVoice = false
                        target.completeVoice(text, presentationID: presentation.id, closingSheet: presentation.window)
                    }.keyboardShortcut(.defaultAction).disabled(busy || voice.text.isEmpty || presentation.target == nil)
                }
            }.padding(ToolPanelMetrics.contentInset)
        }.frame(width: 560).toolPanelSurface(store.toolPanelTheme)
            .dismissOnOutsideClick("voice-input-sheet-" + presentationID.uuidString,
                canDismiss: { store.voiceInputPresentationID == presentationID }, perform: cancelVoiceInput)
            .background { VoiceInputWindowAnchor(presentation: presentation) }
            .onAppear {
                guard store.voiceInputPresentationID == presentationID else { return }
                presentation.begin(store: store, id: presentationID)
                if voice.bind(to: presentationID) { voice.setDraft(store.voiceInputInitialDraft, for: presentationID) }
                voice.canBeginRecording = { [weak presentation, weak store] in
                    guard let presentation, let store, store.voiceInputPresentationID == presentationID else { return false }
                    return presentation.permitsRecording(store: store)
                }
            }
            .onDisappear { voice.stop(presentationID: presentationID) }
    }

    private func cancelVoiceInput() {
        guard store.voiceInputPresentationID == presentationID else { return }
        voice.stop(presentationID: presentationID)
        store.showVoice = false
    }
}
