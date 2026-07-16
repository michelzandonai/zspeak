namespace ZSpeak.Core.Models;

public sealed record AppSettings
{
    public int SchemaVersion { get; init; } = 1;
    public string? MicrophoneId { get; init; }
    public uint HotkeyModifiers { get; init; } = 0x0002 | 0x0001; // Ctrl + Alt
    public uint HotkeyVirtualKey { get; init; } = 0x20; // Espaço
}

public sealed record TranscriptionRecord(
    Guid Id,
    DateTimeOffset CreatedAt,
    string Text,
    double AudioSeconds,
    double InferenceSeconds);

public enum AppStatus
{
    Loading,
    Ready,
    Recording,
    Transcribing,
    Error
}
