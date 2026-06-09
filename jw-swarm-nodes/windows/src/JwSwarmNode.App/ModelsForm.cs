using System.Windows.Forms;
using JwSwarmNode.Core;

namespace JwSwarmNode.App;

/// <summary>
/// Models status window — the Windows analogue of the macOS
/// <c>ModelsWindowController</c>. Shows each catalog model's download/ready
/// state with progress, plus per-model token usage, refreshing live as the
/// coordinator state changes.
/// </summary>
internal sealed class ModelsForm : Form
{
    private readonly TrayApplicationContext _owner;
    private readonly ListView _list;

    public ModelsForm(TrayApplicationContext owner)
    {
        _owner = owner;

        Text = "JW Swarm Node — Models";
        StartPosition = FormStartPosition.CenterScreen;
        Width = 760;
        Height = 360;

        _list = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true,
            HeaderStyle = ColumnHeaderStyle.Nonclickable,
        };
        _list.Columns.Add("Model", 180);
        _list.Columns.Add("Backend", 80);
        _list.Columns.Add("Size", 80);
        _list.Columns.Add("Status", 160);
        _list.Columns.Add("Tokens in/out", 110);
        _list.Columns.Add("Requests", 70);
        Controls.Add(_list);

        _owner.Coordinator.StateChanged += OnStateChanged;
        FormClosed += (_, _) => _owner.Coordinator.StateChanged -= OnStateChanged;

        Refresh_();
    }

    private void OnStateChanged()
    {
        if (IsDisposed) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(Refresh_); } catch (Exception) { /* closing */ }
        }
        else
        {
            Refresh_();
        }
    }

    private void Refresh_()
    {
        var coordinator = _owner.Coordinator;
        var catalog = coordinator.Catalog;
        var states = coordinator.ModelStates;
        var usage = coordinator.TokenUsage;
        var ready = coordinator.ReadyModels;

        _list.BeginUpdate();
        _list.Items.Clear();

        var ids = catalog.Keys.Union(states.Keys).OrderBy(s => s, StringComparer.Ordinal);
        foreach (var id in ids)
        {
            catalog.TryGetValue(id, out var model);
            var name = model?.DisplayName is { Length: > 0 } dn ? $"{dn} ({id})" : id;
            var backend = model?.Backend ?? "?";
            var size = model is null ? "" : $"{model.SizeBytes / (1024.0 * 1024 * 1024):F1} GB";

            string status;
            if (states.TryGetValue(id, out var state))
            {
                status = state.Kind switch
                {
                    ModelStateKind.Downloading => $"downloading {state.Progress * 100:F0}%",
                    ModelStateKind.Ready => "ready",
                    ModelStateKind.Failed => $"failed: {state.Detail}",
                    ModelStateKind.Unsupported => $"unsupported ({state.Detail})",
                    _ => "available",
                };
            }
            else
            {
                status = ready.Contains(id) ? "ready" : "available";
            }

            var tokens = usage.TryGetValue(id, out var u)
                ? $"{u.InputTokens}/{u.OutputTokens}"
                : "—";
            var requests = usage.TryGetValue(id, out var u2) ? u2.Requests.ToString() : "—";

            _list.Items.Add(new ListViewItem(new[] { name, backend, size, status, tokens, requests }));
        }

        _list.EndUpdate();
    }
}
