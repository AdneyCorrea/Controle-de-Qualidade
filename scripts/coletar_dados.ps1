# ============================================================================
# COLETOR DE DIAGNÓSTICO DO WINDOWS
# ============================================================================
# Consulta o hardware e os dispositivos/ drivers do computador e monta o JSON
# consumido pelo painel. Este arquivo concentra a coleta; a interface apenas
# apresenta os campos produzidos aqui.
#
# Fluxo: normalizar valores -> consultar hardware -> inventariar drivers ->
# calcular o resumo -> serializar o resultado para a saída ou para um arquivo.
#
# Sem OutputPath, o JSON é escrito na saída padrão. Com OutputPath, o resultado
# é salvo nesse caminho e o caminho é devolvido ao processo que chamou o script.
param(
    [string]$OutputPath = ""
)

# Falhas não tratadas interrompem a coleta e chegam ao catch principal. As
# consultas opcionais abaixo usam tratamento próprio para tolerar dados ausentes.
$ErrorActionPreference = 'Stop'

# ============================================================================
# 1. NORMALIZAÇÃO E FORMATAÇÃO DOS VALORES
# ============================================================================

# Converte qualquer valor em texto utilizável na interface. Remove caracteres
# nulos e espaços das bordas; valores vazios recebem o marcador padrão "-".
function Safe-Text {
    param($Value)

    if ($null -eq $Value) { return '-' }

    $text = "$Value"
    $text = $text -replace "`0", ''
    $text = $text.Trim()

    if ([string]::IsNullOrWhiteSpace($text)) { return '-' }
    return $text
}

# Substitui os seriais genéricos gravados pelo fabricante por uma mensagem
# legível. A comparação ignora diferenças entre letras maiúsculas e minúsculas.
function Normalize-Serial {
    param($Value)

    $text = Safe-Text $Value

    $invalidos = @(
        '-',
        'Default string',
        'To be filled by O.E.M.',
        'To Be Filled By O.E.M.',
        'System Serial Number',
        'Unknown',
        'None'
    )

    foreach ($i in $invalidos) {
        if ($text -ieq $i) {
            return 'Nao informado pelo fabricante'
        }
    }

    return $text
}

