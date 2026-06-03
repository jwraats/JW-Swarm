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
    private let tunnelMenuItem = NSMenuItem(title: "Tunnel: Disconnected", action: nil, keyEquivalent: "")
    private let modelsMenuItem = NSMenuItem(title: "Models: -", action: nil, keyEquivalent: "")
    private let reconnectMenuItem = NSMenuItem(title: "Reconnect Tunnel", action: #selector(reconnectTunnel), keyEquivalent: "")
    private let disconnectMenuItem = NSMenuItem(title: "Disconnect Tunnel", action: #selector(disconnectTunnel), keyEquivalent: "")
    private let awakeMenuItem = NSMenuItem(title: "Awake", action: #selector(toggleAwake), keyEquivalent: "")
    private var configWindowController: ConfigWindowController?

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
        tunnelMenuItem.isEnabled = false
        modelsMenuItem.isEnabled = false

        reconnectMenuItem.target = self
        disconnectMenuItem.target = self

        awakeMenuItem.target = self
        awakeMenuItem.state = .on

        let openConfig = NSMenuItem(title: "Open Config Folder", action: #selector(openConfigFolder), keyEquivalent: "")
        openConfig.target = self

        let openConfigWindow = NSMenuItem(title: "Configuration...", action: #selector(openConfigurationWindow), keyEquivalent: ",")
        openConfigWindow.target = self

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(tunnelMenuItem)
        menu.addItem(modelsMenuItem)
        menu.addItem(.separator())
        menu.addItem(reconnectMenuItem)
        menu.addItem(disconnectMenuItem)
        menu.addItem(awakeMenuItem)
        menu.addItem(openConfigWindow)
        menu.addItem(openConfig)
        menu.addItem(.separator())
        menu.addItem(quit)

        item.menu = menu
    }

    /// Loads the menu-bar icon and configures it as a template image so macOS
    /// tints it correctly for light/dark menu bars. Sized to standard menu-bar
    /// height (~18pt).
    private static func menuBarIcon() -> NSImage? {
        let bundleCandidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("JWSwarmNode_JWSwarmNode.bundle"),
            Bundle.main.resourceURL?.appendingPathComponent("JWSwarmNode_JWSwarmNode.bundle"),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("JWSwarmNode_JWSwarmNode.bundle"),
        ].compactMap { $0 }

        var iconURL: URL?
        for bundleURL in bundleCandidates {
            guard let bundle = Bundle(url: bundleURL) else { continue }
            if let u = bundle.url(forResource: "JWMenuBar", withExtension: "svg") {
                iconURL = u
                break
            }
        }

        guard let iconURL, let image = NSImage(contentsOf: iconURL) else {
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

        let tunnelConnected = coordinator.isTunnelConnected
        let tunnelText = "Tunnel: " + (tunnelConnected ? "Connected" : "Disconnected")
        let tunnelColor: NSColor = tunnelConnected ? .systemGreen : .secondaryLabelColor
        tunnelMenuItem.attributedTitle = NSAttributedString(
            string: tunnelText,
            attributes: [.foregroundColor: tunnelColor]
        )

        if coordinator.readyModels.isEmpty {
            modelsMenuItem.title = "Models: -"
        } else {
            modelsMenuItem.title = "Models: \(coordinator.readyModels.joined(separator: ", "))"
        }

        reconnectMenuItem.isEnabled = true
        disconnectMenuItem.isEnabled = coordinator.canDisconnectTunnel
        awakeMenuItem.state = coordinator.isAwake ? .on : .off
    }

    @objc
    private func toggleAwake() {
        NodeCoordinator.shared.isAwake.toggle()
        updateMenuState()
    }

    @objc
    private func reconnectTunnel() {
        NodeCoordinator.shared.reconnectTunnel()
        updateMenuState()
    }

    @objc
    private func disconnectTunnel() {
        NodeCoordinator.shared.disconnectTunnel()
        updateMenuState()
    }

    @objc
    private func openConfigFolder() {
        let dir = ConfigManager.shared.dataDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc
    private func openConfigurationWindow() {
        if configWindowController == nil {
            configWindowController = ConfigWindowController()
            configWindowController?.onSave = { [weak self] updated in
                NodeCoordinator.shared.applyConfig(updated)
                self?.updateMenuState()
            }
        }
        configWindowController?.showWindowAndActivate()
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
    var isTunnelConnected: Bool = false
    var canDisconnectTunnel: Bool { tunnel != nil }

    private var tunnel: Tunnel?
    private var config: AppConfig?
    private var maintainTunnel: Bool = true
    private let backend = LlamaBackend(memoryLimitMB: ConfigManager.shared.config.limits.memory_limit_mb)
    private var heartbeatTask: Task<Void, Never>?
    private var catalogPollTask: Task<Void, Never>?
    private var downloadingModels: Set<String> = []

    func start(config: AppConfig) {
        self.maintainTunnel = true
        self.config = config
        self.backend.updateMemoryLimitMB(config.limits.memory_limit_mb)
        guard URL(string: config.fleet_url) != nil else {
            self.status = "Invalid fleet URL"
            return
        }
        self.startOrRestartTunnel()
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

        self.catalogPollTask?.cancel()
        self.catalogPollTask = Task {
            while !Task.isCancelled {
                if NodeCoordinator.shared.isTunnelConnected && NodeCoordinator.shared.readyModels.isEmpty {
                    NodeCoordinator.shared.doSendCatalogRequest()
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func applyConfig(_ updated: AppConfig) {
        let old = self.config
        self.config = updated
        self.backend.updateMemoryLimitMB(updated.limits.memory_limit_mb)

        let needsReconnect =
            old?.fleet_url != updated.fleet_url ||
            old?.node_cert != updated.node_cert ||
            old?.ca_cert != updated.ca_cert
        if needsReconnect {
            self.startOrRestartTunnel()
        }

        self.doSendRegister()
        self.doSendCatalogRequest()
    }

    func reconnectTunnel() {
        maintainTunnel = true
        startOrRestartTunnel()
    }

    func disconnectTunnel() {
        maintainTunnel = false
        tunnel?.stop()
        tunnel = nil
        isTunnelConnected = false
        catalogPollTask?.cancel()
        catalogPollTask = nil
        status = "Disconnected"
    }

    private func startOrRestartTunnel() {
        guard maintainTunnel else {
            return
        }
        guard let c = config, let fleetURL = URL(string: c.fleet_url) else {
            self.status = "Invalid fleet URL"
            return
        }

        self.tunnel?.stop()
        self.isTunnelConnected = false

        let t = Tunnel(fleetURL, nodeCertPath: c.node_cert, caCertPath: c.ca_cert)
        t.setConnectionStateHandler { connected in
            DispatchQueue.main.async {
                NodeCoordinator.shared.isTunnelConnected = connected
                if connected {
                    NodeCoordinator.shared.status = "Tunnel connected"
                    NodeCoordinator.shared.doSendRegister()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        NodeCoordinator.shared.doSendCatalogRequest()
                    }
                    NodeCoordinator.shared.doSendHeartbeat()
                    NodeCoordinator.shared.doUpdateReadyModels()
                } else if NodeCoordinator.shared.maintainTunnel {
                    NodeCoordinator.shared.status = "Reconnecting..."
                } else {
                    NodeCoordinator.shared.status = "Disconnected"
                }
            }
        }
        t.setIncomingHandler { text in
            Task { @MainActor in
                NodeCoordinator.shared.handleInbound(text)
            }
        }
        t.startLoop()

        self.tunnel = t
        self.status = "Connecting..."
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
            NSLog("[Node] Register sent (node_id=\(c.node_id), selected_models=\(c.selected_models.joined(separator: ",")))")
            if self.isTunnelConnected {
                self.status = "Registered"
            }
        } catch { NSLog("Register failed: \(error)") }
    }

    private func doSendCatalogRequest() {
        guard let t = tunnel else { return }
        do {
            let json = try PayloadType.catalogRequest.toJSON()
            t.send(json)
            NSLog("[Node] CatalogRequest sent")
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
            NSLog("[Node] ModelStatus sent: \(models)")
        } catch { NSLog("ModelStatus failed: \(error)") }
    }

    private func handleInbound(_ text: String) {
        let msg: PayloadType
        do {
            msg = try PayloadType.fromJSON(text)
        } catch {
            let details: String
            if let de = error as? DecodingError {
                details = String(describing: de)
            } else {
                details = error.localizedDescription
            }
            let preview = String(text.prefix(2000)).replacingOccurrences(of: "\n", with: "\\n")
            NSLog("[Node] inbound decode failed: \(details) payload=\(preview)")
            return
        }
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
        NSLog("[Node] CatalogResponse received: \(cr.models.count) models")
        let sel = config?.selected_models
        let requested: [CatalogModel] =
            (sel?.isEmpty == false) ? cr.models.filter { sel!.contains($0.id) } : cr.models
        let supported = requested.filter { $0.backend == .llama_cpp }
        let unsupported = requested.filter { $0.backend != .llama_cpp }

        NSLog("[Node] Catalog filtered: requested=\(requested.count), supported=\(supported.count), unsupported=\(unsupported.count)")

        for model in unsupported {
            NSLog("Skipping \(model.id): backend \(model.backend.rawValue) is not supported by the current macOS node")
        }

        self.status = unsupported.isEmpty
            ? "Catalog: \(supported.count) models"
            : "Catalog: \(supported.count) supported, \(unsupported.count) unsupported"

        Task.detached { [supported] in
            for model in supported {
                let shouldStart = await MainActor.run { () -> Bool in
                    if NodeCoordinator.shared.readyModels.contains(model.id) {
                        return false
                    }
                    if NodeCoordinator.shared.downloadingModels.contains(model.id) {
                        return false
                    }
                    NodeCoordinator.shared.downloadingModels.insert(model.id)
                    return true
                }
                if !shouldStart {
                    continue
                }

                do {
                    NSLog("[Node] Download start: \(model.id)")
                    try await ModelDownloader.shared.downloadModel(model)
                    NSLog("[Node] Download ready: \(model.id)")
                    _ = await MainActor.run {
                        NodeCoordinator.shared.downloadingModels.remove(model.id)
                    }
                    NodeCoordinator.shared.backend.register(model.id)
                    NodeCoordinator.shared.doUpdateReadyModels()
                } catch {
                    _ = await MainActor.run {
                        NodeCoordinator.shared.downloadingModels.remove(model.id)
                    }
                    NSLog("Download \(model.id) failed: \(error)")
                    NodeCoordinator.shared.doUpdateReadyModels()
                }
            }
        }
    }
}