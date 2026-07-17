using ZSpeak.Core.Models;
using ZSpeak.Core.Persistence;

namespace ZSpeak.Core.Tests;

public sealed class JsonFileStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "zspeak-tests-" + Guid.NewGuid());

    [Fact]
    public async Task Settings_EHistorico_RoundTripLocal()
    {
        var store = new JsonFileStore(_directory);
        var settings = new AppSettings { MicrophoneId = "mic-teste" };
        await store.SaveSettingsAsync(settings);
        var record = new TranscriptionRecord(Guid.NewGuid(), DateTimeOffset.UtcNow, "texto local", 2, 0.2);
        await store.AddHistoryAsync(record);

        Assert.Equal("mic-teste", (await store.LoadSettingsAsync()).MicrophoneId);
        Assert.Equal(record, Assert.Single(await store.LoadHistoryAsync()));
    }

    [Fact]
    public async Task SettingsCorrompidas_UsamPadraoEPreservamBackup()
    {
        Directory.CreateDirectory(_directory);
        await File.WriteAllTextAsync(Path.Combine(_directory, "settings.json"), "{inválido");

        var result = await new JsonFileStore(_directory).LoadSettingsAsync();

        Assert.Null(result.MicrophoneId);
        Assert.Single(Directory.GetFiles(_directory, "settings.json.corrupt-*"));
    }

    [Fact]
    public async Task PreferenciasWindows_RoundTripSemPerderPrivacidade()
    {
        var store = new JsonFileStore(_directory);
        var settings = new AppSettings
        {
            UseSystemMicrophone = false,
            AutoPaste = false,
            ShowOverlay = false,
            SoundFeedback = true,
            ShowLatency = true,
            EscapeCancelsRecording = false,
            LaunchAtStartup = true
        };

        await store.SaveSettingsAsync(settings);
        var loaded = await store.LoadSettingsAsync();

        Assert.Equal(2, loaded.SchemaVersion);
        Assert.False(loaded.UseSystemMicrophone);
        Assert.False(loaded.AutoPaste);
        Assert.False(loaded.ShowOverlay);
        Assert.True(loaded.SoundFeedback);
        Assert.True(loaded.ShowLatency);
        Assert.False(loaded.EscapeCancelsRecording);
        Assert.True(loaded.LaunchAtStartup);
    }

    [Fact]
    public async Task Historico_PodeExcluirItemESerLimpo()
    {
        var store = new JsonFileStore(_directory);
        var first = new TranscriptionRecord(Guid.NewGuid(), DateTimeOffset.UtcNow, "primeiro", 2, 0.2);
        var second = new TranscriptionRecord(Guid.NewGuid(), DateTimeOffset.UtcNow, "segundo", 4, 0.4);
        await store.SaveHistoryAsync([first, second]);

        await store.SaveHistoryAsync([second]);
        Assert.Equal(second, Assert.Single(await store.LoadHistoryAsync()));

        await store.SaveHistoryAsync([]);
        Assert.Empty(await store.LoadHistoryAsync());
    }

    [Fact]
    public async Task Vocabulario_RoundTripLocal()
    {
        var store = new JsonFileStore(_directory);
        await store.SaveVocabularyAsync(["Kubernetes", "sherpa-onnx", "WASAPI"]);

        Assert.Equal(
            ["Kubernetes", "sherpa-onnx", "WASAPI"],
            await store.LoadVocabularyAsync());
    }

    [Fact]
    public void Registro_CalculaRealTimeFactor()
    {
        var record = new TranscriptionRecord(Guid.NewGuid(), DateTimeOffset.UtcNow, "teste", 10, 0.75);
        Assert.Equal(0.075, record.RealTimeFactor, precision: 6);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
