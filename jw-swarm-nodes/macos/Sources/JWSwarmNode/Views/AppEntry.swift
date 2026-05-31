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

final class NodeCoordinator: ObservableObject {
    static let shared = NodeCoordinator()
    @Published var status: String = "Disconnected"
    @Published var readyModels: [String] = []
    @Published var isAwake: Bool = true

    nonisolated var _tunnel: Tunnel? = nil
    nonisolated var _config: AppConfig? = nil
    private let backend: StubBackend = StubBackend()
    private var heartbeatTimer: Timer?
    nonisolated private let syncQ = DispatchQueue(label: "com.jwswarm.sync")

    func start(config: AppConfig) {
        _config = config
        guard let fleetURL = URL(string: config.fleet_url) else {
            DispatchQueue.main.async { self.status = "Invalid fleet URL" }; return
        }
        _tunnel = Tunnel(fleetURL: fleetURL)
        _tunnel?.setIncomingHandler { [weak self] text in self?.handleInbound(text) }
        _tunnel?.start()
        DispatchQueue.main.async { self.status = "Connecting..." }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.syncQ.async { self?.doSendRegister() }
            self?.syncQ.async { self?.doSendCatalogRequest() }
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.syncQ.async { self?.doSendHeartbeat() }
        }
    }

    nonisolated private func doSendRegister() {
        guard let c = _config, let t = _tunnel else { return }
        let m = collectMetrics()
        let gpu = GpuInfo(vendor: .apple, name: "Apple Silicon", vram_mb: m.totalMB)
        let lim = OwnerLimits(gpu_power_pct: c.limits.gpu_power_pct, memory_limit_mb: c.limits.memory_limit_mb)
        let payload = RegisterPayload(node_id: c.node_id, hostname: c.hostname, os: .macos,
                                       gpu: gpu, limits: lim, selected_models: c.selected_models)
        do {
            let json = try PayloadType.register(payload).toJSON()
            t.sendSync(json)
            DispatchQueue.main.async { self.status = "Registered" }
        } catch { NSLog("Register failed: \(error)") }
    }

    nonisolated private func doSendCatalogRequest() {
        guard let t = _tunnel else { return }
        do {
            let json = try PayloadType.catalogRequest.toJSON()
            t.sendSync(json)
        } catch { NSLog("CatalogRequest failed: \(error)") }
    }

    nonisolated private func doSendHeartbeat() {
        guard let c = _config, let t = _tunnel else { return }
        let m = collectMetrics()
        let met = NodeMetrics(vram_used_mb: m.usedMB, vram_total_mb: m.totalMB,
                              gpu_util_pct: m.gpuPct, tps: 0, latency_ms: 0, in_flight: 0)
        let hb = HeartbeatPayload(node_id: c.node_id, metrics: met,
                                   schedule_state: .awake)
        do {
            let json = try PayloadType.heartbeat(hb).toJSON()
            t.sendSync(json)
        } catch { NSLog("Heartbeat failed: \(error)") }
    }

    nonisolated private func doUpdateReadyModels() {
        let models = backend.ready()
        DispatchQueue.main.async { self.readyModels = models }
        guard let c = _config, let t = _tunnel else { return }
        let ms = ModelStatusPayload(node_id: c.node_id, ready_models: models)
        do {
            let json = try PayloadType.modelStatus(ms).toJSON()
            t.sendSync(json)
        } catch { NSLog("ModelStatus failed: \(error)") }
    }

    nonisolated private func handleInbound(_ text: String) {
        guard let msg = try? PayloadType.fromJSON(text) else { return }
        switch msg {
        case .catalogResponse(let cr): handleCatalog(cr)
        case .promptDispatch(let pd):
            backend.dispatch(pd) { [weak self] json in self?._tunnel?.sendSync(json) }
        case .error(let e):
            NSLog("Server error \(e.request_id): \(e.message)")
        default: break
        }
    }

    nonisolated private func handleCatalog(_ cr: CatalogResponsePayload) {
        let count = cr.models.count
        DispatchQueue.main.async { self.status = "Catalog: \(count) models" }
        let sel = _config?.selected_models
        let toDownload: [CatalogModel] =
            (sel?.isEmpty == false) ? cr.models.filter { sel!.contains($0.id) } : cr.models
        Task.detached { [weak self, toDownload] in
            for model in toDownload {
                do {
                    try await ModelDownloader.shared.downloadModel(model)
                    self?.backend.register(model.id)
                } catch {
                    NSLog("Download \(model.id) failed: \(error)")
                }
                self?.doUpdateReadyModels()
            }
        }
    }
}
