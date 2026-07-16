using System.Runtime.InteropServices;
using System.Windows;

namespace ZSpeak.Platform.Win32;

public sealed record PasteResult(bool FocusRestored, bool InputSent);

public static class TextInserter
{
    private const uint InputKeyboard = 1;
    private const uint KeyUp = 0x0002;
    private const ushort VkControl = 0x11;
    private const ushort VkV = 0x56;

    public static nint CaptureForegroundWindow() => GetForegroundWindow();

    public static async Task<PasteResult> CopyAndPasteAsync(
        string text,
        nint targetWindow,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return new PasteResult(false, false);
        }

        await SetClipboardAsync(text, cancellationToken);
        var focused = RestoreForeground(targetWindow);
        if (!focused)
        {
            return new PasteResult(false, false);
        }

        await Task.Delay(80, cancellationToken);
        var inputs = new[]
        {
            Key(VkControl, 0),
            Key(VkV, 0),
            Key(VkV, KeyUp),
            Key(VkControl, KeyUp)
        };
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) == inputs.Length;
        return new PasteResult(focused, sent);
    }

    private static async Task SetClipboardAsync(string text, CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                Clipboard.SetText(text, TextDataFormat.UnicodeText);
                return;
            }
            catch (ExternalException) when (attempt < 6)
            {
                await Task.Delay(40 * attempt, cancellationToken);
            }
        }
    }

    private static Input Key(ushort key, uint flags) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion { Keyboard = new KeyboardInput { VirtualKey = key, Flags = flags } }
    };

    private static bool RestoreForeground(nint targetWindow)
    {
        if (targetWindow == 0 || !IsWindow(targetWindow))
        {
            return false;
        }

        var targetThread = GetWindowThreadProcessId(targetWindow, out _);
        var foreground = GetForegroundWindow();
        var foregroundThread = foreground == 0 ? 0 : GetWindowThreadProcessId(foreground, out _);
        var currentThread = GetCurrentThreadId();
        try
        {
            if (foregroundThread != 0 && foregroundThread != currentThread)
            {
                AttachThreadInput(currentThread, foregroundThread, true);
            }
            if (targetThread != 0 && targetThread != currentThread && targetThread != foregroundThread)
            {
                AttachThreadInput(currentThread, targetThread, true);
            }

            ShowWindowAsync(targetWindow, 9); // SW_RESTORE
            BringWindowToTop(targetWindow);
            SetForegroundWindow(targetWindow);
            return GetForegroundWindow() == targetWindow;
        }
        finally
        {
            if (targetThread != 0 && targetThread != currentThread && targetThread != foregroundThread)
            {
                AttachThreadInput(currentThread, targetThread, false);
            }
            if (foregroundThread != 0 && foregroundThread != currentThread)
            {
                AttachThreadInput(currentThread, foregroundThread, false);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public HardwareInput Hardware;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public nint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X, Y;
        public uint MouseData, Flags, Time;
        public nint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HardwareInput
    {
        public uint Message;
        public ushort ParamLow, ParamHigh;
    }

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(nint hwnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(nint hwnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(nint hwnd, int command);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);
}
