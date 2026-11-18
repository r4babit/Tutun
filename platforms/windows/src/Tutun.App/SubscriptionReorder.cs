using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Tutun.App;

internal sealed class SubscriptionReorder
{
    readonly Panel list;
    readonly AppModel model;
    Guid? source;
    Point origin;
    bool moving;
    Border? highlight;

    public SubscriptionReorder(Panel list, AppModel model)
    {
        this.list = list;
        this.model = model;
        list.PreviewMouseMove += Move;
        list.PreviewMouseLeftButtonUp += Release;
        list.LostMouseCapture += (_, _) => { if (moving && Mouse.Captured != list) Reset(); };
    }

    public void Register(Button handle, Border header, string id, bool movable)
    {
        header.Tag = id;
        if (movable) handle.PreviewMouseLeftButtonDown += (_, e) =>
        {
            origin = e.GetPosition(list);
            source = Guid.Parse(id);
        };
    }

    Border? Target(Point p)
    {
        for (var el = list.InputHitTest(p) as DependencyObject; el is Visual; el = VisualTreeHelper.GetParent(el))
            if (el is Border { Tag: string } header) return header;
        return null;
    }

    void Move(object sender, MouseEventArgs e)
    {
        if (source == null || e.LeftButton != MouseButtonState.Pressed) return;
        var point = e.GetPosition(list);
        if (!moving)
        {
            if (Math.Abs(point.Y - origin.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            moving = list.CaptureMouse();
            if (!moving) return;
        }
        var target = Target(point);
        if (target == highlight) return;
        if (highlight != null) highlight.BorderThickness = new Thickness(0);
        highlight = target;
        if (highlight != null) { highlight.BorderBrush = UI.B("On"); highlight.BorderThickness = new Thickness(1); }
    }

    void Release(object sender, MouseButtonEventArgs e)
    {
        var target = Target(e.GetPosition(list))?.Tag as string;
        var dragged = source;
        var wasMoving = moving;
        Reset();
        if (!wasMoving) return;
        list.ReleaseMouseCapture();
        e.Handled = true;
        if (target == null || dragged == null) return;
        var items = model.Subscriptions;
        var a = items.FindIndex(sub => sub.Id == dragged);
        var b = target == "manual" ? items.Count - 1 : items.FindIndex(sub => sub.Id.ToString() == target);
        if (a < 0 || b < 0 || a == b) return;
        var item = items[a];
        items.RemoveAt(a);
        items.Insert(b, item);
        model.ScheduleSave();
        model.NotifyChanged();
    }

    void Reset()
    {
        if (highlight != null) highlight.BorderThickness = new Thickness(0);
        highlight = null; moving = false; source = null;
    }
}
