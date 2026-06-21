using System.Diagnostics;
using System.Text;
using System.Text.Json;
using LLama;
using LLama.Common;
using LLama.Sampling;
using JwSwarmNode.Core.Proto;

namespace JwSwarmNode.Core.Backend;

/// <summary>Cumulative token accounting for a single model.</summary>
public sealed class ModelTokenUsage
{
    public ulong InputTokens { get; set; }
    public ulong OutputTokens { get; set; }
    public ulong Requests { get; set; }
}

/// <summary>Rolling throughput statistics across all completions.</summary>
public readonly record struct BackendStats(double AvgTps, double LastTps);

/// <summary>
/// Real llama.cpp inference backend built on LLamaSharp. Mirrors the macOS
/// <c>LlamaBackend</c>: multiple models stay resident in memory LRU-style
/// within the configured memory budget (artifact file size used as the
/// resident size), prompts run one at a time with greedy sampling, and
/// per-model token usage plus throughput stats are tracked.
/// </summary>
public sealed class BackendManager : IDisposable
{
    private sealed class ResidentModel
    {
        public required LLamaWeights Weights { get; init; }
        public required ModelParams Parameters { get; init; }
        public required ulong ResidentSizeMb { get; init; }
    }

    private readonly object _lock = new();
    private readonly Dictionary<string, string> _ready = new();          // id -> dir
    private readonly Dictionary<string, ResidentModel> _loaded = new();  // id -> resident model
    private readonly List<string> _loadedOrder = new();                  // LRU order, oldest first
    private readonly Dictionary<string, ModelTokenUsage> _tokenUsage = new();
    private readonly SemaphoreSlim _inference = new(1, 1);
    private readonly ulong _memoryLimitMb;

    private ulong _totalCompletionTokens;
    private double _totalGenerationSeconds;
    private double _lastTps;

    public BackendManager(ulong memoryLimitMb)
    {
        _memoryLimitMb = memoryLimitMb == 0 ? 24000 : memoryLimitMb;
    }

    /// <summary>Most recently used resident model id, if any.</summary>
    public string? LoadedModel
    {
        get { lock (_lock) { return _loadedOrder.Count > 0 ? _loadedOrder[^1] : null; } }
    }

    /// <summary>Models currently resident in memory (LRU order, oldest first).</summary>
    public List<string> LoadedModels()
    {
        lock (_lock) { return new List<string>(_loadedOrder); }
    }

    /// <summary>Rolling throughput statistics.</summary>
    public BackendStats Stats()
    {
        lock (_lock)
        {
            var avg = _totalGenerationSeconds > 0
                ? _totalCompletionTokens / _totalGenerationSeconds
                : 0.0;
            return new BackendStats(avg, _lastTps);
        }
    }

    /// <summary>Per-model cumulative token usage.</summary>
    public Dictionary<string, ModelTokenUsage> TokenUsage()
    {
        lock (_lock)
        {
            return _tokenUsage.ToDictionary(
                kv => kv.Key,
                kv => new ModelTokenUsage
                {
                    InputTokens = kv.Value.InputTokens,
                    OutputTokens = kv.Value.OutputTokens,
                    Requests = kv.Value.Requests,
                });
        }
    }

    /// <summary>
    /// Registers a downloaded model if its artifact fits the memory budget.
    /// Oversized or missing artifacts are skipped so they are never reported
    /// as ready, mirroring the macOS backend behavior.
    /// </summary>
    public void Register(string id, string dir)
    {
        var file = ModelFile(dir);
        var sizeMb = file is null ? null : FileSizeMb(file);
        lock (_lock)
        {
            if (file is null || sizeMb is null || sizeMb.Value > _memoryLimitMb)
            {
                _ready.Remove(id);
                return;
            }
            _ready[id] = dir;
        }
    }

    /// <summary>Sorted list of ready (registered, fitting) model ids.</summary>
    public List<string> Ready()
    {
        lock (_lock)
        {
            var ids = _ready.Keys.ToList();
            ids.Sort(StringComparer.Ordinal);
            return ids;
        }
    }

