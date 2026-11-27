import SwiftUI
import TerminalCore

struct NotificationSettingsView: View {
    @Binding var preferences: NotificationPreferences
    @Binding var deliveryEnabled: Bool
    var tailscaleAvailable = false
    var expandedControls = false
    var authorize: () -> Void

    var body: some View {
        Form {
            Section("macOS notifications & sounds") {
                Toggle("Enable notifications and sounds", isOn: $deliveryEnabled)
                    .help("Controls macOS notifications and sounds. Tab indicators and Dock badges use separate settings.")
                Button("Allow macOS Notifications…", action: authorize)
                Toggle("macOS notification banners", isOn: $preferences.systemNotifications)
                    .help("Show macOS banners from enabled notification sources, including while Trano is active.")
                Toggle("Play sounds", isOn: $preferences.playSounds)
                HStack {
                    Text("Sound volume")
                    Slider(value: $preferences.soundVolume, in: 0...1)
                    Text(preferences.soundVolume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }.disabled(!preferences.playSounds)
            }
            Section("Quota alerts") {
                Toggle("Low quota", isOn: $preferences.quotaLowEnabled)
                Picker("Remaining quota", selection: $preferences.quotaLowRemainingPercent) {
                    ForEach([5.0, 10, 15, 20, 25, 50], id: \.self) { Text("\(Int($0))%").tag($0) }
                    if ![5.0, 10, 15, 20, 25, 50].contains(preferences.quotaLowRemainingPercent) {
                        Text("\(preferences.quotaLowRemainingPercent.formatted())%").tag(preferences.quotaLowRemainingPercent)
                    }
                }.disabled(!preferences.quotaLowEnabled)
                Toggle("Quota reset", isOn: $preferences.quotaResetEnabled)
            }
            if expandedControls {
            Section("Session activity") {
                Toggle("Badge Dock icon", isOn: $preferences.badgeDockIcon)
                Toggle("Show activity in tabs", isOn: $preferences.showActivityInTabs)
                Toggle("Include idle processes", isOn: $preferences.includeIdleProcesses)
                Toggle("Show each process in Activity", isOn: $preferences.showEachProcessInTabs)
                Grid(alignment: .center, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("State").frame(maxWidth: .infinity, alignment: .leading)
                        Text("All"); Text("Tab"); Text("Banners"); Text("Dock"); Text("Sound")
                    }.font(.caption).foregroundStyle(.secondary)
                    channels("Working", $preferences.working, showsTabIndicator: false)
                    channels("Blocked", $preferences.blocked)
                    channels("Error", $preferences.error)
                    channels("Done", $preferences.done)
                }.toggleStyle(.checkbox)
            }
            Section("Terminal program requests") {
                Toggle("Allow requests from terminal programs", isOn: $preferences.terminalNotifications)
                    .help("Applies only to notifications requested by commands and programs in a terminal. Session activity and quota alerts are configured separately.")
            }
            Section("Tailscale") {
                Toggle("Sign-in notifications", isOn: $preferences.tailscaleSignIn)
                Toggle("Device approval notifications", isOn: $preferences.tailscaleDeviceApproval)
                Toggle("Connection failure notifications", isOn: $preferences.tailscaleFailures)
            }.disabled(!tailscaleAvailable)
            }
        }.formStyle(.grouped)
    }

    private func channels(_ title: String, _ binding: Binding<NotificationChannels>, showsTabIndicator: Bool = true) -> some View {
        GridRow {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Enable \(title)", isOn: binding.enabled).labelsHidden().help("Enable \(title.lowercased()) notifications")
            if showsTabIndicator {
                Toggle("\(title) tab indicator", isOn: binding.tabIndicator).labelsHidden().disabled(!binding.wrappedValue.enabled)
            } else {
                Text("—").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Toggle("\(title) banners", isOn: binding.systemNotification).labelsHidden().disabled(!binding.wrappedValue.enabled)
                .help("Show macOS notifications for this session state, including while Trano is active.")
            Toggle("\(title) Dock badge", isOn: binding.dockBadge).labelsHidden().disabled(!binding.wrappedValue.enabled)
            Toggle("\(title) sound", isOn: binding.sound).labelsHidden().disabled(!binding.wrappedValue.enabled)
        }.font(.callout)
    }
}
