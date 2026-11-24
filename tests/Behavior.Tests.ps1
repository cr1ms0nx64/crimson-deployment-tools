$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src-wpf/app.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Quote-ProcessArg','Test-SafeArchivePath','Read-UpdatePackageManifest','Resolve-KeyPath','Resolve-ServerKeyPath','Test-CrimsonSshOnline')) {
 $definition = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
 if (-not $definition) { throw "Funktion fehlt: $name" }
 . ([scriptblock]::Create($definition.Extent.Text))
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeArguments {
 [DllImport("shell32.dll", SetLastError=true)] static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string text, out int count);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
 public static string[] Parse(string text) {
  int count; var pointer=CommandLineToArgvW(text,out count); if(pointer==IntPtr.Zero) throw new Exception("Cannot parse command line");
  try { var result=new string[count]; for(int i=0;i<count;i++) result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer,i*IntPtr.Size)); return result; }
  finally { LocalFree(pointer); }
 }
}
'@
$checks = 0
foreach ($value in @('simple','value with spaces','C:\folder with spaces\','embedded"quote','slashes\\"quoted','\\server\share\','','ümlaut')) {
 $actual = [NativeArguments]::Parse('program.exe ' + (Quote-ProcessArg $value))
 if ($actual.Length -ne 2 -or $actual[1] -cne $value) { throw 'Windows-Argument wurde verändert.' }
 $checks++
}
foreach ($unsafe in @('../outside','app/../../outside','C:/outside','C:outside','app/file:stream','/absolute','\\server\share','app/CON.txt','app/NUL','app/LPT1.log','app/trailing.','app/trailing ','app//double','app/./file','')) {
 if (Test-SafeArchivePath $unsafe) { throw 'Unsicherer ZIP-Pfad akzeptiert.' }; $checks++
}
foreach ($safe in @('update.json','app/Crimson Deploy Tool.exe','app/app/assets/logo.png','app/app/','app/de-DE/messages.json')) {
 if (-not (Test-SafeArchivePath $safe)) { throw 'Gültiger ZIP-Pfad abgelehnt.' }; $checks++
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('crimson-behavior-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:Root = $testRoot; $script:AppRoot = Join-Path $testRoot 'app'
function New-TestZip($path, $manifest, $entries) {
 $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
 try {
  foreach ($item in @(@{ Name='update.json'; Value=($manifest | ConvertTo-Json) }) + @($entries | ForEach-Object { @{Name=$_;Value='synthetic fixture'} })) {
   $writer = [IO.StreamWriter]::new($zip.CreateEntry($item.Name).Open())
   try { $writer.Write($item.Value) } finally { $writer.Dispose() }
  }
 } finally { $zip.Dispose() }
}
try {
 foreach ($scenario in @('valid','restart','missing','layout','updater','duplicate','ADS')) {
  $manifest = @{ version='1.0.2'; restart='Crimson Deploy Tool.exe'; minUpdaterVersion=3; layoutVersion=2 }
  $entries = @('app/Crimson Deploy Tool.exe')
  switch ($scenario) {
   restart { $manifest.restart='../outside.exe' }
   missing { $entries=@('app/other.txt') }
   layout { $manifest.layoutVersion=1 }
   updater { $manifest.minUpdaterVersion=99 }
   duplicate { $entries+= 'APP/CRIMSON DEPLOY TOOL.EXE' }
   ADS { $entries+= 'app/payload:stream' }
  }
  $zipPath=Join-Path $testRoot ($scenario+'.zip'); New-TestZip $zipPath $manifest $entries
  $accepted=$true
  try { $null=Read-UpdatePackageManifest $zipPath } catch { $accepted=$false }
  if ($accepted -ne ($scenario -eq 'valid')) { throw "Falsche Paketprüfung: $scenario" }; $checks++
 }
 $key=Join-Path $testRoot 'synthetic key'; [IO.File]::WriteAllText($key,'synthetic fixture')
 $source='public class Fixture { public static int Main(string[] args) { return args.Length > 0 ? 0 : 1; } }'
 Add-Type -TypeDefinition $source -OutputAssembly (Join-Path $testRoot 'ssh-fixture.exe') -OutputType ConsoleApplication
 function Get-Command { param($Name,$ErrorAction) [pscustomobject]@{Source=(Join-Path $testRoot 'ssh-fixture.exe')} }
 if (-not (Test-CrimsonSshOnline ([pscustomobject]@{host='example.test';port=22;username='fixture';privateKeyPath=$key}) 3000)) { throw 'SSH-Prozessprüfung unter Windows PowerShell fehlgeschlagen.' }; $checks++
} finally {
 $resolved=[IO.Path]::GetFullPath($testRoot)
 $tempPrefix=[IO.Path]::GetTempPath().TrimEnd('\')+'\'
 if (-not $resolved.StartsWith($tempPrefix) -or -not [IO.Path]::GetFileName($resolved).StartsWith('crimson-behavior-test-')) { throw 'Ungültiger Testpfad.' }
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "$checks Verhaltenstests bestanden; keine Serverkontakte oder Backups."
