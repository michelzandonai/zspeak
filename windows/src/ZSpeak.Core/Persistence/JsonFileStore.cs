using System.Text.Json;
using ZSpeak.Core.Models;

namespace ZSpeak.Core.Persistence;

public sealed class JsonFileStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly string _root;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public JsonFileStore(string? root = null)
    {
        _root = root ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "zspeak");
    }

    public async Task<AppSettings> LoadSettingsAsync(CancellationToken cancellationToken = default) =>
        await LoadAsync("settings.json", new AppSettings(), cancellationToken).ConfigureAwait(false);

    public Task SaveSettingsAsync(AppSettings settings, CancellationToken cancellationToken = default) =>
        SaveAsync("settings.json", settings, cancellationToken);

    public async Task<IReadOnlyList<TranscriptionRecord>> LoadHistoryAsync(
        CancellationToken cancellationToken = default) =>
        await LoadAsync("history.json", new List<TranscriptionRecord>(), cancellationToken).ConfigureAwait(false);

    public async Task AddHistoryAsync(TranscriptionRecord record, CancellationToken cancellationToken = default)
    {
        var history = (await LoadHistoryAsync(cancellationToken).ConfigureAwait(false)).ToList();
        history.Insert(0, record);
        if (history.Count > 200)
        {
            history.RemoveRange(200, history.Count - 200);
        }

        await SaveAsync("history.json", history, cancellationToken).ConfigureAwait(false);
    }

    private async Task<T> LoadAsync<T>(string fileName, T fallback, CancellationToken cancellationToken)
    {
        var path = Path.Combine(_root, fileName);
        if (!File.Exists(path))
        {
            return fallback;
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using var stream = File.OpenRead(path);
            return await JsonSerializer.DeserializeAsync<T>(stream, JsonOptions, cancellationToken).ConfigureAwait(false)
                ?? fallback;
        }
        catch (JsonException)
        {
            var backup = path + ".corrupt-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss");
            File.Move(path, backup, overwrite: true);
            return fallback;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task SaveAsync<T>(string fileName, T value, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(_root);
        var path = Path.Combine(_root, fileName);
        var temporary = path + ".tmp";
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using (var stream = new FileStream(
                temporary, FileMode.Create, FileAccess.Write, FileShare.None, 64 * 1024, useAsync: true))
            {
                await JsonSerializer.SerializeAsync(stream, value, JsonOptions, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }

            _gate.Release();
        }
    }
}
