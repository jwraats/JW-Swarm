import Foundation
import SwiftUI

struct NodeMenuView: View {
    @StateObject private var coordinator = NodeCoordinator.shared
    @State private var showConfig = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow

            if !coordinator.readyModels.isEmpty {
                Text("Models: \(coordinator.readyModels.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()
            awakeRow
            Divider()
            Button("Configure...") {
                showConfig = true
            }
            .sheet(isPresented: $showConfig) {
                ConfigPopoverView()
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private var statusRow: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
            Text(coordinator.status)
                .font(.system(.subheadline, design: .monospaced))
            Spacer()
        }
    }

    private var awakeRow: some View {
        HStack {
            Text("State")
            Spacer()
            Toggle("", isOn: $coordinator.isAwake)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
            Text(coordinator.isAwake ? "Awake" : "Asleep")
                .font(.caption)
        }
    }

    private var statusIcon: String {
        switch coordinator.status {
        case "Disconnected": return "wifi.slash"
        case "Connecting...": return "link"
        case "Registered": return "info.circle"
        default: return "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch coordinator.status {
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
                Slider(value: $vm.gpuPower, in: 0...100) {
                    Text("GPU: \(Int(vm.gpuPower))%")
                }
                Stepper("\(vm.memoryLimit) MB", value: $vm.memoryLimit, in: 1024...65536, step: 1024)
            }
            Section("") {
                Button("Save & Restart") {
                    vm.save()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 350, height: 280)
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
        fleetURL = c.fleet_url
        certPath = c.node_cert
        caPath = c.ca_cert
        gpuPower = Double(c.limits.gpu_power_pct)
        memoryLimit = Int(c.limits.memory_limit_mb)
    }

    func save() {
        var c = ConfigManager.shared.config
        c.fleet_url = fleetURL
        c.node_cert = certPath
        c.ca_cert = caPath
        c.limits.gpu_power_pct = UInt8(gpuPower)
        c.limits.memory_limit_mb = UInt64(memoryLimit)
        ConfigManager.shared.save(c)
    }
}
