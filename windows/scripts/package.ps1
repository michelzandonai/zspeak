[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$windowsRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $windowsRoot
$solution = Join-Path $windowsRoot 'ZSpeak.Windows.sln'
$publish = Join-Path $windowsRoot 'artifacts\publish'
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($dotnetCommand) { $dotnetCommand.Source } else { Join-Path $env:ProgramFiles 'dotnet\dotnet.exe' }
if (-not (Test-Path $dotnet)) { throw 'SDK .NET 8 não encontrado.' }

Push-Location $repositoryRoot
try {
    & $dotnet restore $solution --locked-mode
    if ($LASTEXITCODE -ne 0) { throw "dotnet restore falhou com código $LASTEXITCODE" }
    & $dotnet build $solution -c Release --no-restore
    if ($LASTEXITCODE -ne 0) { throw "dotnet build falhou com código $LASTEXITCODE" }
    if (-not $SkipTests) {
        & $dotnet test $solution -c Release --no-build
        if ($LASTEXITCODE -ne 0) { throw "dotnet test falhou com código $LASTEXITCODE" }
    }
    & $dotnet publish (Join-Path $windowsRoot 'src\ZSpeak.App\ZSpeak.App.csproj') `
        -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=false -o $publish
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish falhou com código $LASTEXITCODE" }

    $runtimeConfigPath = Join-Path $publish 'ZSpeak.App.runtimeconfig.json'
    $runtimeConfig = Get-Content $runtimeConfigPath -Raw | ConvertFrom-Json
    if (-not $runtimeConfig.runtimeOptions.includedFrameworks -or $runtimeConfig.runtimeOptions.frameworks) {
        throw 'Publish inválido: o pacote não está autocontido.'
    }

    if (-not $SkipInstaller) {
        $candidates = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
        )
        $iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $iscc) {
            throw 'Inno Setup 6 não encontrado. Instale com: winget install JRSoftware.InnoSetup'
        }
        & $iscc (Join-Path $windowsRoot 'installer\zspeak.iss')
        if ($LASTEXITCODE -ne 0) { throw "ISCC falhou com código $LASTEXITCODE" }
    }
}
finally {
    Pop-Location
}
