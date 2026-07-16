using System.Security.Cryptography;
using SharpCompress.Common;
using SharpCompress.Readers;

namespace ZSpeak.Core.Asr;

public sealed class ParakeetModelManager
{
    private static readonly HttpClient SharedHttpClient = new() { Timeout = Timeout.InfiniteTimeSpan };
    public const string ModelName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8";
    public const string ArchiveName = ModelName + ".tar.bz2";
    public const string DownloadUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/" + ArchiveName;
    public const string ArchiveSha256 = "5793D0FD397C5778D2CF2126994D58E9D56B1BE7C04D13C7A15BB1B4EAFB16BF";
    public const long ArchiveSize = 487_170_055;

    private readonly string _cacheRoot;
    private readonly HttpClient _httpClient;

    public ParakeetModelManager(string? cacheRoot = null, HttpClient? httpClient = null)
    {
        _cacheRoot = cacheRoot ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "zspeak", "Models");
        _httpClient = httpClient ?? SharedHttpClient;
    }

    public string CacheRoot => _cacheRoot;

    public bool TryGetValidModel(out ParakeetModel? model)
    {
        var directory = Path.Combine(_cacheRoot, ModelName);
        model = new ParakeetModel(
            directory,
            Path.Combine(directory, "encoder.int8.onnx"),
            Path.Combine(directory, "decoder.int8.onnx"),
            Path.Combine(directory, "joiner.int8.onnx"),
            Path.Combine(directory, "tokens.txt"));

        if (!File.Exists(model.Encoder) || new FileInfo(model.Encoder).Length != 652_184_281 ||
            !File.Exists(model.Decoder) || new FileInfo(model.Decoder).Length != 11_845_275 ||
            !File.Exists(model.Joiner) || new FileInfo(model.Joiner).Length != 6_355_277 ||
            !File.Exists(model.Tokens) || new FileInfo(model.Tokens).Length != 93_939)
        {
            model = null;
            return false;
        }

        return true;
    }

    public async Task<ParakeetModel> EnsureAsync(
        bool offlineOnly = false,
        IProgress<ModelDownloadProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (TryGetValidModel(out var cached))
        {
            return cached!;
        }

        if (offlineOnly)
        {
            throw new InvalidOperationException("O modelo Parakeet V3 não está completo no cache local.");
        }

        Directory.CreateDirectory(_cacheRoot);
        var archivePath = Path.Combine(_cacheRoot, ArchiveName);
        if (!await HasExpectedHashAsync(archivePath, cancellationToken).ConfigureAwait(false))
        {
            await DownloadAsync(archivePath, progress, cancellationToken).ConfigureAwait(false);
            if (!await HasExpectedHashAsync(archivePath, cancellationToken).ConfigureAwait(false))
            {
                File.Delete(archivePath);
                throw new InvalidDataException("O hash SHA-256 do modelo baixado não confere.");
            }
        }

        await ExtractAsync(archivePath, cancellationToken).ConfigureAwait(false);
        if (!TryGetValidModel(out var extracted))
        {
            throw new InvalidDataException("O arquivo do modelo foi extraído, mas está incompleto.");
        }

        return extracted!;
    }

    private async Task DownloadAsync(
        string destination,
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        var temporary = destination + ".download";
        try
        {
            using var response = await _httpClient.GetAsync(
                DownloadUrl,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();

            var total = response.Content.Headers.ContentLength;
            await using var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            await using (var target = new FileStream(
                temporary, FileMode.Create, FileAccess.Write, FileShare.None, 1024 * 1024, useAsync: true))
            {
                var buffer = new byte[1024 * 1024];
                long received = 0;
                while (true)
                {
                    var read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                    if (read == 0)
                    {
                        break;
                    }

                    await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    received += read;
                    progress?.Report(new ModelDownloadProgress(received, total));
                }

                await target.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            File.Move(temporary, destination, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    private async Task ExtractAsync(string archivePath, CancellationToken cancellationToken)
    {
        var finalDirectory = Path.Combine(_cacheRoot, ModelName);
        var stagingRoot = Path.Combine(_cacheRoot, ".extract-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stagingRoot);
        try
        {
            await Task.Run(() =>
            {
                using var reader = ReaderFactory.OpenReader(archivePath);
                while (reader.MoveToNextEntry())
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (!reader.Entry.IsDirectory)
                    {
                        reader.WriteEntryToDirectory(stagingRoot, new ExtractionOptions
                        {
                            ExtractFullPath = true,
                            Overwrite = true
                        });
                    }
                }
            }, cancellationToken).ConfigureAwait(false);

            var extractedDirectory = Path.Combine(stagingRoot, ModelName);
            if (!Directory.Exists(extractedDirectory))
            {
                throw new InvalidDataException("Estrutura inesperada no arquivo do modelo.");
            }

            if (Directory.Exists(finalDirectory))
            {
                Directory.Delete(finalDirectory, recursive: true);
            }

            Directory.Move(extractedDirectory, finalDirectory);
        }
        finally
        {
            if (Directory.Exists(stagingRoot))
            {
                Directory.Delete(stagingRoot, recursive: true);
            }
        }
    }

    private static async Task<bool> HasExpectedHashAsync(string path, CancellationToken cancellationToken)
    {
        if (!File.Exists(path) || new FileInfo(path).Length != ArchiveSize)
        {
            return false;
        }

        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        return Convert.ToHexString(hash).Equals(ArchiveSha256, StringComparison.OrdinalIgnoreCase);
    }
}
