using System.Diagnostics;
using SherpaOnnx;
using ZSpeak.Core.Audio;
using ZSpeak.Core.Text;

namespace ZSpeak.Core.Asr;

public sealed record TranscriptionResult(
    string Text,
    TimeSpan AudioDuration,
    TimeSpan InferenceDuration,
    double RealTimeFactor,
    long WorkingSetBytes,
    long PeakWorkingSetBytes);

public sealed class ParakeetAsrService : IDisposable
{
    private readonly OfflineRecognizer _recognizer;

    public ParakeetAsrService(
        ParakeetModel model,
        int? threadCount = null,
        string decodingMethod = "modified_beam_search",
        int maxActivePaths = 4)
    {
        var config = new OfflineRecognizerConfig();
        config.FeatConfig.SampleRate = 16_000;
        config.FeatConfig.FeatureDim = 80;
        config.ModelConfig.Tokens = model.Tokens;
        config.ModelConfig.Transducer.Encoder = model.Encoder;
        config.ModelConfig.Transducer.Decoder = model.Decoder;
        config.ModelConfig.Transducer.Joiner = model.Joiner;
        config.ModelConfig.ModelType = "nemo_transducer";
        config.ModelConfig.NumThreads = threadCount ?? Math.Clamp(Environment.ProcessorCount / 2, 2, 8);
        config.ModelConfig.Provider = "cpu";
        config.ModelConfig.Debug = 0;
        config.DecodingMethod = decodingMethod;
        config.MaxActivePaths = maxActivePaths;
        _recognizer = new OfflineRecognizer(config);
    }

    public TranscriptionResult TranscribeWave(string path)
    {
        var wave = PcmWaveFile.Read(path);
        return Transcribe(wave.Samples, wave.SampleRate);
    }

    public TranscriptionResult Transcribe(float[] samples, int sampleRate = 16_000)
    {
        if (samples.Length == 0)
        {
            return new TranscriptionResult(string.Empty, TimeSpan.Zero, TimeSpan.Zero, 0, 0, 0);
        }

        using var stream = _recognizer.CreateStream();
        stream.AcceptWaveform(sampleRate, samples);
        var process = Process.GetCurrentProcess();
        process.Refresh();
        var timer = Stopwatch.StartNew();
        _recognizer.Decode(stream);
        timer.Stop();
        process.Refresh();
        var audioDuration = TimeSpan.FromSeconds(samples.Length / (double)sampleRate);
        return new TranscriptionResult(
            PTBRTextNormalizer.Normalize(stream.Result.Text),
            audioDuration,
            timer.Elapsed,
            timer.Elapsed.TotalSeconds / audioDuration.TotalSeconds,
            process.WorkingSet64,
            process.PeakWorkingSet64);
    }

    public void Dispose() => _recognizer.Dispose();
}
