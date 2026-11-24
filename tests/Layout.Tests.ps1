$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root=Split-Path -Parent $PSScriptRoot
$source=[IO.File]::ReadAllText((Join-Path $root 'src-wpf/app.ps1'))
$match=[regex]::Match($source,'(?s)\[xml\]\$xaml = @"\r?\n(.*?)\r?\n"@')
if(-not $match.Success){throw 'Hauptlayout fehlt.'}
[xml]$document=$match.Groups[1].Value
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($document))
try {
 $window.Content.Measure([Windows.Size]::new(1306,834));$window.Content.Arrange([Windows.Rect]::new(0,0,1306,834));$window.Content.UpdateLayout()
 foreach($name in @('StageZip','StageCheck','StageUpload','StageBuild','StageHealth','StageDone')){
  $pill=$window.FindName($name)
  if($null -eq $pill -or $pill.ActualHeight -le 0){throw "Pill fehlt: $name"}
  if($pill.CornerRadius.TopLeft -gt ($pill.ActualHeight/2+1)){throw "Rundung unverhältnismäßig: $name"}
 }
 foreach($name in @('DropZone','DeployButton','StatusText','PreflightButton','ServerManagerButton')){if($null -eq $window.FindName($name)){throw "Steuerelement fehlt: $name"}}
 Write-Host 'WPF-XAML geladen; 6 Pill-Geometrien und zentrale Steuerelemente geprüft.'
} finally { $window.Close() }