    /// <summary>
    /// Dispatches a prompt. Rejects unregistered models immediately, then runs
    /// generation in the background (one inference at a time) streaming
    /// TokenChunk/Done/Error frames via <paramref name="send"/>.
    /// </summary>
    public void Dispatch(PromptDispatch pd, Action<string> send)
    {
        string? dir;
        lock (_lock) { _ready.TryGetValue(pd.Model, out dir); }
        if (dir is null)
        {
            send(MessageCodec.Encode(MessageType.Error, new ProtoError
            {
                RequestId = pd.RequestId,
                Message = $"Model file missing for {pd.Model}",
            }));
            return;
        }

        _ = Task.Run(async () =>
        {
            await _inference.WaitAsync();
            try
            {
                await GenerateAsync(pd, dir, send);
            }
            catch (Exception ex)
            {
                send(MessageCodec.Encode(MessageType.Error, new ProtoError
                {
                    RequestId = pd.RequestId,
                    Message = $"inference failed: {ex.Message}",
                }));
            }
            finally
            {
                _inference.Release();
            }
        });
    }

    private async Task GenerateAsync(PromptDispatch pd, string dir, Action<string> send)
    {
        var loaded = EnsureLoaded(pd.Model, dir);
        var prompt = ExtractPrompt(pd.Payload);
        var maxTokens = MaxTokens(pd.Payload);

        uint promptTokens;
        try
        {
            promptTokens = (uint)loaded.Weights
                .Tokenize(prompt, true, false, Encoding.UTF8).Length;
        }
        catch (Exception)
        {
            promptTokens = (uint)(prompt.Length / 4);
        }

        var executor = new StatelessExecutor(loaded.Weights, loaded.Parameters);
        var inferenceParams = new InferenceParams
        {
            MaxTokens = maxTokens,
            SamplingPipeline = new GreedySamplingPipeline(),
        };

        uint index = 0;
        var sw = Stopwatch.StartNew();
        await foreach (var piece in executor.InferAsync(prompt, inferenceParams))
        {
            if (piece.Length == 0) continue;
            send(MessageCodec.Encode(MessageType.TokenChunk, new TokenChunk
            {
                RequestId = pd.RequestId,
                Delta = piece,
                Index = index,
            }));
            index++;
        }
        sw.Stop();

        var completionTokens = index;
        lock (_lock)
        {
            var seconds = sw.Elapsed.TotalSeconds;
            _totalCompletionTokens += completionTokens;
            _totalGenerationSeconds += seconds;
            _lastTps = seconds > 0 ? completionTokens / seconds : 0;
            if (!_tokenUsage.TryGetValue(pd.Model, out var usage))
            {
                usage = new ModelTokenUsage();
                _tokenUsage[pd.Model] = usage;
            }
            usage.InputTokens += promptTokens;
            usage.OutputTokens += completionTokens;
            usage.Requests += 1;
        }

        send(MessageCodec.Encode(MessageType.Done, new Done
        {
            RequestId = pd.RequestId,
            Usage = new Usage
            {
                PromptTokens = promptTokens,
                CompletionTokens = completionTokens,
                TotalTokens = promptTokens + completionTokens,
            },
        }));
    }

    /// <summary>
    /// Ensures the model is resident, evicting least-recently-used models as
    /// needed to stay within the memory budget (the requested model is never
    /// evicted to make room for itself).
    /// </summary>
    private ResidentModel EnsureLoaded(string id, string dir)
    {
        lock (_lock)
        {
            if (_loaded.TryGetValue(id, out var existing))
            {
                _loadedOrder.Remove(id);
                _loadedOrder.Add(id);
                return existing;
            }
        }

        var file = ModelFile(dir)
            ?? throw new FileNotFoundException($"no model artifact in {dir}");
        var sizeMb = FileSizeMb(file) ?? 1;

        lock (_lock)
        {
            TrimLoadedToBudget(preferred: id, reservingMb: sizeMb);
        }

        var parameters = new ModelParams(file)
        {
            ContextSize = 4096,
            GpuLayerCount = 0,
            BatchSize = 512,
        };
        var weights = LLamaWeights.LoadFromFile(parameters);
        var loaded = new ResidentModel
        {
            Weights = weights,
            Parameters = parameters,
            ResidentSizeMb = sizeMb,
        };

        lock (_lock)
        {
            _loaded[id] = loaded;
            _loadedOrder.Remove(id);
            _loadedOrder.Add(id);
        }
        return loaded;
    }

