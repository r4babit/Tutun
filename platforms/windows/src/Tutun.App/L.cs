using System.Globalization;

namespace Tutun.App;

/// Языки интерфейса — как на маке: 20 языков, ключ перевода — русская строка, по умолчанию «как в системе»
/// (нет в списке — английский). Арабский и урду не зеркалятся. Таблицы: папка l10n рядом с Tutun.exe,
/// tr.tsv (ru⇥en⇥uk) и tr_&lt;код&gt;.tsv (ru⇥перевод), UTF-8, подстановки %@.
public static class L
{
    public static readonly (string Code, string Native)[] Languages =
    [
        ("en", "English"), ("zh-Hans", "简体中文"), ("hi", "हिन्दी"), ("es", "Español"), ("ar", "العربية"),
        ("fr", "Français"), ("bn", "বাংলা"), ("pt", "Português"), ("ru", "Русский"), ("ur", "اردو"),
        ("id", "Bahasa Indonesia"), ("de", "Deutsch"), ("ja", "日本語"), ("mr", "मराठी"), ("te", "తెలుగు"),
        ("tr", "Türkçe"), ("ta", "தமிழ்"), ("vi", "Tiếng Việt"), ("ko", "한국어"), ("uk", "Українська"),
    ];

    static Dictionary<string, string> table = new();
    public static string Code { get; private set; } = "ru";
    public static CultureInfo Culture { get; private set; } = new("ru-RU");
    public static event Action? Changed;

    public static string Dir => Path.Combine(AppContext.BaseDirectory, "l10n");
    public static bool TablesPresent => File.Exists(Path.Combine(Dir, "tr.tsv"));

    /// Язык системы, если он в списке; иначе английский.
    public static string SystemCode()
    {
        var ui = CultureInfo.CurrentUICulture;
        if (ui.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase)) return "zh-Hans";
        var two = ui.TwoLetterISOLanguageName;
        return Languages.Any(l => l.Code == two) ? two : "en";
    }

    public static void Load()
    {
        Code = UiPrefs.Current.Language is { } c && Languages.Any(l => l.Code == c) ? c : SystemCode();
        // Пока таблиц нет, весь интерфейс остаётся русским (иначе — смесь языков, например страны по-английски).
        if (!TablesPresent) Code = "ru";
        try { Culture = new CultureInfo(Code == "zh-Hans" ? "zh-Hans" : Code); } catch { Culture = CultureInfo.InvariantCulture; }
        table = new();
        if (Code == "ru") { Changed?.Invoke(); return; }
        try
        {
            if (Code is "en" or "uk")
            {
                var col = Code == "en" ? 1 : 2;
                // tr.tsv — таблица мака, win.tsv — строки только Windows-версии (тот же формат ru⇥en⇥uk).
                foreach (var line in ReadLines("tr.tsv").Concat(ReadLines("win.tsv")))
                {
                    var p = line.Split('\t');
                    if (p.Length > col && p[col].Length > 0) table.TryAdd(p[0], p[col]);
                }
            }
            else
            {
                var code = Code == "zh-Hans" ? "zh" : Code;
                // tr_<код> — таблица мака, win_<код> — строки только Windows-версии.
                foreach (var line in ReadLines($"tr_{code}.tsv").Concat(ReadLines($"win_{code}.tsv")))
                {
                    var p = line.Split('\t');
                    if (p.Length >= 2 && p[1].Length > 0) table[p[0]] = p[1];
                }
                // Чего нет в таблице языка — по-английски, а не по-русски.
                foreach (var line in ReadLines("tr.tsv").Concat(ReadLines("win.tsv")))
                {
                    var p = line.Split('\t');
                    if (p.Length > 1 && p[1].Length > 0) table.TryAdd(p[0], p[1]);
                }
            }
        }
        catch { }
        Changed?.Invoke();
    }

    static IEnumerable<string> ReadLines(string file)
    {
        var path = Path.Combine(Dir, file);
        if (!File.Exists(path)) return [];
        return File.ReadAllLines(path, System.Text.Encoding.UTF8).Select(l => l.TrimEnd('\r')).Where(l => l.Length > 0)
            // В таблицах мака перевод строки внутри строки записан как \n.
            .Select(l => l.Replace("\\n", "\n"));
    }

    /// Перевод русской строки; неизвестная строка возвращается как есть (имена серверов, адреса и т.п.).
    public static string T(string ru)
    {
        if (Code == "ru" || string.IsNullOrEmpty(ru)) return ru;
        return table.TryGetValue(ru, out var t) ? t : ru;
    }

    /// Строка с подстановками: ключ — русский шаблон с %@ (как на маке), аргументы подставляются по порядку.
    public static string F(string ruTemplate, params object[] args)
    {
        var t = T(ruTemplate);
        foreach (var a in args)
        {
            var i = t.IndexOf("%@", StringComparison.Ordinal);
            if (i < 0) break;
            t = t[..i] + a + t[(i + 2)..];
        }
        return t;
    }

    public static void Set(string? code)
    {
        UiPrefs.Current.Language = code;
        UiPrefs.Current.Save();
        Load();
    }
}
