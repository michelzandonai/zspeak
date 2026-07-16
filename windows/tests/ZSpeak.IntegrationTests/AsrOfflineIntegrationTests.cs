using System.Diagnostics;
using System.IO;
using ZSpeak.Core.Asr;

namespace ZSpeak.IntegrationTests;

public sealed class AsrOfflineIntegrationTests
{
    [Fact]
    [Trait("Category", "ASR")]
    public async Task CacheOffline_TranscrevePtBrETermosTecnicos()
    {
        var manager = new ParakeetModelManager();
        var model = await manager.EnsureAsync(offlineOnly: true);
        var load = Stopwatch.StartNew();
        using var asr = new ParakeetAsrService(model);
        load.Stop();

        var shortResult = asr.TranscribeWave(Fixture("pt-short.wav"));
        var longResult = asr.TranscribeWave(Fixture("pt-long.wav"));

        Assert.Contains("transcrição local", shortResult.Text, StringComparison.OrdinalIgnoreCase);
        foreach (var term in new[] { "pipeline", "deploy", "Kubernetes", "PostgreSQL", "cache", "Redis", "pull request" })
        {
            Assert.Contains(term, longResult.Text, StringComparison.OrdinalIgnoreCase);
        }
        Assert.True(load.Elapsed < TimeSpan.FromSeconds(15), $"Carga: {load.Elapsed}");
        Assert.True(shortResult.RealTimeFactor < 1, $"RTF curto: {shortResult.RealTimeFactor}");
        Assert.True(longResult.RealTimeFactor < 1, $"RTF longo: {longResult.RealTimeFactor}");
    }

    private static string Fixture(string name) => Path.GetFullPath(Path.Combine(
        AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "Tests", "Fixtures", name));
}
