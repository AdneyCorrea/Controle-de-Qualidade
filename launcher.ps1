# =============================================================================
# CONTROLE DE QUALIDADE - INICIALIZACAO E SERVIDOR LOCAL
# =============================================================================
# Este arquivo liga a interface web aos scripts e recursos do Windows.
# Fluxo principal: localizar arquivos -> preparar sessao temporaria -> iniciar
# HTTP em 127.0.0.1 -> abrir o navegador -> atender a interface -> liberar recursos.
# As funcoes sao declaradas primeiro; a execucao do servidor fica no try final.
# Falhas nas operacoes principais viram excecoes. Nos blocos de melhor esforco
# (fechar overlays e limpar temporarios), os catch vazios permitem continuar.

# 1. Dependencia grafica e caminhos usados em qualquer local de instalacao.
# Windows.Forms fornece SendKeys e a caixa de mensagem de erro fatal.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

# A base vem do proprio script, para nao depender da pasta de onde foi aberto.
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$webDir = Join-Path $baseDir 'web'
$collectorScript = Join-Path $baseDir 'scripts\coletar_dados.ps1'

# 2. Integracao com os utilitarios externos de drivers e BIOS.
# Usa o atualizador da propria pasta do projeto, independentemente do local de abertura.
# A alternativa PS1 pertence ao mesmo atualizador normal, caso o CMD esteja ausente.
$parentDir = Split-Path -Parent $baseDir
$driverUpdateDir = Join-Path $baseDir 'AtualizarDrivers'
$driverUpdateCmd = Join-Path $driverUpdateDir 'Atualizar Drivers.cmd'
$driverUpdatePs1 = Join-Path $driverUpdateDir 'Atualizar Drivers.ps1'
# Procurar o BIOS.cmd em varios locais conhecidos, na seguinte ordem:
# 1) pasta pai do app (ex.: C:\Windows\Setup\Scripts) - padrao apos o SetupComplete;
# 2) propria pasta do app;
# 3) subpastas provaveis dentro da pasta pai/pasta do app;
# 4) varredura curta, para nao depender de um caminho fixo.
$biosCandidates = @(
    (Join-Path $parentDir 'Utilitarios\BIOS.cmd'),
    (Join-Path $parentDir 'BIOS.cmd'),
    (Join-Path $baseDir 'BIOS.cmd'),
    (Join-Path $parentDir 'Controle de Qualidade\BIOS.cmd'),
    (Join-Path $parentDir 'Script\BIOS.cmd'),
    (Join-Path $baseDir 'Script\BIOS.cmd')
)
$biosCmd = $null
foreach ($candidate in $biosCandidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        $biosCmd = $candidate
        break
    }
}
if (-not $biosCmd) {
    # Fallback: procura BIOS.cmd recursivamente nas pastas provaveis (ate 3 niveis).
    foreach ($root in @($parentDir, $baseDir) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique) {
        try {
            $found = Get-ChildItem -LiteralPath $root -Filter 'BIOS.cmd' -Recurse -File -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $biosCmd = $found.FullName; break }
        } catch {}
    }
}
if (-not $biosCmd) {
    # Mantem um caminho esperado para a mensagem de erro caso nada seja encontrado.
    $biosCmd = Join-Path $parentDir 'BIOS.cmd'
}
# 3. Dados persistidos e arquivos temporarios de cada sessao.
# Os TXT exportados ficam em DriversID. Cada abertura recebe uma pasta unica no
# TEMP para o JSON do coletor e o perfil isolado do navegador. O log fica fora
# dessa pasta da sessao para continuar disponivel depois da limpeza.
$driverIdsDir = Join-Path $baseDir 'DriversID'
$runtimeRoot = Join-Path $env:TEMP 'ControleQualidadePombo'
$sessionId = [guid]::NewGuid().ToString('N')
$runtimeDir = Join-Path $runtimeRoot $sessionId
$browserProfileDir = Join-Path $runtimeDir 'browser-profile'
$logRoot = Join-Path $env:TEMP 'ControleQualidadePombo_Logs'
try { New-Item -Path $logRoot -ItemType Directory -Force | Out-Null } catch {}
$logFile = Join-Path $logRoot 'launcher.log'
# A interface mantem o servidor ativo com requisicoes; 180 s sem acesso encerram
# a sessao. A tolerancia de saida do navegador e mantida deliberadamente alta.
$idleTimeoutSeconds = 180
# Nao encerra mais o servidor so porque o processo inicial do Edge/Chrome terminou.
# Em muitos Windows o navegador reaproveita uma instancia ja aberta e o processo retornado pelo Start-Process fecha em segundos,
# deixando a tela aberta, mas matando o servidor local. Isso causava 'Falha de comunicacao' em qualquer botao.
$browserExitGraceSeconds = 999999999

