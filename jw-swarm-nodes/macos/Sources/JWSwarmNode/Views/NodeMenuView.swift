import Foundation
import SwiftUI

struct NodeMenuView: View {
    @State private var refresh = UUID()
    @State private var showConfig = false
    private var c: NodeCoordinator { NodeCoordinator.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: statusIcon).foregroundColor(statusColor)
                Text(c.status).font(.system(.subheadline, design: .monospaced))
                Spacer()
            }
            if !c.readyModels.isEmpty {
                Text("Models: \(c.readyModels.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            HStack {
                Text("State"); Spacer()
                Toggle("", isOn: Binding(get: { c.isAwake }, set: { c.isAwake = $0 }))
                    .toggleStyle(.switch).scaleEffect(0.8)
                Text(c.isAwake ? "Awake" : "Asleep").font(.caption)
            }
            Divider()
            Button("Configure...") { showConfig = true }
                .sheet(isPresented: $showConfig) { ConfigPopoverView() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding().frame(width: 280)
        .id(refresh)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                refresh = UUID()
            }
        }
    }

    private var statusIcon: String {
        switch c.status {
        case "Disconnected": return "wifi.slash"
        case "Connecting...": return "link"
        case "Registered": return "info.circle"
        default: return "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch c.status {
        case "Disconnected": return .red
        case "Connecting...": return .orange
        case "Registered": return .yellow
        default: return .green
        }
    }
}

struct ConfigPopoverView: View {
    @State private var vm = ConfigViewModel()

    var body: some View {
        Form {
            Section("Fleet") {
                TextField("Fleet URL", text: $vm.fleetURL)
                TextField("Node Cert", text: $vm.certPath)
                TextField("CA Cert", text: $vm.caPath)
            }
            Section("Limits") {
                Slider(value: $vm.gpuPower, in: 0...100) { Text("GPU: \(Int(vm.gpuPower))%") }
                Stepper("\(vm.memoryLimit) MB", value: $vm.memoryLimit, in: 1024...65536, step: 1024)
            }
            Section("") {
                Button("Save & Restart") {
                    vm.save(); NSApplication.shared.terminate(nil)
                }.buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 350, height: 250)
    }
}

class ConfigViewModel: ObservableObject {
    @Published var fleetURL: String
    @Published var certPath: String
    @Published var caPath: String
    @Published var gpuPower: Double
    @Published var memoryLimit: Int

    init() {
        let c = ConfigManager.shared.config
        fleetURL = c.fleet_url; certPath = c.node_cert; caPath = c.ca_cert
        gpuPower = Double(c.limits.gpu_power_pct)
        memoryLimit = Int(c.limits.memory_limit_mb)
    }

    func save() {
        var c = ConfigManager.shared.config
        c.fleet_url = fleetURL; c.node_cert = certPath; c.ca_cert = caPath
        c.limits.gpu_power_pct = UInt8(gpuPower)
        c.limits.memory_limit_mb = UInt64(memoryLimit)
        ConfigManager.shared.save(c)
    }
}