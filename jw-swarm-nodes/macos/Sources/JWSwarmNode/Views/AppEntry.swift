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

final class NodeCoordinator: ObservableObject, @unchecked Sendable {
    static let shared = NodeCoordinator()
    @Published var status: String = "Disconnected"
    @Published var readyModels: [String] = []
    @Published var isAwake: Bool = true

    private var tunnel: Tunnel?
    private var config: AppConfig?
    private let backend = StubBackend()
    private var heartbeatTimer: Timer?

    @MainActor
    func start(config: AppConfig) {
        self.config = config
        guard let fleetURL = URL(string: config.fleet_url) else {
            status = "Invalid fleet URL"; return
        }
        tunnel = Tunnel(fleetURL: fleetURL, certPath: config.node_cert, caPath: config.ca_cert)
        tunnel?.setIncomingHandler { [weak self] text in self?.handleInbound(text) }
        tunnel?.start()
        status = "Connecting..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendRegister(); self?.sendCatalogRequest()
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
    }

    @MainActor
    private func sendRegister() {
        guard let c = config, let t = tunnel else { return }
        let m = collectMetrics()
        let gpu = GpuInfo(vendor: .apple, name: m.name, vram_mb: m.totalMB)
        let lim = OwnerLimits(gpu_power_pct: c.limits.gpu_power_pct,
                              memory_limit_mb: c.limits.memory_limit_mb)
        let payload = RegisterPayload(node_id: c.node_id, hostname: c.hostname, os: .macos,
                                      gpu: gpu, limits: lim,
                                      selected_models: c.selected_models)
        do { let json = try PayloadType.register(payload).toJSON(); t.send(json); status = "Registered" }
        catch { NSLog("Register failed: \(error)") }
    }

    @MainActor
    private func sendCatalogRequest() {
        guard let t = tunnel else { return }
        do { let json = try PayloadType.catalogRequest.toJSON(); t.send(json) }
        catch { NSLog("CatalogRequest failed: \(error)") }
    }

    @MainActor
    private func sendHeartbeat() {
        guard let c = config, let t = tunnel else { return }
        let m = collectMetrics()
        let metrics = NodeMetrics(vram_used_mb: m.usedMB, vram_total_mb: m.totalMB,
                                  gpu_util_pct: m.gpuPct, tps: 0, latency_ms: 0, in_flight: 0)
        let hb = HeartbeatPayload(node_id: c.node_id, metrics: metrics,
                                  schedule_state: isAwake ? .awake : .asleep)
        do { let json = try PayloadType.heartbeat(hb).toJSON(); t.send(json) }
        catch { NSLog("Heartbeat failed: \(error)") }
    }

    @MainActor
    private func updateReadyModels() {
        readyModels = backend.ready()
        guard let c = config, let t = tunnel else { return }
        let ms = ModelStatusPayload(node_id: c.node_id, ready_models: readyModels)
        do { let json = try PayloadType.modelStatus(ms).toJSON(); t.send(json) }
        catch { NSLog("ModelStatus failed: \(error)") }
    }

    @MainActor
    private func handleInbound(_ text: String) {
        guard let msg = try? PayloadType.fromJSON(text) else { return }
        switch msg {
        case .catalogResponse(let cr): handleCatalog(cr)
        case .promptDispatch(let pd):
            backend.dispatch(pd) { [weak self] json in self?.tunnel?.send(json) }
        case .error(let e): NSLog("Server error \(e.request_id): \(e.message)")
        default: break
        }
    }

    @MainActor
    private func handleCatalog(_ cr: CatalogResponsePayload) {
        status = "Catalog: \(cr.models.count) models"
        let toDownload = config?.selected_models.isEmpty == false
            ? cr.models.filter { config!.selected_models.contains($0.id) }
            : cr.models
        Task.detached { [weak self, toDownload] in
            for model in toDownload {
                do { try await ModelDownloader.shared.downloadModel(model); self?.backend.register(model.id) }
                catch { NSLog("Download \(model.id) failed: \(error)") }
                await self?.updateReadyModels()
            }
        }
    }
}
