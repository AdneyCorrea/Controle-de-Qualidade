#Requires -RunAsAdministrator
$ErrorActionPreference = 'Continue'

function Get-DriverRepositoryPath {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        if ($PSScriptRoot) {
            $scriptDrive = [System.IO.Path]::GetPathRoot($PSScriptRoot)
            if (-not [string]::IsNullOrWhiteSpace($scriptDrive)) {
                $candidates.Add((Join-Path $scriptDrive 'DriversRepo'))
            }

            $candidates.Add((Join-Path $PSScriptRoot 'DriversRepo'))

            $parent = Split-Path -Path $PSScriptRoot -Parent
            if ($parent) {
                $candidates.Add((Join-Path $parent 'DriversRepo'))
            }
        }
    }
    catch {}

    try {
        Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveType -eq 2 } |
            ForEach-Object {
                $candidates.Add((Join-Path $_.DeviceID 'DriversRepo'))
            }
    }
    catch {}

    try {
        Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveType -in 3,4,5 } |
            ForEach-Object {
                $candidates.Add((Join-Path $_.DeviceID 'DriversRepo'))
            }
    }
    catch {}

    foreach ($letter in 'D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z','C') {
        $candidates.Add("$letter`:\DriversRepo")
    }

    foreach ($path in ($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    return $null
}

$DriverRepository = Get-DriverRepositoryPath

if (-not $DriverRepository) {
    Write-Host "Repositorio nao encontrado: DriversRepo" -ForegroundColor Red
    exit 1
}

$LogFolder = Join-Path $DriverRepository "_Logs"

if (-not (Test-Path -LiteralPath $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

$LogFile = Join-Path $LogFolder ("InstalarDrivers_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

function Write-Info { param([string]$t) Write-Host $t -ForegroundColor Cyan }
function Write-Ok   { param([string]$t) Write-Host $t -ForegroundColor Green }
function Write-Warn { param([string]$t) Write-Host $t -ForegroundColor Yellow }
function Write-Err  { param([string]$t) Write-Host $t -ForegroundColor Red }

function Add-Log {
    param([string]$Text)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    $line | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Test-IsMicrosoftBasicDisplayAdapter {
    param(
        [string]$Name,
        [string]$Service = "",
        [string]$Manufacturer = "",
        [string]$DriverProvider = ""
    )

    $all = @($Name,$Service,$Manufacturer,$DriverProvider) -join ' '
    if ([string]::IsNullOrWhiteSpace($all)) { return $false }

    $t = $all.ToLowerInvariant()

    return (
        $t -match 'microsoft basic display' -or
        $t -match 'adaptador de vídeo básico da microsoft' -or
        $t -match 'adaptador de video basico da microsoft' -or
        $t -match 'adaptador básico da microsoft' -or
        $t -match 'adaptador basico da microsoft' -or
        $t -match 'adaptador padrão da microsoft' -or
        $t -match 'adaptador padrao da microsoft' -or
        $t -match 'basicdisplay' -or
        $t -match 'basic render'
    )
}

function Get-ContentSafe {
    param([string]$Path)

    try { return Get-Content -LiteralPath $Path -Raw -Encoding Default -ErrorAction Stop } catch {}
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop } catch {}
    try { return Get-Content -LiteralPath $Path -Raw -Encoding Unicode -ErrorAction Stop } catch {}
    return ""
}

function Get-DevicePropertyValue {
    param(
        [string]$InstanceId,
        [string]$KeyName
    )

    try {
        $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop
        if ($null -ne $p.Data) {
            if ($p.Data -is [System.Array]) {
                return @($p.Data | ForEach-Object { $_.ToString() })
            }
            return $p.Data.ToString()
        }
    }
    catch {}

    return $null
}

function Get-HardwareIds {
    param([string]$InstanceId)

    try {
        $prop = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop

        if ($prop.Data -is [System.Array]) {
            return @(
                $prop.Data |
                Where-Object { $_ } |
                ForEach-Object { $_.ToString().ToUpperInvariant().Trim() } |
                Select-Object -Unique
            )
        }
        elseif ($prop.Data) {
            return @($prop.Data.ToString().ToUpperInvariant().Trim())
        }
    }
    catch {}

    return @()
}

function Get-CompatibleIds {
    param([string]$InstanceId)

    try {
        $prop = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_CompatibleIds' -ErrorAction Stop

        if ($prop.Data -is [System.Array]) {
            return @(
                $prop.Data |
                Where-Object { $_ } |
                ForEach-Object { $_.ToString().ToUpperInvariant().Trim() } |
                Select-Object -Unique
            )
        }
        elseif ($prop.Data) {
            return @($prop.Data.ToString().ToUpperInvariant().Trim())
        }
    }
    catch {}

    return @()
}

function Get-AllInfFiles {
    param([string]$Root)

    try {
        return @(Get-ChildItem -Path $Root -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue)
    }
    catch {
        return @()
    }
}

function Get-InfClass {
    param([string]$InfPath)

    $content = Get-ContentSafe -Path $InfPath
    if ([string]::IsNullOrWhiteSpace($content)) { return "" }

    $m = [regex]::Match($content, '(?im)^\s*Class\s*=\s*(.+?)\s*$')
    if ($m.Success) {
        return $m.Groups[1].Value.Trim()
    }

    return ""
}

function Test-InfClassCompatible {
    param(
        [string]$DeviceClass,
        [string]$InfClass
    )

    if ([string]::IsNullOrWhiteSpace($DeviceClass)) { return $true }
    if ([string]::IsNullOrWhiteSpace($InfClass))    { return $true }

    $dc = $DeviceClass.Trim().ToUpperInvariant()
    $ic = $InfClass.Trim().ToUpperInvariant()

    if ($dc -eq $ic) { return $true }
    if ($dc -eq 'DISPLAY' -and $ic -eq 'DISPLAY') { return $true }

    return $false
}

function Expand-HardwareIdCandidates {
    param([string[]]$HardwareIds)

    $out = @()

    foreach ($id in $HardwareIds) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $u = $id.ToUpperInvariant().Trim()

        if ($out -notcontains $u) {
            $out += $u
        }

        if ($u -match '^(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}&SUBSYS_[0-9A-F]{8})&REV_[0-9A-F]{2}$') {
            $v = $Matches[1]
            if ($out -notcontains $v) { $out += $v }
        }

        if ($u -match '^(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})(&SUBSYS_[0-9A-F]{8})?(&REV_[0-9A-F]{2})?$') {
            $v = $Matches[1]
            if ($out -notcontains $v) { $out += $v }
        }

        if ($u -match '^PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}&CC_[0-9A-F]{4,6}$') {
            if ($out -notcontains $u) { $out += $u }
        }
    }

    return @($out)
}

function Find-InfMatchesByHardwareId {
    param(
        [string[]]$HardwareIds,
        [string]$Root,
        [string]$PreferredClass = ""
    )

    $candidateIds = @(Expand-HardwareIdCandidates -HardwareIds $HardwareIds)
    $allInfs = @(Get-AllInfFiles -Root $Root)
    $results = @()

    foreach ($inf in $allInfs) {
        $content = Get-ContentSafe -Path $inf.FullName
        if ([string]::IsNullOrWhiteSpace($content)) { continue }

        $upper = $content.ToUpperInvariant()
        $infClass = Get-InfClass -InfPath $inf.FullName

        if (-not [string]::IsNullOrWhiteSpace($PreferredClass)) {
            if (-not (Test-InfClassCompatible -DeviceClass $PreferredClass -InfClass $infClass)) {
                continue
            }
        }

        for ($i = 0; $i -lt $candidateIds.Count; $i++) {
            $id = $candidateIds[$i]
            $escaped = [regex]::Escape($id)

            if ($upper -match $escaped) {
                $results += [PSCustomObject]@{
                    Path     = $inf.FullName
                    MatchId  = $id
                    Score    = $i
                    InfClass = $infClass
                }
                break
            }
        }
    }

    return @(
        $results |
        Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.Path) } |
        Sort-Object Score, Path -Unique
    )
}

function Install-DriverInf {
    param([string]$InfPath)

    if ([string]::IsNullOrWhiteSpace($InfPath)) {
        Add-Log "INF vazio ignorado"
        return 1
    }

    Add-Log "Tentando instalar INF: $InfPath"

    try {
        pnputil /add-driver "$InfPath" /install | Out-Null
        $rc = $LASTEXITCODE
    }
    catch {
        $rc = 1
    }

    Add-Log "Retorno pnputil: $rc | $InfPath"
    return $rc
}

function Install-DismFolder {
    param([string]$Folder)

    if ([string]::IsNullOrWhiteSpace($Folder)) { return 1 }
    if (-not (Test-Path -LiteralPath $Folder)) { return 1 }

    Add-Log "Executando DISM na pasta: $Folder"

    try {
        dism /online /add-driver /driver:"$Folder" /recurse | Out-Null
        $rc = $LASTEXITCODE
    }
    catch {
        $rc = 1
    }

    Add-Log "Retorno DISM: $rc | $Folder"
    return $rc
}

function Start-ExeFallbackInstall {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) { return $false }

    $executables = @(
        Get-ChildItem -Path $Root -Recurse -File -Include *.exe -ErrorAction SilentlyContinue
    )

    if ($executables.Count -eq 0) {
        Add-Log "Nenhum EXE encontrado para fallback em: $Root"
        return $false
    }

    foreach ($exe in $executables) {
        $argSets = @(
            "/s",
            "/silent",
            "/S",
            "/quiet",
            "/qn",
            "/passive",
            "-s",
            ""
        )

        foreach ($args in $argSets) {
            Add-Log ("Tentando EXE fallback: {0} | Args: {1}" -f $exe.FullName, $args)

            try {
                if ([string]::IsNullOrWhiteSpace($args)) {
                    $p = Start-Process -FilePath $exe.FullName -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                }
                else {
                    $p = Start-Process -FilePath $exe.FullName -ArgumentList $args -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                }

                Add-Log ("EXE retorno: {0} | {1}" -f $p.ExitCode, $exe.FullName)

                if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
                    return $true
                }
            }
            catch {
                Add-Log ("Falha ao executar EXE: {0} | {1}" -f $exe.FullName, $_.Exception.Message)
            }
        }
    }

    return $false
}