# Apresenta capacidades de disco na maior unidade suportada, com duas casas
# decimais e a formatação numérica da cultura atual do PowerShell.
function Format-Bytes {
    param([UInt64]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    elseif ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    elseif ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    elseif ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    else { return "$Bytes B" }
}

# A memória RAM é sempre exibida em GB, com uma casa decimal.
function Format-Bytes-RAM {
    param([UInt64]$Bytes)

    return ('{0:N1} GB' -f ($Bytes / 1GB))
}

# Datas podem chegar como DateTime, texto WMI/CIM ou texto conversível. Tenta
# esses formatos na ordem abaixo e preserva o texto original se nenhum funcionar.
function Format-DriverDate {
    param($Value)

    if ($null -eq $Value) { return '-' }

    # Caminho direto para valores já tipados como data.
    try {
        if ($Value -is [datetime]) {
            return $Value.ToString('dd/MM/yyyy')
        }
    } catch {}

    # Conversão específica do formato de data usado pelas classes WMI.
    try {
        return ([System.Management.ManagementDateTimeConverter]::ToDateTime("$Value")).ToString('dd/MM/yyyy')
    } catch {}

    # Última tentativa: conversão padrão de texto para DateTime.
    try {
        return ([datetime]$Value).ToString('dd/MM/yyyy')
    } catch {}

    return Safe-Text $Value
}

# ============================================================================
# 2. CATEGORIAS DO WINDOWS E REGRAS DE ALERTA
# ============================================================================

# Traduz os identificadores de classe PnP para os títulos usados na árvore do
# painel. Classes desconhecidas continuam visíveis com o identificador original.
function Get-ClassDisplayName {
    param([string]$ClassName)

    switch ((Safe-Text $ClassName).ToLowerInvariant()) {
        'display'               { return 'Adaptadores de video' }
        'net'                   { return 'Adaptadores de rede' }
        'media'                 { return 'Controladores de som, video e jogos' }
        'hidclass'              { return 'Dispositivos de Interface Humana' }
        'usb'                   { return 'Controladores USB' }
        'system'                { return 'Dispositivos de sistema' }
        'diskdrive'             { return 'Unidades de disco' }
        'keyboard'              { return 'Teclados' }
        'mouse'                 { return 'Mouse e apontadores' }
        'monitor'               { return 'Monitores' }
        'ports'                 { return 'Portas (COM e LPT)' }
        'processor'             { return 'Processadores' }
        'firmware'              { return 'Firmware' }
        'battery'               { return 'Baterias' }
        'bluetooth'             { return 'Bluetooth' }
        'camera'                { return 'Cameras' }
        'image'                 { return 'Dispositivos de imagem' }
        'printer'               { return 'Filas de impressao' }
        'printerqueue'          { return 'Filas de impressao' }
        'softwaredevice'        { return 'Dispositivos do software' }
        'softwarecomponent'     { return 'Componentes de software' }
        'securitydevices'       { return 'Dispositivos de seguranca' }
        'scsiadapter'           { return 'Controladores de armazenamento' }
        'hdc'                   { return 'Controladores IDE ATA/ATAPI' }
        'audioendpoint'         { return 'Entradas e saidas de audio' }
        'audioprocessingobject' { return 'Objetos de Processamento de Audio' }
        'volume'                { return 'Volumes' }
        'volumesnapshot'        { return 'Snapshots de volume' }
        'wpd'                   { return 'Dispositivos portateis' }
        'printqueue'            { return 'Filas de impressao' }
        'computer'              { return 'Computador' }
        '-'                     { return 'Outros dispositivos' }
        default                 { return Safe-Text $ClassName }
    }
}

# Traduz os códigos ConfigManagerErrorCode conhecidos. Códigos ainda não
# mapeados mantêm o número para facilitar a identificação do problema.
function Get-ProblemDescription {
    param([int]$Code)

    switch ($Code) {
        0  { return 'Sem problema' }
        1  { return 'Dispositivo configurado incorretamente' }
        3  { return 'Driver pode estar corrompido ou sistema com pouca memoria' }
        10 { return 'Dispositivo nao pode ser iniciado' }
        12 { return 'Recursos insuficientes para o dispositivo' }
        14 { return 'Reinicializacao necessaria' }
        18 { return 'Drivers precisam ser reinstalados' }
        21 { return 'Windows esta removendo o dispositivo' }
        22 { return 'Dispositivo desativado' }
        24 { return 'Dispositivo ausente, com falha ou drivers nao instalados' }
        28 { return 'Drivers nao instalados' }
        31 { return 'Windows nao conseguiu carregar os drivers' }
        32 { return 'Servico do driver desativado' }
        37 { return 'Falha na inicializacao do driver' }
        39 { return 'Driver corrompido ou ausente' }
        40 { return 'Servico do driver ou chave de registro ausente' }
        43 { return 'Dispositivo interrompido pelo Windows' }
        45 { return 'Dispositivo nao conectado' }
        default { return "Codigo de problema $Code" }
    }
}

# Decide se um problema deve ser desconsiderado pela contagem e pelos alertas
# visuais. O dispositivo continua no inventário com o diagnóstico original.
function Is-IgnoredProblemDevice {
    param(
        [string]$Category,
        [string]$CategoryCode,
        [string]$DeviceName
    )

    # Normaliza os três critérios para aplicar as mesmas regras de comparação.
    $cat  = (Safe-Text $Category).ToLowerInvariant()
    $code = (Safe-Text $CategoryCode).ToLowerInvariant()
    $name = (Safe-Text $DeviceName).ToLowerInvariant()

    # Mouse e teclado são ignorados por classe, categoria ou nome detectado.
    if ($cat -eq 'mouse e apontadores') { return $true }
    if ($cat -eq 'teclados') { return $true }
    if ($code -eq 'mouse') { return $true }
    if ($code -eq 'keyboard') { return $true }
    if ($name -match 'mouse') { return $true }
    if ($name -match 'keyboard') { return $true }
    if ($name -match 'teclado') { return $true }

    # Ignorar falso positivo: Serviço de Hipervisor da Microsoft (ROOT\HVSERVICE\0000)
    # No Gerenciador de Dispositivos não aparece como problema, mas pode constar no app.
    if ($name -match 'hvservice|hipervisor') { return $true }
    # instanceId é lido do escopo chamador: o laço de Get-DriverInventory define
    # esse valor antes de consultar esta regra, conforme o fluxo existente.
    if ($instanceId -match 'ROOT\\HVSERVICE\\0000|ROOT\\hvservice') { return $true }

    return $false
}


# ============================================================================
# 3. COLETA DO HARDWARE E DO SISTEMA OPERACIONAL
# ============================================================================

# Reúne os dados apresentados nos cartões de hardware. As consultas essenciais
# propagam falhas; BIOS, sistema, GPUs e discos toleram informações indisponíveis.
function Get-HardwareData {
    # Obtém o primeiro processador e a primeira placa-mãe, além dos dados gerais
    # do computador. Cada classe CIM expõe uma parte diferente do diagnóstico.
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $bb  = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1

    # Soma a capacidade dos módulos físicos para distinguir RAM instalada da
    # memória utilizável informada pelo sistema.
    $installedRamBytes = 0
    try {
        $memModules = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
        foreach ($m in $memModules) {
            if ($m.Capacity) {
                $installedRamBytes += [UInt64]$m.Capacity
            }
        }
    } catch {}

    # Caso a leitura dos módulos falhe ou não traga capacidade, reutiliza o
    # total de memória física do computador como alternativa compatível.
    if ($installedRamBytes -le 0) {
        $installedRamBytes = [UInt64]$cs.TotalPhysicalMemory
    }

    $usableRamBytes = [UInt64]$cs.TotalPhysicalMemory

    # Remove nomes vazios e repetidos da lista de controladores de vídeo.
    $gpuNames = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -and $_.Name.Trim() -ne '' } |
        Select-Object -ExpandProperty Name -Unique

    # Mantém a lista preenchida mesmo quando nenhuma GPU pode ser consultada.
    if (-not $gpuNames -or @($gpuNames).Count -eq 0) {
        $gpuNames = @('Nenhuma GPU encontrada')
    }

    # Monta o modelo da placa-mãe somente com as partes fornecidas pelo Windows.
    $boardParts = @()
    if (-not [string]::IsNullOrWhiteSpace($bb.Manufacturer)) { $boardParts += $bb.Manufacturer.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($bb.Product))      { $boardParts += $bb.Product.Trim() }

    $boardModel = if ($boardParts.Count -gt 0) { ($boardParts -join ' ') } else { '-' }

    # Ordena os discos físicos pelo número que o Windows atribuiu a cada unidade.
    $diskList = @()
    $wmiDisks = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Sort-Object Index

    foreach ($d in $wmiDisks) {
        # Percorre as associações CIM: disco físico -> partições -> volumes.
        # Uma associação indisponível não impede a exibição do restante do disco.
        $partitions = @()
        try {
            $partitions = Get-CimAssociatedInstance -InputObject $d -Association Win32_DiskDriveToDiskPartition -ErrorAction SilentlyContinue
        } catch {}

        $logicalLetters = @()
        foreach ($partition in $partitions) {
            try {
                $volumes = Get-CimAssociatedInstance -InputObject $partition -Association Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue
                foreach ($vol in $volumes) {
                    if ($vol.DeviceID) { $logicalLetters += $vol.DeviceID }
                }
            } catch {}
        }

        # Converte os dados brutos em campos prontos para os cartões do painel.
        # Volumes repetidos são removidos antes de juntar suas letras em texto.
        $diskList += [PSCustomObject]@{
            Numero      = $d.Index
            Nome        = Safe-Text $d.Model
            Interface   = Safe-Text $d.InterfaceType
            Tamanho     = if ($d.Size) { Format-Bytes ([UInt64]$d.Size) } else { '-' }
            Serial      = Normalize-Serial $d.SerialNumber
            Particoes   = @($partitions).Count
            Volumes     = if ($logicalLetters.Count -gt 0) { ($logicalLetters | Select-Object -Unique) -join ', ' } else { '-' }
        }
    }

    # Contrato de hardware enviado ao frontend. Os nomes das propriedades são
    # consumidos pela interface; GPUs e Discos permanecem arrays, mesmo com um item.
    return [PSCustomObject]@{
        CPU                = Safe-Text $cpu.Name
        RAMInstalada       = Format-Bytes-RAM $installedRamBytes
        RAMUtilizavel      = Format-Bytes-RAM $usableRamBytes
        RAMExibicao        = "$(Format-Bytes-RAM $installedRamBytes) ($(Format-Bytes-RAM $usableRamBytes) utilizavel)"
        BoardModel         = Safe-Text $boardModel
        BoardSerial        = Normalize-Serial $bb.SerialNumber
        BIOSVersion        = Safe-Text $bios.SMBIOSBIOSVersion
        BIOSManufacturer   = Safe-Text $bios.Manufacturer
        SistemaOperacional = Safe-Text $os.Caption
        VersaoSO           = Safe-Text $os.Version
        BuildSO            = Safe-Text $os.BuildNumber
        GPUs               = @($gpuNames)
        Discos             = @($diskList)
    }
}



