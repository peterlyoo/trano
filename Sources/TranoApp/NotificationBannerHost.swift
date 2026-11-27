import AppKit
import SwiftUI
import TerminalCore

@MainActor final class NotificationBannerController: ObservableObject {
    @Published var banners: [NotificationBanner] = []
    private let root: URL
    private let queue = DispatchQueue(label: "trano.notifications.banners", qos: .utility)
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var expiry: DispatchWorkItem?
    private var dismissed = Set<String>()

    init(root: URL) {
        self.root = root
        let fd = open(root.path, O_EVTONLY | O_CLOEXEC)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.reload() } }
            source.setCancelHandler { close(fd) }
            source.resume(); watcher = source
        }
        reload()
    }
    deinit { watcher?.cancel(); pending?.cancel(); expiry?.cancel() }
    func dismiss(_ id: String) { dismissed.insert(id); banners.removeAll { $0.id == id } }
    private func reload() {
        pending?.cancel()
        let root = root
        let work = DispatchWorkItem { [weak self] in
            let entries = (try? NotificationBannerInbox(root: root).read()) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.dismissed.formIntersection(Set(entries.map(\.id)))
                self.banners = entries.filter { !self.dismissed.contains($0.id) }
                self.scheduleExpiry()
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(80), execute: work)
    }
    private func scheduleExpiry() {
        expiry?.cancel()
        guard let next = banners.map(\.expiresAt).min() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.banners.removeAll { $0.expiresAt <= Date() }
            self.scheduleExpiry()
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, next.timeIntervalSinceNow), execute: work)
    }
}

struct NotificationBannerHost: View {
    @StateObject private var controller: NotificationBannerController
    let eligiblePaneIDs: Set<String>
    let focusedPaneID: String?
    let activate: (String) -> Void
    init(root: URL, eligiblePaneIDs: Set<String>, focusedPaneID: String? = nil, activate: @escaping (String) -> Void) {
        _controller = StateObject(wrappedValue: NotificationBannerController(root: root))
        self.eligiblePaneIDs = eligiblePaneIDs; self.focusedPaneID = focusedPaneID; self.activate = activate
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(NotificationPosition.allCases, id: \.self) { position in
                    VStack(spacing: 8) {
                        ForEach(NotificationBannerInbox.presentable(controller.banners, paneIDs: eligiblePaneIDs, focusedPaneID: focusedPaneID).filter { $0.position == position }.suffix(3)) { banner in
                            HStack(alignment: .top, spacing: 10) {
                                Button {
                                    if let id = banner.message.paneID { activate(id) }
                                    controller.dismiss(banner.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(banner.message.title).font(.callout.weight(.semibold)).lineLimit(1)
                                        Text(banner.message.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Button { controller.dismiss(banner.id) } label: { Image(systemName: "xmark").font(.caption) }
                                    .buttonStyle(.plain).help("Dismiss notification").accessibilityLabel("Dismiss notification")
                            }.padding(12).frame(width: min(320, max(0, geometry.size.width - 24)))
                                .background(Color(NSColor.windowBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)) }
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(position)).padding(12)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.clipped()
    }
    private func alignment(_ position: NotificationPosition) -> Alignment {
        switch position {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }
}
