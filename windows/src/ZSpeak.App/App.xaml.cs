using System.Drawing;
using System.IO;
using System.Windows;
using Forms = System.Windows.Forms;
using ZSpeak.Core.Models;
using ZSpeak.Platform.Win32;

namespace ZSpeak.App;

public partial class App : System.Windows.Application
{
    private SingleInstance? _singleInstance;
    private AppController? _controller;
    private Forms.NotifyIcon? _tray;
    private Forms.ToolStripMenuItem? _toggleItem;
    private Forms.ToolStripMenuItem? _cancelDownloadItem;
    private MainWindow? _settingsWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _singleInstance = new SingleInstance();
        if (!_singleInstance.IsPrimary)
        {
            System.Windows.MessageBox.Show("O zspeak já está em execução na bandeja.", "zspeak");
            Shutdown();
            return;
        }

        _controller = new AppController();
        _controller.PropertyChanged += (_, _) => Dispatcher.Invoke(UpdateTray);
        CreateTray();
        _ = InitializeAsync();
        var settingsPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "zspeak", "settings.json");
        if (e.Args.Contains("--settings", StringComparer.OrdinalIgnoreCase) || !File.Exists(settingsPath))
        {
            Dispatcher.BeginInvoke(ShowSettings);
        }
    }

    private async Task InitializeAsync()
    {
        try
        {
            await _controller!.InitializeAsync();
        }
        catch (OperationCanceledException)
        {
            _controller!.SetFatalError("Download cancelado. Use “Tentar novamente” quando desejar.");
        }
        catch (Exception exception)
        {
            _controller!.SetFatalError(exception.Message);
        }
    }

    private void CreateTray()
    {
        _tray = new Forms.NotifyIcon
        {
            Text = "zspeak — carregando",
            Icon = SystemIcons.Information,
            Visible = true
        };
        var menu = new Forms.ContextMenuStrip();
        _toggleItem = new Forms.ToolStripMenuItem("Carregando…", null, (_, _) => Dispatcher.InvokeAsync(ToggleAsync));
        var settings = new Forms.ToolStripMenuItem("Configurações e histórico", null, (_, _) => Dispatcher.Invoke(ShowSettings));
        _cancelDownloadItem = new Forms.ToolStripMenuItem("Cancelar download do modelo", null, (_, _) => _controller?.CancelModelDownload());
        var exit = new Forms.ToolStripMenuItem("Sair", null, (_, _) => Dispatcher.Invoke(Shutdown));
        menu.Items.AddRange(new Forms.ToolStripItem[] { _toggleItem, settings, _cancelDownloadItem, new Forms.ToolStripSeparator(), exit });
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowSettings);
        UpdateTray();
    }

    private async Task ToggleAsync()
    {
        if (_controller is null)
        {
            return;
        }

        if (_controller.Status == AppStatus.Error)
        {
            await InitializeAsync();
            return;
        }

        await _controller.ToggleRecordingAsync();
    }

    private void ShowSettings()
    {
        if (_settingsWindow is null)
        {
            _settingsWindow = new MainWindow(_controller!);
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }

        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void UpdateTray()
    {
        if (_tray is null || _controller is null || _toggleItem is null || _cancelDownloadItem is null)
        {
            return;
        }

        var (label, icon) = _controller.Status switch
        {
            AppStatus.Loading => ("Carregando", SystemIcons.Information),
            AppStatus.Ready => ("Pronto", SystemIcons.Application),
            AppStatus.Recording => ("Gravando", SystemIcons.Warning),
            AppStatus.Transcribing => ("Transcrevendo", SystemIcons.Information),
            _ => ("Erro", SystemIcons.Error)
        };
        _tray.Text = $"zspeak — {label}";
        _tray.Icon = icon;
        _toggleItem.Text = _controller.Status switch
        {
            AppStatus.Ready => "Iniciar gravação (Ctrl+Alt+Espaço)",
            AppStatus.Recording => "Encerrar e transcrever",
            AppStatus.Error => "Tentar novamente",
            _ => label + "…"
        };
        _toggleItem.Enabled = _controller.Status is AppStatus.Ready or AppStatus.Recording or AppStatus.Error;
        _cancelDownloadItem.Visible = _controller.Status == AppStatus.Loading;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _controller?.Dispose();
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }

        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
