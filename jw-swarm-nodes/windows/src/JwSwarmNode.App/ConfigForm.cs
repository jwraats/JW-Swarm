using System.Drawing;
using System.Windows.Forms;
using JwSwarmNode.Core.Config;
using JwSwarmNode.Core.Net;

namespace JwSwarmNode.App;

/// <summary>
/// Configuration editor — the Windows analogue of the macOS
/// <c>ConfigWindowController</c>. Edits fleet URL, certificate paths, owner
/// limits, schedule, and model selection; can run connection diagnostics; and
/// applies changes by restarting the coordinator.
/// </summary>
internal sealed class ConfigForm : Form
{
    private readonly NodeConfig _config;
    private readonly Action _apply;

    private readonly TextBox _fleetUrl = new() { Width = 360 };
    private readonly TextBox _nodeCert = new() { Width = 360 };
    private readonly TextBox _caCert = new() { Width = 360 };
    private readonly NumericUpDown _gpuPowerPct = new() { Minimum = 1, Maximum = 100, Width = 100 };
    private readonly NumericUpDown _memoryLimitMb = new() { Minimum = 256, Maximum = 1_048_576, Increment = 1024, Width = 100 };
    private readonly TextBox _awakeFrom = new() { Width = 100, PlaceholderText = "HH:MM" };
    private readonly TextBox _awakeUntil = new() { Width = 100, PlaceholderText = "HH:MM" };
    private readonly TextBox _selectedModels = new() { Width = 360, PlaceholderText = "model ids, comma-separated (empty = all)" };

    public ConfigForm(NodeConfig config, Action apply)
    {
        _config = config;
        _apply = apply;

        Text = "JW Swarm Node — Configuration";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(12);

        var grid = new TableLayoutPanel
        {
            ColumnCount = 2,
            AutoSize = true,
            Dock = DockStyle.Top,
        };

        AddRow(grid, "Fleet URL:", _fleetUrl);
        AddRow(grid, "Node certificate (PEM):", _nodeCert);
        AddRow(grid, "CA certificate (PEM):", _caCert);
        AddRow(grid, "GPU power (%):", _gpuPowerPct);
        AddRow(grid, "Memory limit (MB):", _memoryLimitMb);
        AddRow(grid, "Awake from:", _awakeFrom);
        AddRow(grid, "Awake until:", _awakeUntil);
        AddRow(grid, "Selected models:", _selectedModels);

        var diagnosticsButton = new Button { Text = "Run Diagnostics", AutoSize = true };
        diagnosticsButton.Click += (_, _) => RunDiagnostics();
        var saveButton = new Button { Text = "Save && Apply", AutoSize = true };
        saveButton.Click += (_, _) => SaveAndApply();
        var cancelButton = new Button { Text = "Close", AutoSize = true };
        cancelButton.Click += (_, _) => Close();

        var buttons = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true,
            Dock = DockStyle.Bottom,
        };
        buttons.Controls.Add(saveButton);
        buttons.Controls.Add(cancelButton);
        buttons.Controls.Add(diagnosticsButton);

        var layout = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            AutoSize = true,
            Dock = DockStyle.Fill,
        };
        layout.Controls.Add(grid);
        layout.Controls.Add(buttons);
        Controls.Add(layout);

        LoadValues();
    }

    private static void AddRow(TableLayoutPanel grid, string label, Control control)
    {
        grid.Controls.Add(new Label
        {
            Text = label,
            AutoSize = true,
            TextAlign = ContentAlignment.MiddleRight,
            Anchor = AnchorStyles.Right,
            Margin = new Padding(3, 8, 3, 3),
        });
        control.Margin = new Padding(3, 5, 3, 3);
        grid.Controls.Add(control);
    }

    private void LoadValues()
    {
        _fleetUrl.Text = _config.FleetUrl;
        _nodeCert.Text = _config.NodeCert;
        _caCert.Text = _config.CaCert;
        _gpuPowerPct.Value = Math.Clamp(_config.Limits.GpuPowerPct, (byte)1, (byte)100);
        _memoryLimitMb.Value = Math.Clamp(_config.Limits.MemoryLimitMb, 256, 1_048_576);
        _awakeFrom.Text = _config.Schedule.AwakeFrom;
        _awakeUntil.Text = _config.Schedule.AwakeUntil;
        _selectedModels.Text = string.Join(", ", _config.SelectedModels);
    }

    private void SaveAndApply()
    {
        _config.FleetUrl = _fleetUrl.Text.Trim();
        _config.NodeCert = _nodeCert.Text.Trim();
        _config.CaCert = _caCert.Text.Trim();
        _config.Limits.GpuPowerPct = (byte)_gpuPowerPct.Value;
        _config.Limits.MemoryLimitMb = (ulong)_memoryLimitMb.Value;
        _config.Schedule.AwakeFrom = _awakeFrom.Text.Trim();
        _config.Schedule.AwakeUntil = _awakeUntil.Text.Trim();
        _config.SelectedModels = _selectedModels.Text
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToList();

        try
        {
            _apply();
            MessageBox.Show(this, "Configuration saved and applied.", "JW Swarm Node",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            Close();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"Failed to apply configuration: {ex.Message}", "JW Swarm Node",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void RunDiagnostics()
    {
        UseWaitCursor = true;
        try
        {
            // Diagnose the values currently in the form, not the saved config.
            var probe = new NodeConfig
            {
                FleetUrl = _fleetUrl.Text.Trim(),
                NodeCert = _nodeCert.Text.Trim(),
                CaCert = _caCert.Text.Trim(),
            };
            var result = ConnectionDiagnostics.Run(probe);
            MessageBox.Show(this, $"{result.Summary}\n\n{result.Details}",
                "Connection Diagnostics",
                MessageBoxButtons.OK,
                result.Success ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
        }
        finally
        {
            UseWaitCursor = false;
        }
    }
}