# ============================================================================
# 4. IDENTIFICADORES DE HARDWARE E INVENTÁRIO DOS DRIVERS
# ============================================================================

# Obtém os IDs usados para identificar o hardware e procurar drivers. Prioriza
# a entidade CIM já consultada e recorre ao módulo PnpDevice somente se preciso.
function Get-DeviceHardwareIds {
    param(
        [string]$InstanceId,
        $Entity = $null
    )

    # A lista tipada acumula somente identificadores não vazios.
    $values = New-Object System.Collections.Generic.List[string]

    try {
        if ($Entity -and $Entity.PSObject.Properties['HardwareID'] -and $Entity.HardwareID) {
            foreach ($id in @($Entity.HardwareID)) {
                $text = Safe-Text $id
                if ($text -ne '-') { $values.Add($text) }
            }
        }
    } catch {}

    # Alternativa para máquinas em que Win32_PnPEntity não trouxe HardwareID.
    if ($values.Count -eq 0) {
        try {
            $props = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
            foreach ($prop in @($props)) {
                foreach ($item in @($prop.Data)) {
                    $text = Safe-Text $item
                    if ($text -ne '-') { $values.Add($text) }
                }
            }
        } catch {}
    }

    # Remove duplicatas e devolve a coleção normalizada ao inventário.
    return @($values | Select-Object -Unique)
}

