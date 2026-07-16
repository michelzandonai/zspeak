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

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
