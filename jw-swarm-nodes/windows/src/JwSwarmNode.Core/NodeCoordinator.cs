using JwSwarmNode.Core.Backend;
using JwSwarmNode.Core.Config;
using JwSwarmNode.Core.Gpu;
using JwSwarmNode.Core.Metrics;
using JwSwarmNode.Core.Models;
using JwSwarmNode.Core.Net;
using JwSwarmNode.Core.Proto;

namespace JwSwarmNode.Core;

/// <summary>
/// Orchestrates the node lifecycle: tunnel connection, registration, catalog
/// download, heartbeats, and prompt dispatch. The Windows analogue of the Linux
/// <c>main.rs</c> run loop and the macOS <c>NodeCoordinator</c>.
/// </summary>
public sealed class NodeCoordinator : IAsyncDisposable
{
    private readonly NodeConfig _config;
    private readonly BackendManager _backend;
    private readonly ModelDownloader _downloader = new();
    private readonly Dictionary<string, CatalogModel> _catalog = new();
    private TunnelClient? _tunnel;
    private CancellationTokenSource? _cts;
    private Task? _runTask;

    public NodeCoordinator(NodeConfig config)
    {
        _config = config;
        _backend = new BackendManager(config.Limits.MemoryLimitMb);
    }

    public bool Connected { get; private set; }
    public string? LoadedModel => _backend.LoadedModel;
    public IReadOnlyList<string> ReadyModels => _backend.Ready();

    /// <summary>Raised when connection state or model state changes (for UI refresh).</summary>
    public event Action? StateChanged;

    public void Start()
    {
        if (_runTask is not null) return;
        _cts = new CancellationTokenSource();
        _runTask = RunAsync(_cts.Token);
    }

    private async Task RunAsync(CancellationToken ct)
    {
        Directory.CreateDirectory(_config.ModelDir());

        _tunnel = new TunnelClient(_config.FleetUrl, _config.NodeCert, _config.CaCert);
        _tunnel.ConnectionChanged += OnConnectionChanged;
        _tunnel.MessageReceived += OnMessage;

        var tunnelTask = _tunnel.RunAsync(ct);
        var heartbeatTask = HeartbeatLoopAsync(ct);

        await Task.WhenAll(tunnelTask, heartbeatTask);
    }

    private void OnConnectionChanged(bool connected)
    {
        Connected = connected;
        if (connected)
        {
            SendRegister();
            _tunnel?.Send(MessageCodec.EncodeBare(MessageType.CatalogRequest));
        }
        StateChanged?.Invoke();
    }

    private void SendRegister()
    {
        var vendor = GpuDetect.Vendor();
        var register = new Register
        {
            NodeId = _config.NodeId,
            Hostname = _config.Hostname,
            Os = OsKind.Windows,
            Gpu = new GpuInfo
            {
                Vendor = vendor,
                Name = GpuDetect.Name(vendor),
                VramMb = _config.Limits.MemoryLimitMb,
            },
            Limits = new OwnerLimits
            {
                GpuPowerPct = _config.Limits.GpuPowerPct,
                MemoryLimitMb = _config.Limits.MemoryLimitMb,
            },
            SelectedModels = _config.SelectedModels,
        };
        _tunnel?.Send(MessageCodec.Encode(MessageType.Register, register));
    }

    private async Task HeartbeatLoopAsync(CancellationToken ct)
    {
        var timer = new PeriodicTimer(TimeSpan.FromSeconds(30));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
            {
                if (!Connected) continue;
                var hb = new Heartbeat
                {
                    NodeId = _config.NodeId,
                    Metrics = MetricsCollector.Collect(),
                    ScheduleState = ScheduleStateValue.Awake,
                };
                _tunnel?.Send(MessageCodec.Encode(MessageType.Heartbeat, hb));
            }
        }
        catch (OperationCanceledException)
        {
            // Shutdown requested.
        }
    }

    private async void OnMessage(string json)
    {
        try
        {
            var inbound = MessageCodec.Parse(json);
            switch (inbound.Type)
            {
                case MessageType.CatalogResponse:
                    await HandleCatalogAsync(MessageCodec.DeserializePayload<CatalogResponse>(inbound.Payload));
                    break;
                case MessageType.PromptDispatch:
                    var pd = MessageCodec.DeserializePayload<PromptDispatch>(inbound.Payload);
                    _backend.Dispatch(pd, s => _tunnel?.Send(s));
                    StateChanged?.Invoke();
                    break;
                case MessageType.Error:
                    // Server-side error; nothing actionable on the node.
                    break;
            }
        }
        catch (Exception)
        {
            // Drop malformed messages rather than tearing down the tunnel.
        }
    }

    private async Task HandleCatalogAsync(CatalogResponse response)
    {
        var modelRoot = _config.ModelDir();
        foreach (var model in response.Models)
        {
            var selected = _config.SelectedModels.Count == 0
                           || _config.SelectedModels.Contains(model.Id);
            if (!selected) continue;
            try
            {
                var dir = await _downloader.DownloadModelAsync(model, modelRoot);
                _backend.Register(model.Id, dir);
            }
            catch (Exception)
            {
                // Skip models that fail to download/verify; others remain available.
            }
        }

        _catalog.Clear();
        foreach (var model in response.Models)
        {
            _catalog[model.Id] = model;
        }

        _tunnel?.Send(MessageCodec.Encode(MessageType.ModelStatus, new ModelStatus
        {
            NodeId = _config.NodeId,
            ReadyModels = _backend.Ready(),
        }));
        StateChanged?.Invoke();
    }

    public async ValueTask DisposeAsync()
    {
        _cts?.Cancel();
        if (_runTask is not null)
        {
            try { await _runTask; } catch (Exception) { /* ignore shutdown errors */ }
        }
        if (_tunnel is not null)
        {
            await _tunnel.DisposeAsync();
        }
        _cts?.Dispose();
    }
}
