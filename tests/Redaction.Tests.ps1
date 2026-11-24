$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src-wpf/app.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'PowerShell-Quelldatei enthält Syntaxfehler.' }
foreach ($name in @('Redact-SensitiveText', 'Write-RedactedJsonFile', 'Copy-RedactedTextFile', 'Write-AppLog', 'Write-Utf8Line')) {
    $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Funktion fehlt: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$samples = @(
    @('Authorization: Bearer example-credential', 'example-credential'),
    @('Failed request Bearer example-credential', 'example-credential'),
    @('password="example value with spaces"', 'example value with spaces'),
    @('{"token":"example-credential","safe":true}', 'example-credential'),
    @('X-Amz-Signature=abcdef012345&next=ok', 'abcdef012345'),
    @('X-Amz-Credential=example-credential&next=ok', 'example-credential')
)
foreach ($sample in $samples) {
    if ((Redact-SensitiveText $sample[0]).Contains($sample[1])) { throw 'Maskierung unvollständig.' }
}
if ((Redact-SensitiveText 'Deployment erfolgreich.') -ne 'Deployment erfolgreich.') { throw 'Normaler Logtext verändert.' }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('crimson-redaction-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
try {
    $jsonPath = Join-Path $testRoot 'support.json'
    Write-RedactedJsonFile @{ password = 'example value with spaces'; nested = @{ token = 'example-credential' }; safe = 'keep' } $jsonPath
    $json = Get-Content -LiteralPath $jsonPath -Raw
    if ($json.Contains('example-credential') -or $json.Contains('example value with spaces')) { throw 'JSON enthält Testgeheimnis.' }
    if (($json | ConvertFrom-Json).safe -ne 'keep') { throw 'JSON-Export beschädigt.' }
    $source = Join-Path $testRoot 'input.log'
    Set-Content -LiteralPath $source -Value 'token=example-credential'
    $destination = Join-Path $testRoot 'output.log'
    Copy-RedactedTextFile $source $destination
    if ((Get-Content -LiteralPath $destination -Raw).Contains('example-credential')) { throw 'Textkopie enthält Testgeheimnis.' }
    $script:LogFile = Join-Path $testRoot 'app.log'
    Write-AppLog 'Authorization: Bearer example-credential'
    if ((Get-Content -LiteralPath $script:LogFile -Raw).Contains('example-credential')) { throw 'App-Log enthält Testgeheimnis.' }
    function Redact-SensitiveText { throw 'Simulated redaction error' }
    $failedDestination = Join-Path $testRoot 'must-not-exist.log'
    Copy-RedactedTextFile $source $failedDestination
    if (Test-Path -LiteralPath $failedDestination) { throw 'Unredigierter Fallback wurde geschrieben.' }
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = $tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolved)).StartsWith('crimson-redaction-test-')) { throw 'Ungültiger Testpfad.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'Bestanden: 11 Prüfungen für Header, JSON, Logdateien und fehlersicheren Support-Export.'
