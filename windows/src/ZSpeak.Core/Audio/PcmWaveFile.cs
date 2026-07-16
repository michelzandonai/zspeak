using System.Text;

namespace ZSpeak.Core.Audio;

public sealed record PcmAudio(float[] Samples, int SampleRate);

public static class PcmWaveFile
{
    public static PcmAudio Read(string path)
    {
        using var stream = File.OpenRead(path);
        using var reader = new BinaryReader(stream, Encoding.ASCII, leaveOpen: false);
        if (ReadFourCc(reader) != "RIFF" || reader.ReadUInt32() < 4 || ReadFourCc(reader) != "WAVE")
        {
            throw new InvalidDataException("Arquivo WAV inválido.");
        }

        ushort format = 0;
        ushort channels = 0;
        ushort bitsPerSample = 0;
        int sampleRate = 0;
        byte[]? data = null;
        while (stream.Position + 8 <= stream.Length)
        {
            var chunk = ReadFourCc(reader);
            var size = reader.ReadUInt32();
            var next = stream.Position + size + (size & 1);
            if (next > stream.Length + 1)
            {
                throw new InvalidDataException("Chunk WAV truncado.");
            }

            if (chunk == "fmt ")
            {
                format = reader.ReadUInt16();
                channels = reader.ReadUInt16();
                sampleRate = reader.ReadInt32();
                _ = reader.ReadInt32();
                _ = reader.ReadUInt16();
                bitsPerSample = reader.ReadUInt16();
            }
            else if (chunk == "data")
            {
                data = reader.ReadBytes(checked((int)size));
            }

            stream.Position = Math.Min(next, stream.Length);
        }

        if (data is null || channels == 0 || sampleRate <= 0)
        {
            throw new InvalidDataException("WAV sem formato ou áudio.");
        }

        var bytesPerSample = bitsPerSample / 8;
        if (!((format == 1 && bitsPerSample == 16) || (format == 3 && bitsPerSample == 32)))
        {
            throw new NotSupportedException($"Formato WAV não suportado: {format}, {bitsPerSample} bits.");
        }

        var frames = data.Length / bytesPerSample / channels;
        var samples = new float[frames];
        for (var frame = 0; frame < frames; frame++)
        {
            double sum = 0;
            for (var channel = 0; channel < channels; channel++)
            {
                var offset = (frame * channels + channel) * bytesPerSample;
                sum += format == 1
                    ? BitConverter.ToInt16(data, offset) / 32768f
                    : BitConverter.ToSingle(data, offset);
            }

            samples[frame] = (float)(sum / channels);
        }

        return new PcmAudio(samples, sampleRate);
    }

    private static string ReadFourCc(BinaryReader reader) => new(reader.ReadChars(4));
}
