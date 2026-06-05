using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using JwSwarmNode.Core.Config;

namespace JwSwarmNode.Core.Enroll;

public sealed class EnrollArgs
{
    public required string BaseUrl { get; init; }
    public required string NodeId { get; init; }
    public required string Token { get; init; }
    public string? OutDir { get; init; }
    public bool WriteConfig { get; init; } = true;
}

internal sealed class EnrollRequest
{
    [JsonPropertyName("node_id")] public string NodeId { get; set; } = "";
    [JsonPropertyName("token")] public string Token { get; set; } = "";
    [JsonPropertyName("csr_pem")] public string CsrPem { get; set; } = "";
}

internal sealed class EnrollResponse
{
    [JsonPropertyName("node_cert_pem")] public string NodeCertPem { get; set; } = "";
    [JsonPropertyName("ca_cert_pem")] public string CaCertPem { get; set; } = "";
}

/// <summary>
/// Performs CSR-based mTLS bootstrap against the Fleet Manager, the Windows
/// analogue of the Linux <c>enroll.rs</c>. Generates an RSA key + CSR, posts it
/// with the enrollment token, and writes <c>node.pem</c> + <c>ca.crt</c>.
/// </summary>
public static class Enrollment
{
    public static async Task RunAsync(EnrollArgs args, CancellationToken ct = default)
    {
        var outDir = string.IsNullOrWhiteSpace(args.OutDir) ? NodeConfig.ConfigDir() : args.OutDir!;
        Directory.CreateDirectory(outDir);

        var keyPath = Path.Combine(outDir, "node.key");
        var certPath = Path.Combine(outDir, $"{args.NodeId}.crt");
        var nodePemPath = Path.Combine(outDir, "node.pem");
        var caPath = Path.Combine(outDir, "ca.crt");

        using var rsa = RSA.Create(2048);
        var csrPem = BuildCsrPem(rsa, args.NodeId);

        // Persist the private key in PKCS#8 PEM so it can be paired with the cert.
        var keyPem = PemEncode("PRIVATE KEY", rsa.ExportPkcs8PrivateKey());
        await File.WriteAllTextAsync(keyPath, keyPem, ct);

        var baseUrl = args.BaseUrl.Trim().TrimEnd('/');
        using var http = new HttpClient();

        // Fetch the bootstrap CA first (best-effort; enroll returns it too).
        try
        {
            var caBytes = await http.GetByteArrayAsync($"{baseUrl}/bootstrap/ca.crt", ct);
            await File.WriteAllBytesAsync(caPath, caBytes, ct);
        }
        catch (Exception)
        {
            // Non-fatal; the enroll response carries the CA as well.
        }

        var payload = new EnrollRequest
        {
            NodeId = args.NodeId,
            Token = args.Token,
            CsrPem = csrPem,
        };
        using var resp = await http.PostAsJsonInvariantAsync($"{baseUrl}/bootstrap/enroll", payload, ct);
        resp.EnsureSuccessStatusCode();
        var body = await resp.Content.ReadAsStringAsync(ct);
        var enrolled = JsonSerializer.Deserialize<EnrollResponse>(body)
                       ?? throw new InvalidOperationException("invalid enroll response");

        await File.WriteAllTextAsync(certPath, enrolled.NodeCertPem, ct);
        await File.WriteAllTextAsync(caPath, enrolled.CaCertPem, ct);

        // node.pem = certificate followed by private key.
        var combined = enrolled.NodeCertPem.TrimEnd() + "\n" + keyPem.TrimEnd() + "\n";
        await File.WriteAllTextAsync(nodePemPath, combined, ct);

        if (args.WriteConfig)
        {
            var cfg = NodeConfig.Load();
            cfg.NodeId = args.NodeId;
            cfg.NodeCert = nodePemPath;
            cfg.CaCert = caPath;
            cfg.FleetUrl = ToWssConnectUrl(args.BaseUrl);
            cfg.Save();
        }
    }

    private static string BuildCsrPem(RSA rsa, string nodeId)
    {
        var request = new CertificateRequest(
            $"CN={nodeId}", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var der = request.CreateSigningRequest();
        return PemEncode("CERTIFICATE REQUEST", der);
    }

    private static string PemEncode(string label, byte[] der)
    {
        var base64 = Convert.ToBase64String(der);
        var sb = new StringBuilder();
        sb.Append("-----BEGIN ").Append(label).Append("-----\n");
        for (var i = 0; i < base64.Length; i += 64)
        {
            sb.Append(base64, i, Math.Min(64, base64.Length - i)).Append('\n');
        }
        sb.Append("-----END ").Append(label).Append("-----\n");
        return sb.ToString();
    }

    public static string ToWssConnectUrl(string baseUrl)
    {
        var trimmed = baseUrl.Trim().TrimEnd('/');
        if (trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return "wss://" + trimmed["https://".Length..] + "/node/connect";
        }
        if (trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
        {
            return "ws://" + trimmed["http://".Length..] + "/node/connect";
        }
        return trimmed + "/node/connect";
    }
}

internal static class HttpClientJsonExtensions
{
    public static Task<HttpResponseMessage> PostAsJsonInvariantAsync<T>(
        this HttpClient http, string url, T value, CancellationToken ct)
    {
        var json = JsonSerializer.Serialize(value);
        var content = new StringContent(json, Encoding.UTF8, "application/json");
        return http.PostAsync(url, content, ct);
    }
}
