param(
  [string]$Version = '1.0.0',
  [string]$Output = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($Output)) {
  $Output = Join-Path $root ("crimson-deploy-tool-$Version-update-package.zip")
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ("crimson-update-package-" + [guid]::NewGuid().ToString('N'))
$appDir = Join-Path $temp 'app'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
$manifest = [ordered]@{
  name = 'Crimson Deploy Tool'
  version = $Version
  build = (Get-Date -Format 'yyyy.MM.dd.HHmm')
  minUpdaterVersion = 1
  preserve = @('config/servers.json', 'config/deploy-state.json', 'config/app-settings.json', 'config/server-health.json', 'logs/', 'backups/')
  restart = 'Crimson Deploy Tool.exe'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temp 'update.json') -Encoding UTF8
$items = @('Crimson Deploy Tool.exe','Crimson Native Deployer.exe','Crimson Updater.exe','assets','runtime','src-wpf','src-updater','tools','README_WPF_1.0.0_STABLE.txt','UPDATE_PACKAGES.md','Start-Debug.cmd','update.json')
foreach ($item in $items) {
  $src = Join-Path $root $item
  if (Test-Path -LiteralPath $src) {
    $dst = Join-Path $appDir $item
    if ((Get-Item -LiteralPath $src).PSIsContainer) { Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force }
    else { Copy-Item -LiteralPath $src -Destination $dst -Force }
  }
}
if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
Compress-Archive -LiteralPath (Join-Path $temp 'update.json'), $appDir -DestinationPath $Output -Force
Remove-Item -LiteralPath $temp -Recurse -Force
Write-Host "Update Paket erstellt: $Output"
