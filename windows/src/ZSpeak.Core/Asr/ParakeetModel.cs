namespace ZSpeak.Core.Asr;

public sealed record ParakeetModel(
    string Directory,
    string Encoder,
    string Decoder,
    string Joiner,
    string Tokens);

public sealed record ModelDownloadProgress(long BytesReceived, long? TotalBytes)
{
    public double? Percentage => TotalBytes is > 0
        ? BytesReceived * 100d / TotalBytes.Value
        : null;
}
