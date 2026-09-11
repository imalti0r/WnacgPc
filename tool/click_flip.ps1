param([int]$Clicks = 1)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Click {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@

$hwnd = [IntPtr](Get-Process WNACG -ErrorAction Stop | Select-Object -First 1 -ExpandProperty MainWindowHandle)
if ($hwnd -eq [IntPtr]::Zero) { Write-Output "window not found"; exit 1 }
$rect = New-Object Win32Click+RECT
[Win32Click]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
Write-Output "window: L=$($rect.Left) T=$($rect.Top) R=$($rect.Right) B=$($rect.Bottom)"

# 窗口左侧 1/3 的中心（RTL = 下一页）
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
$x = $rect.Left + [int]($w * 0.17)
$y = $rect.Top + [int]($h * 0.5)
Write-Output "clicking at $x,$y x$Clicks"

for ($i = 0; $i -lt $Clicks; $i++) {
    [Win32Click]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 120
    [Win32Click]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)  # LEFTDOWN
    Start-Sleep -Milliseconds 60
    [Win32Click]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)  # LEFTUP
    Start-Sleep -Milliseconds 500
}
Write-Output "done"
