using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;
using System.Windows;
using System.Windows.Controls;
using Tutun.App;
using Tutun.Core;

class Program
{
    [STAThread]
    static void Main()
    {
        var installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tutun");
        AssemblyLoadContext.Default.Resolving += (context, name) =>
        {
            var path = Path.Combine(installed, name.Name + ".dll");
            return File.Exists(path) ? context.LoadFromAssemblyPath(path) : null;
        };
        CheckInstalledWindow();
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void CheckInstalledWindow()
    {
        var app = new Application();
        app.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/Tutun;component/Theme.xaml", UriKind.Relative) });
        var model = AppModel.Shared;
        model.DaemonReachable = true;
        var window = new MainWindow();
        foreach (var protection in new[] { false, true })
        foreach (var state in Enum.GetValues<TunnelState>())
        {
            model.Status = new DaemonStatus { State = state, Healthy = state == TunnelState.Running,
                EmergencyBlock = protection, Mode = state == TunnelState.Stopped ? null : ConnectionMode.Tun };
            model.NotifyChanged();
            var labels = Buttons(window).Select(b => b.Content is TextBlock t ? t.Text : b.Content as string)
                .Where(s => s is "Подключить" or "Отключить" or "Повторить" or "Повторить подключение").ToArray();
            var expected = state switch {
                TunnelState.Failed => new[] { "Повторить подключение", "Отключить" },
                TunnelState.Stopped when !protection => new[] { "Подключить" },
                _ => new[] { "Отключить" }
            };
            if (!labels.SequenceEqual(expected)) throw new Exception($"{state}, protection={protection}: {string.Join(", ", labels)}");
            Console.WriteLine($"PASS {state} protection={protection}");
        }
    }

    static IEnumerable<Button> Buttons(DependencyObject parent)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>())
        {
            if (child is Button button) yield return button;
            else foreach (var item in Buttons(child)) yield return item;
        }
    }
}
