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
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    private enum Outcome { Shown, Exited, TimedOut }

    // Owned by the process we started, on screen, and with a title. Matching
    // on the title alone used to be enough to fool: an Explorer window open on
    // a folder called screen4screen -- exactly what someone who has just
    // cloned the repository is looking at -- carries that title, and the
    // splash closed on its first tick. The notifier's own hidden window
    // belongs to the same process but is never shown, so it cannot match.
    private static bool HasVisibleWindow(int processId)
    {
        bool found = false;

        EnumWindowsProc callback = delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint owner;
            GetWindowThreadProcessId(hWnd, out owner);

            if (owner == (uint) processId && IsWindowVisible(hWnd) && GetWindowTextLength(hWnd) > 0)
            {
                found = true;
                return false;   // stop enumerating
            }
            return true;
        };

        EnumWindows(callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return found;
    }

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
        // Note that a Group Policy execution policy outranks this one, which
        // is one of the ways the window can die quietly on a managed machine;
        // the check below is what turns that into a message.
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

        // The streams are deliberately not redirected. The child outlives this
        // process, and a pipe whose reader has gone breaks the next write; the
        // window reports its own troubles to the log instead.

        Process child;
        try
        {
            child = Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "screen4screen",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        Application.EnableVisualStyles();
        Splash splash = new Splash(Path.Combine(dir, "assets\\screen4screen.ico"), child);
        Application.Run(splash);

        if (splash.Result == Outcome.Shown) { return 0; }

        // Process.Start only fails when powershell.exe itself cannot be
        // created; everything that goes wrong afterwards used to end with the
        // splash quietly fading and an exit code of 0.
        string detail = splash.Result == Outcome.Exited
            ? "PowerShell stopped (exit code " + child.ExitCode + ") before the window appeared."
            : "The window did not appear within 15 seconds.";

        MessageBox.Show(
            detail + "\n\nThe details are in:\n" +
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                         "screen4screen\\log.txt"),
            "screen4screen", MessageBoxButtons.OK, MessageBoxIcon.Error);

        return 1;
    }

    // Shown immediately and closed as soon as the real window is up. Without
    // it, clicking the icon appears to do nothing for about a second.
    private sealed class Splash : Form
    {
        private readonly Timer _timer;
        private readonly Process _child;
        private int _elapsedMs;
        private int _graceMs;

        public Outcome Result { get; private set; }

        public Splash(string iconPath, Process child)
        {
            _child = child;
            Result = Outcome.TimedOut;

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

            if (HasVisibleWindow(_child.Id)) { Finish(Outcome.Shown); return; }

            // A moment's grace: the window can be up a tick before the process
            // is seen to be alive, and an exiting host still has its error to
            // finish writing to the log.
            if (_child.HasExited)
            {
                _graceMs += _timer.Interval;
                if (_graceMs >= 500) { Finish(Outcome.Exited); }
                return;
            }

            // The timeout is a safety net: if the window never appears, this
            // must not sit on screen forever.
            if (_elapsedMs > 15000) { Finish(Outcome.TimedOut); }
        }

        private void Finish(Outcome outcome)
        {
            Result = outcome;
            _timer.Stop();
            Close();
        }
    }
}
