namespace ZSpeak.Platform.Win32;

public sealed class SingleInstance : IDisposable
{
    private readonly Mutex _mutex;

    public SingleInstance(string name = "Local\\zspeak-windows-single-instance")
    {
        _mutex = new Mutex(initiallyOwned: true, name, out var createdNew);
        IsPrimary = createdNew;
    }

    public bool IsPrimary { get; }

    public void Dispose()
    {
        if (IsPrimary)
        {
            _mutex.ReleaseMutex();
        }

        _mutex.Dispose();
    }
}
