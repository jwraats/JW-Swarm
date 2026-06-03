import Foundation

struct BootstrapEnrollmentResult {
    let nodePemPath: String
    let caCertPath: String
    let details: String
}

enum BootstrapEnrollment {
    static func enroll(baseFleetURL: String, nodeID: String, token: String, outputDir: URL) async throws -> BootstrapEnrollmentResult {
        let baseURL = try enrollmentBaseURL(from: baseFleetURL)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let keyURL = outputDir.appendingPathComponent("\(nodeID).key")
        let csrURL = outputDir.appendingPathComponent("\(nodeID).csr")
        let certURL = outputDir.appendingPathComponent("\(nodeID).crt")
        let nodePemURL = outputDir.appendingPathComponent("node.pem")
        let caURL = outputDir.appendingPathComponent("ca.crt")

        try runOpenSSL([
            "genrsa",
            "-out", keyURL.path,
            "2048",
        ])

        try runOpenSSL([
            "req",
            "-new",
            "-key", keyURL.path,
            "-subj", "/CN=\(nodeID)",
            "-out", csrURL.path,
        ])

        let csr = try String(contentsOf: csrURL, encoding: .utf8)

        let (caData, caResp) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("bootstrap/ca.crt"))
        guard let caHttp = caResp as? HTTPURLResponse, (200..<300).contains(caHttp.statusCode) else {
            throw NSError(domain: "BootstrapEnrollment", code: 11, userInfo: [NSLocalizedDescriptionKey: "CA download failed"])
        }
        try caData.write(to: caURL, options: .atomic)

        struct EnrollRequest: Encodable {
            let node_id: String
            let token: String
            let csr_pem: String
        }
        struct EnrollResponse: Decodable {
            let node_cert_pem: String
            let ca_cert_pem: String
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("bootstrap/enroll"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(EnrollRequest(node_id: nodeID, token: token, csr_pem: csr))

        let (enrollData, enrollResp) = try await URLSession.shared.data(for: req)
        guard let enrollHttp = enrollResp as? HTTPURLResponse, (200..<300).contains(enrollHttp.statusCode) else {
            let body = String(data: enrollData, encoding: .utf8) ?? ""
            throw NSError(domain: "BootstrapEnrollment", code: 12, userInfo: [NSLocalizedDescriptionKey: "Enrollment failed: \(body)"])
        }

        let parsed = try JSONDecoder().decode(EnrollResponse.self, from: enrollData)
        try parsed.node_cert_pem.write(to: certURL, atomically: true, encoding: .utf8)
        try parsed.ca_cert_pem.write(to: caURL, atomically: true, encoding: .utf8)

        let keyText = try String(contentsOf: keyURL, encoding: .utf8)
        let combined = parsed.node_cert_pem + "\n" + keyText
        try combined.write(to: nodePemURL, atomically: true, encoding: .utf8)

        return BootstrapEnrollmentResult(
            nodePemPath: nodePemURL.path,
            caCertPath: caURL.path,
            details: "node.pem: \(nodePemURL.path)\nca.crt: \(caURL.path)"
        )
    }

    private static func enrollmentBaseURL(from fleetURL: String) throws -> URL {
        let trimmed = fleetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed) else {
            throw NSError(domain: "BootstrapEnrollment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid fleet URL"])
        }

        if comps.scheme == "wss" {
            comps.scheme = "https"
        } else if comps.scheme == "ws" {
            comps.scheme = "http"
        }

        comps.path = ""
        comps.query = nil
        comps.fragment = nil

        guard let url = comps.url else {
            throw NSError(domain: "BootstrapEnrollment", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to derive enrollment URL"])
        }
        return url
    }

    private static func runOpenSSL(_ args: [String]) throws {
        let tool = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw NSError(domain: "BootstrapEnrollment", code: 3, userInfo: [NSLocalizedDescriptionKey: "openssl not found at /usr/bin/openssl"])
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args

        let out = Pipe()
        p.standardOutput = out
        p.standardError = out

        try p.run()
        p.waitUntilExit()

        if p.terminationStatus != 0 {
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? "openssl failed"
            throw NSError(domain: "BootstrapEnrollment", code: 4, userInfo: [NSLocalizedDescriptionKey: text])
        }
    }
}
