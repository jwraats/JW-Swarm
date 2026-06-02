import Foundation

struct MTLSDiagnosticsResult {
    let success: Bool
    let summary: String
    let details: String
}

enum ConnectionDiagnostics {
    static func run(config: AppConfig) -> MTLSDiagnosticsResult {
        var lines: [String] = []

        let fleet = config.fleet_url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: fleet), let host = url.host else {
            return MTLSDiagnosticsResult(
                success: false,
                summary: "Invalid Fleet URL",
                details: "Fleet URL is invalid: \(fleet)"
            )
        }

        let port = url.port ?? ((url.scheme == "wss" || url.scheme == "https") ? 443 : 80)
        lines.append("Fleet endpoint: \(host):\(port)\(url.path.isEmpty ? "/" : url.path)")

        let nodeCert = config.node_cert
        let caCert = config.ca_cert

        let fm = FileManager.default
        guard fm.fileExists(atPath: nodeCert) else {
            return MTLSDiagnosticsResult(
                success: false,
                summary: "Node certificate missing",
                details: "Configured node cert file does not exist:\n\(nodeCert)"
            )
        }
        guard fm.fileExists(atPath: caCert) else {
            return MTLSDiagnosticsResult(
                success: false,
                summary: "CA certificate missing",
                details: "Configured CA cert file does not exist:\n\(caCert)"
            )
        }

        let nodePEM = (try? String(contentsOfFile: nodeCert, encoding: .utf8)) ?? ""
        let hasClientCert = nodePEM.contains("-----BEGIN CERTIFICATE-----")
        let hasPrivateKey = nodePEM.contains("-----BEGIN PRIVATE KEY-----") ||
            nodePEM.contains("-----BEGIN EC PRIVATE KEY-----") ||
            nodePEM.contains("-----BEGIN RSA PRIVATE KEY-----")

        lines.append("Node PEM: cert block = \(hasClientCert ? "yes" : "no"), private key = \(hasPrivateKey ? "yes" : "no")")
        if !hasClientCert || !hasPrivateKey {
            return MTLSDiagnosticsResult(
                success: false,
                summary: "Node PEM incomplete",
                details: lines.joined(separator: "\n") + "\nExpected both certificate and private key in node PEM."
            )
        }

        let nodeInfo = runOpenSSL(
            args: ["x509", "-in", nodeCert, "-noout", "-subject", "-issuer", "-enddate"],
            timeoutSeconds: 5
        )
        lines.append("\nNode cert:\n\(trim(nodeInfo.output))")

        let caInfo = runOpenSSL(
            args: ["x509", "-in", caCert, "-noout", "-subject", "-issuer", "-enddate"],
            timeoutSeconds: 5
        )
        lines.append("\nCA cert:\n\(trim(caInfo.output))")

        let mtls = runOpenSSL(
            args: [
                "s_client",
                "-connect", "\(host):\(port)",
                "-servername", host,
                "-CAfile", caCert,
                "-cert", nodeCert,
                "-key", nodeCert,
                "-verify_return_error",
                "-brief",
            ],
            timeoutSeconds: 8
        )

        let mtlsOutput = trim(mtls.output)
        lines.append("\nmTLS probe:\n\(mtlsOutput)")

        let verified = mtlsOutput.localizedCaseInsensitiveContains("verification: ok") ||
            mtlsOutput.localizedCaseInsensitiveContains("verify return code: 0")
        let connected = mtlsOutput.localizedCaseInsensitiveContains("connection established") ||
            mtlsOutput.localizedCaseInsensitiveContains("connected")

        let ok = mtls.timedOut == false && mtls.exitCode == 0 && verified && connected
        let summary: String
        if ok {
            summary = "Connection OK (mTLS verified)"
        } else if mtls.timedOut {
            summary = "Connection test timed out"
        } else if mtls.exitCode != 0 {
            summary = "Connection failed (mTLS handshake failed)"
        } else {
            summary = "Connection uncertain (check details)"
        }

        return MTLSDiagnosticsResult(
            success: ok,
            summary: summary,
            details: lines.joined(separator: "\n")
        )
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runOpenSSL(args: [String], timeoutSeconds: TimeInterval) -> (exitCode: Int32, output: String, timedOut: Bool) {
        let tool = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            return (-1, "openssl not available at /usr/bin/openssl", false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        do {
            try process.run()
            inputPipe.fileHandleForWriting.closeFile()
        } catch {
            return (-1, "Failed to start openssl: \(error.localizedDescription)", false)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
        }

        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output, timedOut)
    }
}
