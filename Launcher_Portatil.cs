using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace ControleDeQualidadeLauncher
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(baseDir, "launcher.ps1");

            if (!File.Exists(scriptPath))
            {
                MessageBox.Show(
                    "Nao foi possivel localizar o arquivo launcher.ps1 na mesma pasta do aplicativo.",
                    "Controle de Qualidade",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
                return;
            }

            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"",
                    WorkingDirectory = baseDir,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Falha ao iniciar o app.\r\n\r\n" + ex.Message,
                    "Controle de Qualidade",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }
        }
    }
}
