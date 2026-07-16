using ZSpeak.Core.Asr;

namespace ZSpeak.Core.Tests;

public sealed class ParakeetModelManagerTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "zspeak-model-test-" + Guid.NewGuid());

    [Fact]
    public async Task Offline_SemCache_FalhaSemTentarRede()
    {
        var handler = new RejectNetworkHandler();
        var manager = new ParakeetModelManager(_directory, new HttpClient(handler));

        await Assert.ThrowsAsync<InvalidOperationException>(() => manager.EnsureAsync(offlineOnly: true));
        Assert.Equal(0, handler.Requests);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    private sealed class RejectNetworkHandler : HttpMessageHandler
    {
        public int Requests { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            throw new InvalidOperationException("Rede não permitida neste teste.");
        }
    }
}
