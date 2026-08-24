[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Get-Location).Path,
    [int]$MaximumPassagesPerRequest = 1
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
    $body = [ordered]@{ model = $Model; reasoning_effort = $reasoningEffort; temperature = 0; max_completion_tokens = 2400; response_format = @{ type = 'json_object' }; messages = @(@{role='system';content=$System}, @{role='user';content=$User}) } | ConvertTo-Json -Depth 10 -Compress
    $client = [System.Net.Http.HttpClient]::new(); $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://api.groq.com/openai/v1/chat/completions')
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Key)
    $request.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
    try { $response = $client.SendAsync($request).GetAwaiter().GetResult(); try { return [pscustomobject]@{ status=[int]$response.StatusCode; headers=$response.Headers; body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } } finally { $response.Dispose() } } finally { $request.Dispose(); $client.Dispose() }
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$build = Join-Path $repo 'build'; $envPath = Join-Path $repo '.env'; $inputPath = Join-Path $build 'passage-manifest.jsonl'; $checkpointPath = Join-Path $build 'llm-topic-review-checkpoint.jsonl'; $logPath = Join-Path $build 'groq-topic-review-requests.jsonl'
if (-not (Test-Path $envPath) -or -not (Test-Path $inputPath)) { throw 'Missing .env or build/passage-manifest.jsonl.' }
$keys = @('GROQ_API_KEY','GROQ_API_KEY2','GROQ_API_KEY3','GROQ_API_KEY4','GROQ_API_KEY5' | ForEach-Object { $key = Get-EnvValue $envPath $_; if ([string]::IsNullOrWhiteSpace($key)) { throw "Missing $_ in .env." }; $key })
$all = @(Get-Content $inputPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }); $flagged = @($all | Where-Object review_required)
$done = @{}; if (Test-Path $checkpointPath) { Get-Content $checkpointPath -Encoding UTF8 | ForEach-Object { $row = $_ | ConvertFrom-Json; $done[$row.passage_id] = $row } }
$pending = @($flagged | Where-Object { -not $done.ContainsKey($_.passage_id) })
$topics = Get-Content (Join-Path $repo 'data\topics.md') -Raw -Encoding UTF8
$system = @'
You independently review knowledge-base topic assignments. Use only the supplied 25 topic definitions and passage text. Return JSON only: {"results":[{"passage_id":"P000001","primary_topic_id":1,"secondary_topic_ids":[2],"confidence":"high|medium|low","rationale":"brief source-grounded reason","routing":"substantive|non_substantive"}]}. Return every requested passage_id exactly once. Topic 25 is only for promotion, banter, low-context material, or commentary that has no broader lesson. Do not rewrite text or add facts.
'@ + "`n`nTOPICS:`n" + $topics
$models = @('openai/gpt-oss-120b','openai/gpt-oss-20b','qwen/qwen3.6-27b')
$utf8 = [System.Text.UTF8Encoding]::new($false); $writer = [System.IO.StreamWriter]::new($checkpointPath, $true, $utf8); $logger = [System.IO.StreamWriter]::new($logPath, $true, $utf8)
$pairStates = [System.Collections.Generic.List[object]]::new()
for ($keyIndex = 0; $keyIndex -lt $keys.Count; $keyIndex++) {
    for ($modelIndex = 0; $modelIndex -lt $models.Count; $modelIndex++) {
        $pairStates.Add([pscustomobject]@{ pair_index = $pairStates.Count; key_index = $keyIndex; model_index = $modelIndex; available_at = [datetime]::MinValue })
    }
}
$pairCursor = 0
try {
    for ($i = 0; $i -lt $pending.Count;) {
        $batch = @($pending[$i..([math]::Min($i + $MaximumPassagesPerRequest - 1, $pending.Count - 1))]); $requestRows = @($batch | ForEach-Object { [ordered]@{ passage_id=$_.passage_id; text=$_.text } }); $user = ([ordered]@{ passages=$requestRows } | ConvertTo-Json -Depth 5 -Compress)
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
            $slot = $state.key_index; $modelIndex = $state.model_index; $model = $models[$modelIndex]
            $response = Invoke-Groq $keys[$slot] $model $system $user; $logger.WriteLine(([ordered]@{timestamp=(Get-Date).ToUniversalTime().ToString('o');key_slot=$slot+1;model=$model;status=$response.status;passage_ids=@($batch|ForEach-Object passage_id)}|ConvertTo-Json -Compress)); $logger.Flush()
            if ($response.status -eq 429) { $seconds = Get-WaitSeconds $response.headers; $state.available_at = [datetime]::UtcNow.AddSeconds($seconds); $pairCursor = ($state.pair_index + 1) % $pairStates.Count; Write-Output "Rate limited for key slot $($slot + 1) on $model; pair cooling down for $seconds second(s)."; continue }
            if ($response.status -lt 200 -or $response.status -ge 300) {
                # A request/model-specific 4xx must not stop checkpointed work. Temporarily
                # quarantine only this pair and immediately try the next available pair.
                $seconds = if ($response.status -ge 500) { 60 } else { 300 }
                $state.available_at = [datetime]::UtcNow.AddSeconds($seconds)
                $pairCursor = ($state.pair_index + 1) % $pairStates.Count
                Write-Output "HTTP $($response.status) for key slot $($slot + 1) on $model; pair cooling down for $seconds second(s)."
                continue
            }
            try {
                $content = (($response.body|ConvertFrom-Json).choices|Select-Object -First 1).message.content
                $result = $content | ConvertFrom-Json
                $rows = @($result.results)
                $ids = @($rows | ForEach-Object passage_id)
                if ($rows.Count -ne $batch.Count -or @($ids | Sort-Object -Unique).Count -ne $batch.Count -or (Compare-Object @($batch | ForEach-Object passage_id | Sort-Object) @($ids | Sort-Object))) { throw 'Groq returned an incomplete or mismatched review batch.' }
                foreach ($row in $rows) {
                    if ($row.primary_topic_id -notin 1..25 -or @($row.secondary_topic_ids | Where-Object { $_ -notin 1..24 }).Count -gt 0) { throw "Invalid topic IDs for $($row.passage_id)." }
                }
            } catch {
                $seconds = 300
                $state.available_at = [datetime]::UtcNow.AddSeconds($seconds)
                $pairCursor = ($state.pair_index + 1) % $pairStates.Count
                Write-Output "Malformed review from key slot $($slot + 1) on $model; pair cooling down for $seconds second(s): $($_.Exception.Message)"
                continue
            }
            foreach ($row in $rows) { $original=$batch|Where-Object passage_id -eq $row.passage_id; $routing=if($row.PSObject.Properties.Name -contains 'routing'){$row.routing}elseif([int]$row.primary_topic_id -eq 25){'non_substantive'}else{'substantive'}; $writer.WriteLine(([ordered]@{passage_id=$row.passage_id;source_id=$original.source_id;primary_topic_id=[int]$row.primary_topic_id;secondary_topic_ids=@($row.secondary_topic_ids);confidence=$row.confidence;rationale=$row.rationale;routing=$routing;heuristic_primary_topic_id=$original.primary_topic_id;reviewed_model=$model;key_slot=$slot+1;reviewed_at=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json -Depth 5 -Compress)); $done[$row.passage_id]=$true }
            $writer.Flush(); $pairCursor = ($state.pair_index + 1) % $pairStates.Count; $i += $batch.Count; Write-Output "Reviewed $($batch.Count) passage(s) with key slot $($slot + 1) on $model. Progress: $($done.Count)/$($flagged.Count)."; break
        }
    }
} finally { $writer.Dispose(); $logger.Dispose() }
Write-Output 'LLM topic review complete.'
