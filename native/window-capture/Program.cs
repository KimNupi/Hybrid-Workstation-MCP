using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using WinRT;

const string Version = "1.3.0";
try
{
    if (args.Length == 1 && args[0] == "--self-test")
    {
        Console.WriteLine($"{{\"ok\":true,\"version\":\"{Version}\",\"captureSupported\":{GraphicsCaptureSession.IsSupported().ToString().ToLowerInvariant()},\"architecture\":\"{RuntimeInformation.ProcessArchitecture}\"}}");
        return 0;
    }

    var options = ParseCaptureArguments(args);
    var before = ReadAndVerifyIdentity(options);
    if (before.Minimized) throw new InvalidOperationException("The target window is minimized.");
    var size = await CaptureAsync(before.Handle, options.OutputPath);
    _ = ReadAndVerifyIdentity(options);
    Console.WriteLine($"{{\"ok\":true,\"backend\":\"windows_graphics_capture\",\"width\":{size.Width},\"height\":{size.Height}}}");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine(error.Message);
    return 1;
}

static CaptureOptions ParseCaptureArguments(string[] args)
{
    if (args.Length != 11 || args[0] != "capture") throw new ArgumentException("Invalid capture command.");
    var values = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var index = 1; index < args.Length; index += 2)
    {
        if (index + 1 >= args.Length || !args[index].StartsWith("--", StringComparison.Ordinal)) throw new ArgumentException("Invalid capture option.");
        if (!values.TryAdd(args[index], args[index + 1])) throw new ArgumentException("Duplicate capture option.");
    }
    if (!long.TryParse(Required(values, "--window-handle"), NumberStyles.None, CultureInfo.InvariantCulture, out var handleValue) || handleValue <= 0)
        throw new ArgumentException("window handle is invalid.");
    if (!int.TryParse(Required(values, "--expected-pid"), NumberStyles.None, CultureInfo.InvariantCulture, out var pid) || pid <= 0)
        throw new ArgumentException("expected process id is invalid.");
    var startedAt = DateTimeOffset.ParseExact(Required(values, "--expected-start"), "o", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind).ToUniversalTime();
    var executablePath = Path.GetFullPath(Required(values, "--expected-exe"));
    var outputPath = Path.GetFullPath(Required(values, "--output"));
    if (File.Exists(outputPath) || Directory.Exists(outputPath)) throw new IOException("capture output already exists.");
    return new CaptureOptions(new IntPtr(handleValue), pid, startedAt, executablePath, outputPath);
}

static string Required(Dictionary<string, string> values, string key) =>
    values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value : throw new ArgumentException($"Missing {key}.");

static WindowIdentity ReadAndVerifyIdentity(CaptureOptions options)
{
    if (!Native.IsWindow(options.Handle)) throw new InvalidOperationException("The target window no longer exists.");
    Native.GetWindowThreadProcessId(options.Handle, out var rawPid);
    if (rawPid != options.ProcessId) throw new InvalidOperationException("The target window process changed.");
    using var process = Process.GetProcessById(options.ProcessId);
    var observedStart = new DateTimeOffset(process.StartTime).ToUniversalTime();
    if (observedStart.UtcTicks != options.ProcessStartedAt.UtcTicks) throw new InvalidOperationException("The target process start time changed.");
    var observedPath = QueryProcessPath(options.ProcessId);
    if (!string.Equals(Path.GetFullPath(observedPath), options.ExecutablePath, StringComparison.OrdinalIgnoreCase))
        throw new InvalidOperationException("The target executable changed.");
    return new WindowIdentity(options.Handle, Native.IsIconic(options.Handle));
}

static string QueryProcessPath(int pid)
{
    const uint ProcessQueryLimitedInformation = 0x1000;
    var process = Native.OpenProcess(ProcessQueryLimitedInformation, false, pid);
    if (process == IntPtr.Zero) Marshal.ThrowExceptionForHR(Marshal.GetHRForLastWin32Error());
    try
    {
        var capacity = 32768;
        var buffer = new char[capacity];
        if (!Native.QueryFullProcessImageName(process, 0, buffer, ref capacity)) Marshal.ThrowExceptionForHR(Marshal.GetHRForLastWin32Error());
        return new string(buffer, 0, capacity);
    }
    finally { Native.CloseHandle(process); }
}

