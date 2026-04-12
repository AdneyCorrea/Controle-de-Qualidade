$ErrorActionPreference = 'Stop'

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$source  = Join-Path $baseDir 'Launcher_Portatil.cs'
$icon    = Join-Path $baseDir 'web\assets\logo.ico'
$output  = Join-Path $baseDir 'Controle de Qualidade.exe'

function Write-Info($t) { Write-Host $t -ForegroundColor Cyan }
function Write-Ok($t) { Write-Host $t -ForegroundColor Green }
function Write-Err($t) { Write-Host $t -ForegroundColor Red }

if (-not (Test-Path $source)) { throw "Arquivo nao encontrado: $source" }
if (-not (Test-Path $icon)) { throw "Arquivo nao encontrado: $icon" }

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)

$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($csc) {
    Write-Info "Compilando launcher com csc.exe..."
    & $csc /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$icon" "/out:$output" $source
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $output)) {
        throw 'Falha ao gerar o launcher com csc.exe.'
    }
    Write-Ok "Launcher gerado com sucesso: $output"
    exit 0
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    $sdks = & dotnet --list-sdks 2>$null
    if ($LASTEXITCODE -eq 0 -and $sdks) {
        Write-Info 'csc.exe nao encontrado. Tentando compilar com dotnet SDK...'
        $buildDir = Join-Path $env:TEMP ("CQLauncherBuild_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $buildDir | Out-Null
        try {
            Copy-Item $source (Join-Path $buildDir 'Program.cs') -Force
            Copy-Item $icon (Join-Path $buildDir 'logo.ico') -Force
            @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <UseWindowsForms>true</UseWindowsForms>
    <ImplicitUsings>disable</ImplicitUsings>
    <Nullable>disable</Nullable>
    <AssemblyName>Controle de Qualidade</AssemblyName>
    <ApplicationIcon>logo.ico</ApplicationIcon>
    <EnableDefaultCompileItems>true</EnableDefaultCompileItems>
    <UseAppHost>true</UseAppHost>
  </PropertyGroup>
</Project>
"@ | Set-Content -Path (Join-Path $buildDir 'ControleQualidadeLauncher.csproj') -Encoding UTF8

            Push-Location $buildDir
            & dotnet publish 'ControleQualidadeLauncher.csproj' -c Release -r win-x64 --self-contained false /p:PublishSingleFile=true /p:DebugType=None /p:DebugSymbols=false
            Pop-Location

            $publishedExe = Get-ChildItem -Path (Join-Path $buildDir 'bin\Release') -Filter '*.exe' -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $publishedExe) { throw 'Falha ao localizar o EXE publicado pelo dotnet.' }
            Copy-Item $publishedExe.FullName $output -Force
            Write-Ok "Launcher gerado com sucesso: $output"
            exit 0
        }
        finally {
            if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

throw 'Nao foi possivel localizar csc.exe nem um .NET SDK compativel. Instale o .NET Framework 4.x Developer Pack ou o .NET SDK.'
