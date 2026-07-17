using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Media;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using ZSpeak.Core.Asr;
using ZSpeak.Core.Models;
using ZSpeak.Core.Persistence;
using ZSpeak.Platform.Audio;
using ZSpeak.Platform.Win32;

namespace ZSpeak.App;

public sealed class AppController : INotifyPropertyChanged, IDisposable
{
    private const string StartupRegistryPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private readonly JsonFileStore _store = new();
    private readonly AppStateMachine _stateMachine = new();
    private readonly SemaphoreSlim _toggleGate = new(1, 1);
    private readonly StatusOverlay _overlay = new();
    private CancellationTokenSource? _modelDownload;
    private ParakeetAsrService? _asr;
    private WasapiMicrophoneCapture? _capture;
    private GlobalHotkey? _hotkey;
    private GlobalHotkey? _escapeHotkey;
    private AppSettings _settings = new();
    private AppStatus _status = AppStatus.Loading;
    private string _statusMessage = "Preparando o modelo local…";
    private nint _targetWindow;
    private bool _settingsLoaded;

    public event PropertyChangedEventHandler? PropertyChanged;
    public ObservableCollection<MicrophoneDevice> Microphones { get; } = new();
    public ObservableCollection<TranscriptionRecord> History { get; } = new();
    public ObservableCollection<string> Vocabulary { get; } = new();

    public AppStatus Status
    {
        get => _status;
        private set
        {
            _stateMachine.TransitionTo(value);
            _status = value;
            NotifyState();
        }
    }

    public string StatusMessage
    {
        get => _statusMessage;
        private set { _statusMessage = value; OnPropertyChanged(); }
    }

    public string StatusTitle => Status switch
    {
        AppStatus.Loading => "Preparando o zspeak",
        AppStatus.Ready => "Pronto para transcrever",
        AppStatus.Recording => "Gravando áudio",
        AppStatus.Transcribing => "Transcrevendo localmente",
        _ => "Atenção necessária"
    };

    public string StatusChip => Status switch
    {
        AppStatus.Loading => "CARREGANDO",
        AppStatus.Ready => "PRONTO",
        AppStatus.Recording => "AO VIVO",
        AppStatus.Transcribing => "PROCESSANDO",
        _ => "ERRO"
    };

    public System.Windows.Media.Brush StatusBrush => Status switch
    {
        AppStatus.Ready => new SolidColorBrush(System.Windows.Media.Color.FromRgb(84, 209, 158)),
        AppStatus.Recording or AppStatus.Error => new SolidColorBrush(System.Windows.Media.Color.FromRgb(255, 77, 82)),
        AppStatus.Transcribing => new SolidColorBrush(System.Windows.Media.Color.FromRgb(89, 199, 237)),
        _ => new SolidColorBrush(System.Windows.Media.Color.FromRgb(255, 168, 61))
    };