function Refresh-Devices {
    Add-Log "Executando pnputil /scan-devices"
    try { pnputil /scan-devices | Out-Null } catch {}
    Start-Sleep -Seconds 3
}

function Update-DeviceNow {
    param([string]$InstanceId)

    try {
        $cmd = Get-Command Update-PnpDevice -ErrorAction SilentlyContinue
        if ($cmd) {
            Update-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
            Add-Log "Update-PnpDevice OK: $InstanceId"
        }
    }
    catch {
        Add-Log "Falha Update-PnpDevice: $InstanceId"
    }
}

function Get-DisplayClassDevices {
    $items = @()

    try {
        $items += @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
            $_.PNPClass -eq 'Display' -or
            $_.ClassGuid -eq '{4d36e968-e325-11ce-bfc1-08002be10318}' -or
            $_.Name -match 'display|video|vga|microsoft basic'
        })
    }
    catch {}

    try {
        $video = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
        foreach ($v in $video) {
            if ($v.PNPDeviceID) {
                $items += [PSCustomObject]@{
                    Name                   = $v.Name
                    PNPDeviceID            = $v.PNPDeviceID
                    PNPClass               = 'Display'
                    ClassGuid              = '{4d36e968-e325-11ce-bfc1-08002be10318}'
                    ConfigManagerErrorCode = 0
                }
            }
        }
    }
    catch {}

    return @(
        $items |
        Where-Object { $_ -and $_.PNPDeviceID } |
        Sort-Object PNPDeviceID -Unique
    )
}

