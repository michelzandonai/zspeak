using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ZSpeak.Platform.Win32;

public sealed class GlobalHotkey : IDisposable
{
    private const int HotkeyId = 0x5A51;
    private const uint WmHotkey = 0x0312;
    private const uint WmQuit = 0x0012;
    private readonly TaskCompletionSource _started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Thread _thread;
    private Exception? _startupError;
    private uint _threadId;
    private bool _disposed;

    public GlobalHotkey(uint modifiers, uint virtualKey)
    {
        Modifiers = modifiers;
        VirtualKey = virtualKey;
        _thread = new Thread(RunMessageLoop)
        {
            IsBackground = true,
            Name = "zspeak-global-hotkey"
        };
        _thread.Start();
        _started.Task.GetAwaiter().GetResult();
        if (_startupError is not null)
        {
            throw _startupError;
        }
    }

    public uint Modifiers { get; }
    public uint VirtualKey { get; }
    public event EventHandler? Pressed;

    private void RunMessageLoop()
    {
        _threadId = GetCurrentThreadId();
        if (!RegisterHotKey(0, HotkeyId, Modifiers | 0x4000, VirtualKey))
        {
            _startupError = new Win32Exception(
                Marshal.GetLastWin32Error(),
                "A hotkey Ctrl+Alt+Espaço já está em uso.");
            _started.TrySetResult();
            return;
        }

        _started.TrySetResult();
        try
        {
            while (GetMessage(out var message, 0, 0, 0) > 0)
            {
                if (message.Id == WmHotkey && message.WParam == HotkeyId)
                {
                    Pressed?.Invoke(this, EventArgs.Empty);
                }
            }
        }
        finally
        {
            UnregisterHotKey(0, HotkeyId);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_threadId != 0 && _thread.IsAlive)
        {
            PostThreadMessage(_threadId, WmQuit, 0, 0);
            _thread.Join(TimeSpan.FromSeconds(2));
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMessage
    {
        public nint Hwnd;
        public uint Id;
        public nuint WParam;
        public nint LParam;
        public uint Time;
        public Point Point;
        public uint Private;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(nint hwnd, int id);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out NativeMessage message, nint hwnd, uint min, uint max);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostThreadMessage(uint threadId, uint message, nuint wParam, nint lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
}
