using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

class Launcher {
    [STAThread]
    static int Main() {
        try {
            string tempDir = Path.Combine(Path.GetTempPath(), "isb-installer");
            Directory.CreateDirectory(tempDir);
            string tempPs1 = Path.Combine(tempDir, "installer.ps1");

            // Extract embedded installer.ps1
            Assembly asm = Assembly.GetExecutingAssembly();
            string resName = null;
            foreach (string n in asm.GetManifestResourceNames()) {
                if (n.EndsWith("installer.ps1", StringComparison.OrdinalIgnoreCase)) {
                    resName = n;
                    break;
                }
            }
            if (resName == null) {
                MessageBox.Show("Встроенный installer.ps1 не найден в .exe.", "ISB Installer",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }

            using (Stream stream = asm.GetManifestResourceStream(resName))
            using (FileStream fs = File.Create(tempPs1)) {
                stream.CopyTo(fs);
            }

            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File \"" + tempPs1 + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;

            Process p = Process.Start(psi);
            p.WaitForExit();
            return p.ExitCode;
        } catch (Exception ex) {
            MessageBox.Show("Ошибка запуска установщика:\n\n" + ex.Message,
                "ISB Installer", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
