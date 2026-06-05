using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using JwSwarmNode.Core;
using JwSwarmNode.Core.Config;

namespace JwSwarmNode.App;

/// <summary>
/// System-tray application context. Hosts the <see cref="NodeCoordinator"/> and
/// surfaces connection state, the loaded model, and ready models in the menu —
/// the Windows analogue of the macOS menu-bar app.
/// </summary>
internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NodeConfig _config;
    private readonly NodeCoordinator _coordinator;
    private readonly NotifyIcon _notifyIcon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _loadedModelItem;
    private readonly ToolStripMenuItem _readyModelsItem;

    public TrayApplicationContext(NodeConfig config)
    {
        _config = config;
        _coordinator = new NodeCoordinator(config);

        _statusItem = new ToolStripMenuItem("Status: connecting…") { Enabled = false };
        _loadedModelItem = new ToolStripMenuItem("Loaded model: none") { Enabled = false };
        _readyModelsItem = new ToolStripMenuItem("Ready models: none") { Enabled = false };

        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(_loadedModelItem);
        menu.Items.Add(_readyModelsItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Open config folder", null, (_, _) => OpenConfigFolder());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Quit());

        _notifyIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "JW Swarm Node",
            Visible = true,
            ContextMenuStrip = menu,
        };

        _coordinator.StateChanged += OnStateChanged;
        _coordinator.Start();
        RefreshMenu();
    }

    private void OnStateChanged()
    {
        // Marshal UI updates onto the UI thread.
        if (_notifyIcon.ContextMenuStrip is { } strip && strip.InvokeRequired)
        {
            strip.BeginInvoke(RefreshMenu);
        }
        else
        {
            RefreshMenu();
        }
    }

    private void RefreshMenu()
    {
        _statusItem.Text = _coordinator.Connected ? "Status: connected" : "Status: connecting…";

        var loaded = _coordinator.LoadedModel;
        _loadedModelItem.Text = string.IsNullOrEmpty(loaded)
            ? "Loaded model: none"
            : $"Loaded model: {loaded}";

        var ready = _coordinator.ReadyModels;
        _readyModelsItem.Text = ready.Count == 0
            ? "Ready models: none"
            : $"Ready models: {string.Join(", ", ready)}";

        _notifyIcon.Text = _coordinator.Connected
            ? "JW Swarm Node — connected"
            : "JW Swarm Node — connecting";
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
        }
        base.Dispose(disposing);
    }
}
