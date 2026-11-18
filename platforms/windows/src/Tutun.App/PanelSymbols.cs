using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Tutun.App;

// Outline artwork for the symbols used by the corresponding macOS panels.
// All paths share a 24-unit drawing area, including their optical padding.
internal static class PanelSymbols
{
    static readonly IReadOnlyDictionary<string, string> Paths = new Dictionary<string, string>
    {
        ["chevron.down"] = "M4,9 L12,17 20,9",
        ["chevron.right"] = "M9,4 L17,12 9,20",
        ["checkmark"] = "M3,12 L9,18 21,5",
        ["xmark"] = "M5,5 L19,19 M19,5 L5,19",
        ["star"] = "M12,2 L15,8.8 22,9.5 16.8,14.7 18.3,22 12,18.2 5.7,22 7.2,14.7 2,9.5 9,8.8 Z",
        ["bolt.fill"] = "M14,1 L4,14 H11 L10,23 21,9 H14 Z",
        ["exclamationmark.triangle"] = "M12,2 L22,20 H2 Z M12,8 V13 M12,16 V16.3",
        ["info.circle"] = "M21,12 A9,9 0 1 1 3,12 A9,9 0 1 1 21,12 M11,11 H12 V17 M10.5,17 H14 M12,7 V7.3",
        ["plus"] = "M12,4 V20 M4,12 H20",
        ["gearshape"] = "M10,3 L14,3 14.6,5.5 16.2,6.2 18.5,4.9 21,7.5 19.7,9.7 20.3,11.2 22,12 21.6,15 19.1,15.5 18.1,17 18.7,19.4 16,21 14.2,19.3 12.1,19.6 10.8,21.7 8,20.7 8,18.3 6.2,17.2 3.9,17.6 2.7,14.6 4.7,13 4.7,11.1 3.1,9.6 4.6,6.6 7,7 8.8,5.8 Z M15.4,12 A3.4,3.4 0 1 1 8.6,12 A3.4,3.4 0 1 1 15.4,12",
        ["list.bullet"] = "M3,6 H3.5 M8,6 H21 M3,12 H3.5 M8,12 H21 M3,18 H3.5 M8,18 H21",
        ["slider.horizontal.3"] = "M3,5 H7 M11,5 H21 M3,12 H14 M18,12 H21 M3,19 H5 M9,19 H21 M8,3 V7 M16,10 V14 M7,17 V21",
        ["arrow.triangle.branch"] = "M6,21 V11 Q6,8 10,8 H15 Q19,8 19,4 M3,6 L6,3 9,6 M6,4 V12 M16,5 L19,2 22,5",
        ["network"] = "M21,12 A9,9 0 1 1 3,12 A9,9 0 1 1 21,12 M12,3 C6,7 6,17 12,21 C18,17 18,7 12,3 M3,12 H21 M5,6 Q12,10 19,6 M5,18 Q12,14 19,18",
        ["wrench.and.screwdriver.fill"] = "M4,3 L7,4 9,7 8,8 20,19 18,21 7,9 6,10 3,6 Z M4,21 L2.8,19.6 10,12.2 M13.5,9 L15,7 Q14,2.7 19,3 L17.5,5.5 19,7 21.4,5.3 Q22,10 17.4,10.2 L15,12.6",
        ["info.circle.fill"] = "F0 M22,12 A10,10 0 1 1 2,12 A10,10 0 1 1 22,12 Z M10.5,10.5 H13 V16 H14.3 V17.5 H10 V16 H11.3 V12 H10.5 Z M13.2,7 A1.2,1.2 0 1 1 10.8,7 A1.2,1.2 0 1 1 13.2,7 Z",
        ["point.3.connected.trianglepath.dotted"] = "M6,16 L10,8 M14,8 L18,16 M8,18 H16 M7,18 A2,2 0 1 1 3,18 A2,2 0 1 1 7,18 M14,6 A2,2 0 1 1 10,6 A2,2 0 1 1 14,6 M21,18 A2,2 0 1 1 17,18 A2,2 0 1 1 21,18",
        ["chart.bar.fill"] = "M4,19 V13 H7 V19 Z M10,19 V8 H13 V19 Z M16,19 V3 H19 V19 Z",
        ["doc.text.fill"] = "M5,2 H14 L19,7 V22 H5 Z M14,3 V8 H18 M8,12 H16 M8,16 H16",
        ["macwindow"] = "M2,5 H22 V19 H2 Z M3,9 H21 M5,7 H5.3 M8,7 H8.3",
        ["arrow.clockwise"] = "M19,8 A8,8 0 1 0 20,14 M19,3 V8 H14",
        ["speedometer"] = "M4,18 A9,9 0 1 1 20,18 M12,14 L17,8 M5,13 H6 M8,7 L9,8 M12,5 V6 M19,13 H18",
        ["arrow.up.arrow.down"] = "M7,20 V4 L3,8 M7,4 L11,8 M17,4 V20 L13,16 M17,20 L21,16",
        ["doc.on.clipboard"] = "M9,5 H5 V21 H17 V17 M10,3 H19 V16 H9 V3 Z M12,3 V2 H16 V3",
        ["qrcode.viewfinder"] = "M3,8 V3 H8 M16,3 H21 V8 M21,16 V21 H16 M8,21 H3 V16 M7,7 H10 V10 H7 Z M14,7 H17 V10 H14 Z M7,14 H10 V17 H7 Z M14,14 H16 V16 H18 V18",
        ["photo"] = "M3,4 H21 V20 H3 Z M4,17 L9,12 13,16 16,12 20,16 M16,8 A1,1 0 1 1 14,8 A1,1 0 1 1 16,8",
        ["doc"] = "M6,2 H14 L19,7 V22 H6 Z M14,3 V8 H18"
    };

    public static void SetTint(Viewbox view, string color)
    {
        var path = (System.Windows.Shapes.Path)((Canvas)view.Child).Children[0];
        path.Stroke = UI.B(color);
        if (path.Fill != null) path.Fill = UI.B(color);
    }

    public static Viewbox Draw(string symbol, double size, string color = "Text2")
    {
        var path = new System.Windows.Shapes.Path { Data = Geometry.Parse(Paths[symbol == "star.fill" ? "star" : symbol]), Stroke = UI.B(color),
            StrokeThickness = 1.95, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round };
        if (symbol is "star.fill" or "bolt.fill") path.Fill = UI.B(color);
        if (symbol == "info.circle.fill") { path.Fill = UI.B(color); path.StrokeThickness = 0; }
        return new Viewbox { Width = size, Height = size, HorizontalAlignment = HorizontalAlignment.Center,
            Child = new Canvas { Width = 24, Height = 24, Children = { path } } };
    }
}
