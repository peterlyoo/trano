import AppKit
import SwiftUI
import TerminalCore

struct ConnectedServerSettingsPage: View {
    @Binding var preferences: ServerPreferences
    @ObservedObject var connection: SettingsServerConnection
    let root: URL
    var body: some View {
        Group {
            if let controller = connection.controller {
                ServerSettingsPage(preferences: $preferences, controller: controller, root: root)
            } else { SettingsConnectionProgress(connection: connection) }
        }
        .padding(18)
        .onAppear { connection.prepare() }
    }
}

struct ConnectedIntegrationsSettingsPage: View {
    @Binding var preferences: IntegrationsPreferences
    @ObservedObject var connection: SettingsServerConnection
    var body: some View {
        Group {
            if let controller = connection.controller {
                IntegrationsDraftSurface(preferences: $preferences,
                    available: controller.snapshot?.availableAgents ?? connection.availableAgents, busy: controller.busy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else { SettingsConnectionProgress(connection: connection) }
        }
        .padding(18)
        .onAppear { connection.prepare() }
    }
}

private struct SettingsConnectionProgress: View {
    @ObservedObject var connection: SettingsServerConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = connection.error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { connection.prepare() }
            } else { ProgressView("Loading…") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct IntegrationsDraftSurface: NSViewRepresentable {
    @Binding var preferences: IntegrationsPreferences
    let available: [AgentKind]
    let busy: Bool
    func makeNSView(context: Context) -> IntegrationsSettingsNativeView { IntegrationsSettingsNativeView(frame: .zero) }
    func updateNSView(_ view: IntegrationsSettingsNativeView, context: Context) {
        view.onChange = { preferences = $0 }
        view.configure(preferences: preferences, available: available, installed: [], busy: busy || !context.environment.isEnabled)
    }
}