function Get-InstalledDisplayDriverInfo {
    param([string]$InstanceId)

    $service       = Get-DevicePropertyValue -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Service'
    $mfg           = Get-DevicePropertyValue -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Manufacturer'
    $provider      = Get-DevicePropertyValue -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_DriverProvider'
    $driverDesc    = Get-DevicePropertyValue -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_DriverDesc'
    $driverVersion = Get-DevicePropertyValue -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_DriverVersion'

    [PSCustomObject]@{
        Service        = $service
        Manufacturer   = $mfg
        DriverProvider = $provider
        DriverDesc     = $driverDesc
        DriverVersion  = $driverVersion
    }
}

function Get-GpuVendorFromHardwareIds {
    param([string[]]$HardwareIds)

    foreach ($id in $HardwareIds) {
        $u = $id.ToUpperInvariant()

        if ($u -match 'VEN_10DE') { return 'NVIDIA' }
        if ($u -match 'VEN_1002') { return 'AMD' }
        if ($u -match 'VEN_1022') { return 'AMD' }
        if ($u -match 'VEN_8086') { return 'INTEL' }
    }

    return ''
}

function Get-GpuProblemTargets {
    $targets = @()
    $displayDevices = @(Get-DisplayClassDevices)

    foreach ($gpu in $displayDevices) {
        $name = [string]$gpu.Name
        $id   = [string]$gpu.PNPDeviceID
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $err = 0
        try { $err = [int]$gpu.ConfigManagerErrorCode } catch { $err = 0 }

        $hardwareIds   = @(Get-HardwareIds -InstanceId $id)
        $compatibleIds = @(Get-CompatibleIds -InstanceId $id)
        $drv           = Get-InstalledDisplayDriverInfo -InstanceId $id

        $isBasic = Test-IsMicrosoftBasicDisplayAdapter `
            -Name $name `
            -Service $drv.Service `
            -Manufacturer $drv.Manufacturer `
            -DriverProvider $drv.DriverProvider

        $vendor = Get-GpuVendorFromHardwareIds -HardwareIds $hardwareIds

        $isProblem = $false
        if ($isBasic) { $isProblem = $true }
        if ($err -ne 0) { $isProblem = $true }

        Add-Log ("GPU detectada: Name={0} | Id={1} | Error={2} | Basic={3} | Service={4} | Provider={5} | Mfg={6} | Desc={7} | Ver={8}" -f `
            $name, $id, $err, $isBasic, $drv.Service, $drv.DriverProvider, $drv.Manufacturer, $drv.DriverDesc, $drv.DriverVersion)

        if ($isProblem) {
            $targets += [PSCustomObject]@{
                Name           = $name
                Class          = 'Display'
                PNPDeviceID    = $id
                ErrorCode      = $err
                IsBasicDisplay = $isBasic
                HardwareIds    = $hardwareIds
                CompatibleIds  = $compatibleIds
                Vendor         = $vendor
                Service        = $drv.Service
                Manufacturer   = $drv.Manufacturer
                DriverProvider = $drv.DriverProvider
                DriverDesc     = $drv.DriverDesc
                DriverVersion  = $drv.DriverVersion
            }
        }
    }

    return @($targets | Sort-Object PNPDeviceID -Unique)
}

function Test-GpuStillMicrosoft {
    $displayDevices = @(Get-DisplayClassDevices)

    foreach ($gpu in $displayDevices) {
        $id = [string]$gpu.PNPDeviceID
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $drv = Get-InstalledDisplayDriverInfo -InstanceId $id

        $isBasic = Test-IsMicrosoftBasicDisplayAdapter `
            -Name ([string]$gpu.Name) `
            -Service $drv.Service `
            -Manufacturer $drv.Manufacturer `
            -DriverProvider $drv.DriverProvider

        if ($isBasic) {
            Add-Log ("GPU ainda em driver Microsoft: Name={0} | Id={1} | Service={2} | Provider={3} | Desc={4}" -f `
                $gpu.Name, $id, $drv.Service, $drv.DriverProvider, $drv.DriverDesc)
            return $true
        }
    }

    return $false
}

