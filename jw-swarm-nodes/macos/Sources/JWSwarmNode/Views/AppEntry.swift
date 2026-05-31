import Foundation
import SwiftUI

@main
struct JWSwarmNodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        MenuBarExtra("JW Swarm", systemImage: "network") { NodeMenuView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NodeCoordinator.shared.start(config: ConfigManager.shared.config)
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
            NodeCoordinator.shared.handleInbound(text)
        }
        self.tunnel?.startLoop()
        self.status = "Connecting..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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