param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
if (-not $SkipBuild) { & (Join-Path $PSScriptRoot 'build.ps1') }
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'dist/Deployment'))
if (Test-Path -LiteralPath $packageRoot) {
  $resolved = (Resolve-Path -LiteralPath $packageRoot).Path
  if ($resolved -ne [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'dist/Deployment'))) { throw 'Ungültiger Paketpfad.' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
$appRoot = Join-Path $packageRoot 'app'
New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Crimson Deploy Tool.exe') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Crimson Updater.exe') -Destination $appRoot
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'assets') -Destination $appRoot -Recurse
$configRoot = Join-Path $appRoot 'config'
New-Item -ItemType Directory -Force -Path $configRoot | Out-Null
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'config') -Filter '*.example.json' | Copy-Item -Destination $configRoot
[IO.File]::WriteAllText((Join-Path $appRoot 'layout.json'), '{"layoutVersion":2}', [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'update.json') -Destination $appRoot
Write-Host "Programmpaket erstellt: $packageRoot"
