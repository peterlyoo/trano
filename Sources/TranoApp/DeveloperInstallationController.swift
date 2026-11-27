import AppKit
import Combine
import TerminalCore

@MainActor final class DeveloperInstallationController: ObservableObject {
    @Published private(set) var metadata: DeveloperInstallationMetadata?
    @Published private(set) var status = "Not checked"
    private let queue = DispatchQueue(label: "trano.developer-installation", qos: .utility)
    private var generation: UInt64 = 0

    func refresh(preferences: DeveloperPreferences, bundledHelper: URL) {
        generation &+= 1
        let generation = generation
        do { try preferences.validate() }
        catch { metadata = nil; status = error.localizedDescription; return }
        status = "Checking…"
        queue.async { [weak self] in
            let result = Result {
                if preferences.installationLocation == .sourceCheckout {
                    return try DeveloperInstallationInspector.sourceBundle(directory: URL(fileURLWithPath: preferences.sourceDirectory))
                }
                return try DeveloperInstallationInspector.inspect(bundle: bundledHelper)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                switch result {
                case .success(let metadata): self.metadata = metadata; self.status = "Ready · API \(metadata.apiVersion)"
                case .failure(let error): self.metadata = nil; self.status = error.localizedDescription
                }
            }
        }
    }

    func chooseDirectory(owner: NSWindow?, onChoose: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        panel.title = "Trano Source Checkout"
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            onChoose(url)
        }
        if let owner { panel.beginSheetModal(for: owner, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
}
