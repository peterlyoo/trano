import AppKit
import TerminalCore
import UserNotifications

final class NativeNotificationSink {
    private var playing: [NSSound] = []

    func sendSystem(_ message: NotificationMessage) {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = nil
        if let paneID = message.paneID { content.userInfo = ["sessionID": paneID] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil)) { _ in }
    }

    func playSound(volume: Double) {
        guard volume.isFinite, volume > 0, volume <= 1 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let sound = NSSound(named: NSSound.Name("Glass"))?.copy() as? NSSound else { return }
            self.playing.removeAll { !$0.isPlaying }
            if self.playing.count >= 4 { self.playing.removeFirst().stop() }
            sound.volume = Float(volume)
            self.playing.append(sound)
            sound.play()
        }
    }
}
