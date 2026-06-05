using System.Text.Json;
using System.Text.Json.Serialization;

namespace JwSwarmNode.Core.Proto;

/// <summary>
/// Message type tags — identical to the serde-tagged enum used by the Fleet
/// Manager and the Linux/macOS nodes. The wire envelope is
/// <c>{"type": &lt;tag&gt;, "payload": &lt;value&gt;}</c>; the unit variant
/// <see cref="CatalogRequest"/> carries no payload.
/// </summary>
public static class MessageType
{
    public const string Register = "Register";
    public const string CatalogRequest = "CatalogRequest";
    public const string Heartbeat = "Heartbeat";
    public const string ModelStatus = "ModelStatus";
    public const string ScheduleState = "ScheduleState";
    public const string TokenChunk = "TokenChunk";
    public const string Done = "Done";
    public const string Error = "Error";
    public const string CatalogResponse = "CatalogResponse";
    public const string PromptDispatch = "PromptDispatch";
}

/// <summary>A parsed inbound envelope: the tag plus its raw payload element.</summary>
public readonly record struct InboundMessage(string Type, JsonElement Payload);

/// <summary>
/// Serializes/deserializes the tunnel message envelope so it is wire-compatible
/// with the serde <c>#[serde(tag = "type", content = "payload")]</c> enum.
/// </summary>
public static class MessageCodec
{
    private static readonly JsonSerializerOptions PayloadOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>Encodes a tagged message that carries a payload object.</summary>
    public static string Encode<T>(string type, T payload)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("type", type);
            writer.WritePropertyName("payload");
            JsonSerializer.Serialize(writer, payload, PayloadOptions);
            writer.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>Encodes a tag-only message (serde unit variant, e.g. CatalogRequest).</summary>
    public static string EncodeBare(string type)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("type", type);
            writer.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>Parses an inbound envelope into its tag and raw payload element.</summary>
    public static InboundMessage Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var type = root.GetProperty("type").GetString()
                   ?? throw new JsonException("message missing 'type'");
        JsonElement payload = default;
        if (root.TryGetProperty("payload", out var p))
        {
            // Clone so the element survives disposal of the JsonDocument.
            payload = p.Clone();
        }
        return new InboundMessage(type, payload);
    }

    /// <summary>Deserializes a payload element into the given DTO.</summary>
    public static T DeserializePayload<T>(JsonElement payload) =>
        payload.Deserialize<T>(PayloadOptions)
        ?? throw new JsonException($"failed to decode payload as {typeof(T).Name}");
}
