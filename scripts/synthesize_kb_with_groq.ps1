[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Get-EnvValue([string]$Path, [string]$Name) {
    $line = Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    return (($line -replace "^\s*$([regex]::Escape($Name))\s*=", '').Trim()).Trim('"').Trim("'")
}
function Get-HeaderValue($Headers, [string]$Name) { try { return (($Headers.GetValues($Name)) -join ',') } catch { return $null } }
function Get-WaitSeconds($Headers) {
    foreach ($name in @('retry-after', 'x-ratelimit-reset-tokens', 'x-ratelimit-reset-requests')) {
        $value = Get-HeaderValue $Headers $name
        if ($value -match '^\s*(\d+(?:\.\d+)?)\s*$') { return [math]::Ceiling([double]$Matches[1]) }
        if ($value -match '^\s*(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?\s*$') { return [math]::Ceiling((if ($Matches[1]) {[double]$Matches[1]} else {0}) * 60 + (if ($Matches[2]) {[double]$Matches[2]} else {0})) }
    }
    return 60
}
function Invoke-Groq([string]$Key, [string]$Model, [string]$System, [string]$User) {
    $reasoningEffort = if ($Model -like 'qwen/*') { 'default' } else { 'low' }
    $body = [ordered]@{ model = $Model; reasoning_effort = $reasoningEffort; temperature = 0.2; max_completion_tokens = 6000; messages = @(@{role='system';content=$System}, @{role='user';content=$User}) } | ConvertTo-Json -Depth 8 -Compress
    $client = [System.Net.Http.HttpClient]::new(); $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://api.groq.com/openai/v1/chat/completions')
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Key)
    $request.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
    try { $response = $client.SendAsync($request).GetAwaiter().GetResult(); try { return [pscustomobject]@{ status=[int]$response.StatusCode; headers=$response.Headers; body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } } finally { $response.Dispose() } } finally { $request.Dispose(); $client.Dispose() }
}
function Read-JsonLines([string]$Path) { return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }
function Get-KbFileByTopic([string]$KbPath) {
    $files = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $KbPath -Filter '*.md')) {
        $topicLine = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -TotalCount 8 | Where-Object { $_ -match '^topic_id:\s*\d+\s*$' } | Select-Object -First 1
        if ($topicLine -notmatch '^topic_id:\s*(\d+)\s*$') { throw "Missing topic_id front matter in $($file.Name)." }
        $topicId = [int]$Matches[1]
        if ($files.ContainsKey($topicId)) { throw "Multiple KB files declare topic $topicId." }
        $files[$topicId] = $file.FullName
    }
    if ($files.Count -ne 25 -or @(1..25 | Where-Object { -not $files.ContainsKey($_) }).Count) { throw 'kb/ must contain exactly one document for every topic ID 1-25.' }
    return $files
}
function Get-SourceListMarkdown($Rows) {
    $sources = @{}
    foreach ($row in $Rows) { $sources[$row.source_id] = $row.relative_path }
    return (($sources.Keys | Sort-Object | ForEach-Object { $path = ([string]$sources[$_]).Replace('\\','/'); "- [$_](../$path)" }) -join "`n")
}
function Write-TopicDocument([string]$Path, $Topic, [string]$Body, $Rows) {
    $sourceCount = @($Rows | Select-Object -ExpandProperty source_id -Unique).Count
    $safeBody = $Body.Trim() -replace '^```(?:markdown|md)?\s*', '' -replace '\s*```\s*$', ''
    $header = @"
---
topic_id: $($Topic.topic_id)
title: $($Topic.topic_title)
status: synthesized
source_count: $sourceCount
source_scope:
  - data/texts
  - data/transcripts
---

# $($Topic.topic_title)

"@
    $document = $header + $safeBody.Trim() + "`n`n## Sources`n`n" + (Get-SourceListMarkdown $Rows) + "`n"
    [System.IO.File]::WriteAllText($Path, $document, [System.Text.UTF8Encoding]::new($false))
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$build = Join-Path $repo 'build'; $kbPath = Join-Path $repo 'kb'; $envPath = Join-Path $repo '.env'
$sourceMapPath = Join-Path $build 'kb-source-map.jsonl'; $checkpointPath = Join-Path $build 'llm-kb-synthesis-checkpoint.jsonl'; $logPath = Join-Path $build 'groq-kb-synthesis-requests.jsonl'
foreach ($path in @($envPath, $sourceMapPath, $kbPath)) { if (-not (Test-Path -LiteralPath $path)) { throw "Required input is missing: $path" } }
$keys = @('GROQ_API_KEY','GROQ_API_KEY2','GROQ_API_KEY3','GROQ_API_KEY4','GROQ_API_KEY5' | ForEach-Object { $key = Get-EnvValue $envPath $_; if ([string]::IsNullOrWhiteSpace($key)) { throw "Missing $_ in .env." }; $key })
$models = @('openai/gpt-oss-120b','openai/gpt-oss-20b','qwen/qwen3.6-27b')
$kbFiles = Get-KbFileByTopic $kbPath
$mapRows = Read-JsonLines $sourceMapPath
$topicRows = @{}
foreach ($topicId in 1..25) { $topicRows[$topicId] = @($mapRows | Where-Object { [int]$_.topic_id -eq $topicId -and $_.assignment_role -eq 'primary' }) }
if (@(1..25 | Where-Object { $topicRows[$_].Count -eq 0 }).Count) { throw 'Every topic must have primary source material.' }

$done = @{}
if (Test-Path -LiteralPath $checkpointPath) { foreach ($entry in (Read-JsonLines $checkpointPath)) { $done[[int]$entry.topic_id] = $entry } }
$pending = @(1..25 | Where-Object { -not $done.ContainsKey($_) })

foreach ($topicId in $done.Keys) {
    $entry = $done[$topicId]
    $topic = $topicRows[$topicId][0]
    Write-TopicDocument $kbFiles[$topicId] $topic $entry.markdown $topicRows[$topicId]
}

$system = @'
You write a rigorous, source-grounded internal knowledge-base document from a creator's source passages. Return Markdown only, beginning with "## Overview". Do not include a title, YAML front matter, a Sources section, or a code fence.

Use exactly these sections, in this order:
## Overview
## Core ideas
## Principles and mental models
## Recommended practices
## Examples and stories
## Tensions and contradictions
## Caveats

Synthesize; do not concatenate or quote long passages. Every substantive paragraph must include one or more inline stable citations such as [S0001]. Cite only source IDs supplied in the input. Attribute claims as the creator's views, especially contested assertions. Do not invent facts, advice, evidence, or examples. Preserve material disagreements and changes over time. Clearly label speculative medical/scientific claims, strongly gendered or misogynistic framing, political claims, and any advice that could be unsafe if followed literally. Keep practical suggestions conditional and source-attributed, not prescriptive.

For topic 25, explain the types of excluded material and the boundary between non-substantive commentary and substantive lessons; do not turn promotional, banter, or low-context material into advice.
'@

$pairStates = [System.Collections.Generic.List[object]]::new()
for ($keyIndex = 0; $keyIndex -lt $keys.Count; $keyIndex++) { for ($modelIndex = 0; $modelIndex -lt $models.Count; $modelIndex++) { $pairStates.Add([pscustomobject]@{ pair_index=$pairStates.Count; key_index=$keyIndex; model_index=$modelIndex; available_at=[datetime]::UtcNow }) } }
$pairCursor = 0; $utf8 = [System.Text.UTF8Encoding]::new($false); $writer = [System.IO.StreamWriter]::new($checkpointPath, $true, $utf8); $logger = [System.IO.StreamWriter]::new($logPath, $true, $utf8)
try {
    foreach ($topicId in $pending) {
        $rows = $topicRows[$topicId]; $topic = $rows[0]
        $passages = @($rows | Sort-Object source_id, segment_index | ForEach-Object { "[$($_.source_id)] ($($_.relative_path))`n$($_.passage_text)" })
        $user = @"
Topic ${topicId}: $($topic.topic_title)

Primary source passages (each bracketed ID is a valid citation):

$($passages -join "`n`n")
"@
        while ($true) {
            $now = [datetime]::UtcNow; $state = $null
            for ($offset = 0; $offset -lt $pairStates.Count; $offset++) { $candidate = $pairStates[($pairCursor + $offset) % $pairStates.Count]; if ($candidate.available_at -le $now) { $state = $candidate; break } }
            if ($null -eq $state) {
                $earliest = $pairStates | Sort-Object available_at | Select-Object -First 1
                $seconds = [math]::Max(1, [math]::Ceiling(($earliest.available_at - $now).TotalSeconds))
                Write-Output "All key/model pairs are cooling down; waiting $seconds second(s) for key slot $($earliest.key_index + 1) on $($models[$earliest.model_index])."
                while ($seconds -gt 0) { $chunk = [math]::Min(60, $seconds); Start-Sleep -Seconds $chunk; $seconds -= $chunk }
                continue
            }
            $slot = $state.key_index; $model = $models[$state.model_index]
            $response = Invoke-Groq $keys[$slot] $model $system $user
            $logger.WriteLine(([ordered]@{timestamp=(Get-Date).ToUniversalTime().ToString('o');topic_id=$topicId;key_slot=$slot+1;model=$model;status=$response.status;source_passages=$rows.Count}|ConvertTo-Json -Compress)); $logger.Flush()
            if ($response.status -eq 429) { $seconds=Get-WaitSeconds $response.headers; $state.available_at=[datetime]::UtcNow.AddSeconds($seconds); $pairCursor=($state.pair_index+1)%$pairStates.Count; Write-Output "Rate limited for topic $topicId on key slot $($slot+1) / $model; pair cooling down for $seconds second(s)."; continue }
            if ($response.status -lt 200 -or $response.status -ge 300) { $seconds=if($response.status -ge 500){60}else{300}; $state.available_at=[datetime]::UtcNow.AddSeconds($seconds); $pairCursor=($state.pair_index+1)%$pairStates.Count; Write-Output "HTTP $($response.status) for topic $topicId on key slot $($slot+1) / $model; pair cooling down for $seconds second(s)."; continue }
            try {
                $markdown = ((($response.body | ConvertFrom-Json).choices | Select-Object -First 1).message.content).Trim()
                $required = @('## Overview','## Core ideas','## Principles and mental models','## Recommended practices','## Examples and stories','## Tensions and contradictions','## Caveats')
                if ([string]::IsNullOrWhiteSpace($markdown) -or $markdown.Length -lt 250 -or $markdown -notmatch '^## Overview') { throw 'Response does not begin with a sufficiently detailed Overview section.' }
                foreach ($section in $required) { if ($markdown -notmatch [regex]::Escape($section)) { throw "Response is missing required section: $section" } }
                $citations = @([regex]::Matches($markdown, '\[S\d{4}\]') | ForEach-Object { $_.Value.Trim('[', ']') } | Sort-Object -Unique)
                if ($citations.Count -eq 0) { throw 'Response has no stable source citations.' }
                $validSources = @($rows | Select-Object -ExpandProperty source_id -Unique)
                if (@($citations | Where-Object { $_ -notin $validSources }).Count -gt 0) { throw 'Response cites a source outside this topic.' }
            } catch {
                $seconds = 300; $state.available_at=[datetime]::UtcNow.AddSeconds($seconds); $pairCursor=($state.pair_index+1)%$pairStates.Count
                Write-Output "Malformed synthesis for topic $topicId from key slot $($slot+1) / $model; pair cooling down for $seconds second(s): $($_.Exception.Message)"
                continue
            }
            Write-TopicDocument $kbFiles[$topicId] $topic $markdown $rows
            $writer.WriteLine(([ordered]@{topic_id=$topicId;topic_title=$topic.topic_title;source_passages=$rows.Count;source_count=@($rows|Select-Object -ExpandProperty source_id -Unique).Count;markdown=$markdown;model=$model;key_slot=$slot+1;synthesized_at=(Get-Date).ToUniversalTime().ToString('o')} | ConvertTo-Json -Depth 4 -Compress)); $writer.Flush()
            $pairCursor=($state.pair_index+1)%$pairStates.Count
            Write-Output "Synthesized topic $topicId/25 with key slot $($slot+1) on $model."
            break
        }
    }
} finally { $writer.Dispose(); $logger.Dispose() }
Write-Output 'LLM KB synthesis complete.'