# Cruza dispositivos presentes, drivers assinados e entidades CIM pelo ID de
# instância. O resultado preserva metadados técnicos e os critérios de alerta UI.
function Get-DriverInventory {
    $driverIndex = @{}
    $entityIndex = @{}
    $items = @()

    # Índice de drivers: permite localizar os metadados sem repetir a consulta
    # Win32_PnPSignedDriver para cada dispositivo.
    try {
        $signedDrivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue
        foreach ($drv in $signedDrivers) {
            $key = Safe-Text $drv.DeviceID
            if ($key -ne '-') {
                $driverIndex[$key] = $drv
            }
        }
    } catch {}

    # Índice complementar de entidades: fabricante, classe e código de problema.
    try {
        $entities = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue
        foreach ($ent in $entities) {
            $key = Safe-Text $ent.PNPDeviceID
            if ($key -ne '-') {
                $entityIndex[$key] = $ent
            }
        }
    } catch {}

    # PnpDevice é a fonte principal e restringe a consulta a dispositivos
    # presentes. Se o comando falhar, a consulta CIM abaixo mantém a compatibilidade.
    $devices = @()

    try {
        $devices = Get-PnpDevice -PresentOnly -ErrorAction Stop
    }
    catch {
        try {
            # Adapta os campos CIM para os mesmos nomes usados no restante do
            # fluxo. Essa alternativa utiliza as entidades retornadas pelo CIM.
            $devices = Get-CimInstance Win32_PnPEntity -ErrorAction Stop | ForEach-Object {
                [PSCustomObject]@{
                    Class        = $_.PNPClass
                    FriendlyName = $_.Name
                    Name         = $_.Name
                    InstanceId   = $_.PNPDeviceID
                    Status       = if ($_.ConfigManagerErrorCode -eq 0) { 'OK' } else { "Erro ($($_.ConfigManagerErrorCode))" }
                    Present      = $true
                    Problem      = $_.ConfigManagerErrorCode
                }
            }
        }
        catch {
            $devices = @()
        }
    }

    foreach ($dev in $devices) {
        # Une as três fontes pelo InstanceId, mantendo nulos quando uma delas
        # não contiver informações para este dispositivo.
        $instanceId = Safe-Text $dev.InstanceId
        $drv = $null
        $entity = $null

        if ($driverIndex.ContainsKey($instanceId)) {
            $drv = $driverIndex[$instanceId]
        }

        if ($entityIndex.ContainsKey($instanceId)) {
            $entity = $entityIndex[$instanceId]
        }

        # Escolhe o nome mais legível disponível e usa o ID como último recurso.
        $name = Safe-Text $dev.FriendlyName
        if ($name -eq '-') { $name = Safe-Text $dev.Name }
        if ($name -eq '-') { $name = $instanceId }

        # Valores padrão mantêm os campos estáveis quando não há driver assinado
        # correspondente ou quando algum metadado não foi fornecido pelo Windows.
        $manufacturer = '-'
        $provider     = '-'
        $version      = '-'
        $date         = '-'
        $inf          = '-'
        $signer       = '-'
        $signed       = '-'
        $service      = '-'

        # Preenche os detalhes do driver e normaliza a indicação de assinatura.
        if ($drv) {
            $manufacturer = Safe-Text $drv.Manufacturer
            $provider     = Safe-Text $drv.DriverProviderName
            $version      = Safe-Text $drv.DriverVersion
            $date         = Format-DriverDate $drv.DriverDate
            $inf          = Safe-Text $drv.InfName
            $signer       = Safe-Text $drv.Signer
            $service      = Safe-Text $drv.Service

            if ($null -ne $drv.IsSigned) {
                try {
                    $signed = if ([bool]$drv.IsSigned) { 'Sim' } else { 'Nao' }
                } catch {
                    $signed = Safe-Text $drv.IsSigned
                }
            }
        }

        # A entidade CIM pode fornecer o fabricante ausente no driver assinado.
        if ($manufacturer -eq '-' -and $entity) {
            $manufacturer = Safe-Text $entity.Manufacturer
        }

        # Primeiro usa o código da entidade; um código positivo de PnpDevice
        # complementa a leitura quando o primeiro resultado permanece em zero.
        $problemCode = 0

        try {
            if ($entity -and $null -ne $entity.ConfigManagerErrorCode) {
                $problemCode = [int]$entity.ConfigManagerErrorCode
            }
        } catch {}

        try {
            if ($problemCode -eq 0 -and $dev.PSObject.Properties['Problem'] -and $null -ne $dev.Problem) {
                $tmpProblem = [int]$dev.Problem
                if ($tmpProblem -gt 0) {
                    $problemCode = $tmpProblem
                }
            }
        } catch {}

        # Usa o status da entidade somente quando o dispositivo não o informou.
        $status = Safe-Text $dev.Status
        if ($status -eq '-' -and $entity) {
            $status = Safe-Text $entity.Status
        }

        # Um código positivo ou um status diferente de OK caracteriza problema.
        # O marcador de ausência "-" sozinho não cria alerta.
        $hasProblem = $false
        if ($problemCode -gt 0) {
            $hasProblem = $true
        }
        elseif ($status -ne '-' -and $status.ToUpperInvariant() -ne 'OK') {
            $hasProblem = $true
        }

        # Descobre a classe, traduz a categoria e aplica as exceções de alerta.
        $classCode = Safe-Text $dev.Class
        if ($classCode -eq '-' -and $entity) {
            $classCode = Safe-Text $entity.PNPClass
        }

        $category = Get-ClassDisplayName $classCode
        $ignoreProblem = Is-IgnoredProblemDevice -Category $category -CategoryCode $classCode -DeviceName $name
        # Mantém os IDs como array e também como texto com uma linha por ID para
        # os detalhes do dispositivo e as ações de cópia na interface.
        $hardwareIds = @(Get-DeviceHardwareIds -InstanceId $instanceId -Entity $entity)
        $hardwareIdsText = if ($hardwareIds.Count -gt 0) { $hardwareIds -join "`r`n" } else { '-' }

        # Contrato de cada driver. HasProblem guarda o diagnóstico bruto;
        # HasProblemUI aplica IgnoreProblem e é usado nas contagens do painel.
        $items += [PSCustomObject]@{
            Category            = $category
            CategoryCode        = $classCode
            DeviceName          = $name
            Manufacturer        = $manufacturer
            Provider            = $provider
            DriverVersion       = $version
            DriverDate          = $date
            InfName             = $inf
            Signer              = $signer
            Signed              = $signed
            Service             = $service
            Status              = $status
            Present             = Safe-Text $dev.Present
            InstanceId          = $instanceId
            HasProblem          = $hasProblem
            IgnoreProblem       = $ignoreProblem
            HasProblemUI        = ($hasProblem -and -not $ignoreProblem)
            ProblemCode         = $problemCode
            ProblemDescription  = Get-ProblemDescription $problemCode
            HardwareIds         = $hardwareIds
            HardwareIdsText     = $hardwareIdsText
        }
    }

    # A ordenação mantém as categorias e seus dispositivos previsíveis no JSON.
    return $items | Sort-Object Category, DeviceName
}

