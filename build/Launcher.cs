// A Windows application, not a console one, whose only job is to start the
// screen4screen window sitting next to it.
//
// It exists for two reasons a .cmd or a bare .ps1 cannot cover: Explorer shows
// the program icon on an .exe, and /target:winexe means no console is ever
// created, so nothing flashes or lingers behind the window.
//
// ASCII only, and C# 5 compatible: it is built by the compiler that ships
// with the .NET Framework.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal static class Launcher
{
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

        return 0;
    }
}
