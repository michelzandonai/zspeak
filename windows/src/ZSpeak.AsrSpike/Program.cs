using System.Diagnostics;
using System.Text.Json;
using ZSpeak.Core.Asr;

var offlineOnly = args.Contains("--offline", StringComparer.OrdinalIgnoreCase);
var useBeamSearch = args.Contains("--beam", StringComparer.OrdinalIgnoreCase);
var explicitFiles = args.Where(arg => !arg.StartsWith("--", StringComparison.Ordinal)).ToArray();
var files = explicitFiles.Length > 0
    ? explicitFiles
    : new[]
    {
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "Tests", "Fixtures", "pt-short.wav")),
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "Tests", "Fixtures", "pt-long.wav"))
    };

var manager = new ParakeetModelManager();
var progress = new Progress<ModelDownloadProgress>(value =>
{
    if (value.Percentage is { } percentage)
    {
        Console.Error.Write($"\rBaixando Parakeet V3: {percentage:F1}%");
    }
});

var modelTimer = Stopwatch.StartNew();
var model = await manager.EnsureAsync(offlineOnly, progress);
modelTimer.Stop();
var loadTimer = Stopwatch.StartNew();
using var asr = new ParakeetAsrService(
    model,
    decodingMethod: useBeamSearch ? "modified_beam_search" : "greedy_search");
loadTimer.Stop();

var results = new List<object>();
foreach (var file in files)
{
    var result = asr.TranscribeWave(file);
    results.Add(new
    {
        file,
        result.Text,
        audioSeconds = Math.Round(result.AudioDuration.TotalSeconds, 3),
        inferenceSeconds = Math.Round(result.InferenceDuration.TotalSeconds, 3),
        realTimeFactor = Math.Round(result.RealTimeFactor, 4),
        workingSetMiB = Math.Round(result.WorkingSetBytes / 1024d / 1024d, 1),
        peakWorkingSetMiB = Math.Round(result.PeakWorkingSetBytes / 1024d / 1024d, 1)
    });
}

Console.WriteLine(JsonSerializer.Serialize(new
{
    offlineOnly,
    decodingMethod = useBeamSearch ? "modified_beam_search" : "greedy_search",
    cacheLookupSeconds = Math.Round(modelTimer.Elapsed.TotalSeconds, 3),
    modelLoadSeconds = Math.Round(loadTimer.Elapsed.TotalSeconds, 3),
    results
}, new JsonSerializerOptions { WriteIndented = true }));
