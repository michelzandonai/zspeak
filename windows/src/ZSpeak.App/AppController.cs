using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using ZSpeak.Core.Asr;
using ZSpeak.Core.Models;
using ZSpeak.Core.Persistence;
using ZSpeak.Platform.Audio;
using ZSpeak.Platform.Win32;

namespace ZSpeak.App;

public sealed class AppController : INotifyPropertyChanged, IDisposable
{
    private readonly JsonFileStore _store = new();
    private readonly AppStateMachine _stateMachine = new();
    private readonly SemaphoreSlim _toggleGate = new(1, 1);
    private readonly StatusOverlay _overlay = new();
    private CancellationTokenSource? _modelDownload;
    private ParakeetAsrService? _asr;
    private WasapiMicrophoneCapture? _capture;
    private GlobalHotkey? _hotkey;
    private AppSettings _settings = new();
    private AppStatus _status = AppStatus.Loading;
    private string _statusMessage = "Preparando o modelo local…";
    private nint _targetWindow;

    public event PropertyChangedEventHandler? PropertyChanged;
    public ObservableCollection<MicrophoneDevice> Microphones { get; } = new();
    public ObservableCollection<TranscriptionRecord> History { get; } = new();

    public AppStatus Status
    {
        get => _status;
        private set
        {
            _stateMachine.TransitionTo(value);
            _status = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanSelectMicrophone));
        }
    }

    public string StatusMessage
    {
        get => _statusMessage;
        private set { _statusMessage = value; OnPropertyChanged(); }
    }

    public bool CanSelectMicrophone => Status is AppStatus.Ready or AppStatus.Error;

    public MicrophoneDevice? SelectedMicrophone
    {
        get => Microphones.FirstOrDefault(microphone => microphone.Id == _settings.MicrophoneId)
            ?? Microphones.FirstOrDefault();
        set
        {
            if (value is null || value.Id == _settings.MicrophoneId)
            {
                return;
            }

            _settings = _settings with { MicrophoneId = value.Id };
            OnPropertyChanged();
            _ = _store.SaveSettingsAsync(_settings);
        }
    }

    public async Task InitializeAsync()
    {
        DisposeRuntime();
        Status = AppStatus.Loading;
        StatusMessage = "Preparando o modelo local…";
        _settings = await _store.LoadSettingsAsync();
        Microphones.Clear();
        foreach (var microphone in WasapiMicrophoneCapture.EnumerateDevices())
        {
            Microphones.Add(microphone);
        }

        if (_settings.MicrophoneId is null && Microphones.FirstOrDefault() is { } defaultMicrophone)
        {
            _settings = _settings with { MicrophoneId = defaultMicrophone.Id };
            await _store.SaveSettingsAsync(_settings);
        }

        OnPropertyChanged(nameof(SelectedMicrophone));
        History.Clear();
        foreach (var record in await _store.LoadHistoryAsync())
        {
            History.Add(record);
        }

        _hotkey = new GlobalHotkey(_settings.HotkeyModifiers, _settings.HotkeyVirtualKey);
        _hotkey.Pressed += OnHotkeyPressed;
        _modelDownload = new CancellationTokenSource();
        var progress = new Progress<ModelDownloadProgress>(value =>
        {
            StatusMessage = value.Percentage is { } percentage
                ? $"Baixando Parakeet V3: {percentage:F1}%"
                : $"Baixando Parakeet V3: {value.BytesReceived / 1024d / 1024d:F1} MiB";
        });
        var model = await new ParakeetModelManager().EnsureAsync(
            progress: progress,
            cancellationToken: _modelDownload.Token);
        StatusMessage = "Carregando Parakeet V3 na CPU…";
        _asr = await Task.Run(() => new ParakeetAsrService(model), _modelDownload.Token);
        Status = AppStatus.Ready;
        StatusMessage = Microphones.Count == 0
            ? "Modelo pronto; nenhum microfone ativo foi encontrado."
            : "Pronto — Ctrl+Alt+Espaço inicia a gravação.";
    }

    public async Task ToggleRecordingAsync()
    {
        if (!await _toggleGate.WaitAsync(0))
        {
            return;
        }

        try
        {
            if (Status == AppStatus.Ready)
            {
                StartRecording();
            }
            else if (Status == AppStatus.Recording)
            {
                await StopAndTranscribeAsync();
            }
        }
        catch (Exception exception)
        {
            SetFatalError(exception.Message);
        }
        finally
        {
            _toggleGate.Release();
        }
    }

    private void StartRecording()
    {
        if (_asr is null)
        {
            throw new InvalidOperationException("O modelo local ainda não está pronto.");
        }

        if (SelectedMicrophone is null)
        {
            throw new InvalidOperationException("Nenhum microfone ativo foi encontrado.");
        }

        _targetWindow = TextInserter.CaptureForegroundWindow();
        _capture = new WasapiMicrophoneCapture();
        _capture.Start(SelectedMicrophone.Id);
        Status = AppStatus.Recording;
        StatusMessage = "Gravando — pressione Ctrl+Alt+Espaço para encerrar.";
        _overlay.ShowStatus("● Gravando");
    }

    private async Task StopAndTranscribeAsync()
    {
        Status = AppStatus.Transcribing;
        StatusMessage = "Transcrevendo localmente…";
        _overlay.ShowStatus("Transcrevendo…");
        var capture = _capture ?? throw new InvalidOperationException("A captura não está ativa.");
        var samples = await capture.StopAsync();
        capture.Dispose();
        _capture = null;
        if (samples.Length < 1_600)
        {
            Status = AppStatus.Ready;
            StatusMessage = "Gravação curta demais; nenhum texto foi inserido.";
            _overlay.Hide();
            return;
        }

        var result = await Task.Run(() => _asr!.Transcribe(samples));
        if (!string.IsNullOrWhiteSpace(result.Text))
        {
            var record = new TranscriptionRecord(
                Guid.NewGuid(), DateTimeOffset.Now, result.Text,
                result.AudioDuration.TotalSeconds, result.InferenceDuration.TotalSeconds);
            await _store.AddHistoryAsync(record);
            History.Insert(0, record);
            var paste = await TextInserter.CopyAndPasteAsync(result.Text, _targetWindow);
            StatusMessage = paste.InputSent
                ? "Transcrição inserida; o texto também está no clipboard."
                : "Não foi possível enviar Ctrl+V; o texto permanece no clipboard.";
        }
        else
        {
            StatusMessage = "Nenhuma fala foi reconhecida.";
        }

        Status = AppStatus.Ready;
        _overlay.Hide();
    }

    private void OnHotkeyPressed(object? sender, EventArgs args) =>
        System.Windows.Application.Current.Dispatcher.InvokeAsync(ToggleRecordingAsync);

    public void CancelModelDownload() => _modelDownload?.Cancel();

    public void SetFatalError(string message)
    {
        Status = AppStatus.Error;
        StatusMessage = message;
        _overlay.ShowStatus("Erro — abra o menu do zspeak");
    }

    private void DisposeRuntime()
    {
        _hotkey?.Dispose();
        _hotkey = null;
        _capture?.Dispose();
        _capture = null;
        _asr?.Dispose();
        _asr = null;
        _modelDownload?.Dispose();
        _modelDownload = null;
    }

    public void Dispose()
    {
        DisposeRuntime();
        _overlay.Close();
        _toggleGate.Dispose();
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
