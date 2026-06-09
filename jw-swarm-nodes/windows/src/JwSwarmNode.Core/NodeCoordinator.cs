using System.Collections.Concurrent;
using JwSwarmNode.Core.Backend;
using JwSwarmNode.Core.Config;
using JwSwarmNode.Core.Gpu;
using JwSwarmNode.Core.Metrics;
using JwSwarmNode.Core.Models;
using JwSwarmNode.Core.Net;
using JwSwarmNode.Core.Proto;

namespace JwSwarmNode.Core;

/// <summary>Lifecycle state of a catalog model on this node.</summary>
public enum ModelStateKind
{
    Available,
    Downloading,
    Ready,
    Failed,
    Unsupported,
}

/// <summary>Per-model state surfaced to the UI.</summary>
public readonly record struct ModelState(ModelStateKind Kind, double Progress, string? Detail);

/// <summary>
/// Orchestrates the node lifecycle: tunnel connection, registration, catalog
/// download, heartbeats, schedule state, and prompt dispatch. The Windows
/// analogue of the macOS <c>NodeCoordinator</c> and the Linux run loop.
/// </summary>
public sealed class NodeCoordinator : IAsyncDisposable
{
    private readonly NodeConfig _config;
    private readonly BackendManager _backend;
    private readonly Dictionary<string, CatalogModel> _catalog = new();
    private readonly object _catalogLock = new();

    // Download tracking: dedup in-flight downloads and memoize failures by
    // (download_url, sha256) fingerprint so identical artifacts are not retried
    // on every catalog pass, mirroring the macOS coordinator.
    private readonly HashSet<string> _downloading = new();
    private readonly Dictionary<string, (string Url, string Sha256)> _failedFingerprints = new();
    private readonly object _downloadLock = new();

    private readonly ConcurrentDictionary<string, ModelState> _modelStates = new();

    private TunnelClient? _tunnel;
    private CancellationTokenSource? _cts;
    private Task? _runTask;
    private volatile bool _awake = true;

    public NodeCoordinator(NodeConfig config)
    {
        _config = config;
        _backend = new BackendManager(config.Limits.MemoryLimitMb);
    }

    public bool Connected { get; private set; }
    public bool Running => _runTask is not null;
    public string? LoadedModel => _backend.LoadedModel;
    public IReadOnlyList<string> ReadyModels => _backend.Ready();
    public IReadOnlyList<string> LoadedModels => _backend.LoadedModels();
    public double? LatencyMs => _tunnel?.LatencyMs;
    public BackendStats Stats => _backend.Stats();
    public IReadOnlyDictionary<string, ModelTokenUsage> TokenUsage => _backend.TokenUsage();

    /// <summary>Snapshot of per-model states for the models UI.</summary>
    public IReadOnlyDictionary<string, ModelState> ModelStates =>
        new Dictionary<string, ModelState>(_modelStates);

    /// <summary>Snapshot of the last received catalog, keyed by model id.</summary>
    public IReadOnlyDictionary<string, CatalogModel> Catalog
    {
        get { lock (_catalogLock) { return new Dictionary<string, CatalogModel>(_catalog); } }
    }

    /// <summary>Owner awake/asleep toggle (mirrors the macOS menu toggle).</summary>
    public bool Awake
    {
        get => _awake;
        set
        {
            if (_awake == value) return;
            _awake = value;
            SendScheduleState();
            SendHeartbeat();
            StateChanged?.Invoke();
        }
    }

    /// <summary>Raised when connection state or model state changes (for UI refresh).</summary>
    public event Action? StateChanged;

    public void Start()
    {
        if (_runTask is not null) return;
        _cts = new CancellationTokenSource();
        _runTask = RunAsync(_cts.Token);
        StateChanged?.Invoke();
    }

    /// <summary>Stops the tunnel and timers without disposing the coordinator.</summary>
    public async Task StopAsync()
    {
        var cts = _cts;
        var task = _runTask;
        var tunnel = _tunnel;
        _cts = null;
        _runTask = null;
        _tunnel = null;

        cts?.Cancel();
        if (task is not null)
        {
            try { await task; } catch (Exception) { /* shutdown */ }
        }
        if (tunnel is not null)
        {
            await tunnel.DisposeAsync();
        }
        cts?.Dispose();
        Connected = false;
        StateChanged?.Invoke();
    }

    /// <summary>Drops the current session and reconnects (or starts if stopped).</summary>
    public async Task ReconnectAsync()
    {
        if (_runTask is null)
        {
            Start();
            return;
        }
        await StopAsync();
        Start();
    }

    private async Task RunAsync(CancellationToken ct)
    {
        Directory.CreateDirectory(_config.ModelDir());

        _tunnel = new TunnelClient(_config.FleetUrl, _config.NodeCert, _config.CaCert);
        _tunnel.ConnectionChanged += OnConnectionChanged;
        _tunnel.MessageReceived += OnMessage;

        var tunnelTask = _tunnel.RunAsync(ct);
        var heartbeatTask = HeartbeatLoopAsync(ct);
        var repollTask = CatalogRepollLoopAsync(ct);

        await Task.WhenAll(tunnelTask, heartbeatTask, repollTask);
    }

