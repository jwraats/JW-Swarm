using System.Net.Security;
using System.Net.WebSockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading.Channels;

namespace JwSwarmNode.Core.Net;

/// <summary>
/// Outbound WSS tunnel to the Fleet Manager with mutual TLS. Auto-reconnects
/// with bounded backoff. Mirrors the Linux node's <c>tunnel.rs</c>.
/// </summary>
public sealed class TunnelClient : IAsyncDisposable
{
    private readonly string _fleetUrl;
    private readonly string _nodeCertPath;
    private readonly string _caCertPath;
    private readonly Channel<string> _outbound =
        Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });

    public TunnelClient(string fleetUrl, string nodeCertPath, string caCertPath)
    {
        _fleetUrl = fleetUrl;
        _nodeCertPath = nodeCertPath;
        _caCertPath = caCertPath;
    }

    /// <summary>Raised with each inbound message JSON string.</summary>
    public event Action<string>? MessageReceived;

    /// <summary>Raised when the socket connects (true) or disconnects (false).</summary>
    public event Action<bool>? ConnectionChanged;

    /// <summary>Queues a message JSON string for delivery.</summary>
    public void Send(string json) => _outbound.Writer.TryWrite(json);

    /// <summary>Runs the connect/reconnect loop until <paramref name="ct"/> is cancelled.</summary>
    public async Task RunAsync(CancellationToken ct)
    {
        var backoff = TimeSpan.FromSeconds(1);
        var maxBackoff = TimeSpan.FromSeconds(30);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await ConnectAndPumpAsync(ct);
                backoff = TimeSpan.FromSeconds(1); // reset after a clean session
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception)
            {
                ConnectionChanged?.Invoke(false);
            }

            try { await Task.Delay(backoff, ct); }
            catch (OperationCanceledException) { break; }
            backoff = TimeSpan.FromMilliseconds(Math.Min(maxBackoff.TotalMilliseconds, backoff.TotalMilliseconds * 2));
        }
    }

    private async Task ConnectAndPumpAsync(CancellationToken ct)
    {
        using var ws = new ClientWebSocket();
        ConfigureTls(ws.Options);

        await ws.ConnectAsync(new Uri(_fleetUrl), ct);
        ConnectionChanged?.Invoke(true);

        using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var sendTask = SendPumpAsync(ws, sessionCts.Token);
        var recvTask = ReceivePumpAsync(ws, sessionCts.Token);

        var completed = await Task.WhenAny(sendTask, recvTask);
        sessionCts.Cancel();
        await Task.WhenAll(
            sendTask.ContinueWith(_ => { }, TaskScheduler.Default),
            recvTask.ContinueWith(_ => { }, TaskScheduler.Default));

        ConnectionChanged?.Invoke(false);
        await completed; // surface any exception to trigger reconnect/backoff
    }

    private async Task SendPumpAsync(ClientWebSocket ws, CancellationToken ct)
    {
        while (await _outbound.Reader.WaitToReadAsync(ct))
        {
            while (_outbound.Reader.TryRead(out var json))
            {
                var bytes = Encoding.UTF8.GetBytes(json);
                await ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct);
            }
        }
    }

    private async Task ReceivePumpAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[1 << 16];
        var sb = new StringBuilder();
        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            sb.Clear();
            WebSocketReceiveResult result;
            do
            {
                result = await ws.ReceiveAsync(buffer, ct);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None);
                    return;
                }
                sb.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));
            }
            while (!result.EndOfMessage);

            var message = sb.ToString();
            if (message.Length > 0)
            {
                MessageReceived?.Invoke(message);
            }
        }
    }

    private void ConfigureTls(ClientWebSocketOptions options)
    {
        if (!string.IsNullOrWhiteSpace(_nodeCertPath) && File.Exists(_nodeCertPath))
        {
            try
            {
                var clientCert = X509Certificate2.CreateFromPemFile(_nodeCertPath, _nodeCertPath);
                options.ClientCertificates ??= new X509CertificateCollection();
                options.ClientCertificates.Add(clientCert);
            }
            catch (Exception)
            {
                // Without a client cert mTLS will fail at the server; let it surface there.
            }
        }

        X509Certificate2? caCert = LoadCa();
        options.RemoteCertificateValidationCallback = (_, cert, chain, errors) =>
            ValidateServer(cert, chain, errors, caCert);
    }

    private X509Certificate2? LoadCa()
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(_caCertPath) && File.Exists(_caCertPath))
            {
                return X509Certificate2.CreateFromPem(File.ReadAllText(_caCertPath));
            }
        }
        catch (Exception)
        {
            // No custom CA; fall back to system trust below.
        }
        return null;
    }

    private static bool ValidateServer(
        X509Certificate? cert, X509Chain? chain, SslPolicyErrors errors, X509Certificate2? caCert)
    {
        if (errors == SslPolicyErrors.None) return true;
        if (caCert is null || cert is null) return false;

        // Validate against the pinned CA as a custom trust anchor.
        using var serverCert = new X509Certificate2(cert);
        using var customChain = new X509Chain();
        customChain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        customChain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        customChain.ChainPolicy.CustomTrustStore.Add(caCert);
        return customChain.Build(serverCert);
    }

    public ValueTask DisposeAsync()
    {
        _outbound.Writer.TryComplete();
        return ValueTask.CompletedTask;
    }
}
