using System.Net;
using System.Net.Http;
using System.IO;
using ZSpeak.Core.Asr;

namespace ZSpeak.IntegrationTests;

public sealed class ModelFirstRunIntegrationTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "zspeak-first-run-" + Guid.NewGuid());

    [Fact]
    [Trait("Category", "ASR")]
    public async Task PrimeiroUso_BaixaValidaExtraiEDepoisFuncionaOffline()
    {
        var localArchive = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "zspeak", "Models", ParakeetModelManager.ArchiveName);
        Assert.True(File.Exists(localArchive), "Execute o spike uma vez para preencher o archive de teste local.");
        var handler = new LocalArchiveHandler(localArchive);
        var manager = new ParakeetModelManager(_directory, new HttpClient(handler));
        var progressEvents = new List<ModelDownloadProgress>();

        var model = await manager.EnsureAsync(progress: new InlineProgress<ModelDownloadProgress>(progressEvents.Add));
        var offline = await manager.EnsureAsync(offlineOnly: true);

        Assert.Equal(1, handler.Requests);
        Assert.NotEmpty(progressEvents);
        Assert.Equal(model, offline);
        Assert.True(File.Exists(model.Encoder));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    private sealed class LocalArchiveHandler(string archive) : HttpMessageHandler
    {
        public int Requests { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            var stream = new FileStream(archive, FileMode.Open, FileAccess.Read, FileShare.Read);
            var response = new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StreamContent(stream)
            };
            response.Content.Headers.ContentLength = stream.Length;
            return Task.FromResult(response);
        }
    }

    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
