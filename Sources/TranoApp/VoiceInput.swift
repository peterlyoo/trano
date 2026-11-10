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
    @Published var locale = "ko-KR"
    @Published var allowNetwork = false
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private let authorizeSpeech: (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void
    private let authorizeMicrophone: (@escaping (Bool) -> Void) -> Void

    init(authorizeSpeech: @escaping (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = SFSpeechRecognizer.requestAuthorization,
         authorizeMicrophone: @escaping (@escaping (Bool) -> Void) -> Void = { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) }) {
        self.authorizeSpeech = authorizeSpeech; self.authorizeMicrophone = authorizeMicrophone
    }

    func start() {
        guard !listening, !authorizing, !finishing else { return }
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
    @State private var targetPaneID: String?
    init(store: AppStore) { self.store = store; _targetPaneID = State(initialValue: store.focusedID) }
    private var busy: Bool { voice.listening || voice.authorizing || voice.finishing }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: voice.listening ? "waveform" : "mic").foregroundStyle(.mint)
                Text("Voice Input").font(.system(size: 20, weight: .semibold))
                Spacer()
                Picker("Language", selection: $voice.locale) { Text("한국어").tag("ko-KR"); Text("English").tag("en-US") }.labelsHidden().frame(width: 120).disabled(busy)
            }
            Text("Record, review, then insert into your terminal.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $voice.text).font(.system(size: 14)).frame(height: 170).padding(8).overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1)) }.disabled(busy).accessibilityLabel("Voice transcript")
            Toggle("Allow Apple network recognition", isOn: $voice.allowNetwork).font(.system(size: 12)).disabled(busy)
            if let error = voice.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Button(voice.authorizing ? "Requesting Permission…" : voice.finishing ? "Finishing…" : voice.listening ? "Stop Recording" : "Start Recording") { voice.listening ? voice.finish() : voice.start() }.disabled(voice.authorizing || voice.finishing)
                Text("Hold to Talk").font(.callout).padding(.horizontal, 10).padding(.vertical, 5).background(.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 5))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in voice.start() }.onEnded { _ in voice.finish() })
                    .accessibilityHidden(true)
                Spacer()
                Button("Cancel") { voice.stop(); store.showVoice = false }.keyboardShortcut(.cancelAction)
                Button("Insert Text") {
                    guard let id = targetPaneID, let target = store.terminalViews[id] else {
                        voice.error = "The original terminal is no longer open. Copy your draft before closing this window."; return
                    }
                    voice.stop()
                    let text = voice.text
                    store.showVoice = false
                    DispatchQueue.main.async { target.pasteDraft(text) }
                }.keyboardShortcut(.defaultAction).disabled(busy || voice.text.isEmpty || targetPaneID == nil)
            }
        }.padding(28).frame(width: 560).preferredColorScheme(.dark).onDisappear { voice.stop() }
    }
}
