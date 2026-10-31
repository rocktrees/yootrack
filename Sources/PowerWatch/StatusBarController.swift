import AppKit
import Combine
import SwiftUI
#if SWIFT_PACKAGE
import PowerWatchCore
#endif

private struct StatusMenuSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct StatusMenuContent: View {
    @ObservedObject var model: AppModel
    var onNavigate: () -> Void
    var onSize: (CGSize) -> Void
    var body: some View {
        QuickMenu(model: model, onNavigate: onNavigate)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: StatusMenuSizeKey.self, value: geometry.size)
            })
            .onPreferenceChange(StatusMenuSizeKey.self, perform: onSize)
    }
}

/// A compact native status item avoids depending on SwiftUI's custom label bridging.
@MainActor final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private weak var model: AppModel?
    private var subscriptions = Set<AnyCancellable>()
    private var requestedSize = CGSize.zero

    init(model: AppModel) {
        self.model = model
        // AppKit's autosaved position is measured from the right edge. On a
        // crowded or notched menu bar, its default leftmost position can be
        // hidden behind the app menus. Seed only the first placement; after a
        // user moves the item, AppKit's saved position is left untouched.
        let positionKey = "NSStatusItem Preferred Position YooTrackStatus"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(300, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.autosaveName = NSStatusItem.AutosaveName("YooTrackStatus")
        statusItem.isVisible = true
        if let button = statusItem.button {
            let icon = (YooTrackBrand.mark.copy() as? NSImage) ?? YooTrackBrand.mark
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            button.image = icon
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityIdentifier("yootrack.status-item")
            button.setAccessibilityLabel("YooTrack")
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        Publishers.CombineLatest(model.$sample, model.$paused)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateDescription() }
            .store(in: &subscriptions)
        updateDescription()
        runFixtureProbeIfRequested()
    }

    private func updateDescription() {
        guard let model, let button = statusItem.button else { return }
        button.toolTip = "YooTrack · " + model.menuLabel
        button.setAccessibilityLabel("YooTrack · " + model.menuLabel)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender); return }
        guard let model, let button = statusItem.button, button.window != nil else { return }
        requestedSize = .zero
        let content = StatusMenuContent(model: model, onNavigate: { [weak self] in self?.popover.performClose(nil) }, onSize: { [weak self] size in
            guard size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.resizePopover(size) }
        })
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 520, height: 500)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func resizePopover(_ size: CGSize) {
        let maxHeight = max(200, (statusItem.button?.window?.screen?.visibleFrame.height ?? 800) - 40)
        let next = CGSize(width: size.width, height: min(size.height, maxHeight))
        guard abs(next.width - requestedSize.width) > 0.5 || abs(next.height - requestedSize.height) > 0.5 else { return }
        requestedSize = next
        popover.contentSize = next
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    private func runFixtureProbeIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--ui-testing"), let index = arguments.firstIndex(of: "--status-probe"), arguments.indices.contains(index + 1) else { return }
        let url = URL(fileURLWithPath: arguments[index + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            button.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                let frame = button.window?.frame ?? .zero
                let screen = button.window?.screen?.frame ?? .zero
                let rightArea = button.window?.screen?.auxiliaryTopRightArea ?? .zero
                let data: [String: Any] = ["statusItemVisible": self.statusItem.isVisible,
                    "statusWindowVisible": button.window?.isVisible ?? false, "popoverShown": self.popover.isShown,
                    "statusX": frame.origin.x, "statusY": frame.origin.y, "statusWidth": frame.width, "statusHeight": frame.height,
                    "screenX": screen.origin.x, "screenY": screen.origin.y, "screenWidth": screen.width, "screenHeight": screen.height,
                    "rightAreaX": rightArea.origin.x, "rightAreaWidth": rightArea.width]
                if let json = try? JSONSerialization.data(withJSONObject: data, options: .sortedKeys) { try? json.write(to: url, options: .atomic) }
            }
        }
    }
}
