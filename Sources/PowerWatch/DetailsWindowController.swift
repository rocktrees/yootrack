import AppKit
import SwiftUI

/// Dispose the hosting view when closed; SwiftUI Window scenes retain their large tables and charts.
@MainActor final class DetailsWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var window: NSWindow?
    private var preferences: NSWindow?
    init(model: AppModel) { self.model = model }
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1250, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = CommandLine.arguments.contains("--ui-testing") ? "Power Watch — UI test fixtures" : "Power Watch"
        window.identifier = NSUserInterfaceItemIdentifier("powerwatch.details")
        window.isReleasedWhenClosed = false; window.delegate = self
        if CommandLine.arguments.contains("--ui-testing") && CommandLine.arguments.contains("--test-quick-menu") {
            // Exercise the exact popup content without relying on status-item
            // coordinates, which menu bar managers can move or hide.
            let host = NSHostingView(rootView: QuickMenu(model: model))
            window.contentView = host
            window.setContentSize(host.fittingSize)
        } else {
            window.contentView = NSHostingView(rootView: Dashboard(model: model))
            window.minSize = NSSize(width: 1130, height: 600)
        }
        window.center(); self.window = window
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func showPreferences() {
        if let preferences { preferences.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); return }
        let preferences = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        preferences.title = "Power Watch Settings"; preferences.isReleasedWhenClosed = false; preferences.delegate = self
        preferences.contentView = NSHostingView(rootView: Preferences(model: model)); preferences.center()
        self.preferences = preferences; preferences.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === preferences {
            preferences?.contentView = nil; preferences?.delegate = nil; preferences = nil
            model.visibility("settings", isVisible: false)
        } else {
            window?.contentView = nil; window?.delegate = nil; window = nil
            model.visibility("details", isVisible: false)
        }
    }
    func windowDidMiniaturize(_ notification: Notification) { model.visibility("details", isVisible: false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.visibility("details", isVisible: true) }
}
