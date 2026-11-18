using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using Tutun.Core;

namespace Tutun.App;

/// Установка службы. Запускается отдельным процессом с правами администратора:
/// Tutun.exe --install-service &lt;SID владельца&gt; / --uninstall-service.
public static class Installer
{
    public static string ProgramFilesDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tutun");

    /// Из окна: запросить права администратора и выполнить установку. Возвращает текст ошибки или null.
    public static async Task<string?> RunElevatedAsync(bool install)
    {
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        var psi = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden,
            Arguments = install ? $"--install-service {sid}" : "--uninstall-service",
        };
        try
        {
            using var p = Process.Start(psi)!;
            await p.WaitForExitAsync();
            if (p.ExitCode == 0) return null;
            var log = Path.Combine(Path.GetTempPath(), "tutun-install.log");
            return File.Exists(log) ? File.ReadAllText(log).Trim() : $"Установщик завершился с кодом {p.ExitCode}";
        }
        catch (System.ComponentModel.Win32Exception) { return "Установка отменена: нужны права администратора"; }
    }

    /// Выполняется в процессе с правами администратора.
    public static int Run(string[] args)
    {
        var log = Path.Combine(Path.GetTempPath(), "tutun-install.log");
        try
        {
            File.Delete(log);
            if (args[0] == "--install-service") Install(new SecurityIdentifier(args[1]));
            else Uninstall();
            return 0;
        }
        catch (Exception e)
        {
            try { File.WriteAllText(log, e.Message); } catch { }
            return 1;
        }
    }

    static void Install(SecurityIdentifier owner)
    {
        if (owner.IsWellKnown(WellKnownSidType.LocalSystemSid) || !owner.IsAccountSid()) throw new InvalidOperationException("Неверный владелец установки");
        StopService();

        // 1. Файлы — в Program Files (папка доступна на запись только администраторам).
        var src = Path.GetDirectoryName(Environment.ProcessPath!)!;
        var dst = ProgramFilesDir;
        // Сначала проверяем, что запущены из полной сборки, — иначе ничего не копируем.
        if (!File.Exists(Path.Combine(src, "Tutun.Service.exe")) || !File.Exists(Path.Combine(Paths.AppCores(src), "xray.exe")) || !File.Exists(Path.Combine(Paths.AppCores(src), "sing-box.exe")))
            throw new InvalidOperationException("Эта копия Tutun неполная (нет Tutun.Service.exe или bin\\xray.exe, bin\\sing-box.exe). Запустите Tutun.exe из папки собранной программы (dist\\Tutun).");
        if (!string.Equals(Path.GetFullPath(src).TrimEnd('\\'), Path.GetFullPath(dst).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
        {
            foreach (var p in Process.GetProcessesByName("Tutun").Where(p => p.Id != Environment.ProcessId))
            {
                try { if (p.MainModule?.FileName?.StartsWith(dst, StringComparison.OrdinalIgnoreCase) == true) { p.Kill(); p.WaitForExit(3000); } } catch { }
            }
            CopyDir(src, dst);
        }
        if (!File.Exists(Path.Combine(dst, "Tutun.Service.exe")) || !File.Exists(Path.Combine(Paths.AppCores(dst), "xray.exe")) || !File.Exists(Path.Combine(Paths.AppCores(dst), "sing-box.exe")))
            throw new InvalidOperationException("В папке программы нет службы или ядер (bin\\xray.exe, bin\\sing-box.exe)");

        // 2. Данные службы: только SYSTEM и администраторы.
        var data = Paths.DataDir;
        Directory.CreateDirectory(data);
        var sec = new DirectorySecurity();
        sec.SetAccessRuleProtection(true, false);
        var inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        sec.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        // Владелец может читать журнал службы, но не менять её файлы.
        sec.AddAccessRule(new FileSystemAccessRule(owner, FileSystemRights.ReadAndExecute, inherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(data).SetAccessControl(sec);
        File.WriteAllText(Paths.OwnerFile, owner.Value);

        // 3. Служба — своей копией в папке service: обновление приложения её не трогает,
        // новая версия службы ставится только этой кнопкой («Обновить службу», с подтверждением администратора).
        var svcDir = Path.Combine(dst, "service");
        CopyServiceFiles(dst, svcDir);
        CopyDir(Paths.AppCores(dst), Path.Combine(svcDir, "bin"));
        var exe = Path.Combine(svcDir, "Tutun.Service.exe");
        if (ServiceController.GetServices().Any(s => s.ServiceName == Paths.ServiceName))
            Sc("config", Paths.ServiceName, "binPath=", $"\"{exe}\"", "start=", "auto");
        else
            Sc("create", Paths.ServiceName, "binPath=", $"\"{exe}\"", "start=", "auto", "DisplayName=", "Tutun VPN");
        Sc("description", Paths.ServiceName, "Держит VPN-подключение Tutun независимо от окна программы.");
        Sc("failure", Paths.ServiceName, "reset=", "86400", "actions=", "restart/2000/restart/5000/restart/10000");
        using (var sc = new ServiceController(Paths.ServiceName))
        {
            sc.Start();
            sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(20));
        }

        // 4. Ярлык в меню «Пуск» для всех пользователей.
        try
        {
            var lnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), "Tutun.lnk");
            var shell = Type.GetTypeFromProgID("WScript.Shell");
            if (shell != null)
            {
                dynamic sh = Activator.CreateInstance(shell)!;
                dynamic link = sh.CreateShortcut(lnk);
                link.TargetPath = Path.Combine(dst, "Tutun.exe");
                link.WorkingDirectory = dst;
                link.Save();
            }
        }
        catch { }
    }

    static void Uninstall()
    {
        StopService();
        if (ServiceController.GetServices().Any(s => s.ServiceName == Paths.ServiceName)) Sc("delete", Paths.ServiceName);
        try { Directory.Delete(Paths.RunDir, true); } catch { }
        try { File.Delete(Paths.DaemonState); } catch { }
        try { File.Delete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), "Tutun.lnk")); } catch { }
    }

    static void StopService()
    {
        if (!ServiceController.GetServices().Any(s => s.ServiceName == Paths.ServiceName)) return;
        using var sc = new ServiceController(Paths.ServiceName);
        if (sc.Status != ServiceControllerStatus.Stopped)
        {
            try { sc.Stop(); } catch { }
            sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(30));
        }
    }

    static void Sc(params string[] args)
    {
        var psi = new ProcessStartInfo("sc.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var o = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException($"sc {args[0]}: {o.Trim()}");
    }

    /// Файлы программы без ядер, переводов и самой папки service (ядра служба берёт из общей bin).
    static void CopyServiceFiles(string appDir, string svcDir)
    {
        Directory.CreateDirectory(svcDir);
        foreach (var f in Directory.GetFiles(appDir))
        {
            var name = Path.GetFileName(f);
            if (name.EndsWith(".old", StringComparison.OrdinalIgnoreCase)) continue;
            File.Copy(f, Path.Combine(svcDir, name), true);
        }
        foreach (var d in Directory.GetDirectories(appDir))
        {
            var name = Path.GetFileName(d);
            if (name is "cores" or "bin" or "l10n" or "service") continue;
            CopyDir(d, Path.Combine(svcDir, name));
        }
    }

    static void CopyDir(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)), true);
        foreach (var d in Directory.GetDirectories(src)) CopyDir(d, Path.Combine(dst, Path.GetFileName(d)));
    }

    public static bool ServiceInstalled =>
        ServiceController.GetServices().Any(s => s.ServiceName == Paths.ServiceName);
}
