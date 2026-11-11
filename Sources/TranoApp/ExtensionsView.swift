import AppKit
import SwiftUI
import TerminalCore

struct ExtensionsView: View {
    @ObservedObject var store: AppStore
    @State private var accountID = ""
    @State private var selected: Set<String> = []
    @State private var kind = ExtensionKind.skill
    @State private var name = ""
    @State private var plan: ExtensionPlan?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Agent extensions").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { store.showExtensions = false }.keyboardShortcut(.cancelAction)
            }
            Text("Share skills and MCP servers. Choose which extensions each account uses.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Account", selection: $accountID) {
                    Text("Select an account").tag("")
                    ForEach(store.state.accounts) { Text($0.label + " · " + $0.provider.rawValue.capitalized).tag($0.id) }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("LIBRARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    List(store.state.extensions) { item in
                        HStack {
                            if item.kind == .plugin {
                                Image(systemName: "puzzlepiece.extension")
                            } else {
                                Toggle("", isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                                    if value { selected.insert(item.id) } else { selected.remove(item.id) }
                                    plan = nil
                                })).labelsHidden().disabled(accountID.isEmpty || busy)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).lineLimit(1)
                                Text(item.kind.rawValue.uppercased()).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.kind == .plugin { Button("Install…") { previewPlugin(item.id) }.disabled(accountID.isEmpty || busy) }
                        }.padding(.vertical, 5)
                    }.frame(width: 270, height: 280)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("PREVIEW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        if let plan {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(plan.links.keys.sorted(), id: \.self) { Text("Link " + $0).font(.caption.monospaced()) }
                                ForEach(plan.files.keys.sorted(), id: \.self) { path in
                                    Text(path).font(.caption.weight(.semibold))
                                    Text(plan.files[path] ?? "").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                }
                                ForEach(plan.unsupported, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("Select extensions, then preview the account’s changes.")
                                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 240)
                        }
                    }.frame(height: 280)
                }
            }
            HStack {
                Picker("Import", selection: $kind) { ForEach(ExtensionKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.frame(width: 150)
                TextField("Extension name", text: $name)
                Button("Choose File…", action: chooseImport).disabled(name.isEmpty || busy)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text(kind == .skill ? "Skills: select a folder containing SKILL.md." : "MCP and hooks use JSON. Plugins map claude/codex to name@marketplace.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Preview", action: preview).disabled(accountID.isEmpty || busy)
                Button("Apply") { apply() }.disabled(plan == nil || busy)
            }
        }.padding(24).frame(width: 800).preferredColorScheme(.dark)
            .onAppear { accountID = store.state.accounts.first?.id ?? "" }
            .onChange(of: accountID) { loadSelection() }
    }

    private func loadSelection() {
        plan = nil; selected = []; error = nil
        guard !accountID.isEmpty else { return }
        let id = accountID, runtime = store.runtime
        busy = true
        store.queue.async {
            let result = Result { try runtime.enabledExtensions(accountID: id) }
            DispatchQueue.main.async {
                busy = false
                guard accountID == id else { return }
                switch result { case .success(let ids): selected = Set(ids); case .failure(let failure): error = failure.localizedDescription }
            }
        }
    }

    private func preview() {
        let id = accountID, ids = Array(selected), runtime = store.runtime
        busy = true; error = nil
        store.queue.async {
            let result = Result { try runtime.extensionPlan(accountID: id, extensionIDs: ids) }
            DispatchQueue.main.async {
                busy = false
                guard id == accountID else { return }
                switch result { case .success(let value): plan = value; case .failure(let failure): error = failure.localizedDescription }
            }
        }
    }

    private func apply() {
        guard let plan else { return }
        let runtime = store.runtime
        busy = true; error = nil
        store.queue.async {
            let result = Result { try runtime.applyExtensions(plan) }
            DispatchQueue.main.async {
                busy = false
                switch result { case .success: self.plan = nil; store.refresh(); case .failure(let failure): error = failure.localizedDescription }
            }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == .skill
        panel.canChooseFiles = kind != .skill
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let name = name, kind = kind, runtime = store.runtime
        busy = true; error = nil
        store.queue.async {
            let result = Result { try runtime.importExtension(name: name, kind: kind, source: source) }
            DispatchQueue.main.async {
                busy = false
                switch result { case .success: self.name = ""; store.refresh(); case .failure(let failure): error = failure.localizedDescription }
            }
        }
    }

    private func previewPlugin(_ extensionID: String) {
        let id = accountID, runtime = store.runtime
        busy = true; error = nil
        store.queue.async {
            let result = Result { try runtime.pluginCommand(accountID: id, extensionID: extensionID) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .failure(let failure): error = failure.localizedDescription
                case .success(let command):
                    let alert = NSAlert()
                    alert.messageText = "Install plugin for this account?"
                    alert.informativeText = command.arguments.map(ShellQuote.quote).joined(separator: " ") + "\n\nThe provider’s installer will open in a new terminal tab."
                    alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Open Installer")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                    let cwd = store.currentDirectory
                    store.showExtensions = false
                    store.perform { _ = try $0.launchPluginInstall(accountID: id, extensionID: extensionID, cwd: cwd) }
                }
            }
        }
    }
}
