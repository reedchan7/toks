import AppKit
import Combine
import SwiftUI

// Cross-shell UI requests (e.g. status item menu -> popover Settings view).
final class UIState: ObservableObject {
    @Published var showSettingsRequested = false
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let settings = SettingsStore()
    private let uiState = UIState()
    private var store: StatsStore!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var setupWindow: NSWindow?
    private let setupState = SetupState()
    private var cancellable: AnyCancellable?
    private var monitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = StatsStore(settings: settings)
        let root = ContentView(store: store, settings: settings, uiState: uiState)
            .frame(width: 300)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateTitle()
        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }

        #if DEBUG_WINDOW
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Toks Debug"
        window.contentViewController = NSHostingController(rootView: root)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        #else
        let popover = NSPopover()
        // .transient auto-closes on its own for .accessory apps once the popover
        // is made key; closing is handled explicitly via event monitors instead.
        popover.behavior = .applicationDefined
        popover.delegate = self
        let hosting = NSHostingController(rootView: root)
        // Track SwiftUI's ideal size, otherwise the popover is positioned using a
        // stale initial size and the arrow ends up floating below the menu bar.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover

        maybeShowSetup()
        #endif
    }

    // MARK: - First-launch setup

    private var collectorInstalled: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.reedchan.toks.collector.plist")
    }

    private func maybeShowSetup() {
        guard !collectorInstalled else { return }
        let view = SetupView(
            state: setupState,
            onInstall: { [weak self] in self?.runInstaller() },
            onQuit: { NSApp.terminate(nil) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Toks"
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        setupWindow = window
    }

    private func runInstaller() {
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            setupState.error = "install.sh is missing from the app bundle."
            return
        }
        setupState.installing = true
        setupState.error = nil
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        var env = ProcessInfo.processInfo.environment
        env["TOKS_SKIP_QUIT"] = "1" // the script's osascript quit would prompt for automation consent
        proc.environment = env
        proc.arguments = [script.path]
        proc.terminationHandler = { p in
            DispatchQueue.main.async { [weak self] in
                if p.terminationStatus == 0 {
                    // The installer already launched the installed copy.
                    NSApp.terminate(nil)
                } else {
                    self?.setupState.installing = false
                    self?.setupState.error =
                        "Install failed (exit \(p.terminationStatus)). Run scripts/install.sh from a terminal for details."
                }
            }
        }
        do {
            try proc.run()
        } catch {
            setupState.installing = false
            setupState.error = "Could not start the installer: \(error.localizedDescription)"
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === setupWindow { NSApp.terminate(nil) }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(under: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func showMenu(under button: NSStatusBarButton) {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            return i
        }
        menu.addItem(item("Refresh Now", #selector(refreshNow)))
        menu.addItem(item(store.paused ? "Resume Refresh" : "Pause Refresh", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(item("Quit Toks", #selector(quitToks)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func refreshNow() {
        store.refreshNow()
    }

    @objc private func togglePause() {
        store.setPaused(!store.paused)
        updateTitle()
    }

    @objc private func openSettings() {
        uiState.showSettingsRequested = true
        guard let popover, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        focusPopover()
        installMonitors()
    }

    @objc private func quitToks() {
        NSApp.terminate(nil)
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            focusPopover()
            installMonitors()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        removeMonitors()
    }

    // Explicit focus-loss close: .transient alone is unreliable for .accessory
    // apps once the popover window is made key.
    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel],
            handler: { [weak self] _ in self?.closePopover() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown],
            handler: { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.closePopover(); return nil } // Esc
                    return event
                }
                // Ignore clicks inside the popover or on the status item button;
                // the button's own action handles icon toggling.
                if let w = event.window,
                   w == self.popover?.contentViewController?.view.window
                    || w == self.statusItem?.button?.window { return event }
                self.closePopover()
                return event
            }) {
            monitors.append(m)
        }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    func popoverDidClose(_ notification: Notification) {
        removeMonitors()
        updateTitle()
    }

    // .accessory apps don't get a key window on their own; without this the
    // popover renders in the inactive (grayed) vibrancy state.
    private func focusPopover() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.popover?.contentViewController?.view.window?.makeKey()
        }
    }

    private var pauseIconShown = false

    private func updateTitle() {
        guard let button = statusItem?.button, let store else { return }
        // Plain title keeps the system's menu bar vibrancy coloring.
        // Dim only when the collector itself is down — idle agents overnight
        // are normal and must not gray out the item.
        button.title = store.menuTitle
        button.alphaValue = (store.readFailed || store.collectorStale) ? 0.5 : 1
        // Flipping the pause icon resizes the status item; defer it while the
        // popover is anchored to the button so the popover stays put.
        if popover?.isShown != true, store.paused != pauseIconShown {
            pauseIconShown = store.paused
            button.image = pauseIconShown
                ? NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Paused")
                : nil
        }
    }
}

final class SettingsStore: ObservableObject {
    @Published var settings: ToksSettings {
        didSet { save() }
    }

    init() {
        var s = (try? JSONDecoder().decode(ToksSettings.self, from: Data(contentsOf: settingsURL)))
            ?? .default
        // Sanitize: only known agents, all agents present, valid interval.
        s.order = s.order.filter { agentOrder.contains($0) } + agentOrder.filter { !s.order.contains($0) }
        s.hidden = s.hidden.filter { agentOrder.contains($0) }
        if ![1, 2, 5].contains(s.refreshSec) { s.refreshSec = 2 }
        settings = s
    }

    var visibleOrder: [String] {
        settings.order.filter { !settings.hidden.contains($0) }
    }

    func toggleHidden(_ key: String) {
        if let i = settings.hidden.firstIndex(of: key) {
            settings.hidden.remove(at: i)
        } else {
            settings.hidden.append(key)
        }
    }

    func applyVisibleOrder(_ visible: [String]) {
        settings.order = mergedOrder(order: settings.order, visible: visible)
    }

    private func save() {
        let dir = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic) // atomic = tmp + rename
    }
}

final class StatsStore: ObservableObject {
    @Published private(set) var stats: StatsFile?
    @Published private(set) var readFailed = false // file missing or undecodable
    @Published private(set) var now = Date()
    @Published private(set) var paused = false // display refresh frozen; collector keeps running

    private let settings: SettingsStore
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var cancellable: AnyCancellable?

    init(settings: SettingsStore) {
        self.settings = settings
        cancellable = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettings() }
        }
        reload()
        reschedule()
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value {
            timer?.invalidate()
            timer = nil
            interval = 0
        } else {
            reschedule()
        }
    }

    // Single-shot reload; does not resume a paused timer.
    func refreshNow() {
        now = Date()
        reload()
    }

    var firstVisibleKey: String {
        settings.visibleOrder.first ?? agentOrder[0]
    }

    // Decoded fine but the collector has not written for >10s.
    var collectorStale: Bool {
        guard let stats else { return false }
        return now.timeIntervalSince1970 * 1000 - Double(stats.updatedAt) > 10_000
    }

    var menuTitle: String {
        let name = shortNames[firstVisibleKey] ?? firstVisibleKey
        guard let last = stats?.agents[firstVisibleKey]?.last,
              let tps = last.tokPerSec else { return "\(name) — tok/s" }
        return "\(name) \(last.approx ? "~" : "")\(formatTps(tps)) tok/s"
    }

    private func applySettings() {
        objectWillChange.send()
        reschedule()
    }

    private func reschedule() {
        guard !paused else { return }
        let wanted = TimeInterval(settings.settings.refreshSec)
        guard wanted != interval else { return }
        interval = wanted
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
            self?.now = Date()
            self?.reload()
        }
    }

    private func reload() {
        do {
            let data = try Data(contentsOf: statsURL)
            stats = try JSONDecoder().decode(StatsFile.self, from: data)
            readFailed = false
        } catch {
            stats = nil
            readFailed = true
        }
    }
}
