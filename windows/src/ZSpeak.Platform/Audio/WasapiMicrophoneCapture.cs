using System.IO;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace ZSpeak.Platform.Audio;

public sealed record MicrophoneDevice(string Id, string Name, bool IsDefault);

public sealed class WasapiMicrophoneCapture : IDisposable
{
    private readonly object _sync = new();
    private readonly MemoryStream _rawAudio = new();
    private WasapiCapture? _capture;
    private TaskCompletionSource<Exception?>? _stopped;
    private WaveFormat? _sourceFormat;
    public event EventHandler<float>? LevelChanged;

    public static IReadOnlyList<MicrophoneDevice> EnumerateDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        string? defaultId = null;
        try
        {
            defaultId = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).ID;
        }
        catch
        {
            // Um computador sem microfone continua podendo abrir o app.
        }

        return enumerator
            .EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .Select(device => new MicrophoneDevice(device.ID, device.FriendlyName, device.ID == defaultId))
            .OrderByDescending(device => device.IsDefault)
            .ThenBy(device => device.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    public void Start(string? deviceId = null)
    {
        if (_capture is not null)
        {
            throw new InvalidOperationException("A captura já está ativa.");
        }

        using var enumerator = new MMDeviceEnumerator();
        var device = deviceId is null
            ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications)
            : enumerator.GetDevice(deviceId);
        _capture = new WasapiCapture(device);
        _sourceFormat = _capture.WaveFormat;
        _rawAudio.SetLength(0);
        _stopped = new TaskCompletionSource<Exception?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;
        _capture.StartRecording();
    }

    public async Task<float[]> StopAsync(CancellationToken cancellationToken = default)
    {
        var capture = _capture ?? throw new InvalidOperationException("A captura não está ativa.");
        capture.StopRecording();
        var error = await _stopped!.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        var samples = ConvertToMono16Khz();
        CleanupCapture();
        if (error is not null && samples.Length == 0)
        {
            throw new InvalidOperationException("O microfone foi desconectado durante a gravação.", error);
        }

        return samples;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs args)
    {
        lock (_sync)
        {
            _rawAudio.Write(args.Buffer, 0, args.BytesRecorded);
        }

        if (_sourceFormat is not null && args.BytesRecorded > 0)
        {
            LevelChanged?.Invoke(this, EstimateLevel(args.Buffer, args.BytesRecorded, _sourceFormat));
        }
    }

    private static float EstimateLevel(byte[] buffer, int bytesRecorded, WaveFormat format)
    {
        double sum = 0;
        var count = 0;
        if (format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32)
        {
            for (var index = 0; index + 3 < bytesRecorded; index += 4)
            {
                var sample = BitConverter.ToSingle(buffer, index);
                sum += sample * sample;
                count++;
            }
        }
        else if (format.BitsPerSample == 16)
        {
            for (var index = 0; index + 1 < bytesRecorded; index += 2)
            {
                var sample = BitConverter.ToInt16(buffer, index) / 32768f;
                sum += sample * sample;
                count++;
            }
        }

        return count == 0 ? 0 : Math.Clamp((float)Math.Sqrt(sum / count) * 4f, 0f, 1f);
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs args) => _stopped?.TrySetResult(args.Exception);

    private float[] ConvertToMono16Khz()
    {
        byte[] bytes;
        lock (_sync)
        {
            bytes = _rawAudio.ToArray();
        }

        if (bytes.Length == 0 || _sourceFormat is null)
        {
            return Array.Empty<float>();
        }

        using var raw = new RawSourceWaveStream(new MemoryStream(bytes, writable: false), _sourceFormat);
        ISampleProvider provider = raw.ToSampleProvider();
        if (provider.WaveFormat.Channels > 1)
        {
            provider = new AverageChannelsSampleProvider(provider);
        }

        if (provider.WaveFormat.SampleRate != 16_000)
        {
            provider = new WdlResamplingSampleProvider(provider, 16_000);
        }

        var output = new List<float>(Math.Max(16_000, bytes.Length / Math.Max(1, _sourceFormat.BlockAlign)));
        var buffer = new float[16_000];
        int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
        {
            output.AddRange(buffer.AsSpan(0, read).ToArray());
        }

        return output.ToArray();
    }

    private void CleanupCapture()
    {
        if (_capture is null)
        {
            return;
        }

        _capture.DataAvailable -= OnDataAvailable;
        _capture.RecordingStopped -= OnRecordingStopped;
        _capture.Dispose();
        _capture = null;
    }

    public void Dispose()
    {
        try
        {
            _capture?.StopRecording();
        }
        catch
        {
            // Dispose nunca derruba o processo durante remoção de dispositivo.
        }

        CleanupCapture();
        _rawAudio.Dispose();
    }

    private sealed class AverageChannelsSampleProvider(ISampleProvider source) : ISampleProvider
    {
        private readonly float[] _sourceBuffer = new float[16_000 * source.WaveFormat.Channels];
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);

        public int Read(float[] buffer, int offset, int count)
        {
            var channels = source.WaveFormat.Channels;
            var frames = source.Read(_sourceBuffer, 0, Math.Min(_sourceBuffer.Length, count * channels)) / channels;
            for (var frame = 0; frame < frames; frame++)
            {
                double sum = 0;
                for (var channel = 0; channel < channels; channel++)
                {
                    sum += _sourceBuffer[frame * channels + channel];
                }

                buffer[offset + frame] = (float)(sum / channels);
            }

            return frames;
        }
    }
}
