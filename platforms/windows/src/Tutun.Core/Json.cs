using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Tutun.Core;

/// Единые настройки JSON. Имена полей совпадают с мак-версией (camelCase), даты ISO 8601.
public static class Json
{
    public static readonly JsonSerializerOptions Options = Make(false);
    public static readonly JsonSerializerOptions Pretty = Make(true);

    static JsonSerializerOptions Make(bool indented) => new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DictionaryKeyPolicy = null,
        WriteIndented = indented,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNameCaseInsensitive = false,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    };

    public static string Serialize<T>(T value, bool pretty = false) => JsonSerializer.Serialize(value, pretty ? Pretty : Options);
    public static T? Deserialize<T>(string text) => JsonSerializer.Deserialize<T>(text, Options);
    public static T? Deserialize<T>(byte[] data) => JsonSerializer.Deserialize<T>(data, Options);

    /// JSON с упорядоченными ключами (как .sortedKeys в Swift) — одинаковый текст для одинаковых объектов.
    public static string ToJSON(JsonNode? node, bool pretty = false)
    {
        var sorted = Sort(node);
        return sorted?.ToJsonString(pretty ? Pretty : Options) ?? "null";
    }

    static JsonNode? Sort(JsonNode? node) => node switch
    {
        JsonObject o => new JsonObject(o.OrderBy(kv => kv.Key, StringComparer.Ordinal)
                                         .Select(kv => KeyValuePair.Create(kv.Key, Sort(kv.Value)))),
        JsonArray a => new JsonArray(a.Select(Sort).ToArray()),
        null => null,
        _ => JsonNode.Parse(node.ToJsonString()),
    };

    public static JsonObject? ParseObject(string text)
    {
        try { return JsonNode.Parse(text, documentOptions: new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip }) as JsonObject; }
        catch { return null; }
    }

    public static JsonNode? Parse(string text)
    {
        try { return JsonNode.Parse(text, documentOptions: new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip }); }
        catch { return null; }
    }

    // Короткие помощники для чтения JsonNode.
    public static string? Str(this JsonNode? n, string key)
    {
        if (n is not JsonObject o || !o.TryGetPropertyValue(key, out var v) || v is null) return null;
        return v is JsonValue jv && jv.TryGetValue<string>(out var s) ? s : v.ToJsonString().Trim('"');
    }

    public static int? Int(this JsonNode? n, string key)
    {
        if (n is not JsonObject o || !o.TryGetPropertyValue(key, out var v) || v is not JsonValue jv) return null;
        if (jv.TryGetValue<int>(out var i)) return i;
        if (jv.TryGetValue<long>(out var l)) return (int)l;
        if (jv.TryGetValue<double>(out var d)) return (int)d;
        if (jv.TryGetValue<string>(out var s) && int.TryParse(s, out var p)) return p;
        return null;
    }

    public static JsonObject? Obj(this JsonNode? n, string key) => n is JsonObject o && o.TryGetPropertyValue(key, out var v) ? v as JsonObject : null;
    public static JsonArray? Arr(this JsonNode? n, string key) => n is JsonObject o && o.TryGetPropertyValue(key, out var v) ? v as JsonArray : null;

    public static JsonArray StrArray(IEnumerable<string> items) => new(items.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray());
    public static JsonObject Clone(this JsonObject o) => (JsonObject)JsonNode.Parse(o.ToJsonString())!;
}
