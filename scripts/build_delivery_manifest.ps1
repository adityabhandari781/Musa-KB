[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$required = @(
    'kb',
    'build/source-manifest.jsonl',
    'build/passage-manifest.jsonl',
    'build/kb-source-map.jsonl',
    'build/kb-validation-report.json',
    'scripts/validate_kb.ps1'
)
$artifacts = foreach ($relative in $required) {
    $full = Join-Path $repo $relative
    [ordered]@{
        path = $relative.Replace('\\','/')
        exists = Test-Path -LiteralPath $full
        kind = if (Test-Path -LiteralPath $full -PathType Container) { 'directory' } else { 'file' }
        bytes = if (Test-Path -LiteralPath $full -PathType Leaf) { (Get-Item -LiteralPath $full).Length } else { $null }
    }
}
$kbFiles = @(Get-ChildItem -LiteralPath (Join-Path $repo 'kb') -Filter '*.md' | Sort-Object Name | ForEach-Object { $_.Name })
$report = Get-Content -LiteralPath (Join-Path $repo 'build/kb-validation-report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    delivery_status = if ($report.status -eq 'passed' -and $kbFiles.Count -eq 25 -and @($artifacts | Where-Object { -not $_.exists }).Count -eq 0) { 'complete' } else { 'incomplete' }
    kb_document_count = $kbFiles.Count
    kb_documents = @($kbFiles)
    validation_report = 'build/kb-validation-report.json'
    artifacts = @($artifacts)
}
$path = Join-Path $repo 'build/delivery-manifest.json'
[System.IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
Write-Output "Delivery manifest: $($manifest.delivery_status)."
if ($manifest.delivery_status -ne 'complete') { exit 1 }
