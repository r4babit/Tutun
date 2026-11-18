using Tutun.Core;

namespace Tutun.Service;

/// Журнал: кольцевой буфер для окна приложения + файл ProgramData\Tutun\tutun.log (не больше 5 МБ).
public static class Log
{
    static readonly object Gate = new();
    static readonly List<string> Ring = new();

    public static void Write(string msg)
    {
        var line = $"{DateTime.Now:dd.MM HH:mm:ss} {msg}";
        lock (Gate)
        {
            Ring.Add(line);
            if (Ring.Count > 400) Ring.RemoveRange(0, Ring.Count - 400);
            try
            {
                var fi = new FileInfo(Paths.Log);
                if (fi.Exists && fi.Length > 5 << 20) fi.Delete();
                File.AppendAllText(Paths.Log, line + Environment.NewLine);
            }
            catch { }
        }
    }

    public static List<string> Tail(int n)
    {
        lock (Gate) return Ring.Skip(Math.Max(0, Ring.Count - n)).ToList();
    }
}
