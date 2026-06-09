using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using JwSwarmNode.Core.Config;

namespace JwSwarmNode.Core.Net;

/// <summary>Outcome of a connection diagnostics run.</summary>
public readonly record struct DiagnosticsResult(bool Success, string Summary, string Details);

/// <summary>
/// Connection diagnostics mirroring the macOS <c>ConnectionDiagnostics</c>:
/// verifies cert files exist, the node PEM contains both certificate and
/// private key, the mTLS handshake succeeds against the pinned CA, and the
/// tunnel path accepts a real WebSocket upgrade (HTTP 101).
/// Implemented with pure .NET (<see cref="SslStream"/>) instead of openssl.
/// </summary>
public static class ConnectionDiagnostics
{
    public static DiagnosticsResult Run(NodeConfig config)
    {
        var lines = new List<string>();

        var fleet = config.FleetUrl.Trim();
        if (!Uri.TryCreate(fleet, UriKind.Absolute, out var url) || string.IsNullOrEmpty(url.Host))
        {
            return new DiagnosticsResult(false, "Invalid Fleet URL", $"Fleet URL is invalid: {fleet}");
        }

        var host = url.Host;
        var port = url.IsDefaultPort
            ? (url.Scheme is "wss" or "https" ? 443 : 80)
            : url.Port;
        var tunnelPath = string.IsNullOrEmpty(url.AbsolutePath) || url.AbsolutePath == "/"
            ? "/node/connect"
            : url.AbsolutePath;
        lines.Add($"Fleet endpoint: {host}:{port}{tunnelPath}");

        if (!File.Exists(config.NodeCert))
        {
            return new DiagnosticsResult(false, "Node certificate missing",
                $"Configured node cert file does not exist:\n{config.NodeCert}");
        }
        if (!File.Exists(config.CaCert))
        {
            return new DiagnosticsResult(false, "CA certificate missing",
                $"Configured CA cert file does not exist:\n{config.CaCert}");
        }

        string nodePem;
        try { nodePem = File.ReadAllText(config.NodeCert); }
        catch (Exception ex)
        {
            return new DiagnosticsResult(false, "Node certificate unreadable",
                $"Failed to read node PEM: {ex.Message}");
        }

        var hasClientCert = nodePem.Contains("-----BEGIN CERTIFICATE-----");
        var hasPrivateKey = nodePem.Contains("-----BEGIN PRIVATE KEY-----")
                            || nodePem.Contains("-----BEGIN EC PRIVATE KEY-----")
                            || nodePem.Contains("-----BEGIN RSA PRIVATE KEY-----");
        lines.Add($"Node PEM: cert block = {(hasClientCert ? "yes" : "no")}, private key = {(hasPrivateKey ? "yes" : "no")}");
        if (!hasClientCert || !hasPrivateKey)
        {
            return new DiagnosticsResult(false, "Node PEM incomplete",
                string.Join("\n", lines) + "\nExpected both certificate and private key in node PEM.");
        }

        X509Certificate2 clientCert;
        X509Certificate2 caCert;
        try
        {
            clientCert = X509Certificate2.CreateFromPemFile(config.NodeCert, config.NodeCert);
            lines.Add($"\nNode cert:\nsubject={clientCert.Subject}\nissuer={clientCert.Issuer}\nnotAfter={clientCert.NotAfter:u}");
        }
        catch (Exception ex)
        {
            return new DiagnosticsResult(false, "Node certificate unparsable",
                string.Join("\n", lines) + $"\nFailed to parse node PEM: {ex.Message}");
        }
        try
        {
            caCert = X509Certificate2.CreateFromPem(File.ReadAllText(config.CaCert));
            lines.Add($"\nCA cert:\nsubject={caCert.Subject}\nissuer={caCert.Issuer}\nnotAfter={caCert.NotAfter:u}");
        }
        catch (Exception ex)
        {
            return new DiagnosticsResult(false, "CA certificate unparsable",
                string.Join("\n", lines) + $"\nFailed to parse CA PEM: {ex.Message}");
        }

        // mTLS handshake + WebSocket upgrade probe over a single connection.
        try
        {
            using var tcp = new TcpClient();
            if (!tcp.ConnectAsync(host, port).Wait(TimeSpan.FromSeconds(8)))
            {
                return new DiagnosticsResult(false, "Connection test timed out",
                    string.Join("\n", lines) + $"\nTCP connect to {host}:{port} timed out.");
            }

            using var ssl = new SslStream(tcp.GetStream(), false,
                (_, cert, _, errors) => ValidatePinned(cert, errors, caCert));
            // SslStream requires an exportable key context on Windows.
            using var clientCertForTls = ReExport(clientCert);
            ssl.AuthenticateAsClient(new SslClientAuthenticationOptions
            {
                TargetHost = host,
                ClientCertificates = new X509CertificateCollection { clientCertForTls },
            });
            lines.Add($"\nmTLS probe:\nhandshake OK ({ssl.SslProtocol}, cipher {ssl.NegotiatedCipherSuite})"
                      + $"\nmutual auth = {(ssl.IsMutuallyAuthenticated ? "yes" : "no")}");

            // RFC 6455 example nonce to satisfy strict validators.
            var request =
                $"GET {tunnelPath} HTTP/1.1\r\n" +
                $"Host: {host}\r\n" +
                "Connection: Upgrade\r\n" +
                "Upgrade: websocket\r\n" +
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
                "Sec-WebSocket-Version: 13\r\n" +
                "\r\n";
            var requestBytes = Encoding.ASCII.GetBytes(request);
            ssl.Write(requestBytes, 0, requestBytes.Length);
            ssl.Flush();

            tcp.ReceiveTimeout = 8000;
            var buffer = new byte[4096];
            var read = ssl.Read(buffer, 0, buffer.Length);
            var response = Encoding.ASCII.GetString(buffer, 0, Math.Max(read, 0));
            var statusLine = response.Split("\r\n").FirstOrDefault() ?? "";
            lines.Add($"\nWebSocket upgrade probe ({tunnelPath}):\n{statusLine}");

            if (response.Contains("101 Switching Protocols", StringComparison.OrdinalIgnoreCase))
            {
                return new DiagnosticsResult(true, "Connection OK (mTLS + tunnel upgrade)",
                    string.Join("\n", lines));
            }

            var summary = response.Contains(" 403", StringComparison.Ordinal)
                ? "Connection failed (tunnel path denied: 403)"
                : response.Contains(" 400", StringComparison.Ordinal)
                    ? "Connection failed (tunnel upgrade rejected: 400)"
                    : "Connection failed (tunnel upgrade not accepted)";
            return new DiagnosticsResult(false, summary, string.Join("\n", lines));
        }
        catch (Exception ex)
        {
            lines.Add($"\nmTLS probe failed: {Unwrap(ex).Message}");
            return new DiagnosticsResult(false, "Connection failed (mTLS handshake failed)",
                string.Join("\n", lines));
        }
    }

    private static bool ValidatePinned(X509Certificate? cert, SslPolicyErrors errors, X509Certificate2 caCert)
    {
        if (errors == SslPolicyErrors.None) return true;
        if (cert is null) return false;
        using var serverCert = new X509Certificate2(cert);
        using var chain = new X509Chain();
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.Add(caCert);
        return chain.Build(serverCert);
    }

    /// <summary>
    /// Round-trips the cert through PKCS#12 so the private key is usable for a
    /// TLS handshake on Windows (ephemeral PEM keys are otherwise rejected).
    /// </summary>
    private static X509Certificate2 ReExport(X509Certificate2 cert)
    {
        try
        {
            return new X509Certificate2(cert.Export(X509ContentType.Pkcs12));
        }
        catch (Exception)
        {
            return cert;
        }
    }

    private static Exception Unwrap(Exception ex) =>
        ex is AggregateException agg && agg.InnerException is not null ? agg.InnerException : ex;
}
