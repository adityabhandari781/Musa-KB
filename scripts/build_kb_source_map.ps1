[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonLines {
    param([Parameter(Mandatory)][string]$Path)
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-TopicCatalog {
    param([Parameter(Mandatory)][string]$Path)

    $catalog = @{}
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^\s*(?<id>\d+)\.\s+(?<title>.+?)(?:\s+\u2014\s+.*|:\s*)$') {
            $catalog[[int]$Matches.id] = $Matches.title.Trim()
        }
    }
    if ($catalog.Count -ne 25 -or @(1..25 | Where-Object { -not $catalog.ContainsKey($_) }).Count -gt 0) {
        throw 'Could not derive all 25 topic titles from artifacts/topics.md.'
    }
    return $catalog
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$build = Join-Path $repo 'build'
$passagePath = Join-Path $build 'passage-manifest.jsonl'
$reviewPath = Join-Path $build 'llm-topic-review-checkpoint.jsonl'
$sourcePath = Join-Path $build 'source-manifest.jsonl'
$topicPath = Join-Path $repo 'artifacts\topics.md'
$outputPath = Join-Path $build 'kb-source-map.jsonl'
$summaryPath = Join-Path $build 'kb-source-map-summary.json'

foreach ($path in @($passagePath, $reviewPath, $sourcePath, $topicPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input is missing: $path" }
}

$topics = Get-TopicCatalog -Path $topicPath
$passages = Read-JsonLines -Path $passagePath
$reviews = Read-JsonLines -Path $reviewPath
$sources = Read-JsonLines -Path $sourcePath

$reviewByPassage = @{}
foreach ($review in $reviews) {
    if ($reviewByPassage.ContainsKey($review.passage_id)) { throw "Duplicate review for passage $($review.passage_id)." }
    $reviewByPassage[$review.passage_id] = $review
}

$sourceById = @{}
foreach ($source in $sources) {
    if ($sourceById.ContainsKey($source.source_id)) { throw "Duplicate source ID $($source.source_id)." }
    $sourceById[$source.source_id] = $source
}

$flagged = @($passages | Where-Object { $_.review_required })
if ($reviews.Count -ne $flagged.Count) { throw "Review coverage mismatch: $($reviews.Count) reviews for $($flagged.Count) flagged passages." }
foreach ($passage in $flagged) {
    if (-not $reviewByPassage.ContainsKey($passage.passage_id)) { throw "Missing review for flagged passage $($passage.passage_id)." }
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$writer = [System.IO.StreamWriter]::new($outputPath, $false, $utf8)
$topicCounts = @{}
foreach ($topicId in 1..25) { $topicCounts[$topicId] = [ordered]@{ primary_passages = 0; secondary_passages = 0; source_ids = [System.Collections.Generic.HashSet[string]]::new() } }
$primaryCount = 0
$secondaryCount = 0

try {
    foreach ($passage in $passages) {
        if (-not $sourceById.ContainsKey($passage.source_id)) { throw "Passage $($passage.passage_id) references missing source $($passage.source_id)." }
        $source = $sourceById[$passage.source_id]
        $review = if ($reviewByPassage.ContainsKey($passage.passage_id)) { $reviewByPassage[$passage.passage_id] } else { $null }
        if ($null -ne $review) {
            $primaryTopicId = [int]$review.primary_topic_id
            $secondaryTopicIds = @($review.secondary_topic_ids)
        } else {
            $primaryTopicId = [int]$passage.primary_topic_id
            $secondaryTopicIds = @($passage.secondary_topic_ids)
        }
        if ($primaryTopicId -notin 1..25) { throw "Invalid primary topic $primaryTopicId for $($passage.passage_id)." }
        $secondaryTopicIds = @($secondaryTopicIds | ForEach-Object { [int]$_ } | Where-Object { $_ -in 1..24 -and $_ -ne $primaryTopicId } | Sort-Object -Unique)
        $method = if ($null -ne $review) { 'llm_review' } else { 'heuristic' }
        $confidence = if ($null -ne $review) { $review.confidence } else { $passage.classification_confidence }
        $rationale = if ($null -ne $review) { $review.rationale } else { ($passage.routing_reasons -join '; ') }
        $routing = if ($null -ne $review) { $review.routing } else { $passage.routing }
        $assignments = @([ordered]@{ topic_id = $primaryTopicId; assignment_role = 'primary' }) + @($secondaryTopicIds | ForEach-Object { [ordered]@{ topic_id = $_; assignment_role = 'secondary' } })

        foreach ($assignment in $assignments) {
            $topicId = [int]$assignment.topic_id
            $row = [ordered]@{
                topic_id = $topicId
                topic_title = $topics[$topicId]
                assignment_role = $assignment.assignment_role
                assignment_method = $method
                routing = $routing
                confidence = $confidence
                rationale = $rationale
                passage_id = $passage.passage_id
                passage_text = $passage.text
                passage_word_count = $passage.word_count
                segment_index = $passage.segment_index
                source_id = $source.source_id
                source_type = $source.source_type
                relative_path = $source.relative_path
                recorded_at = $source.recorded_at
                source_sha256 = $source.file_hash_sha256
                reviewed_model = if ($null -ne $review) { $review.reviewed_model } else { $null }
                reviewed_at = if ($null -ne $review) { $review.reviewed_at } else { $null }
            }
            $writer.WriteLine(($row | ConvertTo-Json -Depth 5 -Compress))
            [void]$topicCounts[$topicId].source_ids.Add([string]$source.source_id)
            if ($assignment.assignment_role -eq 'primary') { $topicCounts[$topicId].primary_passages++; $primaryCount++ } else { $topicCounts[$topicId].secondary_passages++; $secondaryCount++ }
        }
    }
} finally {
    $writer.Dispose()
}

$summaryTopics = foreach ($topicId in 1..25) {
    [ordered]@{
        topic_id = $topicId
        topic_title = $topics[$topicId]
        primary_passages = $topicCounts[$topicId].primary_passages
        secondary_passages = $topicCounts[$topicId].secondary_passages
        distinct_sources = $topicCounts[$topicId].source_ids.Count
    }
}
$summary = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    passage_manifest = 'build/passage-manifest.jsonl'
    review_checkpoint = 'build/llm-topic-review-checkpoint.jsonl'
    source_manifest = 'build/source-manifest.jsonl'
    total_passages = $passages.Count
    llm_reviewed_passages = $reviews.Count
    heuristic_passages = $passages.Count - $reviews.Count
    primary_assignments = $primaryCount
    secondary_assignments = $secondaryCount
    total_source_map_rows = $primaryCount + $secondaryCount
    topics = @($summaryTopics)
}
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 6), $utf8)

Write-Output "Wrote $($primaryCount + $secondaryCount) topic-to-passage rows to $outputPath."
