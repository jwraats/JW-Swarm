import AppKit
import Foundation

// Pure AppKit entry point. A menu-bar-only agent works far more reliably with a
// plain NSApplication run loop than with the SwiftUI `App`/`Settings` scene,
// especially when launched as a bare binary via `swift run` (no app bundle or
// Info.plist). This guarantees the status-bar menu is created and interactive.
@main
enum JWSwarmNodeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        // Retain the delegate for the lifetime of the process.
        app.delegate = delegate
        AppDelegate.retained = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var retained: AppDelegate?

    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?

    private let statusMenuItem = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
    private let modelsMenuItem = NSMenuItem(title: "Models: -", action: nil, keyEquivalent: "")
    private let awakeMenuItem = NSMenuItem(title: "Awake", action: #selector(toggleAwake), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        NodeCoordinator.shared.start(config: ConfigManager.shared.config)

        // Keep menu labels in sync with runtime state.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMenuState()
        }
        updateMenuState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenuState()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            if let icon = Self.menuBarIcon() {
                button.image = icon
                button.imagePosition = .imageOnly
            } else {
                // Fallback so the item is never invisible if the asset is missing.
                button.title = "JW Swarm"
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        statusMenuItem.isEnabled = false
        modelsMenuItem.isEnabled = false

        awakeMenuItem.target = self
        awakeMenuItem.state = .on

        let openConfig = NSMenuItem(title: "Open Config Folder", action: #selector(openConfigFolder), keyEquivalent: "")
        openConfig.target = self

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(modelsMenuItem)
        menu.addItem(.separator())
        menu.addItem(awakeMenuItem)
        menu.addItem(openConfig)
        menu.addItem(.separator())
        menu.addItem(quit)

        item.menu = menu
    }

    /// Loads the menu-bar icon and configures it as a template image so macOS
    /// tints it correctly for light/dark menu bars. Sized to standard menu-bar
    /// height (~18pt).
    private static func menuBarIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "JWMenuBar", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        let target: CGFloat = 18
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        image.size = NSSize(width: target * aspect, height: target)
        image.isTemplate = true
        return image
    }

    private func updateMenuState() {
        let coordinator = NodeCoordinator.shared
        statusMenuItem.title = "Status: \(coordinator.status)"
        if coordinator.readyModels.isEmpty {
            modelsMenuItem.title = "Models: -"
        } else {
            modelsMenuItem.title = "Models: \(coordinator.readyModels.joined(separator: ", "))"
        }
        awakeMenuItem.state = coordinator.isAwake ? .on : .off
    }

    @objc
    private func toggleAwake() {
        NodeCoordinator.shared.isAwake.toggle()
        updateMenuState()
    }

    @objc
    private func openConfigFolder() {
        let dir = ConfigManager.shared.dataDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

class NodeCoordinator: @unchecked Sendable {
    static let shared = NodeCoordinator()
    var status: String = "Disconnected"
    var readyModels: [String] = []
    var isAwake: Bool = true

    private var tunnel: Tunnel?
    private var config: AppConfig?
    private let backend = StubBackend()
    private var heartbeatTask: Task<Void, Never>?

    func start(config: AppConfig) {
        self.config = config
        guard let fleetURL = URL(string: config.fleet_url) else {
            self.status = "Invalid fleet URL"
            return
        }
        self.tunnel = Tunnel(fleetURL)
        self.tunnel?.setIncomingHandler { text in
            Task { @MainActor in
                NodeCoordinator.shared.handleInbound(text)
            }
        }
        self.tunnel?.startLoop()
        self.status = "Connecting..."
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            NodeCoordinator.shared.doSendRegister()
            NodeCoordinator.shared.doSendCatalogRequest()
        }
        self.heartbeatTask = Task {
            while !Task.isCancelled {
                NodeCoordinator.shared.doSendHeartbeat()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func doSendRegister() {
        guard let c = config, let t = tunnel else { return }
        let m = collectMetrics()
        let gpu = GpuInfo(vendor: .apple, name: "Apple Silicon", vram_mb: m.totalMB)
        let lim = OwnerLimits(gpu_power_pct: c.limits.gpu_power_pct, memory_limit_mb: c.limits.memory_limit_mb)
        let payload = RegisterPayload(node_id: c.node_id, hostname: c.hostname, os: .macos,
                                       gpu: gpu, limits: lim, selected_models: c.selected_models)
        do {
            let json = try PayloadType.register(payload).toJSON()
            t.send(json)
            self.status = "Registered"
        } catch { NSLog("Register failed: \(error)") }
    }

    private func doSendCatalogRequest() {
        guard let t = tunnel else { return }
        do {
            let json = try PayloadType.catalogRequest.toJSON()
            t.send(json)
        } catch { NSLog("CatalogRequest failed: \(error)") }
    }

    private func doSendHeartbeat() {
        guard let c = config, let t = tunnel else { return }
        let m = collectMetrics()
        let met = NodeMetrics(vram_used_mb: m.usedMB, vram_total_mb: m.totalMB,
                              gpu_util_pct: m.gpuPct, tps: 0, latency_ms: 0, in_flight: 0)
        let hb = HeartbeatPayload(node_id: c.node_id, metrics: met,
                                   schedule_state: .awake)
        do {
            let json = try PayloadType.heartbeat(hb).toJSON()
            t.send(json)
        } catch { NSLog("Heartbeat failed: \(error)") }
    }

    private func doUpdateReadyModels() {
        let models = backend.ready()
        self.readyModels = models
        guard let c = config, let t = tunnel else { return }
        let ms = ModelStatusPayload(node_id: c.node_id, ready_models: models)
        do {
            let json = try PayloadType.modelStatus(ms).toJSON()
            t.send(json)
        } catch { NSLog("ModelStatus failed: \(error)") }
    }

    private func handleInbound(_ text: String) {
        guard let msg = try? PayloadType.fromJSON(text) else { return }
        switch msg {
        case .catalogResponse(let cr): handleCatalog(cr)
        case .promptDispatch(let pd):
            self.backend.dispatch(pd) { json in
                NodeCoordinator.shared.tunnel?.send(json)
            }
        case .error(let e):
            NSLog("Server error \(e.request_id): \(e.message)")
        default: break
        }
    }

    private func handleCatalog(_ cr: CatalogResponsePayload) {
        let sel = config?.selected_models
        let toDownload: [CatalogModel] =
            (sel?.isEmpty == false) ? cr.models.filter { sel!.contains($0.id) } : cr.models
        self.status = "Catalog: \(toDownload.count) models"
        Task.detached { [toDownload] in
            for model in toDownload {
                do {
                    try await ModelDownloader.shared.downloadModel(model)
                    NodeCoordinator.shared.backend.register(model.id)
                    NodeCoordinator.shared.doUpdateReadyModels()
                } catch {
                    NSLog("Download \(model.id) failed: \(error)")
                    NodeCoordinator.shared.doUpdateReadyModels()
                }
            }
        }
    }
}