function Get-GpuSearchRoots {
    param([string]$Vendor)

    $roots = @()

    if (-not [string]::IsNullOrWhiteSpace($Vendor)) {
        $vendorPath = Join-Path $DriverRepository $Vendor
        if (Test-Path -LiteralPath $vendorPath) {
            $roots += $vendorPath
        }
    }

    if ($roots -notcontains $DriverRepository) {
        $roots += $DriverRepository
    }

    return @($roots | Select-Object -Unique)
}

function Resolve-GpuDrivers {
    $gpuTargets = @(Get-GpuProblemTargets)

    if ($gpuTargets.Count -eq 0) {
        Add-Log "Nenhuma GPU pendente encontrada."
        return $true
    }

    foreach ($gpu in $gpuTargets) {
        Write-Host ""
        Write-Info "Processando GPU: $($gpu.Name)"
        Add-Log ("Processando GPU: {0} | {1}" -f $gpu.Name, $gpu.PNPDeviceID)
        Add-Log ("Vendor detectado por HardwareID: {0}" -f $gpu.Vendor)
        Add-Log ("Hardware IDs GPU: {0}" -f (($gpu.HardwareIds -join " | ")))
        Add-Log ("Compatible IDs GPU: {0}" -f (($gpu.CompatibleIds -join " | ")))

        $searchRoots = @(Get-GpuSearchRoots -Vendor $gpu.Vendor)

        foreach ($root in $searchRoots) {
            Add-Log ("Pasta de busca GPU: {0}" -f $root)

            $allIds = @()
            $allIds += $gpu.HardwareIds
            $allIds += $gpu.CompatibleIds

            if ($gpu.HardwareIds.Count -gt 0) {
                foreach ($hid in $gpu.HardwareIds) {
                    if ($hid -match 'PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}') {
                        $allIds += $Matches[0]
                    }
                }
            }

            $allIds = @(
                $allIds |
                Where-Object { $_ } |
                ForEach-Object { $_.ToUpperInvariant().Trim() } |
                Select-Object -Unique
            )

            $candidateInfs = @(Find-InfMatchesByHardwareId -HardwareIds $allIds -Root $root -PreferredClass "Display")
            Add-Log ("Total de INF(s) GPU encontrados em {0}: {1}" -f $root, $candidateInfs.Count)

            foreach ($cand in $candidateInfs) {
                Add-Log ("GPU candidato: {0} | MatchId={1} | Score={2}" -f $cand.Path, $cand.MatchId, $cand.Score)

                $rc = Install-DriverInf -InfPath $cand.Path
                Start-Sleep -Seconds 3
                Refresh-Devices
                Update-DeviceNow -InstanceId $gpu.PNPDeviceID
                Start-Sleep -Seconds 4

                if (-not (Test-GpuStillMicrosoft)) {
                    Add-Log "GPU resolvida via INF"
                    return $true
                }
            }

            [void](Install-DismFolder -Folder $root)
            Start-Sleep -Seconds 4
            Refresh-Devices
            Update-DeviceNow -InstanceId $gpu.PNPDeviceID
            Start-Sleep -Seconds 4

            if (-not (Test-GpuStillMicrosoft)) {
                Add-Log "GPU resolvida via DISM"
                return $true
            }

            $exeOk = Start-ExeFallbackInstall -Root $root
            if ($exeOk) {
                Start-Sleep -Seconds 5
                Refresh-Devices
                Update-DeviceNow -InstanceId $gpu.PNPDeviceID
                Start-Sleep -Seconds 5

                if (-not (Test-GpuStillMicrosoft)) {
                    Add-Log "GPU resolvida via EXE fallback"
                    return $true
                }
            }
        }
    }

    Add-Log "GPU ainda permanece com adaptador Microsoft."
    return $false
}

