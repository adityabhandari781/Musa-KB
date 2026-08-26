[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [double]$NearDuplicateThreshold = 0.80
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedContent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $normalized = $Content.Normalize([System.Text.NormalizationForm]::FormKC)
    $normalized = $normalized -replace "`r`n?", "`n"
    $normalized = $normalized.Replace([string][char]0x00A0, ' ')
    $normalized = [regex]::Replace($normalized, '[ \t]+\n', "`n")
    $normalized = [regex]::Replace($normalized, '\n{3,}', "`n`n")
    return $normalized.Trim()
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-SourceTimestamp {
    param([Parameter(Mandatory)][string]$Filename)

    $match = [regex]::Match($Filename, '(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{2}-\d{2}-\d{2})(?:_(?<sequence>\d+))?')
    if (-not $match.Success) {
        return $null
    }

    $raw = "$($match.Groups['date'].Value) $($match.Groups['time'].Value)"
    return [datetime]::ParseExact(
        $raw,
        'yyyy-MM-dd HH-mm-ss',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None
    )
}

function Get-ShingleSet {
    param([Parameter(Mandatory)][string]$Content)

    $tokens = @([regex]::Matches($Content.ToLowerInvariant(), '[\p{L}\p{N}]+') | ForEach-Object Value)
    $shingles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($index = 0; $index -le $tokens.Count - 5; $index++) {
        $null = $shingles.Add("$($tokens[$index]) $($tokens[$index + 1]) $($tokens[$index + 2]) $($tokens[$index + 3]) $($tokens[$index + 4])")
    }
    return $shingles
}

function Add-Association {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][double]$Confidence
    )

    if (-not ($Left.associations | Where-Object { $_.source_id -eq $Right.source_id })) {
        $Left.associations += [ordered]@{
            source_id = $Right.source_id
            reason = $Reason
            confidence = $Confidence
        }
    }
    if (-not ($Right.associations | Where-Object { $_.source_id -eq $Left.source_id })) {
        $Right.associations += [ordered]@{
            source_id = $Left.source_id
            reason = $Reason
            confidence = $Confidence
        }
    }
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$dataRoot = Join-Path $repo 'data'
$buildRoot = Join-Path $repo 'build'
$sourceRoots = @(
    [ordered]@{ path = (Join-Path $dataRoot 'texts'); source_type = 'text' },
    [ordered]@{ path = (Join-Path $dataRoot 'transcripts'); source_type = 'transcript' }
)

foreach ($sourceRoot in $sourceRoots) {
    if (-not (Test-Path -LiteralPath $sourceRoot.path -PathType Container)) {
        throw "Required source directory is missing: $($sourceRoot.path)"
    }
}

$null = New-Item -ItemType Directory -Path $buildRoot -Force
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$records = @()
$excluded = @()
$sourceFiles = @()

foreach ($sourceRoot in $sourceRoots) {
    $sourceFiles += Get-ChildItem -LiteralPath $sourceRoot.path -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            [pscustomobject]@{
                file = $_
                source_type = $sourceRoot.source_type
            }
        }
}

$sourceFiles = @($sourceFiles | Sort-Object { $_.file.FullName })
$sourceNumber = 0

