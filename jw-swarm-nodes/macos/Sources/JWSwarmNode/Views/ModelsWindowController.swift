import AppKit
import Foundation

/// Standalone window presenting node performance metrics and a live overview of
/// every model the node knows about, including download progress and state.
final class ModelsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let latencyValueLabel = NSTextField(labelWithString: "-")
    private let avgTpsValueLabel = NSTextField(labelWithString: "-")
    private let lastTpsValueLabel = NSTextField(labelWithString: "-")
    private let tunnelValueLabel = NSTextField(labelWithString: "-")
    private let totalTokensValueLabel = NSTextField(labelWithString: "-")
    private let tableView = NSTableView()

    private var refreshTimer: Timer?
    private var rows: [(id: String, entry: ModelStatusEntry)] = []
    private var usage: [String: ModelTokenUsage] = [:]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "JW Swarm Node — Models & Metrics"
        window.minSize = NSSize(width: 600, height: 360)
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showWindowAndActivate() {
        reload()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let metricsGrid = NSGridView(views: [
            [captionLabel("Tunnel:"), tunnelValueLabel],
            [captionLabel("Latency to Fleet Manager:"), latencyValueLabel],
            [captionLabel("Average tokens/sec:"), avgTpsValueLabel],
            [captionLabel("Last completion tokens/sec:"), lastTpsValueLabel],
            [captionLabel("Total tokens (in / out):"), totalTokensValueLabel],
        ])
        metricsGrid.rowSpacing = 6
        metricsGrid.columnSpacing = 12
        metricsGrid.column(at: 0).xPlacement = .trailing
        metricsGrid.translatesAutoresizingMaskIntoConstraints = false

        let modelsHeader = NSTextField(labelWithString: "Models")
        modelsHeader.font = NSFont.boldSystemFont(ofSize: 13)

        configureTable()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [metricsGrid, NSBox.separator(), modelsHeader, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            metricsGrid.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 0),
            scrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        window?.delegate = self
    }

    private func configureTable() {
        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Model"
        nameColumn.width = 220
        nameColumn.minWidth = 140

        let stateColumn = NSTableColumn(identifier: .init("state"))
        stateColumn.title = "Status"
        stateColumn.width = 160
        stateColumn.minWidth = 120

        let progressColumn = NSTableColumn(identifier: .init("progress"))
        progressColumn.title = "Progress"
        progressColumn.width = 120
        progressColumn.minWidth = 100

        let inputColumn = NSTableColumn(identifier: .init("input"))
        inputColumn.title = "Tokens In"
        inputColumn.width = 90
        inputColumn.minWidth = 70

        let outputColumn = NSTableColumn(identifier: .init("output"))
        outputColumn.title = "Tokens Out"
        outputColumn.width = 90
        outputColumn.minWidth = 70

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(stateColumn)
        tableView.addTableColumn(progressColumn)
        tableView.addTableColumn(inputColumn)
        tableView.addTableColumn(outputColumn)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
    }

    private func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func reload() {
        let coordinator = NodeCoordinator.shared

        let connected = coordinator.isTunnelConnected
        tunnelValueLabel.stringValue = connected ? "Connected" : "Disconnected"
        tunnelValueLabel.textColor = connected ? .systemGreen : .secondaryLabelColor

        if connected, let latency = coordinator.fleetLatencyMs {
            latencyValueLabel.stringValue = String(format: "%.0f ms", latency)
        } else {
            latencyValueLabel.stringValue = "-"
        }

        let avg = coordinator.averageTokensPerSecond
        avgTpsValueLabel.stringValue = avg > 0 ? String(format: "%.1f tok/s", avg) : "-"
        let last = coordinator.lastTokensPerSecond
        lastTpsValueLabel.stringValue = last > 0 ? String(format: "%.1f tok/s", last) : "-"

        rows = coordinator.modelStates
            .sorted { $0.key < $1.key }
            .map { (id: $0.key, entry: $0.value) }
        usage = coordinator.tokenUsageByModel

        let totalIn = usage.values.reduce(UInt64(0)) { $0 + $1.inputTokens }
        let totalOut = usage.values.reduce(UInt64(0)) { $0 + $1.outputTokens }
        if totalIn == 0 && totalOut == 0 {
            totalTokensValueLabel.stringValue = "-"
        } else {
            totalTokensValueLabel.stringValue =
                "\(Self.formatCount(totalIn)) / \(Self.formatCount(totalOut))"
        }

        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let column = tableColumn else { return nil }
        let entry = rows[row].entry
        let modelID = rows[row].id

        switch column.identifier.rawValue {
        case "name":
            return cell(text: entry.displayName, color: .labelColor)
        case "state":
            return cell(text: stateText(entry.state), color: stateColor(entry.state))
        case "progress":
            if case .downloading(let fraction) = entry.state {
                let bar = NSProgressIndicator()
                bar.isIndeterminate = false
                bar.minValue = 0
                bar.maxValue = 1
                bar.doubleValue = fraction
                bar.controlSize = .small
                return bar
            }
            let value: String
            switch entry.state {
            case .ready: value = "100%"
            case .available: value = "—"
            default: value = ""
            }
            return cell(text: value, color: .secondaryLabelColor)
        case "input":
            let count = usage[modelID]?.inputTokens ?? 0
            return cell(text: Self.formatCount(count), color: .secondaryLabelColor)
        case "output":
            let count = usage[modelID]?.outputTokens ?? 0
            return cell(text: Self.formatCount(count), color: .secondaryLabelColor)
        default:
            return nil
        }
    }

    private static func formatCount(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func cell(text: String, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func stateText(_ state: ModelDownloadState) -> String {
        switch state {
        case .available: return "Available"
        case .downloading(let f): return String(format: "Downloading %.0f%%", f * 100)
        case .ready: return "Ready"
        case .failed(let reason): return "Failed: \(reason)"
        case .unsupported: return "Unsupported"
        }
    }

    private func stateColor(_ state: ModelDownloadState) -> NSColor {
        switch state {
        case .ready: return .systemGreen
        case .downloading: return .systemBlue
        case .failed: return .systemRed
        case .unsupported: return .systemOrange
        case .available: return .secondaryLabelColor
        }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }
}
