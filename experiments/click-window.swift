import AppKit
import CoreGraphics
// usage: click-window <pid> <offsetFromRight> <offsetFromTop>
// Activates the pid, then clicks only if the topmost window under the point belongs to that pid.
let pid = Int32(CommandLine.arguments[1])!, dx = Double(CommandLine.arguments[2])!, dy = Double(CommandLine.arguments[3])!
NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
usleep(800_000)
func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
}
func frame(_ w: [String: Any]) -> CGRect {
    let b = w[kCGWindowBounds as String] as! [String: Double]
    return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
}
guard let own = windows().filter({ ($0[kCGWindowOwnerPID as String] as? Int32) == pid }).max(by: { frame($0).width < frame($1).width }) else { print("nowindow"); exit(1) }
let rect = frame(own)
let point = CGPoint(x: rect.maxX - dx, y: rect.minY + dy)
guard let top = windows().first(where: { frame($0).contains(point) }), (top[kCGWindowOwnerPID as String] as? Int32) == pid else { print("obscured"); exit(2) }
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(80_000)
}
print("clicked", point)