# ============================================================================
# 5. AGREGAÇÃO E CONTRATO DO JSON
# ============================================================================

# Executa as duas coletas e produz um único objeto para a interface. Os nomes
# abaixo fazem parte do contrato esperado pelo painel e pelo processo chamador.
function Build-Payload {
    $hardware = Get-HardwareData
    $drivers = @(Get-DriverInventory)

    # As contagens seguem os alertas visíveis, incluindo as exceções de mouse,
    # teclado e hipervisor. @() mantém o uso de Count estável com zero ou um item.
    $problemDrivers = @($drivers | Where-Object { $_.HasProblemUI })
    $driversOk = @($drivers | Where-Object { -not $_.HasProblemUI })
    # Cada categoria informa total de dispositivos e quantidade de alertas UI.
    $categories = @($drivers | Group-Object Category | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            Count = $_.Count
            ProblemCount = @($_.Group | Where-Object { $_.HasProblemUI }).Count
        }
    })

    # GeneratedAt usa a data/hora local do computador que executa a coleta.
    # TotalGPUs e TotalDiscos refletem as listas produzidas em Get-HardwareData.
    return [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Summary = [PSCustomObject]@{
            TotalDrivers        = $drivers.Count
            DriversComProblema  = $problemDrivers.Count
            DriversSemProblema  = $driversOk.Count
            TotalGPUs           = @($hardware.GPUs).Count
            TotalDiscos         = @($hardware.Discos).Count
        }
        Hardware = $hardware
        Categories = $categories
        Drivers = $drivers
    }
}

