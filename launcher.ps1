$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$webDir = Join-Path $baseDir 'web'
$collectorScript = Join-Path $baseDir 'scripts\coletar_dados.ps1'
$driverUpdateDir = Join-Path $baseDir 'AtualizarDrivers'
$driverUpdateCmd = Join-Path $driverUpdateDir 'Instalar_Drivers_Offline.cmd'
$driverUpdatePs1 = Join-Path $driverUpdateDir 'Instalar_Drivers_Offline.ps1'
$driverIdsDir = Join-Path $baseDir 'DriversID'
$runtimeRoot = Join-Path $env:TEMP 'ControleQualidadePombo'
$sessionId = [guid]::NewGuid().ToString('N')
$runtimeDir = Join-Path $runtimeRoot $sessionId
$browserProfileDir = Join-Path $runtimeDir 'browser-profile'
$logFile = Join-Path $runtimeDir 'launcher.log'
$script:lastRequestAt = Get-Date
$idleTimeoutSeconds = 20
$browserExitGraceSeconds = 2

try {
    New-Item -Path $runtimeDir -ItemType Directory -Force | Out-Null
} catch {}

try {
    Set-Location -LiteralPath $env:TEMP
} catch {}

function Write-Log {
    param([string]$Text)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Get-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

function Get-ContentType {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.svg'  { 'image/svg+xml' }
        '.png'  { 'image/png' }
        '.jpg'  { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.bmp'  { 'image/bmp' }
        '.ico'  { 'image/x-icon' }
        '.txt'  { 'text/plain; charset=utf-8' }
        default { 'application/octet-stream' }
    }
}

function Send-Bytes {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [byte[]] $Bytes,
        [string] $ContentType = 'application/octet-stream',
        [int] $StatusCode = 200
    )

    $resp = $Context.Response
    $resp.StatusCode = $StatusCode
    $resp.ContentType = $ContentType
    $resp.ContentLength64 = $Bytes.Length
    $resp.KeepAlive = $false
    $resp.SendChunked = $false
    $resp.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $resp.OutputStream.Close()
}

function Send-Json {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $Object,
        [int] $StatusCode = 200
    )

    $json = $Object | ConvertTo-Json -Depth 8
    Send-Text -Context $Context -Text $json -ContentType 'application/json; charset=utf-8' -StatusCode $StatusCode
}

function Send-Text {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $Text,
        [string] $ContentType = 'text/plain; charset=utf-8',
        [int] $StatusCode = 200
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    Send-Bytes -Context $Context -Bytes $bytes -ContentType $ContentType -StatusCode $StatusCode
}

function Send-File {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Send-Text -Context $Context -Text 'Arquivo nao encontrado.' -StatusCode 404
        return
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    Send-Bytes -Context $Context -Bytes $bytes -ContentType (Get-ContentType $Path)
}

function Read-RequestText {
    param($Request)

    $encoding = if ($Request.ContentEncoding) { $Request.ContentEncoding } else { [Text.Encoding]::UTF8 }
    $reader = [IO.StreamReader]::new($Request.InputStream, $encoding)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Close()
    }
}

function Sanitize-FileName {
    param([string]$Name)

    $safe = [string]$Name
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Driver' }
    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$char, '_')
    }
    $safe = $safe -replace '\s+', ' '
    $safe = $safe.Trim()
    if ($safe.Length -gt 80) {
        $safe = $safe.Substring(0, 80).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Driver' }
    return $safe
}

function Get-CurrentWallpaperPath {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $transcoded = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
        if (Test-Path -LiteralPath $transcoded) {
            $candidates.Add($transcoded)
        }
    } catch {}

    try {
        $cachedDir = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\CachedFiles'
        if (Test-Path -LiteralPath $cachedDir) {
            Get-ChildItem -LiteralPath $cachedDir -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
    } catch {}

    try {
        $path = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction Stop).WallPaper
        if ($path) {
            $candidates.Add($path)
        }
    } catch {}

    foreach ($candidate in $candidates) {
        try {
            if ($candidate -and (Test-Path -LiteralPath $candidate)) {
                $item = Get-Item -LiteralPath $candidate -ErrorAction Stop
                if ($item.Length -gt 0) {
                    return $item.FullName
                }
            }
        } catch {}
    }

    return $null
}

