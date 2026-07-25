[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("list", "capture")]
  [string]$Action,
  [string]$WindowHandle,
  [string]$OutputPath,
  [int]$ExpectedProcessId,
  [string]$ExpectedProcessStartedAt,
  [string]$ExpectedExecutablePath
)

$ErrorActionPreference = "Stop"
$Utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $Utf8
$Source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

public sealed class PublicWindowRecord
{
    public string windowHandle { get; set; }
    public int processId { get; set; }
    public string processStartedAt { get; set; }
    public string executablePath { get; set; }
    public string processName { get; set; }
    public string title { get; set; }
    public int left { get; set; }
    public int top { get; set; }
    public int width { get; set; }
    public int height { get; set; }
    public bool minimized { get; set; }
}

public static class PublicWindowObserver
{
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
    private const int DwmwaCloaked = 14;
    private const uint RenderFullContent = 2;

    public static List<PublicWindowRecord> List()
    {
        var result = new List<PublicWindowRecord>();
        EnumWindows(delegate(IntPtr hwnd, IntPtr ignored) {
            try
            {
                if (!IsWindowVisible(hwnd) || GetWindowTextLength(hwnd) <= 0) return true;
                int cloaked;
                if (DwmGetWindowAttribute(hwnd, DwmwaCloaked, out cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
                var item = Read(hwnd);
                if (item.width > 0 && item.height > 0 && item.width <= 16384 && item.height <= 16384) result.Add(item);
            }
            catch { }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static PublicWindowRecord Read(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) throw new ArgumentException("The window no longer exists.");
        uint rawPid;
        GetWindowThreadProcessId(hwnd, out rawPid);
        if (rawPid == 0 || rawPid > int.MaxValue) throw new Win32Exception("The window process could not be resolved.");
        RECT rect;
        if (!GetWindowRect(hwnd, out rect)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetWindowRect failed.");
        var length = Math.Min(GetWindowTextLength(hwnd), 4096);
        var title = new StringBuilder(length + 1);
        GetWindowText(hwnd, title, title.Capacity);
        using (var process = Process.GetProcessById((int)rawPid))
        {
            return new PublicWindowRecord {
                windowHandle = hwnd.ToInt64().ToString(CultureInfo.InvariantCulture),
                processId = process.Id,
                processStartedAt = process.StartTime.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                executablePath = process.MainModule.FileName,
                processName = process.ProcessName,
                title = title.ToString(),
                left = rect.Left,
                top = rect.Top,
                width = rect.Right - rect.Left,
                height = rect.Bottom - rect.Top,
                minimized = IsIconic(hwnd)
            };
        }
    }

    public static PublicWindowRecord Verify(IntPtr hwnd, int expectedPid, string expectedStart, string expectedPath)
    {
        var item = Read(hwnd);
        if (item.processId != expectedPid || !string.Equals(item.processStartedAt, expectedStart, StringComparison.Ordinal) ||
            !string.Equals(item.executablePath, expectedPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The target window identity changed.");
        return item;
    }

    public static PublicWindowRecord Capture(IntPtr hwnd, string outputPath, int expectedPid, string expectedStart, string expectedPath)
    {
        var before = Verify(hwnd, expectedPid, expectedStart, expectedPath);
        if (before.minimized) throw new InvalidOperationException("The target window is minimized.");
        if (before.width <= 0 || before.height <= 0 || before.width > 16384 || before.height > 16384)
            throw new InvalidOperationException("The target window size is outside the supported range.");
        using (var bitmap = new Bitmap(before.width, before.height, PixelFormat.Format32bppArgb))
        using (var graphics = Graphics.FromImage(bitmap))
        {
            var hdc = graphics.GetHdc();
            bool captured;
            try { captured = PrintWindow(hwnd, hdc, RenderFullContent); }
            finally { graphics.ReleaseHdc(hdc); }
            if (!captured) throw new Win32Exception(Marshal.GetLastWin32Error(), "PrintWindow failed for this application.");
            bitmap.Save(outputPath, ImageFormat.Png);
        }
        return Verify(hwnd, expectedPid, expectedStart, expectedPath);
    }
}
'@
Add-Type -TypeDefinition $Source -ReferencedAssemblies @("System.Drawing") -Language CSharp
if ($Action -eq "list") {
  [ordered]@{ windows = [PublicWindowObserver]::List() } | ConvertTo-Json -Depth 6 -Compress
  return
}
if ([string]::IsNullOrWhiteSpace($WindowHandle) -or [string]::IsNullOrWhiteSpace($OutputPath)) { throw "Capture arguments are incomplete." }
$Handle = [IntPtr]::new([long]::Parse($WindowHandle, [Globalization.CultureInfo]::InvariantCulture))
$Window = [PublicWindowObserver]::Capture($Handle, $OutputPath, $ExpectedProcessId, $ExpectedProcessStartedAt, $ExpectedExecutablePath)
[ordered]@{ window=$Window; outputPath=$OutputPath; backend="print_window_fallback" } | ConvertTo-Json -Depth 6 -Compress
