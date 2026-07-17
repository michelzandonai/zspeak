namespace ZSpeak.Core.Models;

public sealed record AppSettings
{
    public int SchemaVersion { get; init; } = 2;
    public string? MicrophoneId { get; init; }
    public uint HotkeyModifiers { get; init; } = 0x0002 | 0x0001; // Ctrl + Alt
    public uint HotkeyVirtualKey { get; init; } = 0x20; // Espaço
    public bool UseSystemMicrophone { get; init; } = true;
    public bool AutoPaste { get; init; } = true;
    public bool ShowOverlay { get; init; } = true;
    public bool SoundFeedback { get; init; }
    public bool ShowLatency { get; init; }
    public bool EscapeCancelsRecording { get; init; } = true;
    public bool LaunchAtStartup { get; init; }
}

public sealed record TranscriptionRecord(
    Guid Id,
    DateTimeOffset CreatedAt,
    string Text,
    double AudioSeconds,
    double InferenceSeconds)
{
    public double RealTimeFactor => AudioSeconds <= 0 ? 0 : InferenceSeconds / AudioSeconds;
}

public enum AppStatus
{
    Loading,
    Ready,
    Recording,
    Transcribing,
    Error
}