# ============================================================================
# 6. EXECUÇÃO, GRAVAÇÃO E RESPOSTA EM CASO DE FALHA
# ============================================================================

try {
    # Profundidade 8 preserva os objetos e arrays aninhados do diagnóstico.
    $payload = Build-Payload
    $json = $payload | ConvertTo-Json -Depth 8

    # Sem caminho, entrega o JSON diretamente a quem chamou o script.
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $json
    }
    else {
        # Cria a pasta de destino quando necessário e grava o arquivo em UTF-8.
        # A saída contém o caminho salvo, permitindo ao chamador localizar o JSON.
        $folder = Split-Path -Parent $OutputPath
        if ($folder -and -not (Test-Path $folder)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }

        Set-Content -Path $OutputPath -Value $json -Encoding UTF8
        Write-Output $OutputPath
    }
}
catch {
    # Converte falhas não tratadas em um objeto JSON reconhecível pelo painel.
    $err = [PSCustomObject]@{
        Error = $true
        Message = $_.Exception.Message
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    $json = $err | ConvertTo-Json -Depth 4

    # Mantém os mesmos modos de saída. Na gravação de erro, o código de saída 1
    # sinaliza falha ao processo chamador; o modo de saída padrão devolve o JSON.
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $json
    }
    else {
        Set-Content -Path $OutputPath -Value $json -Encoding UTF8
        exit 1
    }
}