# Preparacao de melhor esforco: as funcoes que precisam da pasta tambem a criam.
try {
    New-Item -Path $runtimeDir -ItemType Directory -Force | Out-Null
} catch {}

# Solta o diretorio de trabalho original; os recursos do app usam caminhos
# absolutos e os processos externos recebem seu WorkingDirectory explicitamente.
try {
    Set-Location -LiteralPath $env:TEMP
} catch {}

# =============================================================================
# 4. APOIO: LOG, MENU INICIAR E COMUNICACAO HTTP
# =============================================================================

function Write-Log {
    <#
    .SYNOPSIS
        Acrescenta uma mensagem com data e hora ao log desta abertura.
    .PARAMETER Text
        Mensagem de diagnostico que sera gravada no launcher.log temporario.
    #>
    param([string]$Text)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Close-WindowsStartOverlay {
    <#
    .SYNOPSIS
        Fecha menu Iniciar e pesquisa antes de abrir a janela do painel.
    .DESCRIPTION
        Tenta enviar ESC, espera brevemente e encerra os processos dos overlays.
        Falhas nessa preparacao visual nao interrompem a inicializacao.
    #>
    # Usado antes de abrir o navegador/app. Aqui o ESC ainda e seguro.
    try {
        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    } catch {}

    Start-Sleep -Milliseconds 150

    foreach ($procName in @('StartMenuExperienceHost', 'SearchHost')) {
        try {
            Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Start-WindowsStartOverlayGuard {
    <#
    .SYNOPSIS
        Mantem menu Iniciar e pesquisa fechados nos primeiros segundos do app.
    .DESCRIPTION
        Abre um PowerShell oculto que faz 14 tentativas com intervalo de 500 ms,
        sem bloquear o servidor nem enviar teclas ao navegador ja aberto.
    #>
    # Depois que o Controle de Qualidade abre, NAO enviamos ESC.
    # ESC pode cair no Edge/Chrome e interromper o carregamento da pagina, deixando a tela branca em 127.0.0.1.
    # Entao apenas encerramos os processos do menu/pesquisa em segundo plano.
    $command = "1..14 | ForEach-Object { try { Get-Process -Name StartMenuExperienceHost,SearchHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Milliseconds 500 }"
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-Command',$command) -WindowStyle Hidden | Out-Null
    } catch {}
}

function Get-FreePort {
    <#
    .SYNOPSIS
        Pede ao Windows uma porta TCP livre na interface de loopback.
    .DESCRIPTION
        A porta zero faz o sistema escolher uma porta. O listener de sondagem e
        fechado e o numero retornado sera usado pelo servidor HTTP principal.
    #>
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

function Get-ContentType {
    <#
    .SYNOPSIS
        Retorna o tipo MIME que o navegador deve usar para um arquivo.
    .PARAMETER Path
        Caminho cuja extensao determina o MIME; extensoes desconhecidas usam binario.
    #>
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
    <#
    .SYNOPSIS
        Envia uma resposta HTTP com tamanho conhecido e fecha seu fluxo de saida.
    .PARAMETER Context
        Contexto HTTP da requisicao atendida pelo HttpListener.
    .PARAMETER Bytes
        Conteudo binario completo que sera escrito na resposta.
    .PARAMETER ContentType
        Tipo MIME informado ao cliente; o padrao e application/octet-stream.
    .PARAMETER StatusCode
        Codigo HTTP da resposta; o padrao 200 indica sucesso.
    #>
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
    # Uma resposta completa por conexao simplifica o atendimento sequencial.
    $resp.KeepAlive = $false
    $resp.SendChunked = $false
    $resp.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $resp.OutputStream.Close()
}

function Send-Json {
    <#
    .SYNOPSIS
        Serializa um objeto em JSON e o envia com o MIME correspondente.
    .PARAMETER Context
        Contexto HTTP que recebera a resposta.
    .PARAMETER Object
        Objeto serializado com profundidade maxima de oito niveis.
    .PARAMETER StatusCode
        Codigo HTTP repassado para Send-Text; usa 200 quando nao informado.
    #>
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $Object,
        [int] $StatusCode = 200
    )

    $json = $Object | ConvertTo-Json -Depth 8
    Send-Text -Context $Context -Text $json -ContentType 'application/json; charset=utf-8' -StatusCode $StatusCode
}

function Send-Text {
    <#
    .SYNOPSIS
        Converte texto em bytes UTF-8 e reutiliza o envio HTTP binario.
    .PARAMETER Context
        Contexto HTTP que recebera a resposta.
    .PARAMETER Text
        Texto completo a enviar ao navegador.
    .PARAMETER ContentType
        Tipo MIME da resposta; o padrao e texto simples em UTF-8.
    .PARAMETER StatusCode
        Codigo HTTP repassado para Send-Bytes; o padrao e 200.
    #>
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
    <#
    .SYNOPSIS
        Entrega um arquivo estatico ou responde 404 quando ele nao existe.
    .PARAMETER Context
        Contexto HTTP que recebera os bytes do arquivo.
    .PARAMETER Path
        Caminho literal do arquivo; o tipo MIME sera deduzido da extensao.
    #>
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
    <#
    .SYNOPSIS
        Le o corpo de uma requisicao e sempre fecha o leitor utilizado.
    .PARAMETER Request
        Requisicao HTTP com o JSON enviado pela interface; UTF-8 e o fallback.
    #>
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
    <#
    .SYNOPSIS
        Prepara o nome de um dispositivo para compor um arquivo TXT no Windows.
    .PARAMETER Name
        Nome original: caracteres invalidos viram sublinhado, espacos repetidos
        sao reduzidos e o resultado fica limitado a 80 caracteres. Vazio usa Driver.
    #>
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

# =============================================================================
# 5. COLETA DE DADOS EM PROCESSO SEPARADO
# =============================================================================

function Get-CollectorJson {
    <#
    .SYNOPSIS
        Executa o coletor e retorna o JSON consumido pela rota /api/data.
    .DESCRIPTION
        Usa um arquivo temporario unico e espera ate 120 segundos pelo processo.
        Prefere o JSON desse arquivo, aceita stdout como alternativa e converte
        falhas em respostas JSON. O arquivo intermediario e removido ao terminar.
    #>
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -Path $runtimeDir -ItemType Directory -Force | Out-Null
    }

    # O nome unico evita reaproveitar o resultado de uma coleta anterior.
    $tempPath = Join-Path $runtimeDir ("controle_qualidade_{0}.json" -f ([guid]::NewGuid().ToString('N')))

    try {
        if (-not (Test-Path -LiteralPath $collectorScript)) {
            throw "Coletor nao encontrado em: $collectorScript"
        }

        # Executa o coletor sem janela e captura as duas saidas para diagnostico.
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$collectorScript`" -OutputPath `"$tempPath`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $baseDir

        # Impoe limite de dois minutos; encerra apenas esse processo se excedido.
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(120000)) {
            try { $proc.Kill() } catch {}
            throw 'O coletor demorou demais para responder.'
        }

        $stdOut = $proc.StandardOutput.ReadToEnd()
        $stdErr = $proc.StandardError.ReadToEnd()
        $exitCode = $proc.ExitCode

        $json = $null

        # O arquivo e a fonte principal; stdout so e aceito se parecer um JSON.
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

        # Valida a sintaxe antes de entregar o resultado bruto ao JavaScript.
        try {
            $null = $json | ConvertFrom-Json -ErrorAction Stop
            return $json
        }
        catch {
            Write-Log 'JSON invalido recebido do coletor.'
            if ($stdOut) { Write-Log ("STDOUT: " + ($stdOut.Trim())) }
            if ($stdErr) { Write-Log ("STDERR: " + ($stdErr.Trim())) }
            # Mantem a saida invalida dentro de um JSON valido para a interface
            # poder exibir a falha, incluindo o codigo de saida do coletor.
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
        # Limpa o intermediario mesmo quando o coletor falha ou retorna cedo.
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# =============================================================================
# 6. ACOES DO WINDOWS SOLICITADAS PELOS BOTOES DA INTERFACE
# =============================================================================

function Test-IsAdmin {
    <#
    .SYNOPSIS
        Indica se o processo atual pertence ao grupo Administradores com elevacao.
    .DESCRIPTION
        Retorna false se nao conseguir consultar a identidade do Windows.
    #>
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = [Security.Principal.WindowsPrincipal]::new($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Start-DriverUpdate {
    <#
    .SYNOPSIS
        Inicia o atualizador da propria pasta do projeto.
    .DESCRIPTION
        Prefere o CMD em modo SomenteDrivers; usa o PS1 se o CMD nao existir.
        Usa ProcessStartInfo para preservar caminhos com colchetes e espacos.
    #>
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.WorkingDirectory = $driverUpdateDir
    $startInfo.UseShellExecute = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    if (-not (Test-IsAdmin)) { $startInfo.Verb = 'runas' }

    if (Test-Path -LiteralPath $driverUpdateCmd -PathType Leaf) {
        $launched = $driverUpdateCmd
        $startInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $startInfo.Arguments = '/d /c ""' + $driverUpdateCmd + '" /SomenteDrivers"'
    } elseif (Test-Path -LiteralPath $driverUpdatePs1 -PathType Leaf) {
        $launched = $driverUpdatePs1
        $startInfo.FileName = Join-Path $PSHOME 'powershell.exe'
        $startInfo.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $driverUpdatePs1 + '" -NaoPausar'
    } else {
        throw "Nenhum script de atualizacao foi encontrado em: $driverUpdateDir"
    }

    Write-Log "Iniciando atualizador somente drivers: $launched"
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($process) { $process.Dispose() }
    return [PSCustomObject]@{
        Success = $true
        Message = 'Iniciando script de Atualizar Drivers...'
        Launched = $launched
        Mode = 'SomenteDrivers'
    }
}

function Start-Bios {
    <#
    .SYNOPSIS
        Abre BIOS.cmd para solicitar reinicio na BIOS/UEFI.
    .DESCRIPTION
        Exige que o script exista, usa a pasta dele como diretorio de trabalho e
        solicita elevacao quando necessario. Retorna a confirmacao do lancamento.
    #>
    if (-not (Test-Path -LiteralPath $biosCmd)) {
        throw "Script de BIOS nao encontrado em: $biosCmd"
    }

    Write-Log "Reiniciando para a BIOS via: $biosCmd"
    $args = @{
        FilePath = $biosCmd
        WorkingDirectory = (Split-Path -Parent $biosCmd)
        WindowStyle = 'Normal'
    }
    if (-not (Test-IsAdmin)) { $args.Verb = 'RunAs' }
    Start-Process @args | Out-Null
    return [PSCustomObject]@{
        Success = $true
        Message = 'Reiniciando o computador para entrar na BIOS/UEFI...'
        Launched = $biosCmd
    }
}

function Start-Reboot {
    <#
    .SYNOPSIS
        Solicita reinicio imediato do computador com shutdown.exe /r /t 0.
    .DESCRIPTION
        A funcao e chamada somente pela rota correspondente ao botao Reiniciar.
    #>
    Write-Log 'Reiniciando o computador.'
    & shutdown.exe /r /t 0
    return [PSCustomObject]@{
        Success = $true
        Message = 'Reiniciando o computador...'
    }
}

# =============================================================================
# 7. EXPORTACAO DOS HARDWARE IDS PARA ARQUIVOS TXT
# =============================================================================

function Save-DriverIds {
    <#
    .SYNOPSIS
        Salva os Hardware IDs de um dispositivo em DriversID.
    .PARAMETER JsonText
        JSON com DeviceName, InstanceId e HardwareIds enviado pela interface.
        O TXT contem somente IDs nao vazios e unicos, um por linha.
    #>
    param([string]$JsonText)

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        throw 'Nenhum dado foi recebido para salvar o Hardware ID.'
    }

    # Confirma o formato recebido e descarta Hardware IDs vazios ou repetidos.
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

    # O nome do dispositivo sanitizado e a data identificam a exportacao.
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
    <#
    .SYNOPSIS
        Consolida os Hardware IDs dos drivers enviados em um unico TXT.
    .PARAMETER JsonText
        JSON com a lista Drivers. Cada item informa DeviceName, InstanceId,
        Category e HardwareIds. Itens sem IDs validos sao ignorados.
    #>
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

    # Cada dispositivo valido vira uma secao com os dados necessarios para
    # pesquisar o driver; o contador considera dispositivos, e nao a soma dos IDs.
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

# =============================================================================
# 8. ROTAS HTTP: PAGINA, COLETA, ACOES E EXPORTACAO
# =============================================================================

function Handle-Request {
    <#
    .SYNOPSIS
        Direciona uma requisicao do navegador para a funcao ou arquivo adequado.
    .PARAMETER Context
        Contexto obtido do listener, com requisicao e resposta HTTP associadas.
    .DESCRIPTION
        Atualiza a atividade da sessao antes do atendimento. Cada rota responde
        uma vez e retorna; excecoes sao registradas e enviadas como JSON com 500.
    #>
    param($Context)

    $request = $Context.Request
    $path = $request.Url.AbsolutePath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = '/' }
    $script:lastRequestAt = Get-Date

    try {
        # As expressoes completas (^...$) distinguem as chamadas da API.
        switch -Regex ($path) {
            '^/$' {
                # Documento inicial; seus recursos sao servidos em /assets/.
                Send-File -Context $Context -Path (Join-Path $webDir 'index.html')
                return
            }
            '^/api/ping$' {
                # Resposta leve que a interface usa para manter a sessao ativa.
                Send-Text -Context $Context -Text '{"ok":true}' -ContentType 'application/json; charset=utf-8'
                return
            }
            '^/api/data$' {
                # Faz uma nova coleta e devolve seu JSON para atualizar o painel.
                $json = Get-CollectorJson
                Send-Text -Context $Context -Text $json -ContentType 'application/json; charset=utf-8'
                return
            }
            '^/api/run-driver-update$' {
                # Inicia o atualizador externo e confirma a abertura na resposta.
                $result = Start-DriverUpdate
                Send-Json -Context $Context -Object $result
                return
            }
            '^/api/run-bios$' {
                # Encaminha a solicitacao do botao BIOS ao script do Windows.
                $result = Start-Bios
                Send-Json -Context $Context -Object $result
                return
            }
            '^/api/run-reboot$' {
                # Executa a solicitacao de reinicio imediato.
                $result = Start-Reboot
                Send-Json -Context $Context -Object $result
                return
            }
            '^/api/copy-driver-id$' {
                # O corpo contem um dispositivo selecionado para exportacao.
                $body = Read-RequestText -Request $request
                $result = Save-DriverIds -JsonText $body
                Send-Json -Context $Context -Object $result
                return
            }
            '^/api/copy-driver-id-all$' {
                # O corpo contem os drivers com problema para exportacao conjunta.
                $body = Read-RequestText -Request $request
                $result = Save-AllDriverIds -JsonText $body
                Send-Json -Context $Context -Object $result
                return
            }
            '^/config/' {
                # Traduz separadores de URL em caminho relativo na pasta web.
                $relative = $path.TrimStart('/').Replace('/', '\')
                $target = Join-Path $webDir $relative
                Send-File -Context $Context -Path $target
                return
            }
            '^/assets/' {
                # Entrega os arquivos de estilo, JavaScript e imagens da interface.
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

# =============================================================================
# 9. ABERTURA DA INTERFACE EM EDGE, CHROME OU NAVEGADOR PADRAO
# =============================================================================

function Start-AppBrowser {
    <#
    .SYNOPSIS
        Abre a URL local em uma janela do painel e retorna o processo, se houver.
    .PARAMETER Url
        Endereco HTTP do painel, incluindo o identificador de atualizacao de cache.
    .DESCRIPTION
        Prefere Edge, depois Chrome, com perfil temporario e modo app em tela
        cheia. Como alternativa, abre o navegador padrao e retorna null porque
        esse caminho nao acompanha um processo especifico.
    #>
    param([string]$Url)

    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -Path $runtimeDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $browserProfileDir)) {
        New-Item -Path $browserProfileDir -ItemType Directory -Force | Out-Null
    }

    # Argumentos compartilhados por Edge/Chrome: janela dedicada, perfil da
    # sessao e reducao de tarefas de primeira abertura/sincronizacao em segundo plano.
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

    # Tenta os locais de instalacao de 32/64 bits na ordem abaixo.
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

# =============================================================================
# 10. EXECUCAO PRINCIPAL, TEMPO DE VIDA E LIMPEZA
# =============================================================================

try {
    # Cada abertura reinicia o log; o perfil e os temporarios tem sessao propria.
    if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }
    Write-Log 'Inicializando launcher.'
    Write-Log "Runtime temporario: $runtimeDir"
    Write-Log "Base do app: $baseDir"


    # O servidor escuta somente no computador local, em uma porta livre.
    $port = Get-FreePort
    $prefix = "http://127.0.0.1:$port/"

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)
    $listener.Start()
    Write-Log "Servidor iniciado em $prefix"

    # Fecha overlays antes da abertura e inicia o guard sem atrasar o primeiro GET.
    Close-WindowsStartOverlay
    Start-WindowsStartOverlayGuard
    # O parametro v muda a URL a cada abertura para atualizar a pagina no browser.
    $appUrl = "{0}?v={1}" -f $prefix.TrimEnd('/'), ([DateTimeOffset]::Now.ToUnixTimeMilliseconds())
    $browser = Start-AppBrowser -Url $appUrl

    # Importante: nao bloquear o loop do servidor depois de abrir o navegador.
    # Se ficarmos alguns segundos fechando overlays antes de atender o primeiro GET /,
    # o Edge pode ficar em tela branca. O guard acima roda em segundo plano.
    $script:lastRequestAt = Get-Date

    # Aguarda conexoes em intervalos de 500 ms para tambem verificar inatividade.
    # As requisicoes sao processadas uma de cada vez no processo do launcher.
    while ($listener.IsListening) {
        $async = $listener.BeginGetContext($null, $null)
        while (-not $async.AsyncWaitHandle.WaitOne(500)) {
            $idleSeconds = ((Get-Date) - $script:lastRequestAt).TotalSeconds

            # A tolerancia alta evita fechar o servidor quando Edge/Chrome apenas
            # transfere a janela para uma instancia de navegador ja existente.
            if ($browser -and $browser.HasExited -and $idleSeconds -ge $browserExitGraceSeconds) {
                Write-Log "Navegador encerrado. Encerrando servidor apos $idleSeconds s sem requisicoes."
                $listener.Stop()
                break
            }

            # Sem ping ou outra requisicao por 180 s, termina a sessao local.
            if ($idleSeconds -ge $idleTimeoutSeconds) {
                Write-Log "Tempo limite por inatividade atingido ($idleSeconds s). Encerrando servidor."
                $listener.Stop()
                break
            }
        }

        if (-not $listener.IsListening) { break }

        try {
            # Conclui a espera assincrona e atende a requisicao recebida.
            $context = $listener.EndGetContext($async)
            Handle-Request -Context $context
        }
        catch [System.ObjectDisposedException] {
            # O listener ja foi liberado durante o encerramento da sessao.
            break
        }
        catch {
            Write-Log "Falha no loop principal: $($_.Exception.Message)"
        }
    }
}
catch {
    # Erros que impedem o funcionamento do servidor sao mostrados em uma caixa
    # nativa, pois a interface web pode nao estar disponivel nesse momento.
    Write-Log "Erro fatal: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show("Falha ao iniciar o app.`r`n`r`n$($_.Exception.Message)`r`n`r`nVeja launcher.log para detalhes.", 'Controle de Qualidade', 'OK', 'Error') | Out-Null
}
finally {
    # A limpeza roda apos termino normal ou excecao. Cada etapa e independente
    # para que um recurso ainda ocupado nao impeça as demais tentativas.
    if ($listener) {
        try { $listener.Stop() } catch {}
        try { $listener.Close() } catch {}
    }

    # Pede fechamento normal da janela que foi iniciada, quando acompanhada.
    if ($browser) {
        try {
            if (-not $browser.HasExited) {
                $browser.CloseMainWindow() | Out-Null
                Start-Sleep -Milliseconds 700
            }
        } catch {}
    }

    # Da tempo ao navegador para liberar os arquivos de seu perfil temporario.
    Start-Sleep -Milliseconds 300

    try {
        if (Test-Path -LiteralPath $browserProfileDir) {
            Remove-Item -LiteralPath $browserProfileDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    # Apaga somente a pasta exclusiva da sessao; os logs e TXT permanecem.
    try {
        if (Test-Path -LiteralPath $runtimeDir) {
            Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