    private void OnConnectionChanged(bool connected)
    {
        Connected = connected;
        if (connected)
        {
            // Re-register on every (re)connect so the fleet manager always has
            // fresh node info, then request the catalog and report status.
            SendRegister();
            _tunnel?.Send(MessageCodec.EncodeBare(MessageType.CatalogRequest));
            SendHeartbeat();
            SendModelStatus();
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

    private void SendHeartbeat()
    {
        if (!Connected) return;
        var metrics = MetricsCollector.Collect();
        metrics.Tps = _backend.Stats().AvgTps;
        metrics.LatencyMs = _tunnel?.LatencyMs ?? 0;
        var hb = new Heartbeat
        {
            NodeId = _config.NodeId,
            Metrics = metrics,
            ScheduleState = _awake ? ScheduleStateValue.Awake : ScheduleStateValue.Asleep,
        };
        _tunnel?.Send(MessageCodec.Encode(MessageType.Heartbeat, hb));
    }

    private void SendScheduleState()
    {
        if (!Connected) return;
        _tunnel?.Send(MessageCodec.Encode(MessageType.ScheduleState, new ScheduleState
        {
            NodeId = _config.NodeId,
            State = _awake ? ScheduleStateValue.Awake : ScheduleStateValue.Asleep,
        }));
    }

    private void SendModelStatus()
    {
        if (!Connected) return;
        _tunnel?.Send(MessageCodec.Encode(MessageType.ModelStatus, new ModelStatus
        {
            NodeId = _config.NodeId,
            ReadyModels = _backend.Ready(),
        }));
    }

    private async Task HeartbeatLoopAsync(CancellationToken ct)
    {
        var timer = new PeriodicTimer(TimeSpan.FromSeconds(30));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
            {
                SendHeartbeat();
            }
        }
        catch (OperationCanceledException)
        {
            // Shutdown requested.
        }
    }

    /// <summary>
    /// Re-requests the catalog every 60s while connected with no ready models,
    /// so a node that came up before models were published self-heals.
    /// </summary>
    private async Task CatalogRepollLoopAsync(CancellationToken ct)
    {
        var timer = new PeriodicTimer(TimeSpan.FromSeconds(60));
        try
        {
            while (await timer.WaitForNextTickAsync(ct))
            {
                if (Connected && _backend.Ready().Count == 0)
                {
                    _tunnel?.Send(MessageCodec.EncodeBare(MessageType.CatalogRequest));
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Shutdown requested.
        }
    }

    private void OnMessage(string json)
    {
        try
        {
            var inbound = MessageCodec.Parse(json);
            switch (inbound.Type)
            {
                case MessageType.CatalogResponse:
                    HandleCatalog(MessageCodec.DeserializePayload<CatalogResponse>(inbound.Payload));
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

    private void HandleCatalog(CatalogResponse response)
    {
        lock (_catalogLock)
        {
            _catalog.Clear();
            foreach (var model in response.Models)
            {
                _catalog[model.Id] = model;
            }
        }

        var modelRoot = _config.ModelDir();
        foreach (var model in response.Models)
        {
            var selected = _config.SelectedModels.Count == 0
                           || _config.SelectedModels.Contains(model.Id);
            if (!selected) continue;

            // Only llama.cpp artifacts can run on this node.
            if (model.Backend != BackendKind.LlamaCpp)
            {
                _modelStates[model.Id] = new ModelState(
                    ModelStateKind.Unsupported, 0, $"backend {model.Backend} not supported");
                continue;
            }

            // Already downloaded and registered: nothing to do.
            if (_backend.Ready().Contains(model.Id))
            {
                _modelStates[model.Id] = new ModelState(ModelStateKind.Ready, 1, null);
                continue;
            }

            lock (_downloadLock)
            {
                // Skip in-flight downloads and known-bad artifacts.
                if (_downloading.Contains(model.Id)) continue;
                if (_failedFingerprints.TryGetValue(model.Id, out var fp) &&
                    fp.Url == model.DownloadUrl && fp.Sha256 == model.Sha256)
                {
                    continue;
                }
                _downloading.Add(model.Id);
            }

            _modelStates[model.Id] = new ModelState(ModelStateKind.Downloading, 0, null);
            StateChanged?.Invoke();
            var m = model;
            _ = Task.Run(() => DownloadModelAsync(m, modelRoot));
        }

        SendModelStatus();
        StateChanged?.Invoke();
    }

    private async Task DownloadModelAsync(CatalogModel model, string modelRoot)
    {
        try
        {
            var downloader = new ModelDownloader
            {
                Progress = (written, total) =>
                {
                    if (total > 0)
                    {
                        var fraction = Math.Clamp((double)written / total, 0, 1);
                        _modelStates[model.Id] = new ModelState(
                            ModelStateKind.Downloading, fraction, null);
                    }
                },
            };
            var dir = await downloader.DownloadModelAsync(model, modelRoot);
            _backend.Register(model.Id, dir);

            var ready = _backend.Ready().Contains(model.Id);
            _modelStates[model.Id] = ready
                ? new ModelState(ModelStateKind.Ready, 1, null)
                : new ModelState(ModelStateKind.Failed, 0, "artifact exceeds memory limit");
            lock (_downloadLock)
            {
                _downloading.Remove(model.Id);
                _failedFingerprints.Remove(model.Id);
            }
            SendModelStatus();
        }
        catch (Exception ex)
        {
            lock (_downloadLock)
            {
                _downloading.Remove(model.Id);
                _failedFingerprints[model.Id] = (model.DownloadUrl, model.Sha256);
            }
            _modelStates[model.Id] = new ModelState(ModelStateKind.Failed, 0, ex.Message);
        }
        StateChanged?.Invoke();
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        _backend.Dispose();
    }
}
