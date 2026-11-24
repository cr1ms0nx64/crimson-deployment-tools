param([string]$Version = '1.0.2', [string]$Output = '')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z._-]+)?$') { throw 'Ungültige Version.' }
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $root 'package.ps1') -SkipBuild
$packageRoot = Join-Path $root 'dist/Deployment'
if ([string]::IsNullOrWhiteSpace($Output)) { $Output = Join-Path $root "crimson-deploy-tool-$Version-update-package.zip" }
if (Test-Path -LiteralPath $Output) { throw 'Die Ausgabedatei existiert bereits.' }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temp = Join-Path $tempRoot ('crimson-update-package-' + [guid]::NewGuid().ToString('N'))
try {
  $appDir = Join-Path $temp 'app'
  New-Item -ItemType Directory -Path $appDir -Force | Out-Null
  Get-ChildItem -LiteralPath $packageRoot | Copy-Item -Destination $appDir -Recurse
  $manifest = [ordered]@{
    name = 'Crimson Deploy Tool'; version = $Version; layoutVersion = 2
    build = Get-Date -Format 'yyyy.MM.dd.HHmm'; minUpdaterVersion = 3
    preserve = @('app/config/servers.json', 'app/config/deploy-state.json', 'app/config/app-settings.json', 'app/config/server-health.json', 'app/logs/', 'app/backups/')
    restart = 'Crimson Deploy Tool.exe'
  }
  [IO.File]::WriteAllText((Join-Path $temp 'update.json'), ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  Compress-Archive -LiteralPath (Join-Path $temp 'update.json'), $appDir -DestinationPath $Output
} finally {
  $resolved = [IO.Path]::GetFullPath($temp)
  if (-not $resolved.StartsWith($tempRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('crimson-update-package-')) { throw 'Ungültiger temporärer Pfad.' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host "Update-Paket erstellt: $Output"