    /// <summary>Evicts LRU models until resident size + reservation fits the budget. Caller holds the lock.</summary>
    private void TrimLoadedToBudget(string preferred, ulong reservingMb)
    {
        while (_loadedOrder.Count > 0)
        {
            var resident = _loaded.Values.Aggregate(0UL, (a, m) => a + m.ResidentSizeMb);
            if (resident + reservingMb <= _memoryLimitMb) return;

            var victim = _loadedOrder.FirstOrDefault(m => m != preferred);
            if (victim is null) return;
            _loadedOrder.Remove(victim);
            if (_loaded.Remove(victim, out var evicted))
            {
                evicted.Weights.Dispose();
            }
        }
    }

    /// <summary>Resolves a model artifact: prefer *.gguf, then weights.bin, then any non-marker file.</summary>
    internal static string? ModelFile(string dir)
    {
        try
        {
            var gguf = Directory.EnumerateFiles(dir, "*.gguf").OrderBy(p => p).FirstOrDefault();
            if (gguf is not null) return gguf;

            var weights = Path.Combine(dir, "weights.bin");
            if (File.Exists(weights)) return weights;

            return Directory.EnumerateFiles(dir)
                .Where(p => !Path.GetFileName(p).Equals("sha256", StringComparison.OrdinalIgnoreCase)
                            && !p.EndsWith(".partial", StringComparison.OrdinalIgnoreCase))
                .OrderBy(p => p)
                .FirstOrDefault();
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static ulong? FileSizeMb(string path)
    {
        try
        {
            var len = new FileInfo(path).Length;
            return Math.Max(1UL, (ulong)((len + (1024 * 1024) - 1) / (1024 * 1024)));
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Last non-empty messages[].content, falling back to a "prompt" field.</summary>
    internal static string ExtractPrompt(JsonElement payload)
    {
        try
        {
            if (payload.ValueKind == JsonValueKind.Object &&
                payload.TryGetProperty("messages", out var messages) &&
                messages.ValueKind == JsonValueKind.Array)
            {
                string? last = null;
                foreach (var m in messages.EnumerateArray())
                {
                    if (m.TryGetProperty("content", out var c) &&
                        c.ValueKind == JsonValueKind.String)
                    {
                        var s = c.GetString();
                        if (!string.IsNullOrWhiteSpace(s)) last = s;
                    }
                }
                if (last is not null) return last;
            }
            if (payload.ValueKind == JsonValueKind.Object &&
                payload.TryGetProperty("prompt", out var p) &&
                p.ValueKind == JsonValueKind.String)
            {
                return p.GetString() ?? "";
            }
        }
        catch (Exception)
        {
            // Fall through to empty prompt.
        }
        return "";
    }

    /// <summary>max_tokens from the payload, clamped to 1..512, default 128.</summary>
    internal static int MaxTokens(JsonElement payload)
    {
        try
        {
            if (payload.ValueKind == JsonValueKind.Object &&
                payload.TryGetProperty("max_tokens", out var mt) &&
                mt.ValueKind == JsonValueKind.Number &&
                mt.TryGetInt32(out var n))
            {
                return Math.Clamp(n, 1, 512);
            }
        }
        catch (Exception)
        {
            // Fall through to default.
        }
        return 128;
    }

    public void Dispose()
    {
        lock (_lock)
        {
            foreach (var m in _loaded.Values) m.Weights.Dispose();
            _loaded.Clear();
            _loadedOrder.Clear();
        }
        _inference.Dispose();
    }
}
