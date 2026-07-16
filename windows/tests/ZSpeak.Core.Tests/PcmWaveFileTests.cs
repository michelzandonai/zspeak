using ZSpeak.Core.Audio;

namespace ZSpeak.Core.Tests;

public sealed class PcmWaveFileTests
{
    [Fact]
    public void Read_CarregaFixtureMono16Khz()
    {
        var audio = PcmWaveFile.Read(Fixture("pt-short.wav"));

        Assert.Equal(16_000, audio.SampleRate);
        Assert.InRange(audio.Samples.Length, 44_000, 45_000);
        Assert.All(audio.Samples, sample => Assert.InRange(sample, -1f, 1f));
    }

    private static string Fixture(string name) => Path.GetFullPath(Path.Combine(
        AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "Tests", "Fixtures", name));
}