foreach ($source in $sourceFiles) {
    $file = $source.file
    $relativePath = $file.FullName.Substring($repo.Length + 1).Replace('\', '/')
    $rawContent = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $normalizedContent = Get-NormalizedContent -Content $rawContent
    $wordCount = ([regex]::Matches($normalizedContent, '\S+')).Count
    $timestamp = Get-SourceTimestamp -Filename $file.Name

    if ($wordCount -eq 0) {
        $excluded += [ordered]@{
            relative_path = $relativePath
            source_type = $source.source_type
            reason = 'empty_after_normalization'
            file_hash_sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        continue
    }

    $sourceNumber++
    $records += [pscustomobject][ordered]@{
        source_id = ('S{0:D4}' -f $sourceNumber)
        source_type = $source.source_type
        relative_path = $relativePath
        filename = $file.Name
        recorded_at = if ($null -eq $timestamp) { $null } else { $timestamp.ToString('s') }
        file_bytes = $file.Length
        word_count = $wordCount
        character_count = $normalizedContent.Length
        file_hash_sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        normalized_content_hash_sha256 = (Get-Sha256 -Value $normalizedContent)
        normalized_text = $normalizedContent
        duplicate_status = 'unique'
        canonical_source_id = $null
        exact_duplicate_group = $null
        included_in_synthesis = $true
        near_duplicate_candidates = @()
        associations = @()
    }
}

$duplicateGroups = @()
$duplicateNumber = 0
foreach ($group in ($records | Group-Object normalized_content_hash_sha256 | Where-Object Count -gt 1 | Sort-Object Name)) {
    $duplicateNumber++
    $groupId = ('D{0:D3}' -f $duplicateNumber)
    $canonical = $group.Group | Sort-Object source_id | Select-Object -First 1
    foreach ($record in $group.Group) {
        $record.canonical_source_id = $canonical.source_id
        $record.exact_duplicate_group = $groupId
        if ($record.source_id -eq $canonical.source_id) {
            $record.duplicate_status = 'exact_duplicate_canonical'
        }
        else {
            $record.duplicate_status = 'exact_duplicate'
            $record.included_in_synthesis = $false
        }
    }
    $duplicateGroups += [ordered]@{
        group_id = $groupId
        type = 'exact'
        canonical_source_id = $canonical.source_id
        source_ids = @($group.Group | Sort-Object source_id | ForEach-Object source_id)
        normalized_content_hash_sha256 = $group.Name
    }
}

# A near duplicate is a high-similarity, non-identical canonical record. Five-word
# shingles reduce false matches from short generic posts; candidates remain included
# until a later review explicitly decides otherwise.
$nearDuplicatePairs = @()
$canonicalRecords = @($records | Where-Object { $_.included_in_synthesis -and $_.word_count -ge 50 })
$shingleIndex = @{}
foreach ($record in $canonicalRecords) {
    $shingleIndex[$record.source_id] = Get-ShingleSet -Content $record.normalized_text
}

for ($leftIndex = 0; $leftIndex -lt $canonicalRecords.Count; $leftIndex++) {
    $left = $canonicalRecords[$leftIndex]
    $leftShingles = $shingleIndex[$left.source_id]
    if ($leftShingles.Count -eq 0) { continue }

    for ($rightIndex = $leftIndex + 1; $rightIndex -lt $canonicalRecords.Count; $rightIndex++) {
        $right = $canonicalRecords[$rightIndex]
        $lengthRatio = [math]::Min($left.word_count, $right.word_count) / [math]::Max($left.word_count, $right.word_count)
        if ($lengthRatio -lt 0.75) { continue }

        $rightShingles = $shingleIndex[$canonicalRecords[$rightIndex].source_id]
        if ($rightShingles.Count -eq 0) { continue }
        $smaller = if ($leftShingles.Count -le $rightShingles.Count) { $leftShingles } else { $rightShingles }
        $larger = if ($leftShingles.Count -le $rightShingles.Count) { $rightShingles } else { $leftShingles }
        $intersection = 0
        foreach ($shingle in $smaller) {
            if ($larger.Contains($shingle)) { $intersection++ }
        }
        $union = $leftShingles.Count + $rightShingles.Count - $intersection
        $similarity = if ($union -eq 0) { 0 } else { $intersection / $union }
        if ($similarity -lt $NearDuplicateThreshold) { continue }

        $score = [math]::Round($similarity, 3)
        $right = $canonicalRecords[$rightIndex]
        $left.near_duplicate_candidates += [ordered]@{ source_id = $right.source_id; similarity = $score }
        $right.near_duplicate_candidates += [ordered]@{ source_id = $left.source_id; similarity = $score }
        $nearDuplicatePairs += [ordered]@{
            type = 'near'
            source_id_a = $left.source_id
            source_id_b = $right.source_id
            shingle_jaccard_similarity = $score
        }
    }
}

# Associations are deliberately conservative: only cross-type records that share an
# exact timestamp or normalized content are linked. Nearby timestamps are not enough
# to establish that a text is the caption for a particular transcript.
foreach ($timestampGroup in ($records | Where-Object { $_.recorded_at } | Group-Object recorded_at)) {
    $texts = @($timestampGroup.Group | Where-Object source_type -eq 'text')
    $transcripts = @($timestampGroup.Group | Where-Object source_type -eq 'transcript')
    foreach ($text in $texts) {
        foreach ($transcript in $transcripts) {
            Add-Association -Left $text -Right $transcript -Reason 'exact_timestamp' -Confidence 1.0
        }
    }
}
foreach ($contentGroup in ($records | Group-Object normalized_content_hash_sha256)) {
    $texts = @($contentGroup.Group | Where-Object source_type -eq 'text')
    $transcripts = @($contentGroup.Group | Where-Object source_type -eq 'transcript')
    foreach ($text in $texts) {
        foreach ($transcript in $transcripts) {
            Add-Association -Left $text -Right $transcript -Reason 'identical_normalized_content' -Confidence 1.0
        }
    }
}

$manifestPath = Join-Path $buildRoot 'source-manifest.jsonl'
$excludedPath = Join-Path $buildRoot 'excluded-sources.jsonl'
$duplicatesPath = Join-Path $buildRoot 'duplicate-groups.json'
$summaryPath = Join-Path $buildRoot 'inventory-summary.json'

$manifestWriter = [System.IO.StreamWriter]::new($manifestPath, $false, $utf8NoBom)
try {
    foreach ($record in $records) {
        $manifestWriter.WriteLine(($record | ConvertTo-Json -Depth 8 -Compress))
    }
}
finally {
    $manifestWriter.Dispose()
}

$excludedWriter = [System.IO.StreamWriter]::new($excludedPath, $false, $utf8NoBom)
try {
    foreach ($record in $excluded) {
        $excludedWriter.WriteLine(($record | ConvertTo-Json -Depth 5 -Compress))
    }
}
finally {
    $excludedWriter.Dispose()
}

$duplicateReport = [ordered]@{
    schema_version = 1
    exact_duplicate_groups = $duplicateGroups
    near_duplicate_pairs = $nearDuplicatePairs
}
[System.IO.File]::WriteAllText($duplicatesPath, ($duplicateReport | ConvertTo-Json -Depth 8), $utf8NoBom)

$associationLinkCount = @($records | ForEach-Object { $_.associations }).Count
$associationPairCount = $associationLinkCount / 2
$summary = [ordered]@{
    schema_version = 1
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    source_directories = @('data/texts', 'data/transcripts')
    input_file_count = $sourceFiles.Count
    included_record_count = $records.Count
    excluded_empty_count = $excluded.Count
    canonical_synthesis_record_count = @($records | Where-Object included_in_synthesis).Count
    exact_duplicate_group_count = $duplicateGroups.Count
    exact_duplicate_copy_count = @($records | Where-Object duplicate_status -eq 'exact_duplicate').Count
    near_duplicate_pair_count = $nearDuplicatePairs.Count
    association_pair_count = $associationPairCount
    association_link_count = $associationLinkCount
    files = [ordered]@{
        manifest = 'build/source-manifest.jsonl'
        excluded_sources = 'build/excluded-sources.jsonl'
        duplicate_groups = 'build/duplicate-groups.json'
    }
}
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 6), $utf8NoBom)

Write-Output "Inventory complete: $($summary.included_record_count) non-empty records from $($summary.input_file_count) input files."
Write-Output "Excluded empty records: $($summary.excluded_empty_count); exact duplicate copies: $($summary.exact_duplicate_copy_count); near-duplicate pairs: $($summary.near_duplicate_pair_count)."
Write-Output "Artifacts: build/source-manifest.jsonl, build/excluded-sources.jsonl, build/duplicate-groups.json, build/inventory-summary.json"