function Get-OtherTargets {
    $result = @()

    try {
        $devices = Get-CimInstance Win32_PnPEntity
    }
    catch {
        Add-Log "Falha ao enumerar Win32_PnPEntity"
        return @()
    }

    foreach ($dev in $devices) {
        $name  = [string]$dev.Name
        $class = [string]$dev.PNPClass
        $id    = [string]$dev.PNPDeviceID
        $err   = 0

        try { $err = [int]$dev.ConfigManagerErrorCode } catch { $err = 0 }

        if ($class -ieq 'Keyboard' -or $class -ieq 'Mouse') {
            continue
        }

        if ($class -eq 'Display') {
            continue
        }

        if ($err -ne 0) {
            $result += [PSCustomObject]@{
                Name           = $name
                Class          = $class
                PNPDeviceID    = $id
                ErrorCode      = $err
                IsBasicDisplay = $false
                HardwareIds    = @(Get-HardwareIds -InstanceId $id)
            }
        }
    }

    return @($result)
}

if (-not (Test-Path -LiteralPath $DriverRepository)) {
    Write-Err "Repositorio nao encontrado: $DriverRepository"
    exit 1
}

Add-Log "Inicio da execucao"
Add-Log "Repositorio: $DriverRepository"

$gpuOk = Resolve-GpuDrivers
$otherTargets = @(Get-OtherTargets)

