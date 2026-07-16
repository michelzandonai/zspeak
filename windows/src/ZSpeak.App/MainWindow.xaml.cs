using System.Windows;

namespace ZSpeak.App;

public partial class MainWindow : System.Windows.Window
{
    public MainWindow(AppController controller)
    {
        InitializeComponent();
        DataContext = controller;
    }
}
