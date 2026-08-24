[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [int]$MaximumBatchWords = 1200,
    [int]$MaximumSourcesPerRequest = 1,
    [int]$MaximumAtomicUnitWords = 80
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Get-EnvValue {
    param([string]$Path, [string]$Name)
    $line = Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    $value = ($line -replace "^\s*$([regex]::Escape($Name))\s*=", '').Trim()
    if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
}

function Get-WordCount { param([string]$Text); return ([regex]::Matches($Text, '\S+')).Count }

function Get-AtomicUnits {
    param([string]$Text, [int]$MaximumWords)
    $flat = [regex]::Replace($Text, '\s+', ' ').Trim()
    $sentences = @([regex]::Matches($flat, '(?s).+?(?:[.!?]+(?=\s|$)|$)') | ForEach-Object { $_.Value.Trim() } | Where-Object { $_ })
    if ($sentences.Count -eq 0) { return @() }
    $units = [System.Collections.Generic.List[string]]::new()
    foreach ($sentence in $sentences) {
        foreach ($clause in ([regex]::Split($sentence, '(?<=[,;:])\s+') | Where-Object { $_ })) {
            $words = @($clause -split '\s+' | Where-Object { $_ })
            for ($index = 0; $index -lt $words.Count; $index += $MaximumWords) {
                $last = [math]::Min($index + $MaximumWords - 1, $words.Count - 1)
                $units.Add(($words[$index..$last] -join ' '))
            }
        }
    }
    return @($units | ForEach-Object -Begin { $index = 0 } -Process {
        $entry = [pscustomobject]@{ index = $index; text = $_ }
        $index++
        $entry
    })
}

function Get-HeaderValue {
    param($Headers, [string]$Name)
    if ($null -eq $Headers) { return $null }
    try {
        $value = $Headers[$Name]
        if ($null -ne $value) { return ($value -join ',') }
    } catch {}
    try {
        $value = $Headers.GetValues($Name)
        if ($null -ne $value) { return ($value -join ',') }
    } catch {}
    return $null
}

function Get-ErrorBody {
    param($Response)
    if ($null -eq $Response) { return '' }
    try {
        if ($Response.Content -is [string]) { return $Response.Content }
        if ($null -ne $Response.Content) { return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
    } catch {}
    try {
        $reader = [System.IO.StreamReader]::new($Response.GetResponseStream())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } catch {}
    return ''
}

function Invoke-GroqCompletion {
    param([string]$ApiKey, [string]$Model, [string]$SystemPrompt, [string]$UserPrompt)
    $payload = [ordered]@{
        model = $Model
        temperature = 0
        reasoning_effort = 'low'
        max_completion_tokens = 1800
        response_format = [ordered]@{ type = 'json_object' }
        messages = @(
            [ordered]@{ role = 'system'; content = $SystemPrompt },
            [ordered]@{ role = 'user'; content = $UserPrompt }
        )
    } | ConvertTo-Json -Depth 10 -Compress
    $client = [System.Net.Http.HttpClient]::new()
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://api.groq.com/openai/v1/chat/completions')
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $ApiKey)
    $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
    $request.Content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            return [pscustomobject]@{
                status_code = [int]$response.StatusCode
                headers = $response.Headers
                body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
        }
        finally { $response.Dispose() }
    }
    finally {
        $request.Dispose()
        $client.Dispose()
    }
}

function Get-WaitSeconds {
    param($Headers)
    foreach ($headerName in @('retry-after', 'x-ratelimit-reset-tokens', 'x-ratelimit-reset-requests')) {
        $value = Get-HeaderValue -Headers $Headers -Name $headerName
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($value -match '^\s*(?<seconds>\d+(?:\.\d+)?)\s*$') { return [math]::Ceiling([double]$Matches.seconds) }
        if ($value -match '^\s*(?:(?<minutes>\d+)m)?(?:(?<seconds>\d+(?:\.\d+)?)s)?\s*$') {
            $minutes = if ($Matches.minutes) { [double]$Matches.minutes } else { 0 }
            $seconds = if ($Matches.seconds) { [double]$Matches.seconds } else { 0 }
            if ($minutes -gt 0 -or $seconds -gt 0) { return [math]::Ceiling($minutes * 60 + $seconds) }
        }
    }
    return 60
}

