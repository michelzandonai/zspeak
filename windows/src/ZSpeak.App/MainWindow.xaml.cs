using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using ZSpeak.Core.Models;

namespace ZSpeak.App;

public partial class MainWindow : Window
{
    private readonly AppController _controller;
    private readonly Dictionary<string, FrameworkElement> _pages;

    public MainWindow(AppController controller)
    {
        _controller = controller;
        InitializeComponent();
        DataContext = controller;
        _pages = new Dictionary<string, FrameworkElement>(StringComparer.Ordinal)
        {
            ["Overview"] = OverviewPage,
            ["History"] = HistoryPage,
            ["Benchmark"] = BenchmarkPage,
            ["Vocabulary"] = VocabularyPage,
            ["Correction"] = CorrectionPage,
            ["Keyboard"] = KeyboardPage,
            ["Microphone"] = MicrophonePage,
            ["General"] = GeneralPage,
            ["Permissions"] = PermissionsPage,
            ["About"] = AboutPage
        };
    }

    private void Navigate_Checked(object sender, RoutedEventArgs e)
    {
        if (_pages is null || sender is not System.Windows.Controls.RadioButton { Tag: string page } || !_pages.ContainsKey(page))
        {
            return;
        }

        foreach (var pair in _pages)
        {
            pair.Value.Visibility = pair.Key == page ? Visibility.Visible : Visibility.Collapsed;
        }

        WindowPageTitle.Text = page switch
        {
            "Overview" => "Visão Geral",
            "History" => "Histórico",
            "Benchmark" => "Benchmark",
            "Vocabulary" => "Vocabulário",
            "Correction" => "Correção LLM",
            "Keyboard" => "Atalhos de Teclado",
            "Microphone" => "Microfone",
            "General" => "Geral",
            "Permissions" => "Permissões",
            _ => "Sobre"
        };
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        }
        else
        {
            DragMove();
        }
    }

    private void Minimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    private void CopyHistory_Click(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Button { CommandParameter: TranscriptionRecord record })
        {
            System.Windows.Clipboard.SetText(record.Text);
        }
    }

    private async void DeleteHistory_Click(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Button { CommandParameter: TranscriptionRecord record })
        {
            await _controller.DeleteHistoryAsync(record);
        }
    }

    private async void ClearHistory_Click(object sender, RoutedEventArgs e)
    {
        if (_controller.History.Count == 0)
        {
            return;
        }

        var answer = System.Windows.MessageBox.Show(
            "Apagar todo o histórico local? Esta ação não pode ser desfeita.",
            "zspeak", System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Warning);
        if (answer == System.Windows.MessageBoxResult.Yes)
        {
            await _controller.ClearHistoryAsync();
        }
    }

    private async void AddVocabulary_Click(object sender, RoutedEventArgs e)
    {
        var value = VocabularyInput.Text.Trim();
        if (value.Length == 0)
        {
            VocabularyInput.Focus();
            return;
        }

        await _controller.AddVocabularyAsync(value);
        VocabularyInput.Clear();
    }

    private async void RemoveVocabulary_Click(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Button { CommandParameter: string term })
        {
            await _controller.RemoveVocabularyAsync(term);
        }
    }

    private static void OpenUri(string uri) =>
        Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });

    private void OpenMicrophonePrivacy_Click(object sender, RoutedEventArgs e) => OpenUri("ms-settings:privacy-microphone");
    private void OpenGitHub_Click(object sender, RoutedEventArgs e) => OpenUri("https://github.com/michelzandonai/zspeak");
}
