[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonLines([string]$Path) { @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }
function Get-KbFiles([string]$Path) {
    $files = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Path -Filter '*.md') {
        $line = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -TotalCount 8 | Where-Object { $_ -match '^topic_id:\s*\d+\s*$' } | Select-Object -First 1
        if ($line -notmatch '^topic_id:\s*(\d+)\s*$') { throw "Missing topic_id in $($file.Name)." }
        $files[[int]$Matches[1]] = $file.FullName
    }
    return $files
}
function Get-SourceList($Rows) {
    $sources = @{}
    foreach ($row in $Rows) { $sources[$row.source_id] = $row.relative_path }
    (($sources.Keys | Sort-Object | ForEach-Object { "- [$_](../$(([string]$sources[$_]).Replace('\\','/')))" }) -join "`n")
}
function Write-Document([string]$Path, $Topic, [string]$Body, $Rows) {
    $sourceCount = @($Rows | Select-Object -ExpandProperty source_id -Unique).Count
    $header = "---`ntopic_id: $($Topic.topic_id)`ntitle: $($Topic.topic_title)`nstatus: synthesized`nsource_count: $sourceCount`nsource_scope:`n  - data/texts`n  - data/transcripts`n---`n`n# $($Topic.topic_title)`n`n"
    [System.IO.File]::WriteAllText($Path, $header + $Body.Trim() + "`n`n## Sources`n`n" + (Get-SourceList $Rows) + "`n", [System.Text.UTF8Encoding]::new($false))
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$build = Join-Path $repo 'build'; $kb = Join-Path $repo 'kb'
$mapRows = Read-JsonLines (Join-Path $build 'kb-source-map.jsonl')
$finals = @(Read-JsonLines (Join-Path $build 'llm-kb-hierarchical-synthesis-checkpoint.jsonl') | Where-Object { $_.kind -eq 'final' })
$files = Get-KbFiles $kb
$topicRows = @{}
foreach ($topicId in 1..25) { $topicRows[$topicId] = @($mapRows | Where-Object { [int]$_.topic_id -eq $topicId -and $_.assignment_role -eq 'primary' }) }
$finalByTopic = @{}
foreach ($entry in $finals) { $finalByTopic[[int]$entry.topic_id] = $entry }

$rendered = [System.Collections.Generic.List[int]]::new(); $regenerate = [System.Collections.Generic.List[int]]::new()
foreach ($topicId in 1..25) {
    if (-not $finalByTopic.ContainsKey($topicId)) { $regenerate.Add($topicId); continue }
    $content = [string]$finalByTopic[$topicId].content
    $matches = [regex]::Matches($content, '(?m)^## Overview\s*$')
    if ($matches.Count -eq 0) { $regenerate.Add($topicId); continue }
    $match = $matches[$matches.Count - 1]
    $body = $content.Substring($match.Index).Trim()
    if ($topicId -eq 16 -and $body -match '(?m)^\*\*Overview:\*\*') {
        $body = $body.Substring(([regex]::Match($body, '(?m)^\*\*Overview:\*\*')).Index)
        $body = $body -replace '(?m)^\*\*Overview:\*\*', '## Overview'
        $body = $body -replace '(?m)^\*\*Core ideas:\*\*', '## Core ideas'
        $body = $body -replace '(?m)^\*\*Principles and mental models:\*\*', '## Principles and mental models'
        $body = $body -replace '(?m)^\*\*Recommended practices:\*\*', '## Recommended practices'
        $body = $body -replace '(?m)^\*\*Examples and stories:\*\*', '## Examples and stories'
        $body = $body -replace '(?m)^\*\*Tensions and contradictions:\*\*', '## Tensions and contradictions'
        $body = $body -replace '(?m)^\*\*Caveats:\*\*', '## Caveats'
    }
    $body = [regex]::Replace($body, '(?s)\n(?:Check against constraints:|\*\*Check Constraints.*|\d+\.\s+\*\*Check Constraints.*).*$', '').Trim()
    Write-Document $files[$topicId] $topicRows[$topicId][0] $body $topicRows[$topicId]
    $rendered.Add($topicId)
}
$report = [ordered]@{ rendered_topic_ids = @($rendered); regeneration_required_topic_ids = @($regenerate); generated_at = (Get-Date).ToUniversalTime().ToString('o') }
[System.IO.File]::WriteAllText((Join-Path $build 'kb-rendering-repair-report.json'), ($report | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
Write-Output "Re-rendered $($rendered.Count) documents. Regeneration required: $(@($regenerate) -join ', ')."
