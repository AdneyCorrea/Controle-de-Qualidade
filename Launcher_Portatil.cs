// Entrada portatil do painel: este programa inicia o servidor PowerShell ao lado do executavel.
// Os arquivos web sao lidos em tempo de execucao, sem precisar recompilar o launcher.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace ControleDeQualidadeLauncher
{
    internal static class Program
    {
        // STA permite usar as caixas de mensagem do Windows Forms na thread principal.
        [STAThread]
        private static void Main()
        {
            // Resolve os caminhos pela pasta do EXE, independentemente do diretorio de trabalho.
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(baseDir, "launcher.ps1");

            // Interrompe com uma mensagem clara se o pacote estiver incompleto.
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
                // Inicia o Windows PowerShell sem perfil e sem janela de console.
                // A politica Bypass vale para este processo; o script cuida do servidor e do navegador.
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"",
                    WorkingDirectory = baseDir,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                // O servidor continua no processo filho; este launcher pode encerrar.
                Process.Start(psi);
            }
            // Falhas ao abrir o processo sao mostradas com a mensagem original do Windows.
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
