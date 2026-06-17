import AppKit
import SwiftUI

/// Owns the dedicated **Preferences window** for this menu-bar (`.accessory`) app.
///
/// We manage the window directly with AppKit instead of using SwiftUI's `Settings`
/// scene. Opening a `Settings` window reliably from an LSUIElement / `.accessory`
/// app is a long-standing pain point — it tends to open *behind* other apps or
/// never takes key focus, and the usual workaround (flipping the activation policy
/// to `.regular` and back) drags a flickering Dock icon along with it. A hand-rolled
/// `NSWindow` hosting the SwiftUI `PreferencesView`, brought front with
/// `makeKeyAndOrderFront` right after `NSApp.activate`, is the dependable pattern
/// and needs no policy juggling.
///
/// The window is rebuilt from scratch each time it's opened (we drop our reference
/// when it closes), so `PreferencesView`'s `@State` — notably the prompt editor's
/// working draft — is always re-seeded from the model and can never show a stale
/// copy on reopen.
@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    /// Bring the Preferences window to the front, creating it if necessary.
    func show(model: RecorderModel) {
        // Accessory apps aren't frontmost by default; activate so the window can
        // become key and accept keyboard input.
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.title = AppText.t("window.settings", model.language)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: PreferencesView().environment(model))
        let window = NSWindow(contentViewController: hosting)
        window.title = AppText.t("window.settings", model.language)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Drop the window so the next open builds a fresh PreferencesView with
        // state re-seeded from the model.
        window = nil
    }
}
