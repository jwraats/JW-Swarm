using System.Collections.Concurrent;
using System.Text.Json;
using JwSwarmNode.Core.Proto;

namespace JwSwarmNode.Core.Backend;

/// <summary>
/// Manages registered models and inference dispatch. Enforces a single memory
/// budget across loaded models: only one model is active at a time and any
/// model whose artifact exceeds the configured limit is never advertised as
/// ready. This mirrors the macOS <c>LlamaBackend</c> and Linux
/// <c>BackendManager</c> behavior.
/// </summary>
public sealed class BackendManager
{
    private readonly ConcurrentDictionary<string, string> _models = new(); // id -> dir
    private readonly object _activeLock = new();
    private string? _activeModel;
    private readonly ulong _memoryLimitMb;

    public BackendManager(ulong memoryLimitMb)
    {
        _memoryLimitMb = memoryLimitMb == 0 ? 24000 : memoryLimitMb;
    }

    /// <summary>Currently loaded (active) model id, if any.</summary>
    public string? LoadedModel
    {
        get { lock (_activeLock) { return _activeModel; } }
    }

    /// <summary>
    /// Registers a downloaded model if its artifact fits the memory budget.
    /// Oversized artifacts are skipped so they are never reported as ready.
    /// </summary>
    public void Register(string id, string dir)
    {
        var sizeMb = ModelSizeMb(dir);
        if (sizeMb is ulong mb && mb > _memoryLimitMb)
        {
            _models.TryRemove(id, out _);
            return;
        }
        _models[id] = dir;
    }

    /// <summary>Sorted list of ready (registered, fitting) model ids.</summary>
    public List<string> Ready()
    {
        var ids = _models.Keys.ToList();
        ids.Sort(StringComparer.Ordinal);
        return ids;
    }

    /// <summary>
    /// Dispatches a prompt. Rejects unregistered models, swaps the single
    /// active model when needed, then streams the response via <paramref name="send"/>.
    /// </summary>
    public void Dispatch(PromptDispatch pd, Action<string> send)
    {
        if (!_models.ContainsKey(pd.Model))
        {
            send(MessageCodec.Encode(MessageType.Error, new ProtoError
            {
                RequestId = pd.RequestId,
                Message = $"Model file missing for {pd.Model}",
            }));
            return;
        }

        // Single active model: swap if a different model was loaded.
        lock (_activeLock)
        {
            if (_activeModel is not null && _activeModel != pd.Model)
            {
                _activeModel = null; // unload previous
            }
            _activeModel = pd.Model;
        }

        var stub = new[] { "Hello", ",", " ", "simulated", " ", "response", ".", " ", "!" };
        uint promptTokens = EstimatePromptTokens(pd.Payload);

        for (uint i = 0; i < stub.Length; i++)
        {
            send(MessageCodec.Encode(MessageType.TokenChunk, new TokenChunk
            {
                RequestId = pd.RequestId,
                Delta = stub[i],
                Index = i,
            }));
        }

        send(MessageCodec.Encode(MessageType.Done, new Done
        {
            RequestId = pd.RequestId,
            Usage = new Usage
            {
                PromptTokens = promptTokens,
                CompletionTokens = (uint)stub.Length,
                TotalTokens = promptTokens + (uint)stub.Length,
            },
        }));
    }

    private static uint EstimatePromptTokens(JsonElement payload)
    {
        try
        {
            if (payload.ValueKind == JsonValueKind.Object &&
                payload.TryGetProperty("messages", out var messages) &&
                messages.ValueKind == JsonValueKind.Array)
            {
                long chars = 0;
                foreach (var m in messages.EnumerateArray())
                {
                    if (m.TryGetProperty("content", out var c) && c.ValueKind == JsonValueKind.String)
                    {
                        chars += c.GetString()?.Length ?? 0;
                    }
                }
                return (uint)(chars / 4);
            }
        }
        catch (Exception)
        {
            // Fall through to default estimate.
        }
        return 50;
    }

    private static ulong? ModelSizeMb(string dir)
    {
        try
        {
            var weights = Path.Combine(dir, "weights.bin");
            if (!File.Exists(weights)) return null;
            var len = new FileInfo(weights).Length;
            return (ulong)(len / (1024 * 1024));
        }
        catch (Exception)
        {
            return null;
        }
    }
}
