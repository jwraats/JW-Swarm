using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using JwSwarmNode.Core;
using JwSwarmNode.Core.Config;

namespace JwSwarmNode.App;

/// <summary>
/// System-tray application context. Hosts the <see cref="NodeCoordinator"/> and
/// surfaces connection state, latency, throughput, models, the awake toggle,
/// and reconnect/disconnect controls — the Windows analogue of the macOS
/// menu-bar app.
/// </summary>
internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NodeConfig _config;
    private NodeCoordinator _coordinator;
    private readonly NotifyIcon _notifyIcon;
    private readonly ContextMenuStrip _menu;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _latencyItem;
    private readonly ToolStripMenuItem _tpsItem;
    private readonly ToolStripMenuItem _loadedModelItem;
    private readonly ToolStripMenuItem _readyModelsItem;
    private readonly ToolStripMenuItem _awakeItem;
    private readonly ToolStripMenuItem _reconnectItem;
    private readonly ToolStripMenuItem _disconnectItem;

    private ModelsForm? _modelsForm;
    private ConfigForm? _configForm;

    public TrayApplicationContext(NodeConfig config)
    {
        _config = config;
        _coordinator = new NodeCoordinator(config);

        _statusItem = new ToolStripMenuItem("Status: connecting…") { Enabled = false };
        _latencyItem = new ToolStripMenuItem("Latency: —") { Enabled = false };
        _tpsItem = new ToolStripMenuItem("Avg speed: —") { Enabled = false };
        _loadedModelItem = new ToolStripMenuItem("Loaded model: none") { Enabled = false };
        _readyModelsItem = new ToolStripMenuItem("Ready models: none") { Enabled = false };
        _awakeItem = new ToolStripMenuItem("Awake") { CheckOnClick = false, Checked = true };
        _awakeItem.Click += (_, _) => ToggleAwake();
        _reconnectItem = new ToolStripMenuItem("Reconnect", null, (_, _) => Reconnect());
        _disconnectItem = new ToolStripMenuItem("Disconnect", null, (_, _) => Disconnect());

        _menu = new ContextMenuStrip();
        _menu.Items.Add(_statusItem);
        _menu.Items.Add(_latencyItem);
        _menu.Items.Add(_tpsItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_loadedModelItem);
        _menu.Items.Add(_readyModelsItem);
        _menu.Items.Add(new ToolStripMenuItem("Models…", null, (_, _) => ShowModels()));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_awakeItem);
        _menu.Items.Add(_reconnectItem);
        _menu.Items.Add(_disconnectItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(new ToolStripMenuItem("Configuration…", null, (_, _) => ShowConfig()));
        _menu.Items.Add("Open config folder", null, (_, _) => OpenConfigFolder());
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("Quit", null, (_, _) => Quit());

        _notifyIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "JW Swarm Node",
            Visible = true,
            ContextMenuStrip = _menu,
        };

        _coordinator.StateChanged += OnStateChanged;
        _coordinator.Start();
        RefreshMenu();
    }

    /// <summary>Coordinator instance currently driving the node (for the forms).</summary>
    internal NodeCoordinator Coordinator => _coordinator;

    private void OnStateChanged()
    {
        // Marshal UI updates onto the UI thread.
        if (_menu.InvokeRequired)
        {
            _menu.BeginInvoke(RefreshMenu);
        }
        else
        {
            RefreshMenu();
        }
    }

    private void RefreshMenu()
    {
        var running = _coordinator.Running;
        var connected = _coordinator.Connected;
        _statusItem.Text = !running
            ? "Status: disconnected"
            : connected ? "Status: connected" : "Status: connecting…";
        _statusItem.ForeColor = connected ? Color.Green : (running ? Color.Orange : Color.Red);

        var latency = _coordinator.LatencyMs;
        _latencyItem.Text = latency is double ms ? $"Latency: {ms:F0} ms" : "Latency: —";

        var stats = _coordinator.Stats;
        _tpsItem.Text = stats.AvgTps > 0 ? $"Avg speed: {stats.AvgTps:F1} tok/s" : "Avg speed: —";

        var loaded = _coordinator.LoadedModel;
        _loadedModelItem.Text = string.IsNullOrEmpty(loaded)
            ? "Loaded model: none"
            : $"Loaded model: {loaded}";

        var ready = _coordinator.ReadyModels;
        _readyModelsItem.Text = ready.Count == 0
            ? "Ready models: none"
            : $"Ready models: {ready.Count} ({string.Join(", ", ready)})";

        _awakeItem.Checked = _coordinator.Awake;
        _awakeItem.Text = _coordinator.Awake ? "Awake" : "Asleep (click to wake)";
        _reconnectItem.Text = running ? "Reconnect" : "Connect";
        _disconnectItem.Enabled = running;

        _notifyIcon.Text = !running
            ? "JW Swarm Node — disconnected"
            : connected
                ? "JW Swarm Node — connected"
                : "JW Swarm Node — connecting";
    }

    private void ToggleAwake()
    {
        _coordinator.Awake = !_coordinator.Awake;
        RefreshMenu();
    }

    private void Reconnect()
    {
        _ = _coordinator.ReconnectAsync();
    }

    private void Disconnect()
    {
        _ = _coordinator.StopAsync();
    }

    private void ShowModels()
    {
        if (_modelsForm is { IsDisposed: false })
        {
            _modelsForm.Activate();
            return;
        }
        _modelsForm = new ModelsForm(this);
        _modelsForm.Show();
    }

    private void ShowConfig()
    {
        if (_configForm is { IsDisposed: false })
        {
            _configForm.Activate();
            return;
        }
        _configForm = new ConfigForm(_config, ApplyConfig);
        _configForm.Show();
    }

    /// <summary>Persists the edited config and restarts the coordinator with it.</summary>
    private void ApplyConfig()
    {
        _config.Save();
        var old = _coordinator;
        old.StateChanged -= OnStateChanged;
        _ = old.DisposeAsync();

        _coordinator = new NodeCoordinator(_config);
        _coordinator.StateChanged += OnStateChanged;
        _coordinator.Start();
        RefreshMenu();
    }

    private void OpenConfigFolder()
    {
        try
        {
            var dir = NodeConfig.ConfigDir();
            Directory.CreateDirectory(dir);
            Process.Start(new ProcessStartInfo { FileName = dir, UseShellExecute = true });
        }
        catch (Exception)
        {
            // Best-effort; ignore failures opening the folder.
        }
    }

    private void Quit()
    {
        _notifyIcon.Visible = false;
        _ = _coordinator.DisposeAsync();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _notifyIcon.Dispose();
            _menu.Dispose();
        }
        base.Dispose(disposing);
    }
}
