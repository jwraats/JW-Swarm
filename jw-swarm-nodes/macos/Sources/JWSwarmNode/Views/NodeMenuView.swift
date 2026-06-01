import AppKit
import Foundation
import SwiftUI

struct NodeMenuView: View {
    private var c: NodeCoordinator { NodeCoordinator.shared }

    var body: some View {
        Text("Status: \(c.status)")
        if !c.readyModels.isEmpty {
            Text("Models: \(c.readyModels.joined(separator: ", "))")
        }
        Divider()
        Toggle("Awake", isOn: Binding(get: { c.isAwake }, set: { c.isAwake = $0 }))
        Button("Open Config Folder") { openConfigFolder() }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    private func openConfigFolder() {
        let dir = ConfigManager.shared.dataDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}