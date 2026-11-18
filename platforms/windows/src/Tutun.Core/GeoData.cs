namespace Tutun.Core;

/// Какие коды есть в geoip.dat (protobuf: повторяющиеся записи, в каждой поле 1 — код).
/// Нужен, потому что базы бывают разные: в урезанной сборке runetfreedom (около 3 МБ) нет, например, MM, TR, AE,
/// и xray на «geoip:tr» отказывается запускаться. Служба пропускает правила по IP для отсутствующих кодов.
public static class GeoData
{
    public static HashSet<string>? ReadGeoipCodes(string path)
    {
        try
        {
            var b = File.ReadAllBytes(path);
            var codes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int i = 0;
            while (i < b.Length)
            {
                Varint(b, ref i);                    // ключ записи
                var len = (int)Varint(b, ref i);
                var end = i + len;
                if (len <= 0 || end > b.Length) break;
                int j = i;
                var key = Varint(b, ref j);
                if (key >> 3 == 1)
                {
                    var l2 = (int)Varint(b, ref j);
                    if (j + l2 <= end) codes.Add(System.Text.Encoding.UTF8.GetString(b, j, l2));
                }
                i = end;
            }
            return codes.Count > 0 ? codes : null;
        }
        catch { return null; }
    }

    static ulong Varint(byte[] b, ref int i)
    {
        ulong r = 0; int s = 0;
        while (i < b.Length)
        {
            var c = b[i++];
            r |= (ulong)(c & 0x7F) << s; s += 7;
            if (c < 0x80) break;
        }
        return r;
    }
}
