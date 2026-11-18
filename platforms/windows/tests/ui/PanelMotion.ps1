# Run in the interactive Russian Windows session with Tutun open and animations enabled.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
public class Frame {
 public int Time, X, Y, W, H;
}
public class WindowMotion {
 [StructLayout(LayoutKind.Sequential)] struct RECT { public int l,t,r,b; }
 [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h,int attr,out RECT r,int size);
 public static Frame Read(IntPtr w) {
  RECT r;
  if(DwmGetWindowAttribute(w,9,out r,16)!=0) throw new Exception("DWM bounds unavailable");
  return new Frame{ X=r.l, Y=r.t, W=r.r-r.l, H=r.b-r.t };
 }
 public static Task<Frame[]> Sample(IntPtr w) {
  return Task.Run(()=> {
    var frames=new List<Frame>();var timer=Stopwatch.StartNew();
    while(timer.ElapsedMilliseconds<1600) { var f=Read(w);f.Time=(int)timer.ElapsedMilliseconds;frames.Add(f);Thread.Sleep(6); }
    return frames.ToArray();
  });
 }
}
'@
$proc=Get-Process Tutun|Where-Object MainWindowHandle|Select-Object -First 1
$hwnd=$proc.MainWindowHandle
$window=[Windows.Automation.AutomationElement]::FromHandle($hwnd)
function ClickTile($name){
 $c=New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::NameProperty),$name
 foreach($e in $window.FindAll([Windows.Automation.TreeScope]::Descendants,$c)){
  $node=$e
  while($node -and $node -ne $window){
   $pattern=$null
   if($node.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){ $pattern.Invoke(); return }
   $node=[Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($node)
  }
 }
 throw "Missing tile: $name"
}
$endWidths=@{}
function Measure-PanelMotion($name,$direction){
 $frames=[WindowMotion]::Sample($hwnd)
 Start-Sleep -Milliseconds 90
 ClickTile $name
 $samples=$frames.Result
 $a=$samples[0]; $b=$samples[-1]
 $widths=@($samples.W|Select-Object -Unique)
 $delta=$b.W-$a.W
 $moving=@($samples|Where-Object {$_.W -ne $a.W -and $_.W -ne $b.W})
 $first=$samples|Where-Object W -ne $a.W |Select-Object -First 1
 $finish=$samples|Where-Object W -eq $b.W |Select-Object -First 1
 $ms=$finish.Time-$first.Time
 "$name $direction start=$($a.W) end=$($b.W) intermediate=$($moving.W|Sort-Object -Unique|Measure-Object|Select-Object -ExpandProperty Count) duration_ms=$ms"
 if(@($samples.X|Select-Object -Unique).Count -ne 1 -or @($samples.Y|Select-Object -Unique).Count -ne 1 -or @($samples.H|Select-Object -Unique).Count -ne 1){throw 'Window position or height changed'}
 if($direction -eq 'switch'){if($widths.Count -ne 1){throw 'Window moved on panel switch'};return}
 if($widths.Count -lt 4 -or ($direction -eq 'open' -and $delta -le 0) -or ($direction -eq 'close' -and $delta -ge 0)){throw 'No smooth native width transition'}
 if($endWidths.ContainsKey($direction) -and [math]::Abs($b.W-$endWidths[$direction]) -gt 1){throw 'Window dimensions drifted across repeated clicks'}
 $endWidths[$direction]=$b.W
 for($i=1;$i -lt $samples.Count;$i++){if(($samples[$i].W-$samples[$i-1].W)*$delta -lt 0){throw 'Window width reversed mid-transition'}}
}
$f=[WindowMotion]::Read($hwnd)
if($f.W -gt $f.H){ClickTile 'Настройки';Start-Sleep 1;$f=[WindowMotion]::Read($hwnd);if($f.W -gt $f.H){ClickTile 'Настройки';Start-Sleep 1}}
Measure-PanelMotion 'Серверы' 'open'
Measure-PanelMotion 'Настройки' 'switch'
Measure-PanelMotion 'Настройки' 'close'
Measure-PanelMotion 'Добавить' 'open'
Measure-PanelMotion 'Добавить' 'close'
Measure-PanelMotion 'Серверы' 'open'
'PASS'
