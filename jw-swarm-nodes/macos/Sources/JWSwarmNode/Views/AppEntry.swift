import Foundation
import SwiftUI

@main
struct JWSwarmNodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.shared) var appDelegate

    var body: some Scene {
        MenuBarExtra("JW Swarm", systemImage: "network") {
            NodeMenuView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ConfigManager.shared.config
        NodeCoordinator.shared.start(config: config)
    }
}

// MARK: - Coordinator

final class NodeCoordinator: ObservableObject, @unchecked Sendable {
    static let shared = NodeCoordinator()

    @Published var status: String = "Disconnected"
    @Published var readyModels: [String] = []
    @Published var isAwake: Bool = true

    private var tunnel: Tunnel?
    private var config: AppConfig?
    private let backend = StubBackend()
    private var heartbeatTimer: Timer?
    private let uiQueue = DispatchQueue.main

    @MainActor
    func start(config: AppConfig) {
        self.config = config
        guard let fleetURL = URL(string: config.fleet_url) else {
            updateStatus("Invalid fleet URL")
            return
        }

        tunnel = Tunnel(
            fleetURL: fleetURL,
            nodeCertPath: config.node_cert,
            caCertPath: config.ca_cert
        )

        tunnel?.setIncomingHandler { [weak self] text in
            self?.handleInbound(text)
        }

        tunnel?.start()
        updateStatus("Connecting...")

        // Delay initial messages until tunnel is open
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendRegister()
            self?.sendCatalogRequest()
        }

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
    }

    @MainActor
    private func updateStatus(_ text: String) {
        status = text
    }

    @MainActor
    private func sendRegister() {
        guard let config = config, let tunnel = tunnel else { return }
        let m = SystemMetrics.collect()
        let gpu = GpuInfo(
            vendor: .apple,
            name: m.gpuName,
            vram_mb: m.vram_total_mb
        )
        let limits = OwnerLimits(
            gpu_power_pct: config.limits.gpu_power_pct,
            memory_limit_mb: config.limits.memory_limit_mb
        )
        let payload = RegisterPayload(
            node_id: config.node_id,
            hostname: config.hostname,
            os: .macos,
            gpu: gpu,
            limits: limits,
            selected_models: config.selected_models
        )
        do {
            let json = try PayloadType.register(payload).toJSON()
            tunnel.send(json)
            updateStatus("Registered")
        } catch {
            NSLog("Register failed: \(error)")
        }
    }

    @MainActor
    private func sendCatalogRequest() {
        guard let tunnel = tunnel else { return }
        do {
            let json = try PayloadType.catalogRequest.toJSON()
            tunnel.send(json)
        } catch {
            NSLog("CatalogRequest failed: \(error)")
        }
    }

    @MainActor
    private func handleInbound(_ text: String) {
        guard let msg = try? PayloadType.fromJSON(text) else { return }

        switch msg {
        case .catalogResponse(let cr):
            handleCatalog(cr)
        case .promptDispatch(let pd):
            backend.dispatch(pd) { [weak self] json in
                self?.tunnel?.send(json)
            }
        case .error(let e):
            NSLog("Server error \(e.request_id): \(e.message)")
        default:
            break
        }
    }

    @MainActor
    private func handleCatalog(_ cr: CatalogResponsePayload) {
        updateStatus("Catalog: \(cr.models.count) models")
        let toDownload = selectModels(cr.models)

        Task.detached { [weak self, toDownload] in
            for model in toDownload {
                do {
                    try await ModelDownloader.shared.download(model)
                    self?.backend.register(model.id)
                } catch {
                    NSLog("Download \(model.id) failed: \(error)")
                }
                await self?.updateReadyModels()
            }
        }
    }

    @MainActor
    private func selectModels(_ all: [CatalogModel]) -> [CatalogModel] {
        guard let config = config else { return all }
        if config.selected_models.isEmpty { return all }
        return all.filter { config.selected_models.contains($0.id) }
    }

    @MainActor
    private func sendHeartbeat() {
        guard let config = config, let tunnel = tunnel else { return }
        let m = SystemMetrics.collect()
        let hb = HeartbeatPayload(
            node_id: config.node_id,
            metrics: m.metrics,
            schedule_state: isAwake ? .awake : .asleep
        )
        do {
            let json = try PayloadType.heartbeat(hb).toJSON()
            tunnel.send(json)
        } catch {
            NSLog("Heartbeat failed: \(error)")
        }
    }

    @MainActor
    private func updateReadyModels() {
        readyModels = backend.ready()
        guard let config = config, let tunnel = tunnel else { return }
        let ms = ModelStatusPayload(
            node_id: config.node_id,
            ready_models: readyModels
        )
        do {
            let json = try PayloadType.modelStatus(ms).toJSON()
            tunnel.send(json)
        } catch {
            NSLog("ModelStatus failed: \(error)")
        }
    }
}
