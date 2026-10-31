import SwiftUI
import AppKit

enum YooTrackBrand {
    static let mark: NSImage = {
        let image = Bundle.main.url(forResource: "YooTrackMark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "YooTrack")!
        image.isTemplate = true
        return image
    }()
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    static var openDetails: (() -> Void)?
    static var installStatusBar: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        Self.installStatusBar?()
        if !CommandLine.arguments.contains("--background") { DispatchQueue.main.async { Self.openDetails?() } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.openDetails?()
        return true
    }
}

@main struct PowerWatchApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        let model = CommandLine.arguments.contains("--ui-testing") ? UITestFixtures.makeModel() : AppModel()
        _model = StateObject(wrappedValue: model)
        ApplicationDelegate.openDetails = { [weak model] in model?.openDetails() }
        ApplicationDelegate.installStatusBar = { [weak model] in model?.installStatusBar() }
    }
    var body: some Scene {
        Settings { EmptyView() }
    }
}
