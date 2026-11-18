using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ZXing;
using ZXing.Common;
using static Tutun.App.UI;

namespace Tutun.App;

/// QR-коды: показать ссылку и распознать с экрана или с картинки (ZXing.Net).
public static class QR
{
    public static BitmapSource Encode(string text, int size = 320)
    {
        var writer = new ZXing.QrCode.QRCodeWriter();
        var hints = new Dictionary<EncodeHintType, object> { [EncodeHintType.MARGIN] = 2, [EncodeHintType.CHARACTER_SET] = "UTF-8" };
        var m = writer.encode(text, BarcodeFormat.QR_CODE, size, size, hints);
        var pixels = new byte[m.Width * m.Height];
        for (int y = 0; y < m.Height; y++)
            for (int x = 0; x < m.Width; x++)
                pixels[y * m.Width + x] = m[x, y] ? (byte)0 : (byte)255;
        var bmp = BitmapSource.Create(m.Width, m.Height, 96, 96, PixelFormats.Gray8, null, pixels, m.Width);
        bmp.Freeze();
        return bmp;
    }

    static List<string> Decode(byte[] bgra, int w, int h)
    {
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = true,
            Options = new DecodingOptions { TryHarder = true, PossibleFormats = [BarcodeFormat.QR_CODE] },
        };
        var source = new RGBLuminanceSource(bgra, w, h, RGBLuminanceSource.BitmapFormat.BGRA32);
        var many = reader.DecodeMultiple(source);
        if (many is { Length: > 0 }) return many.Select(r => r.Text).Distinct().ToList();
        return reader.Decode(source) is { } one ? [one.Text] : [];
    }

    /// Все QR-коды на экранах (окно Tutun перед снимком прячется).
    public static List<string> FromScreen()
    {
        var r = System.Windows.Forms.SystemInformation.VirtualScreen;
        using var bmp = new System.Drawing.Bitmap(r.Width, r.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen(r.Left, r.Top, 0, 0, bmp.Size);
        return FromBitmap(bmp);
    }

    public static List<string> FromFile(string path)
    {
        using var bmp = new System.Drawing.Bitmap(path);
        using var copy = new System.Drawing.Bitmap(bmp.Width, bmp.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = System.Drawing.Graphics.FromImage(copy)) g.DrawImage(bmp, 0, 0, bmp.Width, bmp.Height);
        return FromBitmap(copy);
    }

    static List<string> FromBitmap(System.Drawing.Bitmap bmp)
    {
        var rect = new System.Drawing.Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[data.Stride * data.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return Decode(bytes, data.Stride / 4, data.Height);
        }
        finally { bmp.UnlockBits(data); }
    }

    public static readonly string[] ImageExtensions = [".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp"];

    /// Окно с QR-кодом и подписью.
    public static void Show(Window owner, string title, string text)
    {
        var w = new Window
        {
            Title = title, Owner = owner, SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = B("Bg"), ShowInTaskbar = false,
        };
        w.SourceInitialized += (_, _) => SystemIntegration.DarkTitleBar(new System.Windows.Interop.WindowInteropHelper(w).Handle);
        var img = new System.Windows.Controls.Image { Source = Encode(text), Width = 300, Height = 300 };
        RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.NearestNeighbor);
        var panel = V(10, T(title, 15, FontWeights.SemiBold),
            new System.Windows.Controls.Border { Background = Brushes.White, CornerRadius = new CornerRadius(10), Padding = new Thickness(6), Child = img },
            Hint("Отсканируйте камерой телефона или в Tutun на другом устройстве. В коде — ключ сервера, не показывайте посторонним."),
            Btn("Скопировать ссылку", () => Clipboard.SetText(text)));
        panel.Width = 312;
        w.Content = new System.Windows.Controls.Border { Padding = new Thickness(18), Child = panel };
        w.ShowDialog();
    }
}
