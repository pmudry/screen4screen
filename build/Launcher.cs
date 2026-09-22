// A Windows application, not a console one, whose only job is to start the
// screen4screen window sitting next to it.
//
// It exists for three reasons a .cmd or a bare .ps1 cannot cover: Explorer
// shows the program icon on an .exe; /target:winexe means no console is ever
// created, so nothing flashes or lingers; and this process is up in a few tens
// of milliseconds, so it can put something on screen straight away while
// PowerShell and WPF take their second to start.
//
// ASCII only, and C# 5 compatible: it is built by the compiler that ships
// with the .NET Framework.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal static class Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string className, string windowName);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [STAThread]
    private static int Main()
    {
        string dir    = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "screen4screen.ps1");

        if (!File.Exists(script))
        {
            MessageBox.Show(
                "screen4screen.ps1 is missing next to this program.",
                "screen4screen", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        // Windows PowerShell deliberately: the tool must not require PS 7.
        // -ExecutionPolicy Bypass because the machine policy may be AllSigned.
        string host = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell\\v1.0\\powershell.exe");

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName         = host;
        psi.Arguments        = "-NoProfile -STA -ExecutionPolicy Bypass -File \""
                             + script + "\" -Gui";
        psi.WorkingDirectory = dir;
        psi.UseShellExecute  = false;
        psi.CreateNoWindow   = true;

        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "screen4screen",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        Application.EnableVisualStyles();
        Application.Run(new Splash(Path.Combine(dir, "assets\\screen4screen.ico")));
        return 0;
    }

    // Shown immediately and closed as soon as the real window is up. Without
    // it, clicking the icon appears to do nothing for about a second.
    private sealed class Splash : Form
    {
        private readonly Timer _timer;
        private int _elapsedMs;

        public Splash(string iconPath)
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition   = FormStartPosition.CenterScreen;
            ShowInTaskbar   = false;
            TopMost         = true;
            ClientSize      = new Size(260, 120);
            BackColor       = Color.FromArgb(27, 29, 32);

            PictureBox glyph = new PictureBox();
            glyph.SizeMode = PictureBoxSizeMode.Zoom;
            glyph.Size     = new Size(48, 48);
            glyph.Location = new Point((ClientSize.Width - 48) / 2, 22);
            glyph.BackColor = Color.Transparent;
            if (File.Exists(iconPath))
            {
                try
                {
                    Icon icon = new Icon(iconPath, 48, 48);
                    glyph.Image = icon.ToBitmap();
                    this.Icon = icon;
                }
                catch { }
            }
            Controls.Add(glyph);

            Label caption = new Label();
            caption.Text      = "screen4screen";
            caption.ForeColor = Color.FromArgb(236, 238, 240);
            caption.Font      = new Font("Segoe UI", 10F, FontStyle.Regular);
            caption.TextAlign = ContentAlignment.MiddleCenter;
            caption.Dock      = DockStyle.Bottom;
            caption.Height    = 40;
            Controls.Add(caption);

            _timer = new Timer();
            _timer.Interval = 60;
            _timer.Tick += OnTick;
            _timer.Start();
        }

        private void OnTick(object sender, EventArgs e)
        {
            _elapsedMs += _timer.Interval;

            IntPtr window = FindWindow(null, "screen4screen");
            bool up = window != IntPtr.Zero && IsWindowVisible(window);

            // The timeout is a safety net: if the window never appears, this
            // must not sit on screen forever.
            if (up || _elapsedMs > 15000)
            {
                _timer.Stop();
                Close();
            }
        }
    }
}
