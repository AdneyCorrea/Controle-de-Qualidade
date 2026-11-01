
<#
Atualizar Drivers.ps1 - V11.2 ESTAVEL / RAPIDO / VIDEO PRIMEIRO + REDE/WIFI PRIORITARIO
- Mantem a compatibilidade da V7/V9, mas tenta video antes de chipset.
- Para Intel Ultra: primeiro tenta INFs exatos rapidamente; se sobrar driver, cai no lote do Chipset Ultra.
- Evita testar INF NVIDIA problematica nvmdi.inf por padrao, pois gerava timeout.
- Adiciona fase prioritaria para Rede/WiFi, incluindo Intel, Realtek, Qualcomm/Atheros, MediaTek/Ralink e Broadcom.
#>
param(
    [switch]$ModoCompleto,
    [switch]$TodosErros,
    [switch]$ForcarLoteFabricante,
    [switch]$ForcarVideoLote,
    [switch]$UseDismFallback,
    [switch]$SemLoteUltra,
    [switch]$NaoPausar,
    [int]$BatchTimeoutSec = 360,
    [int]$InfTimeoutSec = 35,
    [int]$MaxCandidatesPerDevice = 2
)
$ErrorActionPreference='Continue'
try { [Console]::OutputEncoding=[Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle='Atualizar Drivers' } catch {}

# Corrige erro inicial quando o script e chamado de formas diferentes.
# Em alguns cenarios, $MyInvocation.MyCommand.Path vem nulo dentro de funcoes.
$script:ScriptDir = $null
try { if ($PSScriptRoot) { $script:ScriptDir = $PSScriptRoot } } catch {}
if (-not $script:ScriptDir) { try { if ($PSCommandPath) { $script:ScriptDir = Split-Path -Parent $PSCommandPath } } catch {} }
if (-not $script:ScriptDir) { try { $mp = $MyInvocation.MyCommand.Path; if ($mp) { $script:ScriptDir = Split-Path -Parent $mp } } catch {} }
if (-not $script:ScriptDir) { try { $script:ScriptDir = (Get-Location).Path } catch {} }

function IsAdmin {
    try {
        $id=[Security.Principal.WindowsIdentity]::GetCurrent()
        $p=New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
function FindRepo {
    $list=@()
    $sd=$script:ScriptDir
    if($sd){
        $list += (Join-Path $sd 'DriversRepo')
        try { $parent = Split-Path -Parent $sd; if($parent){ $list += (Join-Path $parent 'DriversRepo') } } catch {}
        try { $grandParent = Split-Path -Parent $parent; if($grandParent){ $list += (Join-Path $grandParent 'DriversRepo') } } catch {}
        try { $greatGrandParent = Split-Path -Parent $grandParent; if($greatGrandParent){ $list += (Join-Path $greatGrandParent 'DriversRepo') } } catch {}
    }
    $list += 'D:\DriversRepo','E:\DriversRepo','F:\DriversRepo','G:\DriversRepo','C:\DriversRepo'
    try { Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2 OR DriveType=3" | ForEach-Object { $list += (Join-Path ($_.DeviceID+'\') 'DriversRepo') } } catch {}
    foreach($p in ($list|Select-Object -Unique)){
        if($p -and (Test-Path -LiteralPath $p) -and ((Test-Path -LiteralPath (Join-Path $p 'INTEL')) -or (Test-Path -LiteralPath (Join-Path $p 'AMD')) -or (Test-Path -LiteralPath (Join-Path $p 'NVIDIA')))){
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
    return $null
}
$Repo=FindRepo
if(-not $Repo){
    $message = 'ERRO: DriversRepo nao encontrado. Coloque a pasta DriversRepo com os pacotes INTEL, AMD ou NVIDIA dentro de AtualizarDrivers, na pasta do projeto ou na raiz de um disco conectado.'
    Write-Host $message -ForegroundColor Red
    $diagnosticPath = Join-Path $script:ScriptDir 'AtualizarDrivers_erro.log'
    try {
        [IO.File]::WriteAllText($diagnosticPath, ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message), [Text.Encoding]::UTF8)
        Write-Host "Diagnostico salvo em: $diagnosticPath" -ForegroundColor Yellow
    } catch { Write-Warning "Nao foi possivel salvar o diagnostico: $($_.Exception.Message)" }
    exit 2
}
$LogDir=Join-Path $Repo '_Logs'; New-Item -ItemType Directory -Path $LogDir -Force|Out-Null
$Stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$Log=Join-Path $LogDir "AtualizarDrivers_$Stamp.log"
function L([string]$m,[ConsoleColor]$c=[ConsoleColor]::Gray){
    $line='[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m
    Add-Content -Path $Log -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $m -ForegroundColor $c
}

function Write-OemFile([string]$Path,[string]$Text){
    try{
        $cp=[Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        $enc=[Text.Encoding]::GetEncoding($cp)
        [IO.File]::WriteAllText($Path,$Text,$enc)
    } catch {
        # Fallback: evita ASCII, pois ASCII quebra caminhos como INTEL\4º.
        [IO.File]::WriteAllText($Path,$Text,[Text.Encoding]::Default)
    }
}
function RunCmd([string]$Command,[string]$Desc,[int]$Timeout=60){
    $id=[guid]::NewGuid().ToString('N')
    $bat=Join-Path $env:TEMP "drv_$id.cmd"
    $out=Join-Path $env:TEMP "drv_$id.out"
    $batText=@"
@echo off
>"$out" echo [CMD] $Command
$Command >>"$out" 2>&1
set RC=%ERRORLEVEL%
echo [RET] %RC% >>"$out"
exit /b %RC%
"@
    # IMPORTANTE: gravar o .cmd em OEM.
    # Antes estava em ASCII e isso quebrava pastas com caractere especial, ex.: D:\DriversRepo\INTEL\4º.
    Write-OemFile $bat $batText
    L "EXEC: $Desc" Cyan; L "CMD : $Command"
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$env:ComSpec; $psi.Arguments="/d /c `"$bat`""; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $p=New-Object Diagnostics.Process; $p.StartInfo=$psi
    try{
        [void]$p.Start(); $ok=$p.WaitForExit($Timeout*1000)
        if(-not $ok){ try{$p.Kill()}catch{}; L "TIMEOUT: $Desc passou de ${Timeout}s e foi encerrado." Yellow; return [pscustomobject]@{Code=124;Text='TIMEOUT'} }
        $code=$p.ExitCode; $text=''
        if(Test-Path $out){
            $lines=@(Get-Content $out -ErrorAction SilentlyContinue); $text=($lines -join "`n")
            $show=@($lines|Select-Object -First 45)
            if($lines.Count -gt 65){$show+='... saida resumida ...'; $show+=($lines|Select-Object -Last 15)}
            foreach($x in $show){ if($x){L "OUT : $x"} }
        }
        L "RET : $code"; return [pscustomobject]@{Code=$code;Text=$text}
    } catch { L "ERRO: $($_.Exception.Message)" Red; return [pscustomobject]@{Code=999;Text=$_.Exception.Message} }
    finally { try{$p.Dispose()}catch{}; Remove-Item $bat,$out -Force -ErrorAction SilentlyContinue }
}
function PnpFolder([string]$Folder,[string]$Desc,[int]$Timeout=$BatchTimeoutSec){
    if(-not(Test-Path -LiteralPath $Folder)){L "Pasta nao encontrada: $Folder" Yellow; return [pscustomobject]@{Code=999;Text='Pasta nao encontrada'} }
    $pnp="$env:WINDIR\System32\pnputil.exe"
    return (RunCmd ('"{0}" /add-driver "{1}" /subdirs /install' -f $pnp,(Join-Path $Folder '*.inf')) $Desc $Timeout)
}
function PnpInf([string]$Inf,[string]$Desc){
    if(-not(Test-Path -LiteralPath $Inf)){return [pscustomobject]@{Code=999;Text='INF nao encontrado'} }
    $pnp="$env:WINDIR\System32\pnputil.exe"
    return (RunCmd ('"{0}" /add-driver "{1}" /install' -f $pnp,$Inf) $Desc $InfTimeoutSec)
}
function Scan([switch]$Async){
    $pnp="$env:WINDIR\System32\pnputil.exe"
    if($Async){ [void](RunCmd ('"{0}" /scan-devices /async' -f $pnp) 'scan-devices async' 60) }
    else { [void](RunCmd ('"{0}" /scan-devices' -f $pnp) 'scan-devices' 90) }
}
function DismFolder([string]$Folder){
    $dism="$env:WINDIR\System32\dism.exe"
    return (RunCmd ('"{0}" /Online /Add-Driver /Driver:"{1}" /Recurse' -f $dism,$Folder) "DISM $Folder" 600)
}

function PropArr($iid,$key){
    try{ $v=(Get-PnpDeviceProperty -InstanceId $iid -KeyName $key -ErrorAction Stop).Data; if($null -eq $v){@()} elseif($v -is [array]){@($v)} else{@([string]$v)} }catch{@()}
}
function Vendor($ids){
    $s=($ids -join '|').ToUpperInvariant()
    if($s -match 'VEN_10DE'){'NVIDIA'}
    elseif($s -match 'VEN_1002|VEN_1022|ACPI\\AMDI|\*AMDI|VEN_AMDI'){'AMD'}
    elseif($s -match 'VEN_8086|VID_8087|ACPI\\INTC|\*INTC'){'INTEL'}
    elseif($s -match 'VEN_10EC|VID_0BDA'){'REALTEK'}
    elseif($s -match 'VEN_168C|VEN_17CB|VID_0CF3'){'QUALCOMM'}
    elseif($s -match 'VEN_14C3|VEN_1814|VID_148F|VID_0E8D'){'MEDIATEK'}
    elseif($s -match 'VEN_14E4|VID_0A5C'){'BROADCOM'}
    else{'UNKNOWN'}
}
function Tokens($ids){
    $r=New-Object Collections.Generic.List[string]
    foreach($x0 in $ids){
        if(-not $x0){continue}; $x=$x0.ToUpperInvariant()

        # --- PCI (inclui HDAUDIO de codec sendo exposto como PCI em algumas placas) ---
        if($x -match 'PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})'){
            $ven=$Matches[1]; $dev=$Matches[2]
            if($x -match 'SUBSYS_([0-9A-F]{8})'){$r.Add("PCI\VEN_$ven&DEV_$dev&SUBSYS_$($Matches[1])")}
            $r.Add("PCI\VEN_$ven&DEV_$dev")
            if($x -match 'CC_([0-9A-F]{4,6})'){$r.Add("PCI\VEN_$ven&DEV_$dev&CC_$($Matches[1])")}
            # Forma "nua" usada por INFs que declaram apenas o par VEN/DEV (fallback de baixo peso).
            $r.Add("VEN_$ven&DEV_$dev")
        }

        # --- USB (com e sem MI_, mais a forma nua VID/PID) ---
        if($x -match 'USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})'){
            $vidUSB=$Matches[1]; $pidUSB=$Matches[2]
            if($x -match 'MI_([0-9A-F]{2})'){$r.Add("USB\VID_$vidUSB&PID_$pidUSB&MI_$($Matches[1])")}
            $r.Add("USB\VID_$vidUSB&PID_$pidUSB")
            $r.Add("VID_$vidUSB&PID_$pidUSB")
        }

        # --- SD / SDStor ---
        if($x -match 'SD\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})'){
            $r.Add("SD\VID_$($Matches[1])&PID_$($Matches[2])")
        }

        # --- ACPI generico (VEN/DEV, IDs curtos tipo SMB0001, PNP0Cxx) ---
        if($x -match 'ACPI\\VEN_([A-Z0-9]{4})&DEV_([A-Z0-9]{4})'){$r.Add("ACPI\VEN_$($Matches[1])&DEV_$($Matches[2])")}
        if($x -match 'ACPI\\([A-Z]{3,4}[0-9A-F]{4})'){$r.Add("ACPI\$($Matches[1])")}
        if($x -match 'ACPI\\(AMDI[0-9A-F]{4})'){$r.Add("ACPI\$($Matches[1])");$r.Add("*$($Matches[1])")}
        if($x -match '\*(AMDI[0-9A-F]{4})'){$r.Add("*$($Matches[1])")}
        if($x -match 'ACPI\\(INTC[0-9A-F]{4})'){$r.Add("ACPI\$($Matches[1])");$r.Add("*$($Matches[1])")}
        if($x -match '\*(INTC[0-9A-F]{4})'){$r.Add("*$($Matches[1])")}

        # --- HDAUDIO: codecs de audio (Realtek/Conexant/Via). Antes nao eram tokenizados
        # e por isso o driver "Dispositivo de High Definition Audio" passava direto.
        if($x -match 'HDAUDIO\\FUNC_0[0-9]&VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})'){
            $hven=$Matches[1]; $hdev=$Matches[2]
            if($x -match 'SUBSYS_([0-9A-F]{8})'){$r.Add("HDAUDIO\FUNC_01&VEN_$hven&DEV_$hdev&SUBSYS_$($Matches[1])")}
            $r.Add("HDAUDIO\FUNC_01&VEN_$hven&DEV_$hdev")
            $r.Add("VEN_$hven&DEV_$hdev")
        }

        # --- Bluetooth
        if($x -match '^(BTH|BTHENUM|BTHHFENUM|BTHMINI)\\'){$r.Add($x)}
        if($x -match 'BTH\\MS_([A-Z0-9_]+)'){$r.Add("BTH\MS_$($Matches[1])")}

        # --- SWC (Intel Ultra PPM/DTT) e outros barramentos raros
        if($x -match 'SWC\\VID_8086'){$r.Add('SWC\VID_8086')}
        if($x -match 'ROOT\\'){$r.Add($x)}
        if($x -match 'VPCI\\'){$r.Add($x)}
        if($x -match '^\*([A-Z0-9]{4,8})$'){$r.Add($x)}
    }
    @($r|Where-Object{$_ -match 'DEV_|ACPI\\|\*INTC|\*AMDI|\*[A-Z0-9]{4,8}$|VID_[0-9A-F]{4}&PID_[0-9A-F]{4}|HDAUDIO\\|BTH\\|SWC\\|VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}'}|Select-Object -Unique)
}

function Targets{
    $out=@()
    try{$all=@(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)}
    catch{throw "Nao foi possivel consultar os dispositivos. A instalacao nao foi verificada: $($_.Exception.Message)"}
    if($all.Count -eq 0){throw 'A consulta de dispositivos retornou vazia. Nao e possivel confirmar a instalacao.'}
    foreach($d in $all){
        $name=[string]$d.Name; $cls=[string]$d.PNPClass; $err=[int]$d.ConfigManagerErrorCode; $iid=[string]$d.PNPDeviceID; if(-not $iid){continue}
        $basic=($d.Service -eq 'BasicDisplay' -or ((($cls -eq 'Display') -or ($name -match 'Video|V.deo|Display')) -and ($name -match 'Basico|B.sico|Basic|Microsoft Basic')))
        # Componente System do Windows, nao um adaptador grafico. Erros reais seguem em $prob.
        if($cls -eq 'System' -and $iid -match '^ROOT\\BASICDISPLAY\\'){$basic=$false}
        # Conjunto ampliado de codigos de problema: antes era {1,28,31,39,43}.
        # Agora inclui 10 (nao iniciou), 18 (reinstalar), 24 (device ausente),
        # 52 (driver nao assinado) e 0x0A/0x1C. Isso evita "passar direto" em
        # dispositivos que ficam pendentes com outro codigo de erro.
        if($TodosErros){$prob=($err -ne 0)}else{$prob=(@(1,10,18,24,28,31,39,43,52) -contains $err)}
        if(-not($basic -or $prob)){continue}
        if($cls -match 'Keyboard|Mouse' -or $name -match 'Teclado|Mouse|HID-compliant mouse|HID Keyboard'){continue}
        $hw=PropArr $iid 'DEVPKEY_Device_HardwareIds'; $cp=PropArr $iid 'DEVPKEY_Device_CompatibleIds'; $ids=@($hw+$cp+$iid)|Where-Object{$_}
        $out += [pscustomobject]@{Name=$name;Class=$cls;Err=$err;Id=$iid;HW=$hw;Compat=$cp;Vendor=(Vendor $ids);Tokens=(Tokens $ids);BasicVideo=$basic}
    }
    @($out)
}
function CpuInfo{
    try{ $n=(Get-CimInstance Win32_Processor|Select-Object -First 1 -ExpandProperty Name); if($n -match 'AMD'){$v='AMD'}elseif($n -match 'Intel'){$v='INTEL'}else{$v='UNKNOWN'}; [pscustomobject]@{Name=$n;Vendor=$v} }
    catch{[pscustomobject]@{Name='';Vendor='UNKNOWN'}}
}
function IsUltra($cpu,$tg){
    if($cpu.Vendor -eq 'INTEL' -and $cpu.Name -match 'Ultra'){return $true}
    foreach($t in $tg){ $s=($t.Id+'|'+(($t.HW+$t.Compat)-join '|')).ToUpperInvariant(); if($s -match 'ACPI\\INTC1042|\*INTC1042|PCI\\VEN_8086&DEV_(7F|AD|AE)[0-9A-F]{2}'){return $true} }
    return $false
}
# ---------------------------------------------------------------------------
# Cache global de INFs e de listagem de pastas.
# Motivo: o script lia o mesmo INF (e re-varria a mesma arvore) varias vezes em
# fases diferentes, o que deixava a atualizacao lenta. Agora cada arquivo e lido
# no maximo uma vez por execucao, e a listagem de *.inf por pasta tambem e memoizada.
# ---------------------------------------------------------------------------
$script:InfTextCache = @{}
$script:InfListCache = @{}

function Get-InfFiles([string]$Root){
    if(-not $Root){return @()}
    if($script:InfListCache.ContainsKey($Root)){return $script:InfListCache[$Root]}
    $files=@()
    try{ $files=@(Get-ChildItem -LiteralPath $Root -Filter *.inf -Recurse -File -Force -ErrorAction SilentlyContinue) }catch{ $files=@() }
    $script:InfListCache[$Root]=$files
    return $files
}
function ReadInf($p){
    if(-not $p){return ''}
    if($script:InfTextCache.ContainsKey($p)){return $script:InfTextCache[$p]}
    $txt=''
    try{ $txt=[IO.File]::ReadAllText($p,[Text.Encoding]::Default).ToUpperInvariant() }
    catch{ try{ $txt=[IO.File]::ReadAllText($p).ToUpperInvariant() }catch{ $txt='' } }
    $script:InfTextCache[$p]=$txt
    return $txt
}
function ScoreInfText([string]$txt,[string]$path,[array]$tokens,[string]$vendor,[switch]$DisplayOnly){
    if(-not $txt){return 0}
    if($DisplayOnly -and ($txt -notmatch '(?m)^\s*CLASS\s*=\s*DISPLAY\s*$')){return 0}
    $score=0
    foreach($tok0 in $tokens){
        if(-not $tok0){continue}
        $tok=$tok0.ToUpperInvariant()
        if($txt.Contains($tok)){
            if($tok -match 'SUBSYS_'){$score+=650}
            elseif($tok -match 'HDAUDIO\\FUNC_01'){ $score+=600 }
            elseif($tok -match 'VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}'){$score+=500}
            elseif($tok -match 'VID_[0-9A-F]{4}&PID_[0-9A-F]{4}'){
                if($tok -match 'MI_'){$score+=540}else{$score+=480}
            }
            elseif($tok -match '^SD\\VID_'){$score+=460}
            elseif($tok -match 'ACPI\\|\*INTC|\*AMDI'){$score+=420}
            elseif($tok -match 'BTH\\'){ $score+=420 }
            elseif($tok -match 'SWC\\VID_8086'){ $score+=460 }
            elseif($tok -match 'VPCI\\|ROOT\\'){ $score+=360 }
            elseif($tok -match '^\*[A-Z0-9]{4,8}$'){ $score+=340 }
            elseif($tok -match 'CC_'){$score+=80}
            else{ $score+=200 }
        }
    }
    if($score -le 0){return 0}
    $up=$path.ToUpperInvariant(); $file=[IO.Path]::GetFileName($up)
    if($vendor -eq 'NVIDIA'){
        if($up -match '\\RTX\\'){$score+=120}
        if($file -eq 'NV_DISPI.INF'){$score+=700}
        elseif($file -eq 'NVDDI.INF'){$score+=250}
        elseif($file -eq 'NVMDI.INF'){$score-=900}
        if($up -match 'COMPLEMENTOS|PPC|_OLD|OLD'){$score-=400}
        if($txt -match '(?m)^\s*CLASS\s*=\s*DISPLAY\s*$'){$score+=160}
    }
    if($vendor -eq 'INTEL'){
        if($up -match 'NPU'){$score+=200}
        if($up -match 'CHIPSET ULTRA|DTT|IPF|RPL|MTL|METEOR|ARROW|LUNAR'){$score+=150}
        if($up -match 'TIGERLAKE'){$score-=300}
    }
    if($vendor -eq 'AMD'){
        if($up.Contains('\AMD\[GRAPH] AM5\')){$score+=420}
        elseif($up.Contains('\AMD\[GRAPH] NEW\')){$score+=260}
        elseif($up.Contains('\AMD\[GRAPH]')){$score+=160}
        if($file -match '^U[0-9A-F]{7}\.INF$'){$score+=120}
        if($up -match 'AMD CHIPSET'){$score+=80}
        if($txt -match '(?m)^\s*CLASS\s*=\s*DISPLAY\s*$'){$score+=160}
    }

    if($txt -match '(?m)^\s*CLASS\s*=\s*NET\s*$'){$score+=260}
    if($up -match 'WIFI|WI-FI|WLAN|WIRELESS|NETWORK|NET|LAN|ETHERNET'){$score+=90}
    # Bluetooth: nao deixar penalizacao impedir instalacao.
    # Como bluetooth pode aparecer sem CLASS=NET em alguns INF, atenuamos a penalizacao.
    if(($up -match 'BLUETOOTH|\\BT\\|BT_|_BT') -and ($txt -notmatch '(?m)^\s*CLASS\s*=\s*NET\s*$')){$score-=80}

    if($vendor -eq 'REALTEK'){
        if($up -match 'REALTEK|RTL|RTW|WLAN|LAN'){$score+=130}
    }
    if($vendor -eq 'QUALCOMM'){
        if($up -match 'QUALCOMM|ATHEROS|QCA|KILLER|WLAN|WIRELESS'){$score+=140}
    }
    if($vendor -eq 'MEDIATEK'){
        if($up -match 'MEDIATEK|RALINK|MTK|WLAN|WIRELESS'){$score+=140}
    }
    if($vendor -eq 'BROADCOM'){
        if($up -match 'BROADCOM|BCM|WLAN|WIRELESS'){$score+=140}
    }
    return $score
}
function FindInf($roots,$tokens,$vendor,[switch]$DisplayOnly,[int]$Max=2){
    $map=@{}; $roots=@($roots|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -Unique); if(-not $tokens){return @()}
    foreach($root in $roots){
        L "Busca INF exata em: $root"
        $infs=@(Get-InfFiles $root)
        L "  INF encontrados: $($infs.Count)"
        foreach($inf in $infs){
            $up=$inf.FullName.ToUpperInvariant()
            if($vendor -eq 'NVIDIA' -and -not $ModoCompleto){ if($up -match 'NVMDI\.INF$|COMPLEMENTOS|PPC|_OLD|OLD'){continue} }
            $txt=ReadInf $inf.FullName
            $score=ScoreInfText $txt $inf.FullName $tokens $vendor -DisplayOnly:$DisplayOnly
            if($score -gt 0){$map[$inf.FullName]=[math]::Max([int]$map[$inf.FullName],$score)}
        }
    }
    @($map.GetEnumerator()|Sort-Object Value -Descending|Select-Object -First $Max|ForEach-Object{[pscustomobject]@{Path=$_.Key;Score=$_.Value}})
}
function FindInfsForMany($roots,[array]$devices,[int]$MaxPerDevice=1){
    $roots=@($roots|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -Unique)
    $devices=@($devices|Where-Object{$_.Tokens})
    if($devices.Count -eq 0){return @()}
    $best=@{}
    foreach($root in $roots){
        L "Busca multipla INF exata em: $root" Cyan
        $infs=@(Get-InfFiles $root)
        L "  INF encontrados: $($infs.Count)"
        foreach($inf in $infs){
            $txt=ReadInf $inf.FullName; if(-not $txt){continue}
            foreach($d in $devices){
                $score=ScoreInfText $txt $inf.FullName $d.Tokens $d.Vendor
                if($score -le 0){continue}
                $key=$d.Id
                if(-not $best.ContainsKey($key)){$best[$key]=New-Object Collections.Generic.List[object]}
                $best[$key].Add([pscustomobject]@{Device=$d;Path=$inf.FullName;Score=$score})
            }
        }
    }
    $sel=@()
    foreach($key in $best.Keys){ $sel += @($best[$key] | Sort-Object Score -Descending | Select-Object -First $MaxPerDevice) }
    @($sel | Sort-Object Path -Unique | Sort-Object Score -Descending)
}
function Get-IntelGraphicsRoots {
    $intelRoot = Join-Path $Repo 'INTEL'
    if (-not (Test-Path -LiteralPath $intelRoot)) { return @() }
    
    $genFolderNames = switch ($script:IntelGen) {
        '4' { @('4º', '4°', '4ª', '4') }
        '7-10' { @('7th', '8th', '9th', '10th', '7º a 10º', '7-10º', '7 a 10º', '7º', '8º', '9º', '10º') }
        '11-14' { @('11º a 14º', '11-14º', '11 a 14º', '11º', '12º', '13º', '14º') }
        'Ultra' { @('Graphics', 'Chipset Ultra') }
        '4' { @('Graphics') }
        default { @('Graphics') }
    }
    
    $roots = @()
    foreach ($folderName in $genFolderNames) {
        $fullPath = Join-Path $intelRoot $folderName
        if (Test-Path -LiteralPath $fullPath) {
            $roots += $fullPath
        }
    }
    
    # Dynamic folder discovery
    try {
        Get-ChildItem -LiteralPath $intelRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $n = $_.Name.ToUpperInvariant()
            switch ($script:IntelGen) {
                '4' {
                    if ($n -match '(^|[^0-9])4([^0-9]|$)' -or $n -match 'QUARTA|4\s*(º|ª|°|O|A|TH|GEN|GERACAO)?') {
                        $roots += $_.FullName
                    }
                }
                '7-10' {
                    if ($n -match '(^|[^0-9])(7|8|9|10)([^0-9]|$)') { $roots += $_.FullName }
                }
                '11-14' {
                    if ($n -match '(^|[^0-9])(11|12|13|14)([^0-9]|$)') { $roots += $_.FullName }
                }
            }
        }
    } catch {}
    
    @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Get-IntelFourthGenRoots {
    $roots=@()
    $intelRoot=Join-Path $Repo 'INTEL'
    if(-not(Test-Path -LiteralPath $intelRoot)){return @()}
    # Caminhos explicitos para nao depender so da varredura quando a pasta tem simbolo especial.
    $roots += (Join-Path $intelRoot '4º')
    $roots += (Join-Path $intelRoot '4°')
    $roots += (Join-Path $intelRoot '4ª')
    $roots += (Join-Path $intelRoot '4')
    try{
        Get-ChildItem -LiteralPath $intelRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $n=$_.Name.ToUpperInvariant()
            # Pega pastas como "4", "4o", "4a", "4th", "4 gen", "4 geracao" e tambem "4º/4ª/4°".
            if($n -match '(^|[^0-9])4([^0-9]|$)' -or $n -match 'QUARTA|4\s*(º|ª|°|O|A|TH)?'){
                $roots += $_.FullName
            }
        }
    } catch {}
    @($roots|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -Unique)
}
function Get-IntelGenCpu($cpuName) {
    if (-not $cpuName -or [string]$cpuName -notmatch 'Intel') { return 'Other' }
    $n = [string]$cpuName
    # Ultra deve ser reconhecido antes de numeros de modelo ou frequencia.
    if ($n -match 'CORE\s*(?:\(TM\))?\s*ULTRA|METEOR LAKE|ARROW LAKE|LUNAR LAKE') { return 'Ultra' }

    $gen = 0
    if ($n -match '\bi[3579][-\s]+([1-9]\d{3,4})[a-z]*\b') {
        $model = $Matches[1]
        if ($model.Length -eq 5) { $gen = [int]$model.Substring(0,2) }
        else { $gen = [int]$model.Substring(0,1) }
    } elseif ($n -match '(?<!\d)(1[0-4]|[4-9])\s*(?:º|ª|°|TH|GEN|GERACAO)\b') {
        $gen = [int]$Matches[1]
    }
    if ($gen -eq 4) { return '4' }
    if ($gen -ge 7 -and $gen -le 10) { return '7-10' }
    if ($gen -ge 11 -and $gen -le 14) { return '11-14' }
    if ($n -match 'ALDER|RAPTOR|ROCKET|\bRPL\b') { return '11-14' }
    return 'Other'
}
function RootsFor($vendor){
    $intelGenRoots=@()
    try { 
        if ($script:IntelGen -ne 'Other') { 
            $intelGenRoots = @(Get-IntelGraphicsRoots) 
        } 
    } catch {}
    $netRoots=@()
    # Em Intel geracoes especificas, alguns repositorios guardam video/rede/chipset juntos em pastas de geracao.
    $netRoots += $intelGenRoots
    $netRoots += @(
        (Join-Path $Repo 'NETWORK'),
        (Join-Path $Repo 'NET'),
        (Join-Path $Repo 'LAN'),
        (Join-Path $Repo 'WIFI'),
        (Join-Path $Repo 'WI-FI'),
        (Join-Path $Repo 'WLAN'),
        (Join-Path $Repo 'WIRELESS'),
        (Join-Path $Repo 'DRIVERS WIFI'),
        (Join-Path $Repo 'DRIVERS REDE')
    )
    switch($vendor){
        'NVIDIA'{ @((Join-Path $Repo 'NVIDIA\RTX'),(Join-Path $Repo 'NVIDIA')) }
        'AMD'{ @((Join-Path $Repo 'AMD')) }
'INTEL'{ @($intelGenRoots + @((Join-Path $Repo 'INTEL\Graphics'),(Join-Path $Repo 'INTEL\WiFi'),(Join-Path $Repo 'INTEL\Wi-Fi'),(Join-Path $Repo 'INTEL\Wireless'),(Join-Path $Repo 'INTEL\LAN'),(Join-Path $Repo 'INTEL\Network'),(Join-Path $Repo 'INTEL\Intel Chipset'),(Join-Path $Repo 'INTEL')) + $netRoots) }
        'REALTEK'{ @((Join-Path $Repo 'REALTEK'),(Join-Path $Repo 'RTL'),(Join-Path $Repo 'LAN\REALTEK'),(Join-Path $Repo 'WIFI\REALTEK')) + $netRoots }
        'QUALCOMM'{ @((Join-Path $Repo 'QUALCOMM'),(Join-Path $Repo 'ATHEROS'),(Join-Path $Repo 'KILLER'),(Join-Path $Repo 'QCA'),(Join-Path $Repo 'WIFI\QUALCOMM'),(Join-Path $Repo 'WIFI\ATHEROS')) + $netRoots }
        'MEDIATEK'{ @((Join-Path $Repo 'MEDIATEK'),(Join-Path $Repo 'MTK'),(Join-Path $Repo 'RALINK'),(Join-Path $Repo 'WIFI\MEDIATEK'),(Join-Path $Repo 'WIFI\RALINK')) + $netRoots }
        'BROADCOM'{ @((Join-Path $Repo 'BROADCOM'),(Join-Path $Repo 'BCM'),(Join-Path $Repo 'WIFI\BROADCOM')) + $netRoots }
        'NETWORK'{ $netRoots }
        default{ @($Repo) }
    }
}
function IsNetworkTarget($d){
    if($null -eq $d -or $d.BasicVideo){return $false}
    $s=(($d.Name+'|'+$d.Class+'|'+$d.Id+'|'+(($d.HW+$d.Compat)-join '|'))).ToUpperInvariant()
    if($d.Class -match '^Net$|Network'){return $true}
    if($s -match 'NETWORK CONTROLLER|CONTROLADOR DE REDE|CONTROLADORA DE REDE|WI-FI|WIFI|WIRELESS|WLAN|802\.11|ETHERNET|ADAPTADOR DE REDE'){return $true}
    if($s -match 'PCI\\VEN_(8086|10EC|168C|17CB|14C3|1814|14E4)&DEV_'){return $true}
    if($s -match 'USB\\VID_(0BDA|148F|0E8D|0CF3|8087|0A5C)&PID_'){return $true}
    return $false
}
function InstallBluetoothMissingPriority([array]$tg){
    if(-not $tg){return}

    # Detecta dispositivos pendentes com pistas de Bluetooth (por Id/tokens/name/class).
    $bt=@($tg | Where-Object{
        if(-not $_){return $false}
        $s=(($_.Name+'|'+$_.Class+'|'+$_.Id+'|'+(($_.HW+$_.Compat)-join '|'))).ToUpperInvariant()
        # Bluetooth pode aparecer como varios padroes; incluir tambem radios comuns (BT/WIDCOMM/Qualcomm BT etc.)
        return ($s -match 'BLUETOOTH|\\BT\\|BT_|_BT|BTH\\|WIDCOMM|AIR\\|RADIO\\|LE\\|802\\.15')
    })

    if($bt.Count -eq 0){return}

    L "FASE BLUETOOTH PRIORITARIA: $($bt.Count) dispositivo(s) Bluetooth pendente(s)." Cyan
    foreach($d in $bt){
        L "BT TARGET: $($d.Name) | Classe=$($d.Class) | Err=$($d.Err) | Vendor=$($d.Vendor) | ID=$($d.Id)" Cyan
        if($d.Tokens){L "  TOKENS: $($d.Tokens -join ' | ')"}
    }

    # Roots: usar o repo inteiro (raiz pendrive) para garantir que sempre exista fallback.
    # E também tenta pastas comuns de fabricante para melhorar chance de acerto.
    $roots = @()
    $roots += @($Repo)
    foreach($v in @($bt|Select-Object -ExpandProperty Vendor -Unique)){
        if($v -and $v -ne 'UNKNOWN'){
            $roots += (RootsFor $v)
        }
    }

    $roots = @($roots | Where-Object{$_ -and (Test-Path -LiteralPath $_)} | Select-Object -Unique)
    L "BT: buscando INF em roots: $($roots -join ' | ')" Cyan

    # Rodada 1: busca por tokens.
    $cands = FindInfsForMany $roots $bt 2

    # Fallback adicional: se tokens não casarem bem, pega INFs cujo texto contenha BT/BLUETOOTH.
    if($cands.Count -eq 0){
        # Debug: se falhar, ajuda a entender se existem sequer INFs com BLUETOOTH no Repo.
        try{
            $btInfCount = (@(Get-InfFiles $Repo) | Where-Object{
                try{ (ReadInf $_.FullName) -match 'BLUETOOTH|\\BT\\|BT_|_BT|WIDCOMM|BTH' }catch{ $false }
            }).Count
            L ("BT: contagem aproximada de INFs com palavras BT/BLUETOOTH no Repo = {0}" -f $btInfCount) Yellow
        }catch{}

        L 'BT: nenhum INF encontrado por tokens; fazendo fallback por texto (BLUETOOTH/BT) no Repo.' Yellow
        $allInfs = @(Get-InfFiles $Repo)
        $map=@{}
        foreach($inf in $allInfs){
            $upTxt = ReadInf $inf.FullName
            if(-not $upTxt){continue}
            if($upTxt -match 'BLUETOOTH|\\BT\\|BT_|_BT'){
                foreach($d in $bt){
                    $score = ScoreInfText $upTxt $inf.FullName $d.Tokens $d.Vendor
                    if($score -gt 0){
                        if(-not $map.ContainsKey($d.Id)){$map[$d.Id]=New-Object Collections.Generic.List[object]}
                        $map[$d.Id].Add([pscustomobject]@{Device=$d;Path=$inf.FullName;Score=$score})
                    }
                }
            }
        }
        $sel=@()
        foreach($k in $map.Keys){
            $sel += @($map[$k] | Sort-Object Score -Descending | Select-Object -First 2)
        }
        $cands = @($sel | Sort-Object Path -Unique | Sort-Object Score -Descending)
    }

    L "BT: INFs selecionados: $($cands.Count)" Cyan
    foreach($c in $cands){
        L "INF Bluetooth Score=$($c.Score): $($c.Path)" Cyan
        [void](PnpInf $c.Path "Bluetooth $($c.Device.Name)")
        $folder=Split-Path -Parent $c.Path
        if($folder -and (Test-Path -LiteralPath $folder)){
            [void](PnpFolder $folder "Bluetooth pasta do INF - $($c.Device.Name)" 180)
        }
    }

    # Rodada 2: re-tenta o que sobrou (para evitar "passou direto" quando o INF não amarrou de primeira).
    Scan -Async
    $tg2=Targets
    $bt2=@($tg2 | Where-Object{
        $s=(($_.Name+'|'+$_.Class+'|'+$_.Id+'|'+(($_.HW+$_.Compat)-join '|'))).ToUpperInvariant()
        return ($s -match 'BLUETOOTH|\\BT\\|BT_|_BT|RADIO\\|AIR\\|802\\.15|WIDCOMM|BTH\\')
    })
    if($bt2.Count -gt 0){
        L "BT: ainda restam $($bt2.Count) pendente(s). Repetindo busca curta por tokens no Repo." Yellow
        $c2=FindInfsForMany @($Repo) $bt2 2
        foreach($c in $c2){
            L "INF Bluetooth (rodada2) Score=$($c.Score): $($c.Path)" Cyan
            [void](PnpInf $c.Path "Bluetooth(2) $($c.Device.Name)")
        }
        Scan -Async
    }
}

function InstallAmdAudioCoprocessor([array]$tg){
    # ACP pode aparecer como Controlador de multimidia, sem nome AMD/Audio.
    $devices=@($tg | Where-Object{
        $_.Vendor -eq 'AMD' -and (
            $_.Name -match 'Audio|ACP|Co.?Processor|Coprocessador' -or
            (($_.HW + @($_.Id)) -join '|') -match 'VEN_1022&DEV_15E2'
        )
    })
    foreach($d in $devices){
        L "AMD ACP: $($d.Name) | ID=$($d.Id) | Erro=$($d.Err)" Cyan
        $chipsetRoot=Join-Path $Repo 'AMD\AMD CHIPSET'
        $candidates=@(FindInf @($chipsetRoot) $d.Tokens 'AMD' -Max 100)
        # Comparacao completa evita escolher REV_60/62/6F/63 para REV_00.
        $deviceIds=@($d.HW + @($d.Id) | ForEach-Object {
            $id=([string]$_).ToUpperInvariant()
            $id
            $id -replace '&SUBSYS_[0-9A-F]{8}',''
        })
        $compatible={
            param($candidate)
            $txt=ReadInf $candidate.Path
            $modelIds=@([regex]::Matches($txt,'(?im)^\s*[^;\r\n=]+\s*=\s*[^,\r\n]+,\s*(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}[^,\s;]*)') | ForEach-Object { $_.Groups[1].Value })
            foreach($modelId in $modelIds){
                foreach($deviceId in $deviceIds){
                    if($deviceId -eq $modelId -or $deviceId.StartsWith($modelId+'&')){return $true}
                }
            }
            return $false
        }
        $candidates=@($candidates | Where-Object { & $compatible $_ })
        if($candidates.Count -eq 0){
            $candidates=@(FindInf @($Repo) $d.Tokens 'AMD' -Max 100 | Where-Object { & $compatible $_ })
        }
        if($candidates.Count -eq 0){
            L "AMD ACP: nenhum INF compativel no DriversRepo. Hardware IDs: $($d.HW -join ' | ')" Yellow
            continue
        }
        foreach($c in $candidates){
            [void](PnpInf $c.Path "AMD Audio CoProcessor - $($d.Name)")
            [void](PnpFolder (Split-Path -Parent $c.Path) 'AMD ACP - pacote complementar' $BatchTimeoutSec)
            Scan
            $state=Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -eq $d.Id } | Select-Object -First 1
            if($state -and $state.ConfigManagerErrorCode -eq 0){
                L 'AMD ACP: dispositivo sem erro confirmado.' Green
                break
            }
        }
    }
}

function InstallAudioMissingPriority([array]$tg){
    # Fase dedicada para audio (HDAUDIO/Realtek/Conexant/VIA).
    # Antes esses codecs nao entravam no foco e as vezes ficavam como
    # "Dispositivo de High Definition Audio" pendente mesmo com INF no Repo.
    $aud=@($tg | Where-Object{
        if(-not $_){return $false}
        $s=(($_.Name+'|'+$_.Class+'|'+$_.Id+'|'+(($_.HW+$_.Compat)-join '|'))).ToUpperInvariant()
        return ($_.Class -match '^MEDIA$|AudioEndpoint|^System$' -and $s -match 'AUDIO|HDAUDIO|HDAUDIO\\FUNC|HIGH DEFINITION|REALTEK|CONEXANT|SOUND') -or ($s -match 'HDAUDIO\\FUNC_0[0-9]')
    })
    if($aud.Count -eq 0){return}

    L "FASE AUDIO PRIORITARIA: $($aud.Count) dispositivo(s) de audio pendente(s)." Cyan
    foreach($d in $aud){
        L "AUDIO TARGET: $($d.Name) | Classe=$($d.Class) | Err=$($d.Err) | Vendor=$($d.Vendor) | ID=$($d.Id)" Cyan
        if($d.Tokens){L "  TOKENS AUDIO: $($d.Tokens -join ' | ')"}
    }

    $roots=@()
    foreach($v in @($aud|Select-Object -ExpandProperty Vendor -Unique)){
        if($v -and $v -ne 'UNKNOWN'){ $roots += (RootsFor $v) }
    }
    # Pastas comuns de audio + Repo (busca ampla com cache e barata).
    $roots += @(
        (Join-Path $Repo 'AUDIO'),
        (Join-Path $Repo 'REALTEK'),
        (Join-Path $Repo 'HDAUDIO'),
        (Join-Path $Repo 'SOUND'),
        (Join-Path $Repo 'Complementos')
    )
    $roots = @($roots | Where-Object{$_ -and (Test-Path -LiteralPath $_)} | Select-Object -Unique)

    $cands = FindInfsForMany $roots $aud 2
    if($cands.Count -eq 0){
        L 'AUDIO: nenhum INF nas pastas provaveis; varrendo DriversRepo por tokens.' Yellow
        $cands = FindInfsForMany @($Repo) $aud 2
    }

    L "AUDIO: INFs selecionados: $($cands.Count)" Cyan
    foreach($c in $cands){
        L "INF Audio Score=$($c.Score): $($c.Path)" Cyan
        [void](PnpInf $c.Path "Audio $($c.Device.Name)")
        $folder=Split-Path -Parent $c.Path
        if($folder -and (Test-Path -LiteralPath $folder)){
            [void](PnpFolder $folder "Audio pasta do INF - $($c.Device.Name)" 180)
        }
    }
}

function InstallNetworkPriority([array]$tg){
    $net=@($tg|Where-Object{ IsNetworkTarget $_ })
    if($net.Count -eq 0){return}
    L "FASE REDE/WIFI PRIORITARIA: $($net.Count) dispositivo(s) de rede pendente(s)." Cyan
    foreach($n in $net){
        L "REDE/WIFI TARGET: $($n.Name) | Classe=$($n.Class) | Err=$($n.Err) | Vendor=$($n.Vendor) | ID=$($n.Id)" Cyan
        if($n.Tokens){L "  TOKENS REDE/WIFI: $($n.Tokens -join ' | ')"}
    }
    foreach($v in @($net|Select-Object -ExpandProperty Vendor -Unique)){
        $devs=@($net|Where-Object{$_.Vendor -eq $v})
        $roots=@()
        if($v -ne 'UNKNOWN'){$roots+=(RootsFor $v)}
        $roots+=(RootsFor 'NETWORK')
        $roots=@($roots|Where-Object{$_}|Select-Object -Unique)
        L "Rede/WiFi Vendor=$v | buscando primeiro em pastas provaveis." Cyan
        $cands=FindInfsForMany $roots $devs 2
        if($cands.Count -eq 0){
            L "Rede/WiFi Vendor=$v | nenhum INF nas pastas provaveis. Fazendo varredura exata no DriversRepo para nao deixar WiFi passar." Yellow
            $cands=FindInfsForMany @($Repo) $devs 2
        }
        L "Rede/WiFi Vendor=$v | INFs selecionados: $($cands.Count)" Cyan
        foreach($c in $cands){
            L "INF Rede/WiFi Score=$($c.Score): $($c.Path)" Cyan
            [void](PnpInf $c.Path "Rede/WiFi $($c.Device.Name)")
            $folder=Split-Path -Parent $c.Path
            if($folder -and (Test-Path -LiteralPath $folder)){
                [void](PnpFolder $folder "Rede/WiFi pasta do INF - $($c.Device.Name)" 180)
            }
        }
    }
}


function InstallIntelGraphicsAggressive {
    $roots = @(Get-IntelGraphicsRoots)
    if ($roots.Count -eq 0) { return }
    $basic = @(Targets | Where-Object { $_.BasicVideo })

    $should = $false
    $intelBasic = @($basic | Where-Object { $_.Vendor -eq 'INTEL' })
    if ($intelBasic.Count -gt 0) { $should = $true }

    if (-not $should) { return }

    L "FASE INTEL GEN VIDEO REFORCADO (Gen=$script:IntelGen): Adaptador Basico Microsoft detectado. Priorizando pastas Intel $script:IntelGen." Cyan
    L "Pastas Intel encontradas: $($roots -join ' | ')" Cyan

    foreach ($b in $intelBasic) {
        if($script:IntelVideoRebootRequired -contains $b.Id){continue}
        L "VIDEO INTEL TARGET: $($b.Name) | Gen=$script:IntelGen | ID=$($b.Id)" Cyan
        if ($b.Tokens) { L "  TOKENS: $($b.Tokens -join ' | ')" }
        $cands = FindInf $roots $b.Tokens 'INTEL' -DisplayOnly -Max 8
        foreach ($c in $cands) {
            L "INF video Intel Score=$($c.Score): $($c.Path)" Cyan
            [void](PnpInf $c.Path "Video Intel Gen=$script:IntelGen - INF exato")
            $folder = Split-Path -Parent $c.Path
            if ($folder -and (Test-Path -LiteralPath $folder)) {
                [void](PnpFolder $folder "Video Intel Gen=$script:IntelGen - pasta do INF" 300)
            }
            Scan
            if(Test-VideoDeviceReady $b.Id){break}
            if(Repair-IntelBasicVideo $b $c.Path){break}
        }
    }

    Scan -Async
    if (@((Targets) | Where-Object { $_.BasicVideo -and $_.Vendor -eq 'INTEL' }).Count -gt 0) {
        L "Video Intel ainda Basico. Aplicando lote completo gen $script:IntelGen." Yellow
        foreach ($r in $roots) { [void](PnpFolder $r "Video Intel Gen=$script:IntelGen - lote completo" 900) }
        Scan -Async
    }

    # DISM /Online /Add-Driver nao instala drivers na sessao Windows ativa.
    # A recuperacao acima usa a API de instalacao para o hardware correspondente.
}
function IsVideoResolved{
    $t=Targets
    return (@($t|Where-Object{$_.BasicVideo}).Count -eq 0)
}
function Test-VideoDeviceReady([string]$DeviceId) {
    # Confirma o dispositivo real; texto do pnputil sozinho nao prova ativacao.
    try {
        $device = Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.PNPDeviceID -eq $DeviceId } | Select-Object -First 1
        return ($null -ne $device -and $device.PNPClass -eq 'Display' -and
            $device.ConfigManagerErrorCode -eq 0 -and $device.Service -and
            $device.Service -notmatch '^BasicDisplay$' -and $device.Name -notmatch 'B.sico|Basico|Basic')
    } catch { return $false }
}
function Invoke-IntelDriverUpdate([string]$HardwareId,[string]$Inf) {
    if(-not ('Pichau.IntelVideoInstaller' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Pichau {
    public class IntelVideoResult {
        public bool Success;
        public bool RebootRequired;
        public int Error;
    }
    public static class IntelVideoInstaller {
        [DllImport("newdev.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateDriverForPlugAndPlayDevicesW(
            IntPtr hwnd, string hardwareId, string inf, uint flags,
            [MarshalAs(UnmanagedType.Bool)] out bool reboot);
        public static IntelVideoResult Install(string hardwareId, string inf) {
            bool reboot;
            // FORCE | NONINTERACTIVE: somente chamado para Intel ainda em BasicDisplay.
            bool ok = UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hardwareId, inf, 5, out reboot);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            return new IntelVideoResult { Success=ok, RebootRequired=reboot, Error=error };
        }
    }
}
'@ -ErrorAction Stop
    }
    [Pichau.IntelVideoInstaller]::Install($HardwareId,$Inf)
}
function Repair-IntelBasicVideo($Device,[string]$Inf) {
    # Nunca substitui um driver Intel ativo: valida o estado atual antes de recuperar.
    $current=@(Targets | Where-Object { $_.Id -eq $Device.Id -and $_.Vendor -eq 'INTEL' -and $_.BasicVideo })
    if($current.Count -ne 1 -or -not (Test-Path -LiteralPath $Inf -PathType Leaf)){return $false}
    $txt=ReadInf $Inf
    if($txt -notmatch '(?m)^\s*CLASS\s*=\s*DISPLAY\s*$'){return $false}
    # Confirma um ID real/compativel declarado no modelo do INF (nao comentarios).
    # VEN/DEV sem SUBSYS costuma estar em CompatibleIds, nao em HardwareIds.
    $matchingId=$null
    foreach($hw in @($current[0].HW+$current[0].Compat)){
        if($hw -notmatch '^PCI\\VEN_8086&DEV_[0-9A-F]{4}'){continue}
        $pattern='(?im)^\s*[^;\r\n=]+=[^;\r\n]*,\s*"?'+[regex]::Escape($hw)+'"?\s*(?:;[^\r\n]*)?$'
        if($txt -match $pattern){$matchingId=$hw;break}
    }
    # Direciona a API ao HardwareId mais especifico, incluindo SUBSYS/REV se disponivel.
    $hardwareId=@($current[0].HW | Where-Object { $_ -match '^PCI\\VEN_8086&DEV_[0-9A-F]{4}' } | Select-Object -First 1)
    if(-not $matchingId -or $hardwareId.Count -ne 1){L "Recuperacao Intel ignorada: INF sem ID compativel confirmado de $($Device.Id)." Yellow;return $false}
    $hardwareId=[string]$hardwareId[0]
    $key=$Device.Id+'|'+$Inf
    if(-not $script:IntelVideoRepairAttempts){$script:IntelVideoRepairAttempts=@{}}
    if($script:IntelVideoRepairAttempts.ContainsKey($key)){return $false}
    $script:IntelVideoRepairAttempts[$key]=$true
    L "RECUPERACAO INTEL: pnputil nao ativou o video. Aplicando INF compativel ao hardware $hardwareId : $Inf" Yellow
    try{
        $result=Invoke-IntelDriverUpdate $hardwareId ([IO.Path]::GetFullPath($Inf))
        if($result.RebootRequired){
            $script:IntelVideoRebootRequired=@($script:IntelVideoRebootRequired)+$Device.Id
            L 'Windows solicitou reinicializacao para concluir o driver Intel. Reinicio automatico desativado.' Yellow
        }
        if(-not $result.Success){
            $detail=(New-Object ComponentModel.Win32Exception($result.Error)).Message
            L "FALHA RECUPERACAO INTEL: codigo=$($result.Error) | $detail | Consulte $env:WINDIR\INF\setupapi.dev.log" Red
            return $false
        }
        Scan
        if(Test-VideoDeviceReady $Device.Id){L 'RECUPERACAO INTEL: driver de video ativo confirmado.' Green;return $true}
        if($result.RebootRequired){return $true}
        L 'A API terminou, mas o driver Intel ainda nao foi confirmado ativo.' Yellow
    }catch{L "FALHA RECUPERACAO INTEL: $($_.Exception.Message)" Red}
    return $false
}
function InstallVideoFirst([array]$tg){
    $basic=@($tg|Where-Object{ $_.BasicVideo -and @('NVIDIA','AMD','INTEL') -contains $_.Vendor })
    foreach($g in $basic){
        L "FASE 1 VIDEO PRIMEIRO: $($g.Vendor) basico detectado." Cyan
        $roots=@()
        if($g.Vendor -eq 'NVIDIA'){
            # NVIDIA: tenta primeiro pastas especificas (RTX), depois faz fallback para NVIDIA.
            # Ajuste para GT series (ex.: GT610/GT1030): usar D:\DriversRepo\NVIDIA\GT quando existir.
            if(Test-Path -LiteralPath (Join-Path $Repo 'NVIDIA\RTX')){ $roots += (Join-Path $Repo 'NVIDIA\RTX') }

            # Detecta placa "GT" pelas Tokens/Ids (sem depender do nome amigavel do Windows).
            $isGT = $false
            try{
                if($g.Tokens){
                    foreach($t in $g.Tokens){
                        if($t -and ($t -match 'GT[0-9]{3,4}' -or $t -match 'NVIDIA\\GT\\')){ $isGT = $true; break }
                    }
                }
            } catch {}

            if($isGT){
                $gtRoot = (Join-Path $Repo 'NVIDIA\GT')
                if(Test-Path -LiteralPath $gtRoot){
                    $roots += $gtRoot
                }
            }

            # Fallback para pasta geral NVIDIA.
            if($ModoCompleto){ $roots += (Join-Path $Repo 'NVIDIA') }
            else {
                # Mesmo no modo rapido, incluir fallback NVIDIA
                if(Test-Path -LiteralPath (Join-Path $Repo 'NVIDIA')){ $roots += (Join-Path $Repo 'NVIDIA') }
            }
        } elseif($g.Vendor -eq 'AMD'){
            $roots+=(Join-Path $Repo 'AMD')
        } elseif($g.Vendor -eq 'INTEL'){
            $roots += @(Get-IntelGraphicsRoots)
            if(Test-Path -LiteralPath (Join-Path $Repo 'INTEL\Graphics')){$roots+=(Join-Path $Repo 'INTEL\Graphics')}
            $roots+=(Join-Path $Repo 'INTEL')
        }
        $c=@()
        if($g.Vendor -eq 'INTEL'){
            # Prioriza o pacote da geracao, incluindo INTEL\7th, antes da arvore geral.
            $c=@(FindInf @(Get-IntelGraphicsRoots) $g.Tokens $g.Vendor -DisplayOnly -Max $MaxCandidatesPerDevice)
        }
        if($c.Count -eq 0){ $c=@(FindInf $roots $g.Tokens $g.Vendor -DisplayOnly -Max $MaxCandidatesPerDevice) }
        if($c.Count -eq 0){
            L 'Nenhum INF de video exato encontrado rapidamente.' Yellow
            if($ForcarVideoLote){
                if($g.Vendor -eq 'NVIDIA' -and (Test-Path -LiteralPath (Join-Path $Repo 'NVIDIA\RTX'))){[void](PnpFolder (Join-Path $Repo 'NVIDIA\RTX') 'NVIDIA RTX lote forcado' $BatchTimeoutSec)}
                elseif($g.Vendor -eq 'AMD'){[void](PnpFolder (Join-Path $Repo 'AMD') 'AMD lote forcado' $BatchTimeoutSec)}
            }
            continue
        }
        foreach($i in $c){
            L "INF video Score=$($i.Score): $($i.Path)" Cyan
            $r=PnpInf $i.Path "Video $($g.Vendor)"
            # Atualiza a enumeracao e verifica se o driver deixou de ser basico.
            Scan
            if(Test-VideoDeviceReady $g.Id){
                L 'Driver de video ativo confirmado no dispositivo. Pulando demais candidatos de video.' Green
                break
            }
            if($g.Vendor -eq 'INTEL' -and (Repair-IntelBasicVideo $g $i.Path)){break}
            # Para NVIDIA, nv_dispi costuma ser o pacote correto; evita gastar tempo com candidatos extras depois dele.
            if(([IO.Path]::GetFileName($i.Path) -ieq 'nv_dispi.inf') -and ($r.Code -eq 0 -or $r.Code -eq 259)){
                L 'nv_dispi.inf processado. Pulando demais candidatos de video.' Green
                break
            }
        }
    }
}

Clear-Host
L '============================================================' Cyan
$script:IntelVideoRepairAttempts=@{}
$script:IntelVideoRebootRequired=@()
L "Versao=IntelVideoRecovery-2 | Script=$PSCommandPath | PowerShell=$($PSVersionTable.PSVersion)"
L '  ATUALIZAR DRIVERS' Cyan
L '============================================================' Cyan
$cpu=CpuInfo; $tg=Targets; $script:IntelGen = Get-IntelGenCpu $cpu.Name; $ultra=IsUltra $cpu $tg; $ultraPath=Join-Path $Repo 'INTEL\Chipset Ultra'
L "Repo=$Repo | CPU=$($cpu.Vendor) | NomeCPU=$($cpu.Name) | IntelGen=$script:IntelGen | IntelUltra=$ultra | Admin=$(IsAdmin)"
L "ModoCompleto=$ModoCompleto | ForcarVideoLote=$ForcarVideoLote | ForcarLoteFabricante=$ForcarLoteFabricante | DISM=$UseDismFallback | SemLoteUltra=$SemLoteUltra"
L "Dispositivos alvo: $($tg.Count)"
foreach($t in $tg){ L "TARGET: $($t.Name) | Err=$($t.Err) | Vendor=$($t.Vendor) | ID=$($t.Id)"; if($t.Tokens){L "  TOKENS: $($t.Tokens -join ' | ')"} }
if(-not(IsAdmin)){ L 'ERRO: execute Atualizar Drivers.cmd como administrador.' Red; exit 5 }

# 1) Video primeiro, para tentar entrar no Windows ja com driver de video atualizado.
InstallVideoFirst $tg
Scan -Async
$tg=Targets

# (debug removido)

# Corrige cenarios em que a pasta D:\DriversRepo\INTEL\4º existia, mas o CMD temporario quebrava o caractere º.
InstallIntelGraphicsAggressive
$tg=Targets

# 1.5) Rede/WiFi prioritario, para nao deixar controladora WiFi pendente quando o INF existe no DriversRepo.
InstallNetworkPriority $tg
Scan -Async
$tg=Targets

# 1.55) Bluetooth prioritario: evitar passar direto quando existir INF em DriversRepo.
InstallBluetoothMissingPriority $tg
Scan -Async
$tg=Targets
# 1.57) Audio prioritario: codecs HDAUDIO/Realtek/Conexant que antes passavam direto.
InstallAmdAudioCoprocessor $tg
$tg=Targets
InstallAudioMissingPriority $tg
Scan -Async
$tg=Targets
# 1.6) Intel 4a geracao: fallback especifico para video/rede em D:\DriversRepo\INTEL\4...
# Resolve casos em que o driver existe na pasta da geracao, mas o Windows nao amarrou no INF exato na primeira tentativa.
InstallIntelGraphicsAggressive
$tg=Targets

# 1.6.5) Intel 4a: Controlador de Barramento SM (SMBus) - procurar primeiro no caminho dedicado.
# Motivo: reduzir risco e acelerar a instalacao do SMBus/SM Bus.
if($script:IntelGen -eq '4'){
    $smBusPendentes=@($tg | Where-Object{
        if(-not $_){return $false}
        $s=(($_.Name+'|'+$_.Class+'|'+$_.Id+'|'+(($_.HW+$_.Compat)-join '|'))).ToUpperInvariant()
        return ($s -match 'SM\\BUS|SMBUS|SM BUS|BARRAMENTO SM|CONTROLADOR DE BARRAMENTO SM|SMBUS' -or $s -match 'SMBUS\\|SMBUS&|SMB\\')
    })

    if($smBusPendentes.Count -gt 0){
        $smRoot = Join-Path $Repo 'INTEL\Intel Chipset\Controlador_Barramento_SM'
        if(Test-Path -LiteralPath $smRoot){
            L "FASE 1.6.5 SMBUS Intel 4a: $($smBusPendentes.Count) pendente(s). Buscando INF em: $smRoot" Yellow
            $candsSM = FindInfsForMany @($smRoot) $smBusPendentes 2
            if($candsSM.Count -eq 0){
                L "SMBUS: nenhum INF encontrado no diretorio dedicado. Fallback curto no repo raiz para nao deixar pendente." Yellow
                $candsSM = FindInfsForMany @($Repo) $smBusPendentes 2
            }

            foreach($c in $candsSM){
                L "INF SMBUS Score=$($c.Score): $($c.Path)" Cyan
                [void](PnpInf $c.Path "SMBus/SM Bus Intel 4a")
                $folder=Split-Path -Parent $c.Path
                if($folder -and (Test-Path -LiteralPath $folder)){
                    [void](PnpFolder $folder "SMBus pasta do INF" 180)
                }
            }
            Scan -Async
            $tg=Targets
        } else {
            L "FASE 1.6.5 SMBUS: diretorio dedicado nao encontrado: $smRoot" Yellow
        }
    }
}

# 2) Intel Ultra rapido: tenta INFs exatos primeiro. So cai no lote se ainda sobrar.

# Observacao: so faz busca em INTEL\Chipset Ultra quando CPU for Core Ultra.
if($ultra){
    $intelTargets=@($tg|Where-Object{ -not $_.BasicVideo -and $_.Vendor -eq 'INTEL' })
    if($intelTargets.Count -gt 0){
        L "FASE 2 INTEL ULTRA RAPIDA: tentando INFs exatos antes do lote pesado. Dispositivos=$($intelTargets.Count)" Cyan

        $ultraRoot1 = (Join-Path $Repo 'INTEL\Chipset Ultra')
        $ultraRoot2 = (Join-Path $Repo 'INTEL\Intel Chipset')
        $ultraRoot3 = (Join-Path $Repo 'INTEL')
        $ultraRoot4 = $Repo

        # Cascata de roots para INFs exatos (primeiro Chipset Ultra; se faltar, fallback progressivo)
        $cands=@()
        foreach($r in @($ultraRoot1,$ultraRoot2,$ultraRoot3,$ultraRoot4)){
            if(Test-Path -LiteralPath $r){
                L "ULTRA RAPIDA: buscando INFs exatos em: $r" Cyan
                $try=FindInfsForMany @($r) $intelTargets 1
                if($try -and $try.Count -gt 0){
                    $cands += $try
                    # reduz targets para nao repetir em lote pesado demais
                    $installedIds=@()
                }
            }
        }

        $cands = @($cands | Sort-Object Score -Descending | Select-Object -First $intelTargets.Count | Sort-Object Path -Unique)
        L "INFs exatos selecionados: $($cands.Count)" Cyan
        foreach($c in $cands){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }

        Scan -Async
        $tg=Targets
        $remainingIntel=@($tg|Where-Object{ -not $_.BasicVideo -and $_.Vendor -eq 'INTEL' })

        if($remainingIntel.Count -gt 0 -and -not $SemLoteUltra){
            $rootsLote=@()
            foreach($r in @($ultraRoot1,$ultraRoot2,$ultraRoot3,$ultraRoot4)){
                if(Test-Path -LiteralPath $r){ $rootsLote += $r }
            }

            # Aplica lote completo progressivo: começa no mais específico e vai relaxando até $Repo.
            foreach($lr in $rootsLote){
                if($remainingIntel.Count -le 0){ break }
                L "FASE 3 INTEL ULTRA LOTE: still restam $($remainingIntel.Count) dispositivo(s). Aplicando em lote: $lr" Yellow
                [void](PnpFolder $lr "Intel Ultra - fallback lote $lr" $BatchTimeoutSec)
                if($UseDismFallback){ L "DISM fallback solicitado para Intel Ultra (root=$lr)." Yellow; [void](DismFolder $lr) }
                Scan -Async
                $tg=Targets
                $remainingIntel=@($tg|Where-Object{ -not $_.BasicVideo -and $_.Vendor -eq 'INTEL' })
            }
        }
    }
} else {
    # Configuracoes gerais: busca em lote por fabricante para evitar varrer a mesma pasta varias vezes.
    $others=@($tg|Where-Object{ -not $_.BasicVideo })
    if($others.Count -gt 0){
        L "FASE 2 GERAL RAPIDA: INF exato em lote para $($others.Count) dispositivo(s)." Cyan
        foreach($v in @($others|Select-Object -ExpandProperty Vendor -Unique)){
            $devs=@($others|Where-Object{$_.Vendor -eq $v})
            if($v -eq 'UNKNOWN'){
                # Antes pulavamos UNKNOWN para nao varrer o Repo inteiro. Como agora a
                # leitura de INFs e cacheada (uma unica passada), vale buscar no Repo
                # para nao deixar driver pendente por falta de classificacao de fabricante.
                L "Vendor=UNKNOWN: buscando por tokens no DriversRepo (cache ativo, baixo custo)." Yellow
                $cands=FindInfsForMany @($Repo) $devs 1
                L "Vendor=UNKNOWN | INFs selecionados: $($cands.Count)" Cyan
                foreach($c in $cands){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }
                continue
            }
            $roots=RootsFor $v
            if($ModoCompleto){$roots+=$Repo}
            $cands=FindInfsForMany $roots $devs 1
            L "Vendor=$v | INFs selecionados: $($cands.Count)" Cyan
            foreach($c in $cands){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }
        }
        Scan -Async
        $tg=Targets
    }
}

# 2.7.5) MSI Hidden ACPI (Software Component Interface / MBID0001)
# Seu caso no log: dispositivo pendente com ID=ACPI\MBID0001\1 e Erro=28 (ConfigManagerErrorCode).
# Tenta aplicar o INF complementar que fica em D:\DriversRepo\Complementos\MSI.
try{
    $msiInf = Join-Path $Repo 'Complementos\MSI\msiswacpi.inf'
    if(-not (Test-Path -LiteralPath $msiInf)){
        # fallback direto no disco (caso o $Repo mude)
        $msiInf = 'D:\DriversRepo\Complementos\MSI\msiswacpi.inf'
    }

    $msiPend = @($tg | Where-Object{
        if(-not $_){return $false}
        $idT = ([string]$_.Id)
        return ($idT -match 'ACPI\\MBID0001')
    })

    if($msiPend.Count -gt 0){
        if(Test-Path -LiteralPath $msiInf){
            L "FASE 2.7.5 MSI: $($msiPend.Count) pendente(s) ACPI\\MBID0001. Instalando INF: $msiInf" Yellow
            [void](PnpInf $msiInf 'MSI Software Component Interface')
            Scan -Async
            $tg = Targets
        } else {
            L "FASE 2.7.5 MSI: pendente ACPI\\MBID0001, mas msiswacpi.inf nao encontrado em: $msiInf" Red
        }
    }
}catch{ L "FASE 2.7.5 MSI: erro durante instalacao: $($_.Exception.Message)" Red }

# 2.8) Intel Ultra - fase dedicada para SWC (PPM/DTT/DTTCFG)
# (Seu caso: hardware IDs começam com SWC\VID_8086_* e ficam com Erro=28.)
try{
    $swcPend=@($tg | Where-Object{
        if(-not $_){return $false}
        $idT=(($_.Id) -as [string])
        $tok=(($_.HW + $_.Compat) -join '|')
        $s=(($idT+'|'+$tok).ToUpperInvariant())
        return ($s -match 'SWC\\VID_8086|PPM_|DTT_|DTTCFG|PPM\\|DTT\\|DTTCFG\\')
    })
    if($swcPend.Count -gt 0){
        L "FASE 2.8 INTEL ULTRA SWC: $($swcPend.Count) dispositivo(s) pendente(s)." Yellow
        $ultraSwcRoots=@()
        $r1 = Join-Path $Repo 'INTEL\Chipset Ultra'
        $r2 = Join-Path $Repo 'INTEL\Intel Chipset'
        $r3 = Join-Path $Repo 'INTEL'
        $r4 = $Repo
        foreach($rr in @($r1,$r2,$r3,$r4)){
            if(Test-Path -LiteralPath $rr){$ultraSwcRoots += $rr}
        }

        # Busca por tokens exatos primeiro.
        $candsSWC = FindInfsForMany $ultraSwcRoots $swcPend 3

        # Fallback: se tokens não casarem, procura no texto por GUID/VID8086 e palavras de PPM/DTT.
        if($candsSWC.Count -eq 0){
            L 'SWC: sem INF por tokens. Fallback por texto (VID_8086/PPM/DTT) no Repo.' Yellow
            $allInfs = @(Get-InfFiles $r1)
            if($allInfs.Count -eq 0){ $allInfs = @(Get-InfFiles $r4) }
            $map=@{}
            foreach($inf in $allInfs){
                $upTxt = ReadInf $inf.FullName
                if(-not $upTxt){continue}
                if($upTxt -match 'VID_8086|SWC\\VID_8086|PPM_|DTT_|DTTCFG'){
                    foreach($d in $swcPend){
                        $score = ScoreInfText $upTxt $inf.FullName $d.Tokens $d.Vendor
                        # Força: se o INF contiver explicitamente o padrão SWC, sobe score.
                        if($upTxt -match 'SWC\\VID_8086' -or $upTxt -match 'PPM_|DTT_|DTTCFG'){$score += 250}
                        if($score -gt 0){
                            if(-not $map.ContainsKey($d.Id)){$map[$d.Id]=New-Object Collections.Generic.List[object]}
                            $map[$d.Id].Add([pscustomobject]@{Device=$d;Path=$inf.FullName;Score=$score})
                        }
                    }
                }
            }
            $sel=@()
            foreach($k in $map.Keys){
                $sel += @($map[$k] | Sort-Object Score -Descending | Select-Object -First 3)
            }
            $candsSWC = @($sel | Sort-Object Path -Unique | Sort-Object Score -Descending)
        }

        L "SWC: INFs selecionados: $($candsSWC.Count)" Yellow
        foreach($c in $candsSWC){
            L "INF SWC Score=$($c.Score): $($c.Path)" Cyan
            [void](PnpInf $c.Path "Intel Ultra SWC $($c.Device.Name)")
        }

        Scan -Async
        $tg = Targets
    }
}catch{
    L "FASE 2.8 SWC: erro durante busca/instalacao: $($_.Exception.Message)" Red
}

# 3) Complementar geral: se sobrou algo, busca exata nas pastas de fabricante.
$others=@($tg|Where-Object{ -not $_.BasicVideo })
if($others.Count -gt 0){
    L "FASE COMPLEMENTAR: ainda restaram $($others.Count) dispositivo(s). Busca curta por Hardware ID exato." Cyan
    foreach($v in @($others|Select-Object -ExpandProperty Vendor -Unique)){
        $devs=@($others|Where-Object{$_.Vendor -eq $v})
        if($v -eq 'UNKNOWN'){
            # Ver FASE 2: agora buscamos UNKNOWN no Repo com cache, em vez de pular.
            L "FASE COMPLEMENTAR UNKNOWN: buscando tokens restantes no DriversRepo." Yellow
            $candsU=FindInfsForMany @($Repo) $devs 1
            foreach($c in $candsU){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }
            continue
        }
        $roots=RootsFor $v; if($ModoCompleto){$roots+=$Repo}
        $cands=FindInfsForMany $roots $devs 1
        foreach($c in $cands){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }
    }
}

if($ForcarLoteFabricante -and -not $ultra){
    L 'FASE LOTE FORCADO: fabricantes restantes.' Yellow
    foreach($v in @((Targets)|Where-Object{$_.Vendor -ne 'UNKNOWN'}|Select-Object -ExpandProperty Vendor -Unique)){
        foreach($r in (RootsFor $v|Where-Object{Test-Path -LiteralPath $_}|Select-Object -Unique)){ [void](PnpFolder $r "Lote $v" $BatchTimeoutSec) }
    }
}

L 'Scan final.' Cyan; Scan
L 'RESULTADO FINAL' Green
Start-Sleep 2

# Resumo breve do PC (CPU/RAM/GPU/Armazenamento)
# Observacao: em alguns ambientes o script pode ser executado em contexto/powershell sem o parser de expressao esperado.
# Para evitar quebra, coletamos com cmdlets simples e guardamos tudo em strings.
try{
    $cpuObj = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $cpuName = ''
    try{ if($cpuObj -and $cpuObj.Name){ $cpuName = [string]$cpuObj.Name } }catch{}

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -First 1
    $memGB = ''
    try{ if($cs -and $cs.TotalPhysicalMemory){ $memGB = [math]::Round(($cs.TotalPhysicalMemory/1GB),1).ToString() } }catch{}

    $gpuStr = ''
    try{
        $gpus = Get-CimInstance -ClassName Win32_VideoController | Select-Object Name,AdapterRAM | Sort-Object Name
        $parts=@()
        foreach($g in $gpus){
            $ramTxt=''
            try{
                if($g.AdapterRAM){ $ramTxt = ( [math]::Round(($g.AdapterRAM/1GB),1) ).ToString() + 'GB' }
            }catch{}
            $n = ''
            try{ if($g.Name){ $n=[string]$g.Name } }catch{}
            if(-not $n){ $n='GPU' }
            if($ramTxt){ $parts += @($n + ' (' + $ramTxt + ')') } else { $parts += @($n) }
        }
        if($parts -and $parts.Count -gt 0){ $gpuStr = ($parts -join ' | ') } else { $gpuStr='(nao detectada via WMI)' }
    } catch { $gpuStr='(falha ao coletar GPU via WMI)' }

    $diskStr=''
    try{
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | Select-Object DeviceID,Size,FreeSpace
        $dparts=@()
        foreach($d in $disks){
            $szTxt=''
            $freeTxt=''
            try{ if($d.Size){ $szTxt = [math]::Round(($d.Size/1GB),1).ToString() } }catch{}
            try{ if($d.FreeSpace){ $freeTxt = [math]::Round(($d.FreeSpace/1GB),1).ToString() } }catch{}
            $dparts += @([string]$d.DeviceID + ': ' + $szTxt + 'GB (livre ' + $freeTxt + 'GB)')
        }
        if($dparts -and $dparts.Count -gt 0){ $diskStr = ($dparts -join ' | ') } else { $diskStr='(sem discos fisicos reportados)' }
    } catch { $diskStr='(falha ao coletar armazenamento via WMI)' }

    $cpuTxt = if($cpuName){$cpuName}else{'(nao detectada)'}
    $ramTxt = if($memGB){$memGB}else{'(nao detectada)'}
    # Remove “(4GB)” e similares no caso solicitado (ex.: RTX 5060 (4GB)).
    # Mantém o nome da GPU, mas remove quantidade/VRAM entre parênteses.
    $gpuStr = $gpuStr -replace '\s*\([^)]*\d+\s*(GB|MB|TB)[^)]*\)\s*',' '
    $gpuStr = ($gpuStr -replace '\s+',' ').Trim()

    L "Resumo do PC: CPU=$cpuTxt | RAM=${ramTxt}GB | GPU=$gpuStr | Armazenamento=$diskStr" Green
} catch {

    L "Resumo do PC: (falha ao coletar detalhes via WMI: $($_.Exception.Message))" Yellow
}

Start-Sleep 3


$end=Targets; $gpu=@($end|Where-Object{$_.BasicVideo}); $prob=@($end|Where-Object{-not $_.BasicVideo})
# Inclui video basico no resultado: pacote adicionado nao confirma driver ativo.
$prob=@($end)
if($prob.Count){
    L "Ainda restam $($prob.Count) dispositivo(s) alvo:" Yellow
    foreach($p in $prob){L " - $($p.Name) | Erro=$($p.Err) | Vendor=$($p.Vendor) | ID=$($p.Id)" Yellow}
}else{
    L 'Nenhum dispositivo alvo restante.' Green
}
L "Log salvo em: $Log" Cyan
if($script:IntelVideoRebootRequired.Count -gt 0){L 'Reinicie o Windows e execute novamente para confirmar o resultado.' Yellow;exit 3010}
if($prob.Count -gt 0){exit 1}
exit 0

