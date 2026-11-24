$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$previousGoOs = $env:GOOS
$previousGoArch = $env:GOARCH
try {
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    Push-Location (Join-Path $root 'src-wpf')
    try {
        & go build -trimpath -ldflags '-H=windowsgui -s -w' -o (Join-Path $root 'Crimson Deploy Tool.exe') .
        if ($LASTEXITCODE -ne 0) { throw 'Launcher-Build fehlgeschlagen.' }
    } finally { Pop-Location }
    Copy-Item -LiteralPath (Join-Path $root 'Crimson Deploy Tool.exe') -Destination (Join-Path $root 'Crimson Native Deployer.exe') -Force
    Push-Location (Join-Path $root 'src-updater')
    try {
        & go build -trimpath -ldflags '-H=windowsgui -s -w' -o (Join-Path $root 'Crimson Updater.exe') .
        if ($LASTEXITCODE -ne 0) { throw 'Updater-Build fehlgeschlagen.' }
    } finally { Pop-Location }
} finally {
    $env:GOOS = $previousGoOs
    $env:GOARCH = $previousGoArch
}
Write-Host 'Windows-x64-Launcher und Updater erstellt.'
