$ErrorActionPreference = 'SilentlyContinue'
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = (Get-Command powershell.exe).Source
$icon = Join-Path $baseDir 'web\assets\logo.ico'
$args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $baseDir 'launcher.ps1') + '"'
$workingDir = $baseDir

$locations = @(
    (Join-Path $baseDir 'Controle de Qualidade.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Controle de Qualidade.lnk')
)

$wshell = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in $locations) {
    try {
        $shortcut = $wshell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $target
        $shortcut.Arguments = $args
        $shortcut.WorkingDirectory = $workingDir
        if (Test-Path $icon) { $shortcut.IconLocation = $icon }
        $shortcut.WindowStyle = 7
        $shortcut.Description = 'Abrir Controle de Qualidade'
        $shortcut.Save()
    } catch {}
}