    public bool CanSelectMicrophone => Status is AppStatus.Ready or AppStatus.Error;
    public int HistoryCount => History.Count;
    public int TodayCount => History.Count(item => item.CreatedAt.LocalDateTime.Date == DateTime.Today);
    public string TotalAudioText => FormatDuration(History.Sum(item => item.AudioSeconds));
    public string AverageRtfText => History.Count == 0 ? "—" : History.Average(item => item.RealTimeFactor).ToString("F2");
    public string AverageInferenceText => History.Count == 0 ? "—" : $"{History.Average(item => item.InferenceSeconds):F1}s";
    public Visibility HasHistoryVisibility => History.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    public Visibility VocabularyEmptyVisibility => Vocabulary.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public string LatestTranscriptionText => History.FirstOrDefault()?.Text ?? string.Empty;
    public string LatestTranscriptionMeta => History.FirstOrDefault() is { } item
        ? $"{item.CreatedAt.LocalDateTime:dd/MM/yyyy · HH:mm} · {item.AudioSeconds:F1}s de áudio · RTF {item.RealTimeFactor:F2}"
        : string.Empty;
    public string MicrophoneSummary => SelectedMicrophone?.Name ?? "Não encontrado";
    public string VersionText => $"Versão {Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.0.51"}";

    public MicrophoneDevice? SelectedMicrophone
    {
        get => (_settings.UseSystemMicrophone ? Microphones.FirstOrDefault(item => item.IsDefault) : null)
            ?? Microphones.FirstOrDefault(microphone => microphone.Id == _settings.MicrophoneId)
            ?? Microphones.FirstOrDefault();
        set
        {
            if (value is null || value.Id == _settings.MicrophoneId)
            {
                return;
            }

            UpdateSettings(_settings with { MicrophoneId = value.Id, UseSystemMicrophone = false });
            OnPropertyChanged();
            OnPropertyChanged(nameof(UseSystemMicrophone));
            OnPropertyChanged(nameof(MicrophoneSummary));
        }
    }

    public bool UseSystemMicrophone
    {
        get => _settings.UseSystemMicrophone;
        set
        {
            if (value == _settings.UseSystemMicrophone) return;
            UpdateSettings(_settings with { UseSystemMicrophone = value });
            OnPropertyChanged();
            OnPropertyChanged(nameof(SelectedMicrophone));
            OnPropertyChanged(nameof(MicrophoneSummary));
        }
    }

    public bool AutoPaste { get => _settings.AutoPaste; set => SetSetting(value, _settings.AutoPaste, s => s with { AutoPaste = value }); }
    public string InsertionMode
    {
        get => _settings.AutoPaste ? "paste" : "copy";
        set
        {
            var autoPaste = !string.Equals(value, "copy", StringComparison.Ordinal);
            if (autoPaste == _settings.AutoPaste) return;
            UpdateSettings(_settings with { AutoPaste = autoPaste });
            OnPropertyChanged();
            OnPropertyChanged(nameof(AutoPaste));
        }
    }
    public bool ShowOverlay { get => _settings.ShowOverlay; set => SetSetting(value, _settings.ShowOverlay, s => s with { ShowOverlay = value }); }
    public bool SoundFeedback { get => _settings.SoundFeedback; set => SetSetting(value, _settings.SoundFeedback, s => s with { SoundFeedback = value }); }
    public bool ShowLatency { get => _settings.ShowLatency; set => SetSetting(value, _settings.ShowLatency, s => s with { ShowLatency = value }); }
    public bool EscapeCancelsRecording { get => _settings.EscapeCancelsRecording; set => SetSetting(value, _settings.EscapeCancelsRecording, s => s with { EscapeCancelsRecording = value }); }
    public bool LaunchAtStartup
    {
        get => _settings.LaunchAtStartup;
        set
        {
            if (value == _settings.LaunchAtStartup) return;
            ConfigureStartup(value);
            UpdateSettings(_settings with { LaunchAtStartup = value });
            OnPropertyChanged();
        }
    }

    public async Task InitializeAsync()
    {
        DisposeRuntime();
        Status = AppStatus.Loading;
        StatusMessage = "Preparando o modelo local…";
        _settings = await _store.LoadSettingsAsync();
        if (_settings.SchemaVersion < 2)
        {
            _settings = _settings with { SchemaVersion = 2 };
            await _store.SaveSettingsAsync(_settings);
        }
        _settingsLoaded = true;

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

        History.Clear();
        foreach (var record in await _store.LoadHistoryAsync()) History.Add(record);
        Vocabulary.Clear();
        foreach (var term in await _store.LoadVocabularyAsync()) Vocabulary.Add(term);
        NotifySettings();
        NotifyHistory();
        NotifyVocabulary();

        _hotkey = new GlobalHotkey(_settings.HotkeyModifiers, _settings.HotkeyVirtualKey);
        _hotkey.Pressed += OnHotkeyPressed;
        _modelDownload = new CancellationTokenSource();
        var progress = new Progress<ModelDownloadProgress>(value =>
        {
            StatusMessage = value.Percentage is { } percentage
                ? $"Baixando Parakeet V3: {percentage:F1}%"
                : $"Baixando Parakeet V3: {value.BytesReceived / 1024d / 1024d:F1} MiB";
        });
        var model = await new ParakeetModelManager().EnsureAsync(progress: progress, cancellationToken: _modelDownload.Token);
        StatusMessage = "Carregando Parakeet V3 na CPU…";
        _asr = await Task.Run(() => new ParakeetAsrService(model), _modelDownload.Token);
        Status = AppStatus.Ready;
        StatusMessage = Microphones.Count == 0
            ? "Modelo pronto; nenhum microfone ativo foi encontrado."
            : "Pronto — Ctrl+Alt+Espaço inicia a gravação.";
    }

    public async Task ToggleRecordingAsync()
    {
        if (!await _toggleGate.WaitAsync(0)) return;
        try
        {
            if (Status == AppStatus.Ready) StartRecording();
            else if (Status == AppStatus.Recording) await StopAndTranscribeAsync();
        }
        catch (Exception exception) { SetFatalError(exception.Message); }
        finally { _toggleGate.Release(); }
    }

    private void StartRecording()
    {
        if (_asr is null) throw new InvalidOperationException("O modelo local ainda não está pronto.");
        if (SelectedMicrophone is null) throw new InvalidOperationException("Nenhum microfone ativo foi encontrado.");

        _targetWindow = TextInserter.CaptureForegroundWindow();
        _capture = new WasapiMicrophoneCapture();
        _capture.LevelChanged += OnCaptureLevelChanged;
        _capture.Start(SelectedMicrophone.Id);
        if (_settings.EscapeCancelsRecording)
        {
            try
            {
                _escapeHotkey = new GlobalHotkey(0, 0x1B);
                _escapeHotkey.Pressed += OnEscapePressed;
            }
            catch
            {
                // Outro aplicativo pode reservar Escape; a gravação principal continua funcional.
                _escapeHotkey = null;
            }
        }
        if (_settings.SoundFeedback) SystemSounds.Asterisk.Play();
        Status = AppStatus.Recording;
        StatusMessage = "Gravando — pressione Ctrl+Alt+Espaço para encerrar.";
        if (_settings.ShowOverlay) _overlay.ShowRecording(TextInserter.GetWindowTitle(_targetWindow), SelectedMicrophone.Name);
    }

    private async Task StopAndTranscribeAsync()
    {
        DisposeEscapeHotkey();
        Status = AppStatus.Transcribing;
        StatusMessage = "Transcrevendo localmente…";
        if (_settings.ShowOverlay) _overlay.ShowTranscribing();
        var capture = _capture ?? throw new InvalidOperationException("A captura não está ativa.");
        var samples = await capture.StopAsync();
        capture.LevelChanged -= OnCaptureLevelChanged;
        capture.Dispose();
        _capture = null;
        if (_settings.SoundFeedback) SystemSounds.Asterisk.Play();
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
            var text = ApplyVocabulary(result.Text);
            var record = new TranscriptionRecord(Guid.NewGuid(), DateTimeOffset.Now, text,
                result.AudioDuration.TotalSeconds, result.InferenceDuration.TotalSeconds);
            await _store.AddHistoryAsync(record);
            History.Insert(0, record);
            NotifyHistory();
            if (_settings.AutoPaste)
            {
                var paste = await TextInserter.CopyAndPasteAsync(text, _targetWindow);
                StatusMessage = paste.InputSent
                    ? "Transcrição inserida; o texto também está no clipboard."
                    : "Não foi possível enviar Ctrl+V; o texto permanece no clipboard.";
            }
            else
            {
                await TextInserter.CopyAsync(text);
                StatusMessage = "Transcrição copiada para o clipboard.";
            }
        }
        else StatusMessage = "Nenhuma fala foi reconhecida.";

        Status = AppStatus.Ready;
        _overlay.Hide();
    }

    public async Task DeleteHistoryAsync(TranscriptionRecord record)
    {
        History.Remove(record);
        await _store.SaveHistoryAsync(History);
        NotifyHistory();
    }

    public async Task ClearHistoryAsync()
    {
        History.Clear();
        await _store.SaveHistoryAsync(History);
        NotifyHistory();
    }

    public async Task AddVocabularyAsync(string term)
    {
        var clean = term.Trim();
        if (clean.Length == 0 || Vocabulary.Any(item => string.Equals(item, clean, StringComparison.CurrentCultureIgnoreCase))) return;
        Vocabulary.Add(clean);
        await _store.SaveVocabularyAsync(Vocabulary);
        NotifyVocabulary();
    }

    public async Task RemoveVocabularyAsync(string term)
    {
        Vocabulary.Remove(term);
        await _store.SaveVocabularyAsync(Vocabulary);
        NotifyVocabulary();
    }

    private string ApplyVocabulary(string text)
    {
        foreach (var term in Vocabulary)
        {
            text = System.Text.RegularExpressions.Regex.Replace(
                text, $@"\b{System.Text.RegularExpressions.Regex.Escape(term)}\b", term,
                System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);
        }
        return text;
    }

    private void SetSetting(bool value, bool current, Func<AppSettings, AppSettings> update, [CallerMemberName] string? propertyName = null)
    {
        if (value == current) return;
        UpdateSettings(update(_settings));
        OnPropertyChanged(propertyName);
    }

    private void UpdateSettings(AppSettings settings)
    {
        _settings = settings;
        if (_settingsLoaded) _ = _store.SaveSettingsAsync(_settings);
    }

    private static void ConfigureStartup(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(StartupRegistryPath, writable: true)
            ?? Registry.CurrentUser.CreateSubKey(StartupRegistryPath, writable: true);
        if (enabled)
        {
            var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Executável não encontrado.");
            key.SetValue("zspeak", $"\"{executable}\"");
        }
        else key.DeleteValue("zspeak", throwOnMissingValue: false);
    }

    private static string FormatDuration(double seconds) => seconds switch
    {
        < 60 => $"{seconds:F0}s",
        < 3600 => $"{TimeSpan.FromSeconds(seconds).TotalMinutes:F1} min",
        _ => $"{TimeSpan.FromSeconds(seconds).TotalHours:F1} h"
    };

    private void NotifyState()
    {
        OnPropertyChanged(nameof(Status)); OnPropertyChanged(nameof(StatusTitle)); OnPropertyChanged(nameof(StatusChip));
        OnPropertyChanged(nameof(StatusBrush)); OnPropertyChanged(nameof(CanSelectMicrophone));
    }

    private void NotifySettings()
    {
        OnPropertyChanged(nameof(SelectedMicrophone)); OnPropertyChanged(nameof(MicrophoneSummary));
        OnPropertyChanged(nameof(UseSystemMicrophone)); OnPropertyChanged(nameof(AutoPaste)); OnPropertyChanged(nameof(InsertionMode)); OnPropertyChanged(nameof(ShowOverlay));
        OnPropertyChanged(nameof(SoundFeedback)); OnPropertyChanged(nameof(ShowLatency)); OnPropertyChanged(nameof(EscapeCancelsRecording));
        OnPropertyChanged(nameof(LaunchAtStartup));
    }

    private void NotifyHistory()
    {
        OnPropertyChanged(nameof(HistoryCount)); OnPropertyChanged(nameof(TodayCount)); OnPropertyChanged(nameof(TotalAudioText));
        OnPropertyChanged(nameof(AverageRtfText)); OnPropertyChanged(nameof(AverageInferenceText)); OnPropertyChanged(nameof(HasHistoryVisibility));
        OnPropertyChanged(nameof(LatestTranscriptionText)); OnPropertyChanged(nameof(LatestTranscriptionMeta));
    }

    private void NotifyVocabulary() => OnPropertyChanged(nameof(VocabularyEmptyVisibility));
    private void OnCaptureLevelChanged(object? sender, float level) => _overlay.UpdateLevel(level);
    private void OnEscapePressed(object? sender, EventArgs args) => System.Windows.Application.Current.Dispatcher.InvokeAsync(CancelRecordingAsync);
    private void OnHotkeyPressed(object? sender, EventArgs args) => System.Windows.Application.Current.Dispatcher.InvokeAsync(ToggleRecordingAsync);
    public void CancelModelDownload() => _modelDownload?.Cancel();

    public void SetFatalError(string message)
    {
        Status = AppStatus.Error;
        StatusMessage = message;
        if (_settings.ShowOverlay) _overlay.ShowError("Abra o menu do zspeak para tentar novamente");
    }

    private void DisposeRuntime()
    {
        DisposeEscapeHotkey();
        _hotkey?.Dispose(); _hotkey = null;
        _capture?.Dispose(); _capture = null;
        _asr?.Dispose(); _asr = null;
        _modelDownload?.Dispose(); _modelDownload = null;
    }

    private async Task CancelRecordingAsync()
    {
        if (Status != AppStatus.Recording || !await _toggleGate.WaitAsync(0)) return;
        try
        {
            var capture = _capture;
            _capture = null;
            DisposeEscapeHotkey();
            if (capture is not null)
            {
                capture.LevelChanged -= OnCaptureLevelChanged;
                await capture.StopAsync();
                capture.Dispose();
            }
            Status = AppStatus.Ready;
            StatusMessage = "Gravação cancelada; clipboard e histórico não foram alterados.";
            _overlay.Hide();
        }
        catch (Exception exception) { SetFatalError(exception.Message); }
        finally { _toggleGate.Release(); }
    }

    private void DisposeEscapeHotkey()
    {
        if (_escapeHotkey is null) return;
        _escapeHotkey.Pressed -= OnEscapePressed;
        _escapeHotkey.Dispose();
        _escapeHotkey = null;
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