static async Task<(int Width, int Height)> CaptureAsync(IntPtr hwnd, string outputPath)
{
    if (!GraphicsCaptureSession.IsSupported()) throw new InvalidOperationException("Windows Graphics Capture is not supported.");
    var item = CreateItem(hwnd);
    if (item.Size.Width <= 0 || item.Size.Height <= 0 || item.Size.Width > 16384 || item.Size.Height > 16384)
        throw new InvalidOperationException("The target window size is outside the supported range.");
    using var device = CreateDirect3DDevice();
    using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
    using var session = pool.CreateCaptureSession(item);
    try { session.IsCursorCaptureEnabled = false; } catch { }
    var completion = new TaskCompletionSource<Direct3D11CaptureFrame>(TaskCreationOptions.RunContinuationsAsynchronously);
    void OnFrame(Direct3D11CaptureFramePool sender, object _)
    {
        try
        {
            var frame = sender.TryGetNextFrame();
            if (frame is not null) completion.TrySetResult(frame);
        }
        catch (Exception error) { completion.TrySetException(error); }
    }
    pool.FrameArrived += OnFrame;
    var temporaryPath = outputPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
        session.StartCapture();
        using var frame = await completion.Task.WaitAsync(TimeSpan.FromSeconds(8));
        using var bitmap = await SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface);
        await using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        using (var random = stream.AsRandomAccessStream())
        {
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, random);
            encoder.SetSoftwareBitmap(bitmap);
            await encoder.FlushAsync();
        }
        File.Move(temporaryPath, outputPath, false);
        return (frame.ContentSize.Width, frame.ContentSize.Height);
    }
    finally
    {
        pool.FrameArrived -= OnFrame;
        if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
    }
}

static GraphicsCaptureItem CreateItem(IntPtr hwnd)
{
    var interopIid = new Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
    using var factory = ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem", interopIid);
    var vtable = Marshal.ReadIntPtr(factory.ThisPtr);
    var method = Marshal.ReadIntPtr(vtable, IntPtr.Size * 3);
    var createForWindow = Marshal.GetDelegateForFunctionPointer<CreateForWindowDelegate>(method);
    var itemIid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    var result = createForWindow(factory.ThisPtr, hwnd, ref itemIid, out var itemPtr);
    Marshal.ThrowExceptionForHR(result);
    try { return GraphicsCaptureItem.FromAbi(itemPtr); }
    finally { Marshal.Release(itemPtr); }
}

static IDirect3DDevice CreateDirect3DDevice()
{
    const uint BgraSupport = 0x20;
    var result = Native.D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, BgraSupport, IntPtr.Zero, 0, 7,
        out var d3dDevice, out _, out var immediateContext);
    if (result < 0)
        result = Native.D3D11CreateDevice(IntPtr.Zero, 5, IntPtr.Zero, BgraSupport, IntPtr.Zero, 0, 7,
            out d3dDevice, out _, out immediateContext);
    Marshal.ThrowExceptionForHR(result);
    if (immediateContext != IntPtr.Zero) Marshal.Release(immediateContext);
    var dxgiIid = new Guid("54EC77FA-1377-44E6-8C32-88FD5F44C84C");
    result = Marshal.QueryInterface(d3dDevice, in dxgiIid, out var dxgiDevice);
    Marshal.Release(d3dDevice);
    Marshal.ThrowExceptionForHR(result);
    try
    {
        result = Native.CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice, out var inspectable);
        Marshal.ThrowExceptionForHR(result);
        try { return MarshalInterface<IDirect3DDevice>.FromAbi(inspectable); }
        finally { Marshal.Release(inspectable); }
    }
    finally { Marshal.Release(dxgiDevice); }
}

readonly record struct CaptureOptions(IntPtr Handle, int ProcessId, DateTimeOffset ProcessStartedAt, string ExecutablePath, string OutputPath);
readonly record struct WindowIdentity(IntPtr Handle, bool Minimized);

[UnmanagedFunctionPointer(CallingConvention.StdCall)]
delegate int CreateForWindowDelegate(IntPtr @this, IntPtr window, ref Guid iid, out IntPtr result);

static class Native
{
    [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int processId);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] internal static extern bool QueryFullProcessImageName(IntPtr process, uint flags, [Out] char[] path, ref int size);
    [DllImport("kernel32.dll")] internal static extern bool CloseHandle(IntPtr handle);
    [DllImport("d3d11.dll", ExactSpelling = true)]
    internal static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags,
        IntPtr featureLevels, uint featureLevelCount, uint sdkVersion, out IntPtr device,
        out int selectedFeatureLevel, out IntPtr immediateContext);
    [DllImport("d3d11.dll", ExactSpelling = true)]
    internal static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
}
