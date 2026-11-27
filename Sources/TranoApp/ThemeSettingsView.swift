import AppKit
import Darwin
import SwiftUI
import SwiftTerm
import TerminalCore

struct ThemeSettingsView: View {
    @Binding var preferences: ThemePreferences
    let legacy: TerminalSettings
    var fontSmoothing = false
    @State private var previewMode: ThemeMode = .dark
    @State private var editor: ThemeEditorRequest?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                modeControls(.light)
                Divider()
                modeControls(.dark)
                Divider()
                Picker("Preview", selection: $previewMode) {
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                }.pickerStyle(.segmented).frame(width: 200)
                ThemeTerminalPreview(application: preferences.application(for: previewMode, legacy: legacy), fontSmoothing: fontSmoothing)
                    .frame(height: 150).clipped().allowsHitTesting(false).accessibilityLabel("Terminal theme preview")
                if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }.padding(18)
        }.sheet(item: $editor) { request in
            ThemePaletteEditor(palette: request.palette, legacy: legacy, fontSmoothing: fontSmoothing) { palette in
                var changed = preferences
                try changed.save(palette); try changed.select(palette.id, for: request.mode)
                preferences = changed; previewMode = request.mode
            }
        }
    }

    private func modeControls(_ mode: ThemeMode) -> some View {
        let selected = mode == .light ? preferences.lightThemeID : preferences.darkThemeID
        let custom = preferences.customThemes.contains { $0.id == selected }
        return VStack(alignment: .leading, spacing: 10) {
            Picker(mode == .light ? "Light theme" : "Dark theme", selection: Binding(get: { selected }, set: { id in
                do { try preferences.select(id, for: mode); previewMode = mode; error = nil }
                catch { self.error = error.localizedDescription }
            })) {
                Text("Current Appearance").tag(ThemePreferences.currentPaletteID)
                Divider()
                ForEach(ThemePreferences.builtIns) { Text($0.name).tag($0.id) }
                if !preferences.customThemes.isEmpty { Divider() }
                ForEach(preferences.customThemes) { Text($0.name).tag($0.id) }
            }.pickerStyle(.menu)
            Toggle("Use extended theme palette", isOn: Binding(get: {
                mode == .light ? preferences.lightExtendedPalette : preferences.darkExtendedPalette
            }, set: { enabled in
                if mode == .light { preferences.lightExtendedPalette = enabled } else { preferences.darkExtendedPalette = enabled }
                previewMode = mode
            })).toggleStyle(.checkbox)
            HStack(spacing: 12) {
                Button(custom ? "Edit…" : "Customize…") { edit(selected, mode: mode, duplicate: !custom) }
                Button("Duplicate…") { edit(selected, mode: mode, duplicate: true) }
                if custom {
                    Button("Delete", role: .destructive) {
                        do { try preferences.remove(selected); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Import Theme…") { importTheme(for: mode) }
            }.controlSize(.small)
        }
    }

    private func edit(_ id: String, mode: ThemeMode, duplicate: Bool) {
        do {
            var candidate = preferences
            let selected = duplicate ? try candidate.duplicate(id, legacy: legacy) : id
            guard let palette = candidate.palette(id: selected, legacy: legacy) else { return }
            editor = ThemeEditorRequest(palette: palette, mode: mode); error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func importTheme(for mode: ThemeMode) {
        let panel = NSOpenPanel()
        panel.title = "Import Theme"; panel.message = "Ghostty or iTerm color theme"
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try boundedThemeData(url)
                _ = try preferences.importTheme(data: data, filename: url.lastPathComponent, for: mode)
                previewMode = mode; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ThemeEditorRequest: Identifiable {
    var id: String { palette.id }
    let palette: ThemePalette
    let mode: ThemeMode
}

struct ThemePaletteEditor: View {
    @State var palette: ThemePalette
    let legacy: TerminalSettings
    var fontSmoothing = false
    let commit: (ThemePalette) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var extendedIndex = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Theme").font(.title2.weight(.semibold))
            TextField("Name", text: $palette.name).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        ColorPicker("Background", selection: themeColor($palette.background), supportsOpacity: false)
                        ColorPicker("Text", selection: themeColor($palette.foreground), supportsOpacity: false)
                    }
                    HStack {
                        ColorPicker("Cursor", selection: themeColor($palette.cursor), supportsOpacity: false)
                        ColorPicker("Selection", selection: themeColor($palette.selection), supportsOpacity: false)
                    }
                    optionalColor("Cursor text", value: $palette.cursorText, fallback: palette.background)
                    optionalColor("Selected text", value: $palette.selectionForeground, fallback: palette.foreground)
                    Divider()
                    Text("ANSI Colors").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 48), spacing: 10), count: 8), spacing: 10) {
                        ForEach(0..<16, id: \.self) { index in
                            ColorPicker("ANSI \(index)", selection: themeColor(Binding(get: { palette.ansiColors.indices.contains(index) ? palette.ansiColors[index] : "#000000" }, set: {
                                if palette.ansiColors.indices.contains(index) { palette.ansiColors[index] = $0 }
                            })), supportsOpacity: false).labelsHidden().help("ANSI color \(index)")
                        }
                    }
                    Divider()
                    HStack {
                        Text("Extended Colors").font(.headline)
                        Spacer()
                        Stepper("\(extendedIndex)", value: $extendedIndex, in: 16...255).monospacedDigit().frame(width: 110)
                        Button("Add") { if palette.indexedColors[extendedIndex] == nil { palette.indexedColors[extendedIndex] = palette.foreground } }
                    }
                    ForEach(palette.indexedColors.keys.sorted(), id: \.self) { index in
                        HStack {
                            ColorPicker("Color \(index)", selection: themeColor(Binding(get: { palette.indexedColors[index] ?? palette.foreground }, set: { palette.indexedColors[index] = $0 })), supportsOpacity: false)
                            Spacer()
                            Button { palette.indexedColors.removeValue(forKey: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove color \(index)").accessibilityLabel("Remove color \(index)")
                        }
                    }
                    ThemeTerminalPreview(application: preview, fontSmoothing: fontSmoothing).frame(height: 140).clipped().allowsHitTesting(false)
                }.padding(.vertical, 4)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Theme") {
                    do { try palette.validate(); try commit(palette); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 570, height: 620)
    }

    private var preview: ThemeApplication {
        var preferences = ThemePreferences()
        var previewPalette = palette; previewPalette.name = "Preview"
        if (try? preferences.save(previewPalette)) != nil { try? preferences.select(previewPalette.id, for: .dark) }
        preferences.darkExtendedPalette = true
        return preferences.application(for: .dark, legacy: legacy)
    }

    private func optionalColor(_ title: String, value: Binding<String?>, fallback: String) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? fallback : nil })).toggleStyle(.checkbox)
            Spacer()
            if value.wrappedValue != nil {
                ColorPicker(title, selection: themeColor(Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 })), supportsOpacity: false).labelsHidden()
            }
        }
    }
}

