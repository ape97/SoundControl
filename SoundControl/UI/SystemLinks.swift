import AppKit

/// macOS System Settings → Sound.
enum SystemSettings {
    static func openSound() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
