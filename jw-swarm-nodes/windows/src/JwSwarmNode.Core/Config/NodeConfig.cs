using System.Text.Json;
using System.Text.Json.Serialization;

namespace JwSwarmNode.Core.Config;

public sealed class Limits
{
    [JsonPropertyName("gpu_power_pct")] public byte GpuPowerPct { get; set; } = 100;
    [JsonPropertyName("memory_limit_mb")] public ulong MemoryLimitMb { get; set; } = 24000;
}

public sealed class Schedule
{
    [JsonPropertyName("awake_from")] public string AwakeFrom { get; set; } = "";
    [JsonPropertyName("awake_until")] public string AwakeUntil { get; set; } = "";
}

/// <summary>
/// Persistent node configuration, the Windows analogue of the Linux
/// <c>config.rs</c> store. Persisted as JSON under
/// <c>%APPDATA%\JWSwarmNode\config.json</c>.
/// </summary>
public sealed class NodeConfig
{
    [JsonPropertyName("fleet_url")] public string FleetUrl { get; set; } = "wss://localhost/node/connect";
    [JsonPropertyName("node_id")] public string NodeId { get; set; } = "";
    [JsonPropertyName("hostname")] public string Hostname { get; set; } = "";
    [JsonPropertyName("node_cert")] public string NodeCert { get; set; } = "";
    [JsonPropertyName("ca_cert")] public string CaCert { get; set; } = "";
    [JsonPropertyName("limits")] public Limits Limits { get; set; } = new();
    [JsonPropertyName("schedule")] public Schedule Schedule { get; set; } = new();
    [JsonPropertyName("selected_models")] public List<string> SelectedModels { get; set; } = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    /// <summary>Base directory for configuration (overridable via JW_CONFIG_DIR).</summary>
    public static string ConfigDir()
    {
        var env = Environment.GetEnvironmentVariable("JW_CONFIG_DIR");
        if (!string.IsNullOrWhiteSpace(env)) return env;
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(appData, "JWSwarmNode");
    }

    public static string ConfigPath() => Path.Combine(ConfigDir(), "config.json");

    /// <summary>Base directory for downloaded model artifacts (overridable via JW_DATA_DIR).</summary>
    public string DataDir()
    {
        var env = Environment.GetEnvironmentVariable("JW_DATA_DIR");
        if (!string.IsNullOrWhiteSpace(env)) return env;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(local, "JWSwarmNode");
    }

    public string ModelDir() => Path.Combine(DataDir(), "models");

    /// <summary>Loads config from disk, generating a fresh one on first run.</summary>
    public static NodeConfig Load()
    {
        var path = ConfigPath();
        if (File.Exists(path))
        {
            try
            {
                var text = File.ReadAllText(path);
                var cfg = JsonSerializer.Deserialize<NodeConfig>(text, JsonOptions);
                if (cfg is not null) return cfg;
            }
            catch (Exception)
            {
                // Fall through to regenerate on a corrupt config.
            }
        }
        return Generate();
    }

    /// <summary>Creates and persists a default configuration with a new node id.</summary>
    public static NodeConfig Generate()
    {
        var cfg = new NodeConfig
        {
            FleetUrl = Environment.GetEnvironmentVariable("JW_FLEET_URL")
                       ?? "wss://localhost/node/connect",
            NodeId = Guid.NewGuid().ToString(),
            Hostname = SafeHostname(),
            NodeCert = Path.Combine(ConfigDir(), "node.pem"),
            CaCert = Path.Combine(ConfigDir(), "ca.crt"),
        };
        cfg.Save();
        return cfg;
    }

    public void Save()
    {
        var dir = ConfigDir();
        Directory.CreateDirectory(dir);
        var text = JsonSerializer.Serialize(this, JsonOptions);
        File.WriteAllText(ConfigPath(), text);
    }

    private static string SafeHostname()
    {
        try { return Environment.MachineName; }
        catch { return "jw-node"; }
    }
}
