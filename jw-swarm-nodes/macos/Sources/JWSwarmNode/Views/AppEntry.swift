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
        Task { @MainActor in
            await NodeCoordinator.shared.start(config: ConfigManager.shared.config)
        }
    }
}

@MainActor
final class NodeCoordinator: ObservableObject {
    static let shared = NodeCoordinator()
    @Published var status: String = "Disconnected"
    @Published var readyModels: [String] = []
    @Published var isAwake: Bool = true

    nonisolated(unsafe) private var tunnel: Tunnel?
    nonisolated(unsafe) private var config: AppConfig?
    nonisolated(unsafe) private var backend: StubBackend = StubBackend()
    nonisolated(unsafe) private var heartbeatTask: Task<Void, Never>?

    func start(config: AppConfig) async {
        nonisolated(unsafe) self.config = config
        guard let fleetURL = URL(string: config.fleet_url) else {
            nonisolated(unsafe) self.status = "Invalid fleet URL"; return
        }
        nonisolated(unsafe) self.tunnel = Tunnel(fleetURL)
        nonisolated(unsafe) self.tunnel?.setIncomingHandler { [weak self] text in
            self?.handleInbound(text)
        }
        nonisolated(unsafe) self.tunnel?.startLoop()
        nonisolated(unsafe) self.status = "Connecting..."
        try? await Task.sleep(nanoseconds: 500_000_000)
        await doSendRegister()
        await doSendCatalogRequest()
        nonisolated(unsafe) self.heartbeatTask = Task { @MainActor in
            for _ in 0..<1000 {
                await Self.shared.doSendHeartbeat()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    nonisolated private func doSendRegister() async {
        await MainActor.run {
            nonisolated(unsafe) let s = Self.shared
            guard let c = s.config, let t = s.tunnel else { return }
            let m = collectMetrics()
            let gpu = GpuInfo(vendor: .apple, name: "Apple Silicon", vram_mb: m.totalMB)
            let lim = OwnerLimits(gpu_power_pct: c.limits.gpu_power_pct, memory_limit_mb: c.limits.memory_limit_mb)
            let payload = RegisterPayload(node_id: c.node_id, hostname: c.hostname, os: .macos,
                                           gpu: gpu, limits: lim, selected_models: c.selected_models)
            do {
                let json = try PayloadType.register(payload).toJSON()
                t.send(json)
                nonisolated(unsafe) s.status = "Registered"
            } catch { NSLog("Register failed: \(error)") }
        }
    }

    nonisolated private func doSendCatalogRequest() async {
        await MainActor.run {
            nonisolated(unsafe) let s = Self.shared
            guard let t = s.tunnel else { return }
            do {
                let json = try PayloadType.catalogRequest.toJSON()
                t.send(json)
            } catch { NSLog("CatalogRequest failed: \(error)") }
        }
    }

    nonisolated private func doSendHeartbeat() async {
        await MainActor.run {
            nonisolated(unsafe) let s = Self.shared
            guard let c = s.config, let t = s.tunnel else { return }
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
    }

    nonisolated private func doUpdateReadyModels() async {
        await MainActor.run {
            nonisolated(unsafe) let s = Self.shared
            let models = s.backend.ready()
            nonisolated(unsafe) s.readyModels = models
            guard let c = s.config, let t = s.tunnel else { return }
            let ms = ModelStatusPayload(node_id: c.node_id, ready_models: models)
            do {
                let json = try PayloadType.modelStatus(ms).toJSON()
                t.send(json)
            } catch { NSLog("ModelStatus failed: \(error)") }
        }
    }

    nonisolated private     private func handleInbound(_ text: String) {
        guard let msg = try? PayloadType.fromJSON(text) else { return }
        switch msg {
        case .catalogResponse(let cr): handleCatalog(cr)
        case .promptDispatch(let pd):
            nonisolated(unsafe) let s = Self.shared
            s.backend.dispatch(pd) { json in
                nonisolated(unsafe) let s2 = Self.shared
                s2.tunnel?.send(json)
            }
        case .error(let e):
            NSLog("Server error \(e.request_id): \(e.message)")
        default: break
        }
    }

    nonisolated private func handleCatalog(_ cr: CatalogResponsePayload) {
        nonisolated(unsafe) let s = Self.shared
        let sel = s.config?.selected_models
        let toDownload: [CatalogModel] =
            (sel?.isEmpty == false) ? cr.models.filter { sel!.contains($0.id) } : cr.models
        nonisolated(unsafe) let s2 = Self.shared
        s2.status = "Catalog: \(toDownload.count) models"
        Task.detached { @MainActor [toDownload] in
            for model in toDownload {
                do {
                    try await ModelDownloader.shared.downloadModel(model)
                    nonisolated(unsafe) let s = NodeCoordinator.shared
                    s.doRegisterBackendModel(model.id)
                    s.doUpdateReadyModels()
                } catch {
                    NSLog("Download \(model.id) failed: \(error)")
                    nonisolated(unsafe) let s = NodeCoordinator.shared
                    s.doUpdateReadyModels()
                }
            }
        }
            }
        }
    }
}