if ($otherTargets.Count -gt 0) {
    Write-Warn "Outros dispositivos pendentes:"
    foreach ($dev in $otherTargets) {
        Write-Host " - $($dev.Name)"
        Add-Log ("Pendente: {0} | Classe={1} | Erro={2}" -f $dev.Name, $dev.Class, $dev.ErrorCode)
    }

    foreach ($dev in $otherTargets) {
        Write-Host ""
        Write-Info "Processando: $($dev.Name)"
        Add-Log ("Processando dispositivo: {0} | {1}" -f $dev.Name, $dev.PNPDeviceID)

        if ($dev.HardwareIds.Count -eq 0) {
            Add-Log "Sem HardwareID"
            continue
        }

        $candidateInfs = @(Find-InfMatchesByHardwareId -HardwareIds $dev.HardwareIds -Root $DriverRepository)
        Add-Log ("Total de INF(s) encontrados: {0}" -f $candidateInfs.Count)

        foreach ($cand in $candidateInfs) {
            Add-Log ("Candidato: {0} | MatchId={1} | Score={2} | Class={3}" -f $cand.Path, $cand.MatchId, $cand.Score, $cand.InfClass)

            $rc = Install-DriverInf -InfPath $cand.Path

            if ($rc -eq 0) {
                Refresh-Devices
                Update-DeviceNow -InstanceId $dev.PNPDeviceID
                Start-Sleep -Seconds 3
                break
            }
        }
    }
}

Write-Host ""
if (Test-GpuStillMicrosoft) {
    Write-Warn "A GPU ainda permanece com Adaptador de Vídeo Básico/Padrão da Microsoft."
    Add-Log "GPU ainda permanece com adaptador Microsoft"
}
else {
    $gpuDetected = @(Get-DisplayClassDevices)
    if ($gpuDetected.Count -gt 0) {
        Write-Ok "GPU atualizada com sucesso."
        Add-Log "GPU atualizada com sucesso"
    }
    else {
        Write-Warn "Nenhuma GPU de display foi validada no final da execucao."
        Add-Log "Nenhuma GPU de display foi validada no final da execucao"
    }
}

Write-Ok "Processo concluido."
Write-Host "Log salvo em: $LogFile"
exit 0