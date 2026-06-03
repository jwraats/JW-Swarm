import AppKit
import Foundation

final class ConfigWindowController: NSWindowController {
    private let fleetURLField = NSTextField()
    private let nodeCertField = NSTextField()
    private let caCertField = NSTextField()
    private let gpuPowerField = NSTextField()
    private let memoryLimitField = NSTextField()
    private let enrollmentTokenScrollView = NSScrollView()
    private let enrollmentTokenTextView = NSTextView()
    private let pasteTokenButton = NSButton(title: "Paste Token", target: nil, action: nil)
    private let clearTokenButton = NSButton(title: "Clear", target: nil, action: nil)
    private let memorySlider = NSSlider(value: 0, minValue: 512, maxValue: 32768, target: nil, action: nil)
    private let detectedGPULabel = NSTextField(labelWithString: "")
    private let detectedMemoryLabel = NSTextField(labelWithString: "")
    private let connectionStatusLabel = NSTextField(labelWithString: "")
    private let detailsScrollView = NSScrollView()
    private let detailsTextView = NSTextView()
    private let testButton = NSButton(title: "Test Connection (Tunnel)", target: nil, action: nil)
    private let enrollButton = NSButton(title: "Enroll Node (Token)", target: nil, action: nil)

    var onSave: ((AppConfig) -> Void)?

    private var detectedTotalMemoryMB: UInt64 {
        max(deviceTotalMemoryMB(), 1024)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
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
        let enrollTokenRow = tokenEditorRow()

        memorySlider.target = self
        memorySlider.action = #selector(memorySliderChanged)
        memorySlider.numberOfTickMarks = 12
        memorySlider.allowsTickMarkValuesOnly = false

        testButton.target = self
        testButton.action = #selector(testConnectionPressed)

        enrollButton.target = self
        enrollButton.action = #selector(enrollPressed)

        pasteTokenButton.target = self
        pasteTokenButton.action = #selector(pasteTokenPressed)

        clearTokenButton.target = self
        clearTokenButton.action = #selector(clearTokenPressed)

        enrollmentTokenTextView.isRichText = false
        enrollmentTokenTextView.isEditable = true
        enrollmentTokenTextView.isSelectable = true
        enrollmentTokenTextView.usesFindBar = true
        enrollmentTokenTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        enrollmentTokenTextView.textContainerInset = NSSize(width: 6, height: 8)
        enrollmentTokenTextView.textContainer?.lineBreakMode = .byCharWrapping
        enrollmentTokenTextView.textContainer?.widthTracksTextView = true
        enrollmentTokenTextView.isHorizontallyResizable = false
        enrollmentTokenTextView.autoresizingMask = [.width]

        enrollmentTokenScrollView.hasVerticalScroller = true
        enrollmentTokenScrollView.borderType = .bezelBorder
        enrollmentTokenScrollView.documentView = enrollmentTokenTextView
        enrollmentTokenScrollView.translatesAutoresizingMaskIntoConstraints = false
        enrollmentTokenScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        enrollmentTokenScrollView.heightAnchor.constraint(equalToConstant: 76).isActive = true

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
        stack.addArrangedSubview(enrollTokenRow)
        stack.addArrangedSubview(enrollButton)
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

    private func tokenEditorRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12

        let title = NSTextField(labelWithString: "Enroll Token")
        title.alignment = .right
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let editorColumn = NSStackView()
        editorColumn.orientation = .vertical
        editorColumn.alignment = .leading
        editorColumn.spacing = 6

        let helper = NSTextField(labelWithString: "Paste the full one-time token here. Paste button reads directly from the macOS clipboard.")
        helper.font = NSFont.systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor
        helper.lineBreakMode = .byWordWrapping
        helper.maximumNumberOfLines = 2

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(pasteTokenButton)
        buttonRow.addArrangedSubview(clearTokenButton)

        editorColumn.addArrangedSubview(helper)
        editorColumn.addArrangedSubview(enrollmentTokenScrollView)
        editorColumn.addArrangedSubview(buttonRow)

        row.addArrangedSubview(title)
        row.addArrangedSubview(editorColumn)
        return row
    }

    private func enrollmentToken() -> String {
        enrollmentTokenTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setEnrollmentToken(_ token: String) {
        enrollmentTokenTextView.string = token
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
        setEnrollmentToken("")
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
    private func pasteTokenPressed() {
        guard let token = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            connectionStatusLabel.stringValue = "Clipboard does not contain a token."
            connectionStatusLabel.textColor = .systemRed
            return
        }

        setEnrollmentToken(token)
        connectionStatusLabel.stringValue = "Token pasted from clipboard."
        connectionStatusLabel.textColor = .secondaryLabelColor
    }

    @objc
    private func clearTokenPressed() {
        setEnrollmentToken("")
        connectionStatusLabel.stringValue = "Enrollment token cleared."
        connectionStatusLabel.textColor = .secondaryLabelColor
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
        connectionStatusLabel.stringValue = "Running tunnel diagnostics..."
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

    @objc
    private func enrollPressed() {
        var cfg = ConfigManager.shared.config
        let fleet = fleetURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fleet.isEmpty {
            cfg.fleet_url = fleet
        }

        let token = enrollmentToken()
        if token.isEmpty {
            connectionStatusLabel.stringValue = "Enrollment token is required."
            connectionStatusLabel.textColor = .systemRed
            return
        }

        enrollButton.isEnabled = false
        testButton.isEnabled = false
        connectionStatusLabel.stringValue = "Running bootstrap enrollment..."
        connectionStatusLabel.textColor = .secondaryLabelColor
        detailsTextView.string = ""

        let outDir = ConfigManager.shared.dataDir().appendingPathComponent("certs")
        Task {
            do {
                let result = try await BootstrapEnrollment.enroll(
                    baseFleetURL: cfg.fleet_url,
                    nodeID: cfg.node_id,
                    token: token,
                    outputDir: outDir
                )
                cfg.node_cert = result.nodePemPath
                cfg.ca_cert = result.caCertPath
                ConfigManager.shared.setAndSave(cfg)
                onSave?(cfg)

                await MainActor.run {
                    nodeCertField.stringValue = result.nodePemPath
                    caCertField.stringValue = result.caCertPath
                    setEnrollmentToken("")
                    connectionStatusLabel.stringValue = "Enrollment successful."
                    connectionStatusLabel.textColor = .systemGreen
                    detailsTextView.string = result.details
                    enrollButton.isEnabled = true
                    testButton.isEnabled = true
                }
            } catch {
                await MainActor.run {
                    connectionStatusLabel.stringValue = "Enrollment failed."
                    connectionStatusLabel.textColor = .systemRed
                    detailsTextView.string = error.localizedDescription
                    enrollButton.isEnabled = true
                    testButton.isEnabled = true
                }
            }
        }
    }
}
