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
        Task { await NodeCoordinator.shared.start(config: ConfigManager.shared.config) }
    }
}

final class NodeCoordinator: ObservableObject {
    static let shared = NodeCoordinator()
    @Published var status: String = "Disconnected"
    @Published var readyModels: [String] = []
    @Published var isAwake: Bool = true

    nonisolated(unsafe) private var tunnel: Tunnel?
    nonisolated(unsafe) private var config: AppConfig?
    nonisolated(unsafe) private let backend = StubBackend()
    nonisolated(unsafe) private var heartbeatTask: Task<Void, Never>?

    func start(config: AppConfig) async {
        self.config = config
        guard let fleetURL = URL(string: config.fleet_url) else {
            status = "Invalid fleet URL"; return
        }
        tunnel = Tunnel(fleetURL: fleetURL)
        tunnel?.setIncomingHandler { @MainActor [weak self] text in
            self?.handleInbound(text)
        }
        tunnel?.start()
        status = "Connecting..."
        try? await Task.sleep(nanoseconds: 500_000_000)
        sendRegister()
        sendCatalogRequest()
        heartbeatTask = Task {
            while !Task.isCancelled {
                sendHeartbeat()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func sendRegister() {
        guard let c = config, let t = tunnel else { return }
        let m = collectMetrics()
        let gpu = GpuInfo(vendor: .apple, name: "Apple Silicon", vram_mb: m.totalMB)
        let lim = OwnerLimits(gpu_power_pct: c.limits.gpu_power_pct, memory_limit_mb: c.limits.memory_limit_mb)
        let payload = RegisterPayload(node_id: c.node_id, hostname: c.hostname, os: .macos,
                                       gpu: gpu, limits: lim, selected_models: c.selected_models)
        do {
            let json = try PayloadType.register(payload).toJSON()
            t.send(json)
            status = "Registered"
        } catch { NSLog("Register failed: \(error)") }
    }

    private func sendCatalogRequest() {
        guard let t = tunnel else { return }
        do {
            let json = try PayloadType.catalogRequest.toJSON()
            t.send(json)
        } catch { NSLog("CatalogRequest failed: \(error)") }
    }

    private func sendHeartbeat() {
        guard let c = config, let t = tunnel else { return }
        let m = collectMetrics()
        let met = NodeMetrics(vram_used_mb: m.usedMB, vram_total_mb: m.totalMB,
                              gpu_util_pct: m.gpuPct, tps: 0, latency_ms: 0, in_flight: 0)
        let hb = HeartbeatPayload(node_id: c.node_id, metrics: met,
                                   schedule_state: isAwake ? .awake : .asleep)
        do {
            let json = try PayloadType.heartbeat(hb).toJSON()
            t.send(json)
        } catch { NSLog("Heartbeat failed: \(error)") }
    }

    private func updateReadyModels() {
        let models = backend.ready()
        readyModels = models
        guard let c = config, let t = tunnel else { return }
        let ms = ModelStatusPayload(node_id: c.node_id, ready_models: models)
        do {
            let json = try PayloadType.modelStatus(ms).toJSON()
            t.send(json)
        } catch { NSLog("ModelStatus failed: \(error)") }
    }

    @MainActor
    private func handleInbound(_ text: String) {
        guard let msg = try? PayloadType.fromJSON(text) else { return }
        switch msg {
        case .catalogResponse(let cr):
            handleCatalog(cr)
        case .promptDispatch(let pd):
            backend.dispatch(pd) { [weak self] json in self?.tunnel?.send(json) }
        case .error(let e):
            NSLog("Server error \(e.request_id): \(e.message)")
        default: break
        }
    }

    private func handleCatalog(_ cr: CatalogResponsePayload) {
        let count = cr.models.count
        status = "Catalog: \(count) models"
        let sel = config?.selected_models
        let toDownload: [CatalogModel] =
            (sel?.isEmpty == false) ? cr.models.filter { sel!.contains($0.id) } : cr.models
        Task.detached { [weak self, toDownload] in
            for model in toDownload {
                do {
                    try await ModelDownloader.shared.downloadModel(model)
                    await self?.backend.register(model.id)
                } catch {
                    NSLog("Download \(model.id) failed: \(error)")
                }
                await self?.updateReadyModels()
            }
        }
    }
}
