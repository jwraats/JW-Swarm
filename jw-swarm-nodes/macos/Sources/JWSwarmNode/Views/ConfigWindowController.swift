import AppKit
import Foundation

final class ConfigWindowController: NSWindowController {
    private let fleetURLField = NSTextField()
    private let nodeCertField = NSTextField()
    private let caCertField = NSTextField()
    private let gpuPowerField = NSTextField()
    private let memoryLimitField = NSTextField()
    private let memorySlider = NSSlider(value: 0, minValue: 512, maxValue: 32768, target: nil, action: nil)
    private let detectedGPULabel = NSTextField(labelWithString: "")
    private let detectedMemoryLabel = NSTextField(labelWithString: "")
    private let connectionStatusLabel = NSTextField(labelWithString: "")
    private let detailsScrollView = NSScrollView()
    private let detailsTextView = NSTextView()
    private let testButton = NSButton(title: "Test Connection (mTLS)", target: nil, action: nil)

    var onSave: ((AppConfig) -> Void)?

    private var detectedTotalMemoryMB: UInt64 {
        max(deviceTotalMemoryMB(), 1024)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "JW Swarm Node Configuration"
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showWindowAndActivate() {
        loadFromConfig()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let fleetRow = labeledRow(label: "Fleet URL", field: fleetURLField)
        let nodeCertRow = labeledRow(label: "Node Cert (PEM)", field: nodeCertField)
        let caCertRow = labeledRow(label: "CA Cert", field: caCertField)
        let gpuRow = labeledRow(label: "GPU Power (%)", field: gpuPowerField)
        let memoryRow = labeledRow(label: "Memory Limit (MB)", field: memoryLimitField)

        memorySlider.target = self
        memorySlider.action = #selector(memorySliderChanged)
        memorySlider.numberOfTickMarks = 12
        memorySlider.allowsTickMarkValuesOnly = false

        testButton.target = self
        testButton.action = #selector(testConnectionPressed)

        detailsTextView.isEditable = false
        detailsTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsTextView.string = "Connection diagnostics output appears here."
        detailsScrollView.hasVerticalScroller = true
        detailsScrollView.borderType = .bezelBorder
        detailsScrollView.documentView = detailsTextView
        detailsScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailsScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        detailsScrollView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(savePressed))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)

        detectedMemoryLabel.font = NSFont.systemFont(ofSize: 12)
        detectedMemoryLabel.textColor = .secondaryLabelColor
        detectedGPULabel.font = NSFont.systemFont(ofSize: 12)
        detectedGPULabel.textColor = .secondaryLabelColor
        connectionStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        connectionStatusLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(fleetRow)
        stack.addArrangedSubview(nodeCertRow)
        stack.addArrangedSubview(caCertRow)
        stack.addArrangedSubview(detectedGPULabel)
        stack.addArrangedSubview(gpuRow)
        stack.addArrangedSubview(detectedMemoryLabel)
        stack.addArrangedSubview(memoryRow)
        stack.addArrangedSubview(memorySlider)
        stack.addArrangedSubview(testButton)
        stack.addArrangedSubview(connectionStatusLabel)
        stack.addArrangedSubview(detailsScrollView)
        stack.addArrangedSubview(buttonRow)

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func labeledRow(label: String, field: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12

        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 130).isActive = true

        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        row.addArrangedSubview(title)
        row.addArrangedSubview(field)
        return row
    }

    private func loadFromConfig() {
        let cfg = ConfigManager.shared.config
        fleetURLField.stringValue = cfg.fleet_url
        nodeCertField.stringValue = cfg.node_cert
        caCertField.stringValue = cfg.ca_cert
        gpuPowerField.stringValue = "\(cfg.limits.gpu_power_pct)"
        detectedGPULabel.stringValue = "Detected GPU: \(detectedGPUDescription())"

        let maxMB = max(Double(detectedTotalMemoryMB), 1024)
        memorySlider.maxValue = maxMB
        detectedMemoryLabel.stringValue = "Detected unified memory: \(detectedTotalMemoryMB) MB"

        let limitMB = min(max(Double(cfg.limits.memory_limit_mb), 512), maxMB)
        memorySlider.doubleValue = limitMB
        memoryLimitField.stringValue = "\(UInt64(limitMB))"
        connectionStatusLabel.stringValue = "Connection test not run yet."
    }

    @objc
    private func memorySliderChanged() {
        let rounded = UInt64(memorySlider.doubleValue.rounded())
        memoryLimitField.stringValue = "\(rounded)"
    }

    @objc
    private func cancelPressed() {
        close()
    }

    @objc
    private func savePressed() {
        var cfg = ConfigManager.shared.config

        let maxMB = detectedTotalMemoryMB
        let fleet = fleetURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fleet.isEmpty {
            cfg.fleet_url = fleet
        }

        let nodeCert = nodeCertField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nodeCert.isEmpty {
            cfg.node_cert = nodeCert
        }
        let caCert = caCertField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caCert.isEmpty {
            cfg.ca_cert = caCert
        }

        let gpuValue = UInt8(max(0, min(100, Int(gpuPowerField.integerValue))))
        cfg.limits.gpu_power_pct = gpuValue

        let requestedMB = UInt64(max(512, min(Int(memoryLimitField.integerValue), Int(maxMB))))
        cfg.limits.memory_limit_mb = requestedMB

        ConfigManager.shared.setAndSave(cfg)
        onSave?(cfg)
        close()
    }

    @objc
    private func testConnectionPressed() {
        var cfg = ConfigManager.shared.config
        let fleet = fleetURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fleet.isEmpty {
            cfg.fleet_url = fleet
        }
        let nodeCert = nodeCertField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nodeCert.isEmpty {
            cfg.node_cert = nodeCert
        }
        let caCert = caCertField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caCert.isEmpty {
            cfg.ca_cert = caCert
        }

        testButton.isEnabled = false
        connectionStatusLabel.stringValue = "Running mTLS diagnostics..."
        detailsTextView.string = ""

        DispatchQueue.global(qos: .utility).async {
            let result = ConnectionDiagnostics.run(config: cfg)
            DispatchQueue.main.async {
                self.testButton.isEnabled = true
                self.connectionStatusLabel.stringValue = result.summary
                self.connectionStatusLabel.textColor = result.success ? .systemGreen : .systemRed
                self.detailsTextView.string = result.details
            }
        }
    }
}
