param(
  [string]$Version = '1.0.1',
  [string]$Output = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$required = @('Crimson Deploy Tool.exe', 'Crimson Native Deployer.exe', 'Crimson Updater.exe')
foreach ($file in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) {
    throw "Build fehlt: $file. Zuerst build.ps1 ausführen."
  }
}
if ([string]::IsNullOrWhiteSpace($Output)) {
  $Output = Join-Path $root "crimson-deploy-tool-$Version-update-package.zip"
}
if (Test-Path -LiteralPath $Output) { throw 'Die Ausgabedatei existiert bereits.' }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temp = Join-Path $tempRoot ('crimson-update-package-' + [guid]::NewGuid().ToString('N'))
$appDir = Join-Path $temp 'app'
try {
  New-Item -ItemType Directory -Path $appDir -Force | Out-Null
  $manifest = [ordered]@{
    name = 'Crimson Deploy Tool'
    version = $Version
    build = Get-Date -Format 'yyyy.MM.dd.HHmm'
    minUpdaterVersion = 1
    preserve = @('config/servers.json', 'config/deploy-state.json', 'config/app-settings.json', 'config/server-health.json', 'logs/', 'backups/')
    restart = 'Crimson Deploy Tool.exe'
  }
  [IO.File]::WriteAllText((Join-Path $temp 'update.json'), ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  $items = $required + @(
    'assets/app-icon.ico', 'assets/app-icon.png', 'assets/crimson-wordmark.png', 'assets/favicon.svg',
    'config/servers.example.json', 'config/app-settings.example.json',
    'src-wpf/app.ps1', 'src-wpf/go.mod', 'src-wpf/main.go', 'src-wpf/rsrc_windows_amd64.syso',
    'src-updater/go.mod', 'src-updater/main.go', 'src-updater/rsrc_windows_amd64.syso',
    'tools/Create-UpdatePackage.ps1', 'build.ps1', 'README.md', 'CHANGELOG.md', 'UPDATE_PACKAGES.md', 'Start-Debug.cmd'
  )
  foreach ($item in $items) {
    $src = Join-Path $root $item
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Paketdatei fehlt: $item" }
    $dst = Join-Path $appDir $item
    New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst
  }
  Copy-Item -LiteralPath (Join-Path $temp 'update.json') -Destination (Join-Path $appDir 'update.json')
  Compress-Archive -LiteralPath (Join-Path $temp 'update.json'), $appDir -DestinationPath $Output
} finally {
  $resolved = [IO.Path]::GetFullPath($temp)
  $prefix = $tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
      -not ([IO.Path]::GetFileName($resolved)).StartsWith('crimson-update-package-')) {
    throw 'Temporärer Pfad liegt außerhalb des Paketierungsbereichs.'
  }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host "Update-Paket erstellt: $Output"
