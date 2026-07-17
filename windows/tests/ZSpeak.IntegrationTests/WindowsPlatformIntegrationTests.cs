using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using System.Runtime.InteropServices;
using ZSpeak.Platform.Audio;
using ZSpeak.Platform.Win32;

namespace ZSpeak.IntegrationTests;

public sealed class WindowsPlatformIntegrationTests
{
    [Fact]
    [Trait("Category", "Windows")]
    public void Hotkey_DetectaConflitoELiberaRegistro()
    {
        const uint modifiers = 0x0002 | 0x0001;
        var virtualKey = (uint)(0x70 + Random.Shared.Next(0, 12));
        using (var first = new GlobalHotkey(modifiers, virtualKey))
        {
            Assert.ThrowsAny<Exception>(() => new GlobalHotkey(modifiers, virtualKey));
        }

        using var afterUnregister = new GlobalHotkey(modifiers, virtualKey);
    }

    [Fact]
    [Trait("Category", "Windows")]
    public async Task Hotkey_RecebeKeyDownGlobalInjetado()
    {
        const uint modifiers = 0x0002 | 0x0001;
        var virtualKey = (uint)(0x70 + Random.Shared.Next(0, 12));
        using var hotkey = new GlobalHotkey(modifiers, virtualKey);
        var pressed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        hotkey.Pressed += (_, _) => pressed.TrySetResult();

        KeybdEvent(0x11, 0, 0, 0);
        KeybdEvent(0x12, 0, 0, 0);
        KeybdEvent((byte)virtualKey, 0, 0, 0);
        KeybdEvent((byte)virtualKey, 0, 2, 0);
        KeybdEvent(0x12, 0, 2, 0);
        KeybdEvent(0x11, 0, 2, 0);

        await pressed.Task.WaitAsync(TimeSpan.FromSeconds(2));
    }

    [Fact]
    [Trait("Category", "Windows")]
    public async Task EscapeGlobal_TemCicloDeVidaLimitadoAGravacao()
    {
        using var escape = new GlobalHotkey(0, 0x1B);
        var pressed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        escape.Pressed += (_, _) => pressed.TrySetResult();

        KeybdEvent(0x1B, 0, 0, 0);
        KeybdEvent(0x1B, 0, 2, 0);

        await pressed.Task.WaitAsync(TimeSpan.FromSeconds(2));
    }

    [Fact]
    [Trait("Category", "Windows")]
    public async Task ClipboardEFoco_ColaNoCampoAnteriormenteFocado()
    {
        var pasted = await RunOnDispatcherAsync(async () =>
        {
            var textBox = new TextBox { Width = 300, Height = 40 };
            var window = new Window { Width = 400, Height = 140, Content = textBox, ShowInTaskbar = false };
            window.Show();
            window.Activate();
            textBox.Focus();
            await Task.Delay(100);
            var target = new WindowInteropHelper(window).Handle;
            var result = await TextInserter.CopyAndPasteAsync("zspeak clipboard teste", target);
            await Task.Delay(200);
            var value = textBox.Text;
            var clipboard = Clipboard.GetText();
            window.Close();
            Assert.True(result.FocusRestored);
            Assert.True(result.InputSent);
            Assert.Equal("zspeak clipboard teste", clipboard);
            return value;
        });

        Assert.Equal("zspeak clipboard teste", pasted);
    }

    [Fact]
    [Trait("Category", "Windows")]
    public async Task FalhaDeFoco_MantemTextoNoClipboardENaoEnviaPaste()
    {
        var result = await RunOnDispatcherAsync(async () =>
        {
            var paste = await TextInserter.CopyAndPasteAsync("fallback seguro", 0);
            Assert.Equal("fallback seguro", Clipboard.GetText());
            return paste;
        });

        Assert.False(result.FocusRestored);
        Assert.False(result.InputSent);
    }

    [Fact]
    [Trait("Category", "Windows")]
    public async Task ModoApenasCopiar_NaoPrecisaDeJanelaAlvo()
    {
        await RunOnDispatcherAsync(async () =>
        {
            await TextInserter.CopyAsync("somente clipboard");
            Assert.Equal("somente clipboard", Clipboard.GetText());
            return true;
        });
    }

    [Fact]
    [Trait("Category", "Windows")]
    public void SingleInstance_ImpedeSegundaInstancia()
    {
        var name = "Local\\zspeak-test-" + Guid.NewGuid();
        using var first = new SingleInstance(name);
        using var second = new SingleInstance(name);
        Assert.True(first.IsPrimary);
        Assert.False(second.IsPrimary);
    }

    [Fact]
    [Trait("Category", "Hardware")]
    public async Task Wasapi_GravaAudioRealMono16KhzFloat32()
    {
        var devices = WasapiMicrophoneCapture.EnumerateDevices();
        Assert.NotEmpty(devices);
        using var capture = new WasapiMicrophoneCapture();
        var receivedLevel = new TaskCompletionSource<float>(TaskCreationOptions.RunContinuationsAsynchronously);
        capture.LevelChanged += (_, level) => receivedLevel.TrySetResult(level);
        capture.Start(devices[0].Id);
        await Task.Delay(750);
        var samples = await capture.StopAsync();

        Assert.InRange(samples.Length, 8_000, 32_000);
        Assert.All(samples, sample => Assert.True(float.IsFinite(sample) && sample is >= -1.1f and <= 1.1f));
        Assert.InRange(await receivedLevel.Task.WaitAsync(TimeSpan.FromSeconds(2)), 0f, 1f);
    }

    private static Task<T> RunOnDispatcherAsync<T>(Func<Task<T>> action)
    {
        var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            dispatcher.InvokeAsync(async () =>
            {
                try { result.TrySetResult(await action()); }
                catch (Exception exception) { result.TrySetException(exception); }
                finally { dispatcher.BeginInvokeShutdown(DispatcherPriority.Background); }
            });
            Dispatcher.Run();
        })
        { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return result.Task;
    }

    [DllImport("user32.dll", EntryPoint = "keybd_event")]
    private static extern void KeybdEvent(byte virtualKey, byte scanCode, uint flags, nuint extraInfo);
}