function Wait-RateLimit {
    param([int]$Seconds)
    $remaining = [math]::Max(1, $Seconds)
    while ($remaining -gt 0) {
        $chunk = [math]::Min(60, $remaining)
        Write-Output "Rate limited; waiting $remaining second(s) before retrying."
        Start-Sleep -Seconds $chunk
        $remaining -= $chunk
    }
}

function Test-DailyQuotaExhausted {
    param([string]$Body, $Headers)
    $text = $Body.ToLowerInvariant()
    if ($text -match 'per day|daily|\btpd\b|\brpd\b|daily quota') { return $true }
    $remainingRequests = Get-HeaderValue -Headers $Headers -Name 'x-ratelimit-remaining-requests'
    return $remainingRequests -eq '0'
}

function Convert-ResponseToRanges {
    param([string]$Body, [object[]]$Batch)
    $content = (($Body | ConvertFrom-Json).choices | Select-Object -First 1).message.content
    if ([string]::IsNullOrWhiteSpace($content)) { throw 'The model returned no JSON content.' }
    $cleanContent = $content.Trim()
    if ($cleanContent.StartsWith('```')) { $cleanContent = $cleanContent -replace '^```(?:json)?\s*', '' -replace '\s*```$', '' }
    $parsed = $cleanContent | ConvertFrom-Json
    $results = @($parsed.results)
    if ($results.Count -lt $Batch.Count) { throw "Expected at least $($Batch.Count) source results, received $($results.Count)." }
    $byId = @{}
    foreach ($result in $results) {
        if ($null -eq $result.source_id) { throw 'The model returned a missing source_id.' }
        if ($byId.ContainsKey($result.source_id)) {
            $existingRanges = @($byId[$result.source_id].passages) | ConvertTo-Json -Depth 4 -Compress
            $newRanges = @($result.passages) | ConvertTo-Json -Depth 4 -Compress
            if ($existingRanges -ne $newRanges) { throw "The model returned conflicting duplicate ranges for $($result.source_id)." }
            continue
        }
        $byId[$result.source_id] = $result
    }
    $validated = @()
    foreach ($source in $Batch) {
        if (-not $byId.ContainsKey($source.source_id)) { throw "The model omitted $($source.source_id)." }
        if ($source.units.Count -eq 1) {
            $validated += [pscustomobject]@{ source = $source; ranges = @([ordered]@{ start = 0; end = 0 }) }
            continue
        }
        $expectedStart = 0
        $ranges = @($byId[$source.source_id].passages)
        if ($ranges.Count -eq 0) { throw "The model returned no passages for $($source.source_id)." }
        if ($ranges.Count -eq 1 -and [int]$ranges[0].start -eq 0) {
            $validated += [pscustomobject]@{ source = $source; ranges = @([ordered]@{ start = 0; end = $source.units.Count - 1 }) }
            continue
        }
        $validatedRanges = @()
        foreach ($range in $ranges) {
            $end = [math]::Min([int]$range.end, $source.units.Count - 1)
            if ($end -lt $expectedStart) { continue }
            $validatedRanges += [ordered]@{ start = $expectedStart; end = $end }
            $expectedStart = $end + 1
        }
        if ($expectedStart -lt $source.units.Count) {
            $validatedRanges += [ordered]@{ start = $expectedStart; end = $source.units.Count - 1 }
        }
        $validated += [pscustomobject]@{ source = $source; ranges = $validatedRanges }
    }
    return $validated
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$buildRoot = Join-Path $repo 'build'
$envPath = Join-Path $repo '.env'
$sourceManifestPath = Join-Path $buildRoot 'source-manifest.jsonl'
$checkpointPath = Join-Path $buildRoot 'llm-segmentation-checkpoint.jsonl'
$requestLogPath = Join-Path $buildRoot 'groq-segmentation-requests.jsonl'
$outputPath = Join-Path $buildRoot 'llm-passage-manifest.jsonl'
$summaryPath = Join-Path $buildRoot 'llm-segmentation-summary.json'
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { throw 'Missing .env file.' }
if (-not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) { throw 'Missing build/source-manifest.jsonl. Run inventory first.' }

$keys = @('GROQ_API_KEY', 'GROQ_API_KEY2', 'GROQ_API_KEY3' | ForEach-Object {
    $value = Get-EnvValue -Path $envPath -Name $_
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Missing $_ in .env." }
    $value
})
$records = @(Get-Content -LiteralPath $sourceManifestPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object included_in_synthesis)
$completed = @{}
if (Test-Path -LiteralPath $checkpointPath -PathType Leaf) {
    Get-Content -LiteralPath $checkpointPath -Encoding UTF8 | ForEach-Object {
        $entry = $_ | ConvertFrom-Json
        $completed[$entry.source_id] = $entry
    }
}

$pending = @($records | Where-Object { -not $completed.ContainsKey($_.source_id) })
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$checkpointWriter = [System.IO.StreamWriter]::new($checkpointPath, $true, $utf8NoBom)
$requestWriter = [System.IO.StreamWriter]::new($requestLogPath, $true, $utf8NoBom)
$systemPrompt = @'
You segment source text for a knowledge base. Return JSON only: {"results":[{"source_id":"...","passages":[{"start":0,"end":2}]}]}. Every source_id supplied must appear exactly once. For each source, group every contiguous unit index exactly once, from 0 through its final index. Never rewrite, omit, reorder, or combine units across sources. Choose boundaries only where the idea changes; keep short posts as one passage and aim for coherent 100–250 word passages when the source length permits.
'@
$models = @('openai/gpt-oss-120b', 'openai/gpt-oss-20b')
$modelIndex = 0
$keyCursor = 0
$exhausted = @{}

try {
    $pendingIndex = 0
    while ($pendingIndex -lt $pending.Count) {
        $batch = [System.Collections.Generic.List[object]]::new()
        $batchWords = 0
        while ($pendingIndex -lt $pending.Count -and $batch.Count -lt $MaximumSourcesPerRequest) {
            $record = $pending[$pendingIndex]
            $units = @(Get-AtomicUnits -Text $record.normalized_text -MaximumWords $MaximumAtomicUnitWords)
            if ($units.Count -eq 0) { throw "No units generated for $($record.source_id)." }
            $candidateWords = $record.word_count
            if ($batch.Count -gt 0 -and $batchWords + $candidateWords -gt $MaximumBatchWords) { break }
            $batch.Add([pscustomobject]@{
                source_id = $record.source_id
                source_type = $record.source_type
                relative_path = $record.relative_path
                recorded_at = $record.recorded_at
                units = $units
            })
            $batchWords += $candidateWords
            $pendingIndex++
        }

        $requestSources = @($batch | ForEach-Object { [ordered]@{ source_id = $_.source_id; units = $_.units } })
        $userPrompt = ([ordered]@{ sources = $requestSources } | ConvertTo-Json -Depth 8 -Compress)
        $completedBatch = $false
        while (-not $completedBatch) {
            $model = $models[$modelIndex]
            $selectedKey = $null
            for ($offset = 0; $offset -lt $keys.Count; $offset++) {
                $candidateIndex = ($keyCursor + $offset) % $keys.Count
                if (-not $exhausted.ContainsKey("$model|$candidateIndex")) { $selectedKey = $candidateIndex; break }
            }
            if ($null -eq $selectedKey) {
                if ($modelIndex -eq 0) {
                    $modelIndex = 1
                    Write-Output 'All configured keys exhausted their GPT-OSS 120B daily quota; switching to GPT-OSS 20B.'
                    continue
                }
                throw 'All configured keys are exhausted for GPT-OSS 20B.'
            }

            $response = Invoke-GroqCompletion -ApiKey $keys[$selectedKey] -Model $model -SystemPrompt $systemPrompt -UserPrompt $userPrompt
            $requestWriter.WriteLine(([ordered]@{ timestamp = (Get-Date).ToUniversalTime().ToString('o'); model = $model; key_slot = $selectedKey + 1; status_code = $response.status_code; source_ids = @($batch | ForEach-Object source_id); batch_words = $batchWords } | ConvertTo-Json -Compress))
            $requestWriter.Flush()
            if ($response.status_code -ge 200 -and $response.status_code -lt 300) {
                try { $validated = Convert-ResponseToRanges -Body $response.body -Batch @($batch) }
                catch {
                    [System.IO.File]::WriteAllText((Join-Path $buildRoot 'llm-last-invalid-response.json'), $response.body, $utf8NoBom)
                    throw "Invalid model response for batch beginning $($batch[0].source_id): $($_.Exception.Message)"
                }
                foreach ($item in $validated) {
                    $checkpointWriter.WriteLine(([ordered]@{
                        source_id = $item.source.source_id
                        source_type = $item.source.source_type
                        relative_path = $item.source.relative_path
                        recorded_at = $item.source.recorded_at
                        model = $model
                        key_slot = $selectedKey + 1
                        unit_count = $item.source.units.Count
                        passage_ranges = $item.ranges
                        completed_at = (Get-Date).ToUniversalTime().ToString('o')
                    } | ConvertTo-Json -Depth 6 -Compress))
                    $completed[$item.source.source_id] = $true
                }
                $checkpointWriter.Flush()
                $keyCursor = ($selectedKey + 1) % $keys.Count
                $completedBatch = $true
                Write-Output "Segmented $($batch.Count) source(s) with $model using key slot $($selectedKey + 1). Progress: $($completed.Count)/$($records.Count)."
                continue
            }
            if ($response.status_code -eq 429) {
                if (Test-DailyQuotaExhausted -Body $response.body -Headers $response.headers) {
                    $exhausted["$model|$selectedKey"] = $true
                    Write-Output "Daily quota exhausted for $model on key slot $($selectedKey + 1); rotating key."
                    $keyCursor = ($selectedKey + 1) % $keys.Count
                    continue
                }
                Wait-RateLimit -Seconds (Get-WaitSeconds -Headers $response.headers)
                continue
            }
            if ($response.status_code -in 401, 403) { throw "Groq rejected key slot $($selectedKey + 1) with HTTP $($response.status_code)." }
            $errorDetail = [regex]::Replace($response.body, '\s+', ' ').Trim()
            if ($errorDetail.Length -gt 600) { $errorDetail = $errorDetail.Substring(0, 600) }
            throw "Groq request failed with HTTP $($response.status_code): $errorDetail"
        }
    }
}
finally {
    $checkpointWriter.Dispose()
    $requestWriter.Dispose()
}

$checkpointById = @{}
Get-Content -LiteralPath $checkpointPath -Encoding UTF8 | ForEach-Object { $entry = $_ | ConvertFrom-Json; $checkpointById[$entry.source_id] = $entry }
if ($checkpointById.Count -ne $records.Count) { throw 'Segmentation checkpoint is incomplete; rerun this script to resume.' }
$outputWriter = [System.IO.StreamWriter]::new($outputPath, $false, $utf8NoBom)
try {
    $passageCount = 0
    foreach ($record in $records) {
        $units = @(Get-AtomicUnits -Text $record.normalized_text -MaximumWords $MaximumAtomicUnitWords)
        $checkpoint = $checkpointById[$record.source_id]
        $segmentIndex = 0
        foreach ($range in @($checkpoint.passage_ranges)) {
            $segmentIndex++
            $passageCount++
            $text = ($units[$range.start..$range.end] | ForEach-Object text) -join ' '
            $outputWriter.WriteLine(([ordered]@{
                llm_passage_id = ('LP{0:D6}' -f $passageCount)
                source_id = $record.source_id
                source_type = $record.source_type
                relative_path = $record.relative_path
                recorded_at = $record.recorded_at
                segment_index = $segmentIndex
                unit_start = $range.start
                unit_end = $range.end
                word_count = Get-WordCount -Text $text
                text = $text
                model = $checkpoint.model
                key_slot = $checkpoint.key_slot
            } | ConvertTo-Json -Depth 6 -Compress))
        }
    }
}
finally { $outputWriter.Dispose() }

$summary = [ordered]@{
    schema_version = 1
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    canonical_source_count = $records.Count
    segmented_source_count = $checkpointById.Count
    llm_passage_count = $passageCount
    primary_model = $models[0]
    fallback_model = $models[1]
    files = [ordered]@{
        checkpoint = 'build/llm-segmentation-checkpoint.jsonl'
        request_log = 'build/groq-segmentation-requests.jsonl'
        passage_manifest = 'build/llm-passage-manifest.jsonl'
    }
}
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 6), $utf8NoBom)
Write-Output "LLM segmentation complete: $passageCount passages from $($records.Count) sources."
