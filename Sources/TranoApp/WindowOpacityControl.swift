import AppKit
import SwiftUI
import TerminalCore

struct WindowOpacityControl: NSViewRepresentable {
    @Binding var value: Double
    func makeNSView(context: Context) -> WindowOpacityNativeSlider { WindowOpacityNativeSlider() }
    func updateNSView(_ slider: WindowOpacityNativeSlider, context: Context) {
        slider.doubleValue = value
        slider.isEnabled = context.environment.isEnabled
        slider.onChange = { value = $0 }
    }
}

final class WindowOpacityNativeSlider: NSSlider {
    var onChange: ((Double) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minValue = AppearancePreferences.opacityRange.lowerBound
        maxValue = AppearancePreferences.opacityRange.upperBound
        isContinuous = true
        target = self
        action = #selector(changed(_:))
        identifier = NSUserInterfaceItemIdentifier("window-opacity-slider")
        setAccessibilityLabel("Window opacity")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func changed(_ sender: Any?) { if isEnabled { onChange?(doubleValue) } }
}