private func themeColor(_ value: Binding<String>) -> Binding<SwiftUI.Color> {
    Binding(get: { SwiftUI.Color(NSColor(hex: value.wrappedValue)) }, set: { selected in
        guard let native = NSColor(selected).usingColorSpace(.sRGB) else { return }
        value.wrappedValue = String(format: "#%02X%02X%02X", Int((native.redComponent * 255).rounded()), Int((native.greenComponent * 255).rounded()), Int((native.blueComponent * 255).rounded()))
    })
}

struct ThemeTerminalPreview: NSViewRepresentable {
    let application: ThemeApplication
    var fontSmoothing = false
    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular); view.fontSmoothing = fontSmoothing
        TerminalThemeRenderer.apply(application, to: view)
        view.feed(text: "Trano  ~/projects\r\n한글 입력 · English · 0123456789\r\n\u{1b}[32m❯\u{1b}[0m git status\r\n\u{1b}[31mred\u{1b}[0m  \u{1b}[32mgreen\u{1b}[0m  \u{1b}[34mblue\u{1b}[0m  \u{1b}[38;5;31mextended\u{1b}[0m")
        return view
    }
    func updateNSView(_ view: SwiftTerm.TerminalView, context: Context) {
        if view.fontSmoothing != fontSmoothing {
            view.fontSmoothing = fontSmoothing
            view.needsDisplay = true
            view.requestRedraw()
        }
        TerminalThemeRenderer.apply(application, to: view)
    }
}

private func boundedThemeData(_ url: URL) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw TerminalError.invalid("Cannot open this theme file.") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= ThemeImport.maximumBytes else {
        throw TerminalError.invalid("Choose a regular theme file of at most 1 MiB.")
    }
    var data = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = read(fd, &bytes, bytes.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw TerminalError.invalid("Cannot read this theme file.") }
        if count == 0 { break }
        guard data.count + count <= ThemeImport.maximumBytes else { throw TerminalError.invalid("Theme file exceeds 1 MiB.") }
        data.append(contentsOf: bytes.prefix(count))
    }
    return data
}
