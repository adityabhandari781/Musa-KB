[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonLines([string]$Path) { @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$kb = Join-Path $repo 'kb'
# Long-lived corpus artifacts were separated from transient run files.  Retain a
# flat build/ fallback so existing clones made before that reorganization work too.
$artifactRoot = if (Test-Path -LiteralPath (Join-Path $repo 'build\longterm\kb-source-map.jsonl')) { Join-Path $repo 'build\longterm' } else { Join-Path $repo 'build' }
$mapRows = Read-JsonLines (Join-Path $artifactRoot 'kb-source-map.jsonl')
$sourceRows = Read-JsonLines (Join-Path $artifactRoot 'source-manifest.jsonl')
$expectedTopics = @{}
foreach ($topicId in 1..25) { $expectedTopics[$topicId] = @($mapRows | Where-Object { [int]$_.topic_id -eq $topicId })[0].topic_title }
$expectedSourceCounts = @{}
foreach ($topicId in 1..25) { $expectedSourceCounts[$topicId] = @($mapRows | Where-Object { [int]$_.topic_id -eq $topicId -and $_.assignment_role -eq 'primary' } | Select-Object -ExpandProperty source_id -Unique).Count }
$sourceById = @{}
foreach ($source in $sourceRows) { $sourceById[$source.source_id] = $source }

$errors = [System.Collections.Generic.List[string]]::new(); $warnings = [System.Collections.Generic.List[string]]::new(); $documentResults = [System.Collections.Generic.List[object]]::new()
$files = @(Get-ChildItem -LiteralPath $kb -Filter '*.md' | Where-Object { $_.Name -match '^(0[1-9]|1\d|2[0-5])-.+\.md$' } | Sort-Object Name)
if ($files.Count -ne 25) { $errors.Add("kb/ contains $($files.Count) Markdown files; expected 25.") }
$seenTopics = @{}
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$requiredSections = @('## Overview','## Core ideas','## Principles and mental models','## Recommended practices','## Examples and stories','## Tensions and contradictions','## Caveats')
$sourceAppendixName = '26-all-texts.md'
$sourceAppendixPath = Join-Path $kb $sourceAppendixName
$sourceAppendixText = ''
if (-not (Test-Path -LiteralPath $sourceAppendixPath)) {
    $errors.Add("Missing source appendix: kb/$sourceAppendixName.")
} else {
    try { $sourceAppendixText = $utf8Strict.GetString([System.IO.File]::ReadAllBytes($sourceAppendixPath)) }
    catch { $errors.Add("$($sourceAppendixName): invalid UTF-8.") }
}

foreach ($file in $files) {
    try { $text = $utf8Strict.GetString([System.IO.File]::ReadAllBytes($file.FullName)) } catch { $errors.Add("$($file.Name): invalid UTF-8."); continue }
    $idMatch = [regex]::Match($text, '(?m)^topic_id:\s*(\d+)\s*$'); $titleMatch = [regex]::Match($text, '(?m)^title:\s*(.+?)\s*$')
    if (-not $idMatch.Success -or -not $titleMatch.Success) { $errors.Add("$($file.Name): missing topic front matter."); continue }
    $topicId = [int]$idMatch.Groups[1].Value; $seenTopics[$topicId] = $file.Name
    if ($topicId -notin 1..25) { $errors.Add("$($file.Name): invalid topic ID $topicId.") }
    if ($titleMatch.Groups[1].Value -ne $expectedTopics[$topicId]) { $errors.Add("$($file.Name): title does not match topic $topicId.") }
    if ($text.Length -lt 500) { $errors.Add("$($file.Name): document is too short.") }
    if ($text -match '<think>|</think>') { $errors.Add("$($file.Name): contains leaked model reasoning.") }
    if ($text -match '\[Paragraph with citations\]|\[Bullets/Paragraphs with citations\]|I need to synthesize the (provided )?notes|Check against constraints') { $errors.Add("$($file.Name): contains model-generation boilerplate or placeholders.") }
    if ($text -match '(?s)^# [^\r\n]+\s*\r?\n\s*## Overview\s*\r?\n## ') { $errors.Add("$($file.Name): Overview section is empty.") }
    foreach ($section in $requiredSections) { if ($text -notmatch [regex]::Escape($section)) { $errors.Add("$($file.Name): missing $section.") } }
    if ($text -match '(?m)^## Sources\s*$') { $errors.Add("$($file.Name): contains a deprecated Sources section.") }
    $countMatch = [regex]::Match($text, '(?m)^source_count:\s*(\d+)\s*$')
    if (-not $countMatch.Success -or [int]$countMatch.Groups[1].Value -ne $expectedSourceCounts[$topicId]) { $errors.Add("$($file.Name): source_count does not match its primary source-map entries.") }

    $citationLinks = @([regex]::Matches($text, '\[(S\d{4})\]\((26-all-texts\.md#s\d{4})\)') | ForEach-Object { [pscustomobject]@{ id=$_.Groups[1].Value; url=$_.Groups[2].Value } })
    $inline = @([regex]::Matches($text, '\[S\d{4}\]') | ForEach-Object { $_.Value.Trim('[',']') } | Sort-Object -Unique)
    if ($inline.Count -eq 0) { $warnings.Add("$($file.Name): no inline source citations.") }
    if ($citationLinks.Count -ne @([regex]::Matches($text, '\[S\d{4}\]')).Count) { $errors.Add("$($file.Name): every inline citation must link to the source appendix.") }
    $citationGroup = '\(\[S\d{4}\]\(26-all-texts\.md#s\d{4}\)(?:, \[S\d{4}\]\(26-all-texts\.md#s\d{4}\))*\)'
    $withoutCitationGroups = [regex]::Replace($text, $citationGroup, '')
    if ($withoutCitationGroups -match '\[S\d{4}\]\(26-all-texts\.md#s\d{4}\)') { $errors.Add("$($file.Name): citations must be enclosed in one complete comma-separated group.") }
    foreach ($citation in $citationLinks) {
        if (-not $sourceById.ContainsKey($citation.id)) { $errors.Add("$($file.Name): unknown source $($citation.id).") }
        elseif (-not $sourceById[$citation.id].included_in_synthesis) { $errors.Add("$($file.Name): excluded duplicate or empty source $($citation.id) was cited.") }
        else {
            $expectedUrl = "$sourceAppendixName#$($citation.id.ToLowerInvariant())"
            if ($citation.url -ne $expectedUrl) { $errors.Add("$($file.Name): citation $($citation.id) does not link to its source appendix anchor.") }
            elseif ($sourceAppendixText -notmatch [regex]::Escape("<a id=""$($citation.id.ToLowerInvariant())""></a>")) { $errors.Add("$($file.Name): citation $($citation.id) has no matching appendix anchor.") }
        }
    }
    $documentResults.Add([ordered]@{ topic_id=$topicId; file=$file.Name; source_links=$citationLinks.Count; inline_citations=$inline.Count; bytes=$text.Length })
}
foreach ($topicId in 1..25) { if (-not $seenTopics.ContainsKey($topicId)) { $errors.Add("Missing KB document for topic $topicId.") } }

$topic25 = Get-Content -LiteralPath (Join-Path $kb '25-non-substantive-material.md') -Raw -Encoding UTF8
if ($topic25 -notmatch 'There are no recommended practices') { $errors.Add('Topic 25 lacks an explicit non-advisory boundary.') }
$health = Get-Content -LiteralPath (Join-Path $kb '14-health-testosterone-and-vitality.md') -Raw -Encoding UTF8
if ($health -notmatch '(?i)speculative|unsupported|not supported|not.*clinical') { $errors.Add('Health document lacks a speculative/unsupported-claim caution.') }
$gender = Get-Content -LiteralPath (Join-Path $kb '19-marriage-women-and-gender-dynamics.md') -Raw -Encoding UTF8
if ($gender -notmatch '(?i)gendered|misogyn') { $errors.Add('Gender-dynamics document lacks a gendered-framing caution.') }
$politics = Get-Content -LiteralPath (Join-Path $kb '22-social-conditioning-and-genjutsu.md') -Raw -Encoding UTF8
if ($politics -notmatch '(?i)political|partisan') { $errors.Add('Genjutsu document lacks a political-claim caution.') }

$topicCoverage = foreach ($topicId in 1..25) {
    $rows = @($mapRows | Where-Object { [int]$_.topic_id -eq $topicId })
    $primary = @($rows | Where-Object assignment_role -eq 'primary')
    [ordered]@{
        topic_id = $topicId
        topic_title = $expectedTopics[$topicId]
        primary_passages = @($primary | Select-Object -ExpandProperty passage_id -Unique).Count
        secondary_passages = @($rows | Where-Object assignment_role -eq 'secondary' | Select-Object -ExpandProperty passage_id -Unique).Count
        distinct_sources = @($primary | Select-Object -ExpandProperty source_id -Unique).Count
        low_confidence_passages = @($rows | Where-Object { $_.confidence -eq 'low' } | Select-Object -ExpandProperty passage_id -Unique).Count
    }
}
$usedSourceIds = @($mapRows | Where-Object assignment_role -eq 'primary' | Select-Object -ExpandProperty source_id -Unique)
$lowConfidence = @($mapRows | Where-Object { $_.confidence -eq 'low' } | Group-Object topic_id | Sort-Object { [int]$_.Name } | ForEach-Object { [ordered]@{ topic_id=[int]$_.Name; passage_ids=@($_.Group | Select-Object -ExpandProperty passage_id -Unique | Sort-Object) } })

$report = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    status = if ($errors.Count) { 'failed' } else { 'passed' }
    source_manifest_summary = [ordered]@{ canonical_sources=@($sourceRows | Where-Object included_in_synthesis).Count; canonical_sources_used=$usedSourceIds.Count; excluded_empty_or_duplicate_copies=@($sourceRows | Where-Object { -not $_.included_in_synthesis }).Count }
    passage_coverage = [ordered]@{ total_primary_passages=@($mapRows | Where-Object assignment_role -eq 'primary' | Select-Object -ExpandProperty passage_id -Unique).Count; total_secondary_assignments=@($mapRows | Where-Object assignment_role -eq 'secondary').Count; by_topic=@($topicCoverage) }
    unresolved_ambiguities = @($lowConfidence)
    documents = @($documentResults | Sort-Object topic_id)
    errors = @($errors)
    warnings = @($warnings)
    manual_boundary_review = @('Identity vs. confidence','Ghost Mode vs. brotherhood','Discipline vs. professionalism','Masculinity vs. gender dynamics','Technology vs. Genjutsu','Spirituality vs. manifestation within goal-setting')
}
$reportPath = Join-Path $artifactRoot 'kb-validation-report.json'
[System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
Write-Output "Validation $($report.status): $($errors.Count) error(s), $($warnings.Count) warning(s). Report: $reportPath"
if ($errors.Count) { exit 1 }
