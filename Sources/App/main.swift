import AppKit
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var panel: FloatingPanel!
    private var hosting: ClickThroughHostingView<PanelView>!
    private var statusItem: NSStatusItem!
    private var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        buildPanel()
        buildStatusItem()
        store.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleResize()
                self?.scheduleStatusItemUpdate()
            }
            .store(in: &bag)
        store.start()
    }

    private func buildPanel() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        applyCaptureSetting()

        hosting = ClickThroughHostingView(rootView: PanelView(store: store))
        panel.contentView = hosting

        if !panel.setFrameUsingName("DekhrekhPanel"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - 316, y: f.maxY - 16))
        }
        panel.setFrameAutosaveName("DekhrekhPanel")
        resizeKeepingTop()
        keepOnScreen()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resizeKeepingTop() }
        }
    }

    /// A saved position on a display that has since been unplugged leaves the panel invisible;
    /// move it to the top-right of the main screen when it no longer overlaps any screen.
    private func keepOnScreen() {
        let frame = panel.frame
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 40, dy: 40)) }
        guard !visible, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - frame.width - 16, y: f.maxY - 16))
        resizeKeepingTop()
    }

    private func scheduleResize() {
        DispatchQueue.main.async { [weak self] in self?.resizeKeepingTop() }
    }

    private func resizeKeepingTop() {
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let cap = max(screenFrame.height - Config.panelScreenMargin * 2 - Config.panelHeaderHeight, 120)
        if abs(store.maxBodyHeight - cap) > 0.5 {
            store.maxBodyHeight = cap
            return  // the change re-renders the view and schedules another resize
        }
        let size = hosting.fittingSize
        let frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let top = min(frame.maxY, visible.maxY)
        let x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        panel.setFrame(NSRect(x: x, y: max(top - size.height, visible.minY), width: size.width, height: size.height),
                       display: true)
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(item("Show / Hide Panel", #selector(togglePanel), "l"))
        menu.addItem(item("Compact", #selector(toggleCompact), "c"))
        menu.addItem(item("Sound Alerts", #selector(toggleSound), "s"))
        menu.addItem(item("Hide from Screenshots", #selector(toggleCapture), "h"))
        menu.addItem(item("Refresh Now", #selector(refreshNow), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(Config.appName)", #selector(quit), "q"))
        statusItem.menu = menu
        updateStatusItem()
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func scheduleStatusItemUpdate() {
        DispatchQueue.main.async { [weak self] in self?.updateStatusItem() }
    }

    private func updateStatusItem() {
        let counts = [
            store.failureCount > 0 ? "\(store.failureCount) CI" : nil,
            store.waitingCount > 0 ? "\(store.waitingCount) waiting" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        statusItem.button?.image = menuBarIcon(store.attention)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.attributedTitle = NSAttributedString(
            string: counts.isEmpty ? "" : " " + counts,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        )
        statusItem.menu?.items.first { $0.action == #selector(toggleCompact) }?.state = store.compact ? .on : .off
        statusItem.menu?.items.first { $0.action == #selector(toggleSound) }?.state = store.soundOn ? .on : .off
        statusItem.menu?.items.first { $0.action == #selector(toggleCapture) }?.state = store.hideFromCapture ? .on : .off
    }

    /// Calm: a template image, so it matches the other menu bar icons in light and dark.
    /// Otherwise tinted, so it stands out.
    private func menuBarIcon(_ attention: Attention) -> NSImage? {
        let base = NSImage(systemSymbolName: Config.iconSymbol, accessibilityDescription: Config.appName)
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard attention != .calm else {
            let img = base?.withSymbolConfiguration(size)
            img?.isTemplate = true
            return img
        }
        let tint: NSColor = attention == .alert ? .systemRed : .systemOrange
        return base?.withSymbolConfiguration(size.applying(.init(paletteColors: [tint])))
    }

    @objc private func togglePanel() {
        panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    @objc private func toggleCompact() { store.compact.toggle() }
    @objc private func toggleSound() { store.soundOn.toggle() }

    @objc private func toggleCapture() {
        store.hideFromCapture.toggle()
        applyCaptureSetting()
    }

    private func applyCaptureSetting() {
        panel.sharingType = store.hideFromCapture ? .none : .readOnly
    }

    @objc private func refreshNow() {
        store.refreshLocal()
        store.refreshCI()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
