using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace ZSpeak.App;

public partial class StatusOverlay : Window
{
    private const int GwlExStyle = -20;
    private const int WsExNoActivate = 0x08000000;
    private const int WsExToolWindow = 0x00000080;
    private readonly DispatcherTimer _durationTimer;
    private readonly Queue<float> _levels = new();
    private readonly List<Border> _bars = new();
    private DateTimeOffset _startedAt;

    public StatusOverlay()
    {
        InitializeComponent();
        for (var index = 0; index < 52; index++)
        {
            var bar = new Border
            {
                Width = 4,
                Height = 4,
                Margin = new Thickness(2, 0, 2, 0),
                CornerRadius = new CornerRadius(2),
                Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(121, 141, 160)),
                VerticalAlignment = VerticalAlignment.Center
            };
            _bars.Add(bar);
            WaveformBars.Children.Add(bar);
            _levels.Enqueue(0);
        }

        _durationTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(250), DispatcherPriority.Background, (_, _) =>
        {
            DurationText.Text = (DateTimeOffset.Now - _startedAt).ToString(@"mm\:ss");
        }, Dispatcher);

        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            SetWindowLong(handle, GwlExStyle, GetWindowLong(handle, GwlExStyle) | WsExNoActivate | WsExToolWindow);
        };
    }

    public void ShowRecording(string focusedApp, string microphone)
    {
        Dispatcher.Invoke(() =>
        {
            Height = 270;
            FocusedAppText.Text = CompactTitle(focusedApp);
            MicrophoneText.Text = microphone;
            StatusLabel.Text = "AO VIVO";
            StatusLabel.Foreground = Brush("#FF777B");
            StatusDot.Fill = Brush("#FF4D52");
            StatusPill.BorderBrush = Brush("#A54B53");
            StatusPill.Background = Brush("#302024");
            DurationText.Visibility = Visibility.Visible;
            WaveformRegion.Visibility = Visibility.Visible;
            MicrophoneRow.Visibility = Visibility.Visible;
            ProcessingCard.Visibility = Visibility.Collapsed;
            _startedAt = DateTimeOffset.Now;
            _durationTimer.Start();
            PositionAndShow();
        });
    }

    public void ShowTranscribing()
    {
        Dispatcher.Invoke(() =>
        {
            _durationTimer.Stop();
            Height = 220;
            StatusLabel.Text = "TRANSCREVENDO";
            StatusLabel.Foreground = Brush("#75D5F5");
            StatusDot.Fill = Brush("#59C7ED");
            StatusPill.BorderBrush = Brush("#39788C");
            StatusPill.Background = Brush("#15303A");
            DurationText.Visibility = Visibility.Collapsed;
            WaveformRegion.Visibility = Visibility.Collapsed;
            MicrophoneRow.Visibility = Visibility.Collapsed;
            ProcessingHeading.Text = "TRANSCRIÇÃO";
            ProcessingHeading.Foreground = Brush("#59C7ED");
            ProcessingText.Text = "Processando transcrição…";
            ProcessingCard.Visibility = Visibility.Visible;
            PositionAndShow();
        });
    }

    public void ShowError(string message)
    {
        Dispatcher.Invoke(() =>
        {
            _durationTimer.Stop();
            Height = 220;
            FocusedAppText.Text = "zspeak";
            StatusLabel.Text = "ERRO";
            StatusLabel.Foreground = Brush("#FF777B");
            StatusDot.Fill = Brush("#FF4D52");
            DurationText.Visibility = Visibility.Collapsed;
            WaveformRegion.Visibility = Visibility.Collapsed;
            MicrophoneRow.Visibility = Visibility.Collapsed;
            ProcessingHeading.Text = "ATENÇÃO";
            ProcessingHeading.Foreground = Brush("#FF777B");
            ProcessingText.Text = message;
            ProcessingCard.Visibility = Visibility.Visible;
            PositionAndShow();
        });
    }

    public void UpdateLevel(float level)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (_levels.Count >= _bars.Count) _levels.Dequeue();
            _levels.Enqueue(Math.Clamp(level, 0, 1));
            var values = _levels.ToArray();
            for (var index = 0; index < _bars.Count; index++)
            {
                _bars[index].Height = Math.Max(4, values[index] * 62);
                _bars[index].Opacity = 0.45 + values[index] * 0.55;
            }
        });
    }

    private void PositionAndShow()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Bottom - Height - 54;
        if (!IsVisible) Show();
    }

    private static string CompactTitle(string title) => title.Length > 55 ? title[..52] + "…" : title;
    private static System.Windows.Media.Brush Brush(string color) =>
        new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(color));

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong(nint hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static extern int SetWindowLong(nint hwnd, int index, int value);
}
