[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonLines([string]$Path) {
    @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$kbPath = Join-Path $repo 'kb'
$outputPath = Join-Path $kbPath '26-all-texts.md'
$artifactRoot = if (Test-Path -LiteralPath (Join-Path $repo 'build\longterm\source-manifest.jsonl')) { Join-Path $repo 'build\longterm' } else { Join-Path $repo 'build' }
$sourceRows = Read-JsonLines -Path (Join-Path $artifactRoot 'source-manifest.jsonl')
$sources = @($sourceRows | Sort-Object { [int]$_.source_id.Substring(1) })

$textFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repo 'data\texts') -File -Filter '*.txt'
    Get-ChildItem -LiteralPath (Join-Path $repo 'data\transcripts') -File -Filter '*.txt'
) | Sort-Object FullName

$builder = [System.Text.StringBuilder]::new()
[void]$builder.AppendLine('# All texts and transcripts')
[void]$builder.AppendLine()
[void]$builder.AppendLine('This appendix contains the full corpus used by the knowledge base. Topic citations link to the matching S#### anchor below.')
[void]$builder.AppendLine()
$writtenPaths = @{}

foreach ($source in $sources) {
    $relativePath = [string]$source.relative_path
    $fullPath = Join-Path $repo ($relativePath.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
    $writtenPaths[$relativePath] = $true
    $anchor = $source.source_id.ToLowerInvariant()
    $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
    [void]$builder.AppendLine(('<a id="{0}"></a>' -f $anchor))
    [void]$builder.AppendLine(('## {0} — {1}' -f $source.source_id, $relativePath))
    [void]$builder.AppendLine()
    [void]$builder.AppendLine(('Source file: {0}' -f $relativePath))
    [void]$builder.AppendLine()
    if ([string]::IsNullOrWhiteSpace($content)) {
        [void]$builder.AppendLine('_Empty file._')
    } else {
        [void]$builder.AppendLine($content.TrimEnd())
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('---')
    [void]$builder.AppendLine()
}

# Include every physical .txt file, even files that predate or are otherwise
# absent from the source manifest. These do not receive S#### citation anchors.
foreach ($file in $textFiles) {
    $relativePath = $file.FullName.Substring($repo.Length + 1).Replace('\', '/')
    if ($writtenPaths.ContainsKey($relativePath)) { continue }
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    [void]$builder.AppendLine(('## Unmapped file — {0}' -f $relativePath))
    [void]$builder.AppendLine()
    [void]$builder.AppendLine(('Source file: {0}' -f $relativePath))
    [void]$builder.AppendLine()
    if ([string]::IsNullOrWhiteSpace($content)) {
        [void]$builder.AppendLine('_Empty file._')
    } else {
        [void]$builder.AppendLine($content.TrimEnd())
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('---')
    [void]$builder.AppendLine()
}

[System.IO.File]::WriteAllText($outputPath, $builder.ToString().TrimEnd() + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
Write-Output "Built $outputPath with $($sources.Count) mapped sources and $($textFiles.Count - $writtenPaths.Count) unmapped files."