function Get-CollectorJson {
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -Path $runtimeDir -ItemType Directory -Force | Out-Null
    }

    $tempPath = Join-Path $runtimeDir ("controle_qualidade_{0}.json" -f ([guid]::NewGuid().ToString('N')))

    try {
        if (-not (Test-Path -LiteralPath $collectorScript)) {
            throw "Coletor nao encontrado em: $collectorScript"
        }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$collectorScript`" -OutputPath `"$tempPath`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $baseDir

        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(120000)) {
            try { $proc.Kill() } catch {}
            throw 'O coletor demorou demais para responder.'
        }

        $stdOut = $proc.StandardOutput.ReadToEnd()
        $stdErr = $proc.StandardError.ReadToEnd()
        $exitCode = $proc.ExitCode

        $json = $null

        if (Test-Path -LiteralPath $tempPath) {
            $json = Get-Content -LiteralPath $tempPath -Raw -Encoding UTF8
        }
        elseif (-not [string]::IsNullOrWhiteSpace($stdOut)) {
            $candidate = [string]$stdOut
            $candidate = $candidate.Trim()
            if ($candidate.StartsWith('{') -or $candidate.StartsWith('[')) {
                $json = $candidate
            }
        }

        if ([string]::IsNullOrWhiteSpace($json)) {
            Write-Log "Coletor sem JSON. ExitCode=$exitCode"
            if ($stdOut) { Write-Log ("STDOUT: " + ($stdOut.Trim())) }
            if ($stdErr) { Write-Log ("STDERR: " + ($stdErr.Trim())) }
            throw 'O coletor nao gerou o arquivo JSON esperado.'
        }

        $json = [string]$json
        $json = $json.Trim()

        if ([string]::IsNullOrWhiteSpace($json)) {
            throw 'O coletor retornou um JSON vazio.'
        }

        try {
            $null = $json | ConvertFrom-Json -ErrorAction Stop
            return $json
        }
        catch {
            Write-Log 'JSON invalido recebido do coletor.'
            if ($stdOut) { Write-Log ("STDOUT: " + ($stdOut.Trim())) }
            if ($stdErr) { Write-Log ("STDERR: " + ($stdErr.Trim())) }
            $wrapped = [PSCustomObject]@{
                Error = $true
                Message = 'O coletor retornou uma saida invalida.'
                RawOutput = $json
                GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                ExitCode = $exitCode
            }
            return ($wrapped | ConvertTo-Json -Depth 6)
        }
    }
    catch {
        $err = [PSCustomObject]@{
            Error = $true
            Message = $_.Exception.Message
            GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        return ($err | ConvertTo-Json -Depth 4)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-DriverUpdate {
    if (Test-Path -LiteralPath $driverUpdateCmd) {
        Write-Log "Iniciando atualizador por CMD: $driverUpdateCmd"
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "`"$driverUpdateCmd`"") -WorkingDirectory $driverUpdateDir -WindowStyle Normal -Verb RunAs | Out-Null
        return [PSCustomObject]@{
            Success = $true
            Message = 'Atualizador de drivers iniciado.'
            Launched = $driverUpdateCmd
        }
    }

    if (Test-Path -LiteralPath $driverUpdatePs1) {
        Write-Log "Iniciando atualizador por PowerShell: $driverUpdatePs1"
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $driverUpdatePs1) -WorkingDirectory $driverUpdateDir -WindowStyle Normal -Verb RunAs | Out-Null
        return [PSCustomObject]@{
            Success = $true
            Message = 'Atualizador de drivers iniciado.'
            Launched = $driverUpdatePs1
        }
    }

    throw "Nenhum script de atualizacao foi encontrado em: $driverUpdateDir"
}

function Save-DriverIds {
    param([string]$JsonText)

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        throw 'Nenhum dado foi recebido para salvar o Hardware ID.'
    }

    $payload = $JsonText | ConvertFrom-Json -ErrorAction Stop

    $deviceName = [string]$payload.DeviceName
    $instanceId = [string]$payload.InstanceId
    $hardwareIds = @($payload.HardwareIds) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    if ($hardwareIds.Count -eq 0) {
        throw 'Hardware ID nao encontrado para este dispositivo.'
    }

    if (-not (Test-Path -LiteralPath $driverIdsDir)) {
        New-Item -Path $driverIdsDir -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeName = Sanitize-FileName $deviceName
    $filePath = Join-Path $driverIdsDir ("{0}_{1}.txt" -f $safeName, $stamp)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($id in $hardwareIds) {
        $lines.Add($id)
    }

    Set-Content -LiteralPath $filePath -Value $lines -Encoding UTF8

    Write-Log "Hardware ID salvo: $filePath :: InstanceId=$instanceId"

    return [PSCustomObject]@{
        Success = $true
        Message = "Hardware ID salvo em: $filePath"
        Path = $filePath
        Count = $hardwareIds.Count
    }
}

function Save-AllDriverIds {
    param([string]$JsonText)

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        throw 'Nenhum dado foi recebido para salvar os Hardware IDs.'
    }

    $payload = $JsonText | ConvertFrom-Json -ErrorAction Stop
    $drivers = @($payload.Drivers)
    if ($drivers.Count -eq 0) {
        throw 'Nenhum driver com problema foi enviado.'
    }

    if (-not (Test-Path -LiteralPath $driverIdsDir)) {
        New-Item -Path $driverIdsDir -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filePath = Join-Path $driverIdsDir ("Drivers_Faltantes_{0}.txt" -f $stamp)
    $lines = New-Object System.Collections.Generic.List[string]
    $savedCount = 0

    foreach ($driver in $drivers) {
        $deviceName = [string]$driver.DeviceName
        $instanceId = [string]$driver.InstanceId
        $category = [string]$driver.Category
        $hardwareIds = @($driver.HardwareIds) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        if ($hardwareIds.Count -eq 0) { continue }

        $savedCount++
        $lines.Add(('='.PadLeft(72, '=')))
        $lines.Add("Dispositivo: $deviceName")
        $lines.Add("Categoria: $category")
        $lines.Add("Instance ID: $instanceId")
        $lines.Add('Hardware IDs:')
        foreach ($id in $hardwareIds) {
            $lines.Add($id)
        }
        $lines.Add('')
    }

    if ($savedCount -eq 0) {
        throw 'Nenhum Hardware ID valido foi encontrado nos drivers com problema.'
    }

    Set-Content -LiteralPath $filePath -Value $lines -Encoding UTF8
    Write-Log "Hardware IDs consolidados salvos: $filePath :: Drivers=$savedCount"

    return [PSCustomObject]@{
        Success = $true
        Message = "Hardware IDs de $savedCount driver(s) salvos em: $filePath"
        Path = $filePath
        Count = $savedCount
    }
}

function Handle-Request {
    param($Context)

    $request = $Context.Request
    $path = $request.Url.AbsolutePath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = '/' }
    $script:lastRequestAt = Get-Date

    try {
        switch -Regex ($path) {
            '^/$' {
                Send-File -Context $Context -Path (Join-Path $webDir 'index.html')
                return
            }
            '^/api/ping$' {
                Send-Text -Context $Context -Text '{"ok":true}' -ContentType 'application/json; charset=utf-8'
                return
            }
            '^/api/data$' {
                $json = Get-CollectorJson
                Send-Text -Context $Context -Text $json -ContentType 'application/json; charset=utf-8'
                return
            }
            '^/api/wallpaper$' {
                $wallpaperPath = Get-CurrentWallpaperPath
                if (-not $wallpaperPath) {
                    Send-Text -Context $Context -Text 'Wallpaper nao encontrado.' -StatusCode 404
                    return
                }
                Send-File -Context $Context -Path $wallpaperPath
                return
            }
            '^/api/run-driver-update$' {
                $result = Start-DriverUpdate
                Send-Json -Context $Context -Object $result
                return
            }
            '^/api/copy-driver-id$' {
                $body = Read-RequestText -Request $request
                $result = Save-DriverIds -JsonText $body
                Send-Json -Context $Context -Object $result
                return
            }
            '^/api/copy-driver-id-all$' {
                $body = Read-RequestText -Request $request
                $result = Save-AllDriverIds -JsonText $body
                Send-Json -Context $Context -Object $result
                return
            }
            '^/config/' {
                $relative = $path.TrimStart('/').Replace('/', '\')
                $target = Join-Path $webDir $relative
                Send-File -Context $Context -Path $target
                return
            }
            '^/assets/' {
                $relative = $path.TrimStart('/').Replace('/', '\')
                $target = Join-Path $webDir $relative
                Send-File -Context $Context -Path $target
                return
            }
            default {
                Send-Text -Context $Context -Text 'Rota nao encontrada.' -StatusCode 404
                return
            }
        }
    }
    catch {
        Write-Log "Erro ao processar $path :: $($_.Exception.Message)"
        $err = [PSCustomObject]@{
            Error = $true
            Message = $_.Exception.Message
            Path = $path
        }
        Send-Json -Context $Context -Object $err -StatusCode 500
    }
}

function Start-AppBrowser {
    param([string]$Url)

    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -Path $runtimeDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $browserProfileDir)) {
        New-Item -Path $browserProfileDir -ItemType Directory -Force | Out-Null
    }

    $commonArgs = @(
        '--start-fullscreen',
        '--start-maximized',
        '--window-position=0,0',
        '--new-window',
        '--no-first-run',
        '--disable-background-mode',
        '--disable-background-networking',
        '--disable-default-apps',
        '--disable-sync',
        '--disable-component-update',
        '--disable-features=msWebOOUI,msPdfOOUI,CalculateNativeWinOcclusion',
        '--bwsi',
        "--user-data-dir=$browserProfileDir"
    )

    $edgeCandidates = @(
        "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )

    foreach ($candidate in $edgeCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            Write-Log "Abrindo Edge app mode em tela cheia: $candidate"
            return Start-Process -FilePath $candidate -ArgumentList (@("--app=$Url") + $commonArgs) -PassThru
        }
    }

    $chromeCandidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles (x86)\Google\Chrome\Application\chrome.exe"
    )

    foreach ($candidate in $chromeCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            Write-Log "Abrindo Chrome app mode em tela cheia: $candidate"
            return Start-Process -FilePath $candidate -ArgumentList (@("--app=$Url") + $commonArgs) -PassThru
        }
    }

    Write-Log 'Nenhum Edge/Chrome localizado. Abrindo navegador padrao.'
    Start-Process $Url | Out-Null
    return $null
}

try {
    if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }
    Write-Log 'Inicializando launcher.'
    Write-Log "Runtime temporario: $runtimeDir"
    Write-Log "Base do app: $baseDir"


    $port = Get-FreePort
    $prefix = "http://127.0.0.1:$port/"

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)
    $listener.Start()
    Write-Log "Servidor iniciado em $prefix"

    $browser = Start-AppBrowser -Url $prefix
    $script:lastRequestAt = Get-Date

    while ($listener.IsListening) {
        $async = $listener.BeginGetContext($null, $null)
        while (-not $async.AsyncWaitHandle.WaitOne(500)) {
            $idleSeconds = ((Get-Date) - $script:lastRequestAt).TotalSeconds

            if ($browser -and $browser.HasExited -and $idleSeconds -ge $browserExitGraceSeconds) {
                Write-Log "Navegador encerrado. Encerrando servidor apos $idleSeconds s sem requisicoes."
                $listener.Stop()
                break
            }

            if ($idleSeconds -ge $idleTimeoutSeconds) {
                Write-Log "Tempo limite por inatividade atingido ($idleSeconds s). Encerrando servidor."
                $listener.Stop()
                break
            }
        }

        if (-not $listener.IsListening) { break }

        try {
            $context = $listener.EndGetContext($async)
            Handle-Request -Context $context
        }
        catch [System.ObjectDisposedException] {
            break
        }
        catch {
            Write-Log "Falha no loop principal: $($_.Exception.Message)"
        }
    }
}
catch {
    Write-Log "Erro fatal: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show("Falha ao iniciar o app.`r`n`r`n$($_.Exception.Message)`r`n`r`nVeja launcher.log para detalhes.", 'Controle de Qualidade', 'OK', 'Error') | Out-Null
}
finally {
    if ($listener) {
        try { $listener.Stop() } catch {}
        try { $listener.Close() } catch {}
    }

    if ($browser) {
        try {
            if (-not $browser.HasExited) {
                $browser.CloseMainWindow() | Out-Null
                Start-Sleep -Milliseconds 700
            }
        } catch {}
    }

    Start-Sleep -Milliseconds 300

    try {
        if (Test-Path -LiteralPath $browserProfileDir) {
            Remove-Item -LiteralPath $browserProfileDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    try {
        if (Test-Path -LiteralPath $runtimeDir) {
            Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
