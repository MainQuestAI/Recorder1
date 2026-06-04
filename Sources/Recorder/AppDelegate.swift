import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only agent app: no Dock icon, no app-switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}
