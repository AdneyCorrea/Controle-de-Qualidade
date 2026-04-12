param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = 'Stop'

function Safe-Text {
    param($Value)

    if ($null -eq $Value) { return '-' }

    $text = "$Value"
    $text = $text -replace "`0", ''
    $text = $text.Trim()

    if ([string]::IsNullOrWhiteSpace($text)) { return '-' }
    return $text
}

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

function Format-Bytes {
    param([UInt64]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    elseif ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    elseif ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    elseif ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    else { return "$Bytes B" }
}

function Format-Bytes-RAM {
    param([UInt64]$Bytes)

    return ('{0:N1} GB' -f ($Bytes / 1GB))
}

function Format-DriverDate {
    param($Value)

    if ($null -eq $Value) { return '-' }

    try {
        if ($Value -is [datetime]) {
            return $Value.ToString('dd/MM/yyyy')
        }
    } catch {}

    try {
        return ([System.Management.ManagementDateTimeConverter]::ToDateTime("$Value")).ToString('dd/MM/yyyy')
    } catch {}

    try {
        return ([datetime]$Value).ToString('dd/MM/yyyy')
    } catch {}

    return Safe-Text $Value
}

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

function Is-IgnoredProblemDevice {
    param(
        [string]$Category,
        [string]$CategoryCode,
        [string]$DeviceName
    )

    $cat  = (Safe-Text $Category).ToLowerInvariant()
    $code = (Safe-Text $CategoryCode).ToLowerInvariant()
    $name = (Safe-Text $DeviceName).ToLowerInvariant()

    if ($cat -eq 'mouse e apontadores') { return $true }
    if ($cat -eq 'teclados') { return $true }
    if ($code -eq 'mouse') { return $true }
    if ($code -eq 'keyboard') { return $true }
    if ($name -match 'mouse') { return $true }
    if ($name -match 'keyboard') { return $true }
    if ($name -match 'teclado') { return $true }

    return $false
}

function Get-HardwareData {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $bb  = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1

    $installedRamBytes = 0
    try {
        $memModules = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
        foreach ($m in $memModules) {
            if ($m.Capacity) {
                $installedRamBytes += [UInt64]$m.Capacity
            }
        }
    } catch {}

    if ($installedRamBytes -le 0) {
        $installedRamBytes = [UInt64]$cs.TotalPhysicalMemory
    }

    $usableRamBytes = [UInt64]$cs.TotalPhysicalMemory

    $gpuNames = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -and $_.Name.Trim() -ne '' } |
        Select-Object -ExpandProperty Name -Unique

    if (-not $gpuNames -or @($gpuNames).Count -eq 0) {
        $gpuNames = @('Nenhuma GPU encontrada')
    }

    $boardParts = @()
    if (-not [string]::IsNullOrWhiteSpace($bb.Manufacturer)) { $boardParts += $bb.Manufacturer.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($bb.Product))      { $boardParts += $bb.Product.Trim() }

    $boardModel = if ($boardParts.Count -gt 0) { ($boardParts -join ' ') } else { '-' }

    $diskList = @()
    $wmiDisks = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Sort-Object Index

    foreach ($d in $wmiDisks) {
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



function Get-DeviceHardwareIds {
    param(
        [string]$InstanceId,
        $Entity = $null
    )

    $values = New-Object System.Collections.Generic.List[string]

    try {
        if ($Entity -and $Entity.PSObject.Properties['HardwareID'] -and $Entity.HardwareID) {
            foreach ($id in @($Entity.HardwareID)) {
                $text = Safe-Text $id
                if ($text -ne '-') { $values.Add($text) }
            }
        }
    } catch {}

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

    return @($values | Select-Object -Unique)
}

function Get-DriverInventory {
    $driverIndex = @{}
    $entityIndex = @{}
    $items = @()

    try {
        $signedDrivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue
        foreach ($drv in $signedDrivers) {
            $key = Safe-Text $drv.DeviceID
            if ($key -ne '-') {
                $driverIndex[$key] = $drv
            }
        }
    } catch {}

    try {
        $entities = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue
        foreach ($ent in $entities) {
            $key = Safe-Text $ent.PNPDeviceID
            if ($key -ne '-') {
                $entityIndex[$key] = $ent
            }
        }
    } catch {}

    $devices = @()

    try {
        $devices = Get-PnpDevice -PresentOnly -ErrorAction Stop
    }
    catch {
        try {
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
        $instanceId = Safe-Text $dev.InstanceId
        $drv = $null
        $entity = $null

        if ($driverIndex.ContainsKey($instanceId)) {
            $drv = $driverIndex[$instanceId]
        }

        if ($entityIndex.ContainsKey($instanceId)) {
            $entity = $entityIndex[$instanceId]
        }

        $name = Safe-Text $dev.FriendlyName
        if ($name -eq '-') { $name = Safe-Text $dev.Name }
        if ($name -eq '-') { $name = $instanceId }

        $manufacturer = '-'
        $provider     = '-'
        $version      = '-'
        $date         = '-'
        $inf          = '-'
        $signer       = '-'
        $signed       = '-'
        $service      = '-'

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

        if ($manufacturer -eq '-' -and $entity) {
            $manufacturer = Safe-Text $entity.Manufacturer
        }

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

        $status = Safe-Text $dev.Status
        if ($status -eq '-' -and $entity) {
            $status = Safe-Text $entity.Status
        }

        $hasProblem = $false
        if ($problemCode -gt 0) {
            $hasProblem = $true
        }
        elseif ($status -ne '-' -and $status.ToUpperInvariant() -ne 'OK') {
            $hasProblem = $true
        }

        $classCode = Safe-Text $dev.Class
        if ($classCode -eq '-' -and $entity) {
            $classCode = Safe-Text $entity.PNPClass
        }

        $category = Get-ClassDisplayName $classCode
        $ignoreProblem = Is-IgnoredProblemDevice -Category $category -CategoryCode $classCode -DeviceName $name
        $hardwareIds = @(Get-DeviceHardwareIds -InstanceId $instanceId -Entity $entity)
        $hardwareIdsText = if ($hardwareIds.Count -gt 0) { $hardwareIds -join "`r`n" } else { '-' }

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

    return $items | Sort-Object Category, DeviceName
}

function Build-Payload {
    $hardware = Get-HardwareData
    $drivers = @(Get-DriverInventory)

    $problemDrivers = @($drivers | Where-Object { $_.HasProblemUI })
    $driversOk = @($drivers | Where-Object { -not $_.HasProblemUI })
    $categories = @($drivers | Group-Object Category | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            Count = $_.Count
            ProblemCount = @($_.Group | Where-Object { $_.HasProblemUI }).Count
        }
    })

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

try {
    $payload = Build-Payload
    $json = $payload | ConvertTo-Json -Depth 8

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $json
    }
    else {
        $folder = Split-Path -Parent $OutputPath
        if ($folder -and -not (Test-Path $folder)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }

        Set-Content -Path $OutputPath -Value $json -Encoding UTF8
        Write-Output $OutputPath
    }
}
catch {
    $err = [PSCustomObject]@{
        Error = $true
        Message = $_.Exception.Message
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    $json = $err | ConvertTo-Json -Depth 4

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $json
    }
    else {
        Set-Content -Path $OutputPath -Value $json -Encoding UTF8
        exit 1
    }
}
