using System.Text.Json;
using System.Text.Json.Serialization;

namespace JwSwarmNode.Core.Proto;

// ---- Enumerated wire values (kept as strings to match the serde wire format) ----

public static class ScheduleStateValue
{
    public const string Awake = "awake";
    public const string Asleep = "asleep";
    public const string Draining = "draining";
}

public static class GpuVendor
{
    public const string Nvidia = "nvidia";
    public const string Amd = "amd";
    public const string Apple = "apple";
    public const string Intel = "intel";
}

public static class OsKind
{
    public const string Macos = "macos";
    public const string Linux = "linux";
    public const string Windows = "windows";
}

public static class BackendKind
{
    public const string Vllm = "vllm";
    public const string LlamaCpp = "llama.cpp";
    public const string Mlx = "mlx";
}

// ---- Payload DTOs (field names mirror the Rust/Swift mirrors exactly) ----

public sealed class GpuInfo
{
    [JsonPropertyName("vendor")] public string Vendor { get; set; } = GpuVendor.Nvidia;
    [JsonPropertyName("name")] public string Name { get; set; } = "GPU";
    [JsonPropertyName("vram_mb")] public ulong VramMb { get; set; }
}

public sealed class OwnerLimits
{
    [JsonPropertyName("gpu_power_pct")] public byte GpuPowerPct { get; set; } = 100;
    [JsonPropertyName("memory_limit_mb")] public ulong MemoryLimitMb { get; set; } = 24000;
}

public sealed class Metrics
{
    [JsonPropertyName("vram_used_mb")] public ulong VramUsedMb { get; set; }
    [JsonPropertyName("vram_total_mb")] public ulong VramTotalMb { get; set; }
    [JsonPropertyName("gpu_util_pct")] public double GpuUtilPct { get; set; }
    [JsonPropertyName("tps")] public double Tps { get; set; }
    [JsonPropertyName("latency_ms")] public double LatencyMs { get; set; }
    [JsonPropertyName("in_flight")] public uint InFlight { get; set; }
}

public sealed class CatalogModel
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("display_name")] public string DisplayName { get; set; } = "";
    [JsonPropertyName("download_url")] public string DownloadUrl { get; set; } = "";
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
    [JsonPropertyName("size_bytes")] public ulong SizeBytes { get; set; }
    [JsonPropertyName("context_length")] public uint ContextLength { get; set; }
    [JsonPropertyName("params_billions")] public double ParamsBillions { get; set; }
    [JsonPropertyName("backend")] public string Backend { get; set; } = BackendKind.Vllm;
}

public sealed class Usage
{
    [JsonPropertyName("prompt_tokens")] public uint PromptTokens { get; set; }
    [JsonPropertyName("completion_tokens")] public uint CompletionTokens { get; set; }
    [JsonPropertyName("total_tokens")] public uint TotalTokens { get; set; }
}

public sealed class Register
{
    [JsonPropertyName("node_id")] public string NodeId { get; set; } = "";
    [JsonPropertyName("hostname")] public string Hostname { get; set; } = "";
    [JsonPropertyName("os")] public string Os { get; set; } = OsKind.Windows;
    [JsonPropertyName("gpu")] public GpuInfo Gpu { get; set; } = new();
    [JsonPropertyName("limits")] public OwnerLimits Limits { get; set; } = new();
    [JsonPropertyName("selected_models")] public List<string> SelectedModels { get; set; } = new();
}

public sealed class CatalogResponse
{
    [JsonPropertyName("models")] public List<CatalogModel> Models { get; set; } = new();
}

public sealed class Heartbeat
{
    [JsonPropertyName("node_id")] public string NodeId { get; set; } = "";
    [JsonPropertyName("metrics")] public Metrics Metrics { get; set; } = new();
    [JsonPropertyName("schedule_state")] public string ScheduleState { get; set; } = ScheduleStateValue.Awake;
}

public sealed class ModelStatus
{
    [JsonPropertyName("node_id")] public string NodeId { get; set; } = "";
    [JsonPropertyName("ready_models")] public List<string> ReadyModels { get; set; } = new();
}

public sealed class ScheduleState
{
    [JsonPropertyName("node_id")] public string NodeId { get; set; } = "";
    [JsonPropertyName("state")] public string State { get; set; } = ScheduleStateValue.Awake;
}

public sealed class PromptDispatch
{
    [JsonPropertyName("request_id")] public string RequestId { get; set; } = "";
    [JsonPropertyName("model")] public string Model { get; set; } = "";
    [JsonPropertyName("payload")] public JsonElement Payload { get; set; }
}

public sealed class TokenChunk
{
    [JsonPropertyName("request_id")] public string RequestId { get; set; } = "";
    [JsonPropertyName("delta")] public string Delta { get; set; } = "";
    [JsonPropertyName("index")] public uint Index { get; set; }
}

public sealed class Done
{
    [JsonPropertyName("request_id")] public string RequestId { get; set; } = "";
    [JsonPropertyName("usage")] public Usage Usage { get; set; } = new();
}

public sealed class ProtoError
{
    [JsonPropertyName("request_id")] public string RequestId { get; set; } = "";
    [JsonPropertyName("message")] public string Message { get; set; } = "";
}
