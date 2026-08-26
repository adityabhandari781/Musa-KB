[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Read-JsonLines {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-EnvValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $line = Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    return (($line -replace "^\s*$([regex]::Escape($Name))\s*=", '').Trim()).Trim('"').Trim("'")
}

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
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RecordedAt {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $match = [regex]::Match($File.Name, '(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{2}-\d{2}-\d{2})(?:_\d+)?')
    if ($match.Success) {
        return [datetime]::ParseExact("$($match.Groups['date'].Value) $($match.Groups['time'].Value)", 'yyyy-MM-dd HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None).ToString('s')
    }
    return $File.LastWriteTime.ToString('s')
}

function Get-OldestIncomingFile {
    param([Parameter(Mandatory)]$IncomingRoots)
    $candidates = @(
        $IncomingRoots | ForEach-Object {
        $root = $_
        if (Test-Path -LiteralPath $root.path -PathType Container) {
            Get-ChildItem -LiteralPath $root.path -File -Filter '*.txt' | ForEach-Object {
                $match = [regex]::Match($_.Name, '(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{2}-\d{2}-\d{2})(?:_\d+)?')
                $sortTime = if ($match.Success) {
                    [datetime]::ParseExact("$($match.Groups['date'].Value) $($match.Groups['time'].Value)", 'yyyy-MM-dd HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
                } else { $_.LastWriteTime }
                [pscustomobject]@{ File = $_; SortTime = $sortTime; SourceType = $root.source_type; DestinationRoot = $root.destination_root }
            }
        }
    }
    )
    $oldest = $candidates | Sort-Object SortTime, @{ Expression = { $_.File.Name }; Ascending = $true }, SourceType | Select-Object -First 1
    if ($null -eq $oldest) { return $null }
    return $oldest
}

function Get-NextNumericId {
    param([Parameter(Mandatory)]$Rows, [Parameter(Mandatory)][string]$Property, [Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][int]$Digits)
    $max = 0
    foreach ($row in $Rows) {
        $value = [string]$row.$Property
        if ($value -match "^$([regex]::Escape($Prefix))(\d+)$") { $max = [math]::Max($max, [int]$Matches[1]) }
    }
    return ('{0}{1:D' + $Digits + '}') -f $Prefix, ($max + 1)
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $temp = "$Path.tmp"
    [System.IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Append-JsonLine {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $writer = [System.IO.StreamWriter]::new($Path, $true, [System.Text.UTF8Encoding]::new($false))
    try { $writer.WriteLine(($Value | ConvertTo-Json -Depth 10 -Compress)) }
    finally { $writer.Dispose() }
}

function Get-HeaderValue {
    param($Headers, [Parameter(Mandatory)][string]$Name)
    try { return (($Headers.GetValues($Name)) -join ',') } catch { return $null }
}

function Get-WaitSeconds {
    param($Headers)
    foreach ($name in @('retry-after', 'x-ratelimit-reset-tokens', 'x-ratelimit-reset-requests')) {
        $value = Get-HeaderValue -Headers $Headers -Name $name
        if ($value -match '^\s*(\d+(?:\.\d+)?)\s*$') { return [math]::Ceiling([double]$Matches[1]) }
        if ($value -match '^\s*(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?\s*$') {
            return [math]::Ceiling((if ($Matches[1]) { [double]$Matches[1] } else { 0 }) * 60 + (if ($Matches[2]) { [double]$Matches[2] } else { 0 }))
        }
    }
    return 60
}

function Invoke-GroqAttempt {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$ModelName,
        [Parameter(Mandatory)][string]$System,
        [Parameter(Mandatory)][string]$User
    )
    $reasoningEffort = if ($ModelName -like 'qwen/*') { 'default' } else { 'low' }
    $payloadJson = [ordered]@{
        api_key = $Key
        model = $ModelName
        reasoning_effort = $reasoningEffort
        system = $System
        user = $User
        timeout_seconds = 90
    } | ConvertTo-Json -Depth 6 -Compress
    # Redirected Windows console streams can corrupt Unicode Markdown.  Base64
    # carries the UTF-8 JSON as ASCII to the Python helper.
    $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
    $clientScript = Join-Path $PSScriptRoot 'groq_chat.py'
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'python'
    $startInfo.Arguments = ('"{0}"' -f $clientScript)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Could not start the Python Groq transport.' }
        $process.StandardInput.Write($payload)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) {
            throw "Python Groq transport failed: $stderr"
        }
        $response = $stdout | ConvertFrom-Json
        return [pscustomobject]@{ status=[int]$response.status; body=[string]$response.body; retry_seconds=[int]$response.retry_seconds }
    }
    catch {
        return [pscustomobject]@{ status=599; body=$_.Exception.GetBaseException().Message; retry_seconds=60 }
    }
    finally { $process.Dispose() }
}

function Invoke-GroqJson {
    param(
        [Parameter(Mandatory)]$KeyEntries,
        [Parameter(Mandatory)][string[]]$ModelNames,
        [Parameter(Mandatory)][string]$System,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$WorkLabel
    )
    # The ordered pair list deliberately encodes the requested policy: all three
    # models on key 1, then all three on key 2, and so on.
    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($keyEntry in $KeyEntries) {
        foreach ($modelName in $ModelNames) {
            $pairs.Add([pscustomobject]@{
                key_name = $keyEntry.name
                key = $keyEntry.key
                model = $modelName
                available_at = [datetime]::MinValue
                disabled = $false
            })
        }
    }
    $cursor = 0
    $errors = [System.Collections.Generic.List[string]]::new()
    $transportFailures = 0
    while ($true) {
        $now = [datetime]::UtcNow
        $pair = $null
        for ($offset = 0; $offset -lt $pairs.Count; $offset++) {
            $candidate = $pairs[($cursor + $offset) % $pairs.Count]
            if (-not $candidate.disabled -and $candidate.available_at -le $now) { $pair = $candidate; break }
        }
        if ($null -eq $pair) {
            $usable = @($pairs | Where-Object { -not $_.disabled })
            if ($usable.Count -eq 0) { throw "All Groq key/model pairs failed for $WorkLabel. $($errors -join ' | ')" }
            $earliest = $usable | Sort-Object available_at | Select-Object -First 1
            $seconds = [math]::Max(1, [math]::Ceiling(($earliest.available_at - $now).TotalSeconds))
            Write-Host "All Groq key/model pairs are cooling down for $WorkLabel; waiting $seconds second(s) for $($earliest.key_name) / $($earliest.model)."
            while ($seconds -gt 0) {
                $chunk = [math]::Min(60, $seconds)
                Start-Sleep -Seconds $chunk
                $seconds -= $chunk
            }
            continue
        }

        $pairIndex = $pairs.IndexOf($pair)
        Write-Host "Requesting $WorkLabel with $($pair.key_name) / $($pair.model)."
        $response = Invoke-GroqAttempt -Key $pair.key -ModelName $pair.model -System $System -User $User
        if ($response.status -ge 200 -and $response.status -lt 300) {
            try {
                $content = (($response.body | ConvertFrom-Json).choices | Select-Object -First 1).message.content
                if ([string]::IsNullOrWhiteSpace($content)) { throw 'Empty completion.' }
                return [pscustomobject]@{ value=($content | ConvertFrom-Json); model=$pair.model; api_key_name=$pair.key_name }
            }
            catch {
                $pair.available_at = [datetime]::UtcNow.AddSeconds(300)
                $errors.Add("$($pair.key_name)/$($pair.model): invalid JSON response")
                Write-Host "Invalid JSON from $($pair.key_name) / $($pair.model) for $WorkLabel; trying the next pair."
            }
        }
        elseif ($response.status -eq 429 -or $response.status -eq 408 -or $response.status -eq 599 -or $response.status -ge 500) {
            $wait = [math]::Max(1, [int]$response.retry_seconds)
            $pair.available_at = [datetime]::UtcNow.AddSeconds($wait)
            $errors.Add("$($pair.key_name)/$($pair.model): HTTP $($response.status), retry in $wait s")
            if ($response.status -eq 599) {
                $transportFailures++
                $detail = ([string]$response.body -replace '\s+', ' ').Trim()
                if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 240) + '…' }
                Write-Host "HTTP 599 from $($pair.key_name) / $($pair.model) for $($WorkLabel): $detail"
                if ($transportFailures -ge $pairs.Count) {
                    throw "Every Groq key/model pair had a transport failure for $WorkLabel. Check network connectivity before retrying."
                }
            } else {
                Write-Host "HTTP $($response.status) from $($pair.key_name) / $($pair.model) for $WorkLabel; pair cooling down for $wait second(s)."
            }
        }
        else {
            # A model/key-specific client error is not expected to recover during
            # this logical request.  Move on immediately and do not wait on it.
            $pair.disabled = $true
            $errors.Add("$($pair.key_name)/$($pair.model): HTTP $($response.status)")
            Write-Host "HTTP $($response.status) from $($pair.key_name) / $($pair.model) for $WorkLabel; trying the next pair."
        }
        $cursor = ($pairIndex + 1) % $pairs.Count
    }
}

function Get-TopicFile {
    param([Parameter(Mandatory)][string]$KbPath, [Parameter(Mandatory)][int]$TopicId)
    $file = Get-ChildItem -LiteralPath $KbPath -Filter '*.md' | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Encoding UTF8 -TotalCount 8) -match "^topic_id:\s*$TopicId\s*$"
    } | Select-Object -First 1
    if ($null -eq $file) { throw "Could not find KB document for topic $TopicId." }
    return $file
}

function Get-TopicBody {
    param([Parameter(Mandatory)][string]$Document)
    $withoutHeader = [regex]::Replace($Document, '(?s)\A---.*?---\s*\r?\n\r?\n# .*?\r?\n\r?\n', '')
    return ([regex]::Split($withoutHeader, '(?m)^## Sources\s*$')[0]).Trim()
}

function Remove-CitationsForGroq {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    # Groq receives no source identifiers or links.
    $citation = '\[S\d{4}\](?:\([^\)]*\))?'
    $Text = [regex]::Replace($Text, "\s*\((?:\s*$citation\s*,?)+\s*\)", '')
    $Text = [regex]::Replace($Text, "\s*$citation", '')
    $Text = [regex]::Replace($Text, '[ \t]+([,.;:!?])', '$1')
    return [regex]::Replace($Text, '(?m)[ \t]+$', '')
}

function Format-LinkedCitationRuns {
    param([Parameter(Mandatory)][string]$Text)

    $citationLink = '\[S\d{4}\]\([^\)]+\)'
    $separator = '[ \t\u00A0\u202F]*'
    # Unwrap a pre-existing citation-only list before formatting, so retries or
    # resumed ingestions never add a second set of parentheses.
    $Text = [regex]::Replace($Text, "(?<!\\w)\\($separator($citationLink(?:$separator,$separator$citationLink)*)$separator\\)", {
        param($match)
        $match.Groups[1].Value
    })
    return [regex]::Replace($Text, "(?<![\\(\\w])($citationLink(?:$separator$citationLink)*)", {
        param($match)
        $links = @([regex]::Matches($match.Groups[1].Value, $citationLink) | ForEach-Object Value)
        '(' + ($links -join ', ') + ')'
    })
}

function Convert-CitationsForKb {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)]$SourceById)
    $linked = [regex]::Replace($Text, '\[(S\d{4})\](?:\([^\)]*\))?', {
        param($match)
        $id = $match.Groups[1].Value
        if (-not $SourceById.ContainsKey($id)) { throw "Cannot link unknown source $id." }
        return "[$id]($script:SourceAppendix#$($id.ToLowerInvariant()))"
    })
    return Format-LinkedCitationRuns -Text $linked
}

function Assert-CitationFreeTopicBody {
    param([Parameter(Mandatory)][string]$Body)
    $sections = @('## Overview', '## Core ideas', '## Principles and mental models', '## Recommended practices', '## Examples and stories', '## Tensions and contradictions', '## Caveats')
    if ($Body -match '<think>|</think>|```') { throw 'The KB update response contains forbidden model markup.' }
    if ($Body -match '\[S\d{4}\]|github\.com/') { throw 'The KB update response must not contain citations or source links.' }
    $positions = @()
    foreach ($section in $sections) {
        $match = [regex]::Match($Body, "(?m)^$([regex]::Escape($section))\s*$")
        if (-not $match.Success) { throw "The KB update response is missing $section." }
        $positions += $match.Index
    }
    $sortedPositions = (@($positions | Sort-Object) -join ',')
    $declaredPositions = ($positions -join ',')
    if ($sortedPositions -ne $declaredPositions) { throw 'The KB update response has sections out of order.' }
}

function Get-ComparisonKey {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $withoutCitations = Remove-CitationsForGroq -Text $Line
    return [regex]::Replace($withoutCitations.Trim(), '\s+', ' ')
}

function Test-SubstantiveContentLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $trimmed = $Line.Trim()
    return $trimmed.Length -gt 0 -and $trimmed -notmatch '^#{1,6}\s' -and $trimmed -notmatch '^(---|\*\*\*|___)$'
}

function Get-LineDifferenceSummary {
    param([Parameter(Mandatory)][string]$OriginalBody, [Parameter(Mandatory)][string]$UpdatedBody)

    $counts = @{}
    $originalCount = 0
    foreach ($line in [regex]::Split($OriginalBody, "\r?\n")) {
        if (-not (Test-SubstantiveContentLine -Line $line)) { continue }
        $key = Get-ComparisonKey -Line $line
        if (-not $key) { continue }
        $originalCount++
        if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
        $counts[$key]++
    }
    $added = 0
    foreach ($line in [regex]::Split($UpdatedBody, "\r?\n")) {
        if (-not (Test-SubstantiveContentLine -Line $line)) { continue }
        $key = Get-ComparisonKey -Line $line
        if ($key -and $counts.ContainsKey($key) -and $counts[$key] -gt 0) { $counts[$key]-- }
        else { $added++ }
    }
    $removed = @($counts.Values | ForEach-Object { [int]$_ } | Measure-Object -Sum).Sum
    if ($null -eq $removed) { $removed = 0 }
    return [pscustomobject]@{ original_count=$originalCount; added=$added; removed=[int]$removed; changed=($added + [int]$removed) }
}

function Assert-MinimalLineEdits {
    param([Parameter(Mandatory)][string]$OriginalBody, [Parameter(Mandatory)][string]$UpdatedBody)

    $summary = Get-LineDifferenceSummary -OriginalBody $OriginalBody -UpdatedBody $UpdatedBody
    $limit = [math]::Max(5, [math]::Ceiling($summary.original_count * 0.25))
    if ($summary.changed -gt $limit) {
        throw "The KB update rewrote too much of the document ($($summary.changed) changed/deleted substantive lines; limit $limit). Refusing to attach the incoming source citation broadly."
    }
}

function Add-SourceCitationToLine {
    param([Parameter(Mandatory)][string]$Line, [Parameter(Mandatory)][string]$Citation)

    $trailingMatch = [regex]::Match($Line, '[ \t]*$')
    $trailing = $trailingMatch.Value
    $content = $Line.Substring(0, $Line.Length - $trailing.Length)
    $punctuationMatch = [regex]::Match($content, '^(.*?)([.!?])$')
    if ($punctuationMatch.Success) { return "$($punctuationMatch.Groups[1].Value) $Citation$($punctuationMatch.Groups[2].Value)$trailing" }
    return "$content $Citation$trailing"
}

function Restore-DeterministicCitations {
    param(
        [Parameter(Mandatory)][string]$OriginalBody,
        [Parameter(Mandatory)][string]$UpdatedBody,
        [Parameter(Mandatory)][string]$NewSourceId,
        [Parameter(Mandatory)]$SourceById
    )

    if (-not $SourceById.ContainsKey($NewSourceId)) { throw "Cannot build a citation for unknown source $NewSourceId." }
    $newCitation = "([$NewSourceId]($script:SourceAppendix#$($NewSourceId.ToLowerInvariant()))"
    $originalByKey = @{}
    foreach ($line in [regex]::Split($OriginalBody, "\r?\n")) {
        $key = Get-ComparisonKey -Line $line
        if (-not $key) { continue }
        if (-not $originalByKey.ContainsKey($key)) {
            $originalByKey[$key] = [System.Collections.Generic.Queue[string]]::new()
        }
        $originalByKey[$key].Enqueue($line)
    }

    $restored = foreach ($line in [regex]::Split($UpdatedBody, "\r?\n")) {
        $key = Get-ComparisonKey -Line $line
        if ($key -and $originalByKey.ContainsKey($key) -and $originalByKey[$key].Count -gt 0) {
            # An unchanged line is restored byte-for-byte, including its prior citations.
            $originalByKey[$key].Dequeue()
        } elseif (Test-SubstantiveContentLine -Line $line) {
            Add-SourceCitationToLine -Line $line -Citation $newCitation
        } else {
            $line
        }
    }
    return ($restored -join [Environment]::NewLine).Trim()
}

function Write-TopicDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$TopicId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][int]$SourceCount
    )
    $header = "---`ntopic_id: $TopicId`ntitle: $Title`nstatus: synthesized`nsource_count: $SourceCount`nsource_scope:`n  - data/texts`n  - data/transcripts`n---`n`n# $Title`n`n"
    [System.IO.File]::WriteAllText($Path, $header + $Body.Trim() + "`n", [System.Text.UTF8Encoding]::new($false))
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$incomingPath = Join-Path $repo 'data\incoming'
$incomingTextsPath = Join-Path $incomingPath 'texts'
$incomingTranscriptsPath = Join-Path $incomingPath 'transcripts'
$incomingMediaPath = Join-Path $incomingPath 'media'
$transcriptMediaIndexPath = Join-Path $incomingTranscriptsPath 'media-index.jsonl'
$textsPath = Join-Path $repo 'data\texts'
$transcriptsPath = Join-Path $repo 'data\transcripts'
$mediaPath = Join-Path $repo 'data\media\audio and video'
$kbPath = Join-Path $repo 'kb'
$longtermPath = Join-Path $repo 'build\longterm'
$usefulPath = Join-Path $repo 'build\useful'
$statePath = Join-Path $usefulPath 'incoming-ingestion-active.json'
$logPath = Join-Path $usefulPath 'incoming-ingestion-log.jsonl'
$sourcePath = Join-Path $longtermPath 'source-manifest.jsonl'
$passagePath = Join-Path $longtermPath 'passage-manifest.jsonl'
$mapPath = Join-Path $longtermPath 'kb-source-map.jsonl'
$envPath = Join-Path $repo '.env'
$script:SourceAppendix = '26-all-texts.md'
$apiKeyNames = @('GROQ_API_KEY', 'GROQ_API_KEY2', 'GROQ_API_KEY3', 'GROQ_API_KEY4', 'GROQ_API_KEY5', 'GROQ_API_KEY6')
$models = @('openai/gpt-oss-120b', 'openai/gpt-oss-20b', 'qwen/qwen3.6-27b')

foreach ($path in @($textsPath, $transcriptsPath, $mediaPath, $kbPath, $longtermPath, $usefulPath, $sourcePath, $passagePath, $mapPath, $envPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input is missing: $path" }
}
$keyEntries = @($apiKeyNames | ForEach-Object {
    $key = Get-EnvValue -Path $envPath -Name $_
    if ([string]::IsNullOrWhiteSpace($key)) { throw "Missing $_ in .env." }
    [pscustomobject]@{ name=$_; key=$key }
})

$state = $null
if (Test-Path -LiteralPath $statePath) {
    # ConvertFrom-Json creates a fixed PSCustomObject.  A resumed ingestion
    # needs to add fields as it advances through later stages, so use a mutable
    # ordered map just like a newly created checkpoint.
    $savedState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $state = [ordered]@{}
    foreach ($property in $savedState.PSObject.Properties) {
        $state[$property.Name] = $property.Value
    }
    Write-Output "Resuming active ingestion for $($state.filename) at stage '$($state.stage)'."
} else {
    $incomingRoots = @(
        [pscustomobject]@{ path=$incomingTextsPath; source_type='text'; destination_root=$textsPath },
        [pscustomobject]@{ path=$incomingTranscriptsPath; source_type='transcript'; destination_root=$transcriptsPath }
    )
    $incoming = Get-OldestIncomingFile -IncomingRoots $incomingRoots
    if ($null -eq $incoming) { Write-Output 'No .txt files are waiting in data/incoming/texts or data/incoming/transcripts.'; exit 0 }
    $destination = Join-Path $incoming.DestinationRoot $incoming.File.Name
    if (Test-Path -LiteralPath $destination) { throw "Cannot move $($incoming.File.Name): destination already contains that file: $destination" }
    $state = [ordered]@{
        schema_version = 1
        filename = $incoming.File.Name
        source_type = $incoming.SourceType
        incoming_relative_path = "data/incoming/$($incoming.SourceType)s/$($incoming.File.Name)"
        incoming_path = $incoming.File.FullName
        relative_path = "data/$($incoming.SourceType)s/$($incoming.File.Name)"
        destination_path = $destination
        stage = 'selected'
        started_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($incoming.SourceType -eq 'transcript') {
        $entry = @(Read-JsonLines -Path $transcriptMediaIndexPath | Where-Object { $_.transcript_relative_path -eq $state.incoming_relative_path } | Select-Object -Last 1)
        if (-not $entry.Count) { throw "Transcript $($state.filename) has no media-index entry." }
        $mediaSourcePath = Join-Path $repo $entry[0].media_relative_path
        $mediaDestinationPath = Join-Path $mediaPath ([System.IO.Path]::GetFileName($mediaSourcePath))
        if (-not (Test-Path -LiteralPath $mediaSourcePath)) { throw "Transcript media is missing: $mediaSourcePath" }
        if (Test-Path -LiteralPath $mediaDestinationPath) { throw "Cannot move transcript media: destination already exists: $mediaDestinationPath" }
        $state.media_incoming_path = $mediaSourcePath
        $state.media_relative_path = "data/media/audio and video/$([System.IO.Path]::GetFileName($mediaSourcePath))"
        $state.media_destination_path = $mediaDestinationPath
    }
    Write-JsonAtomic -Path $statePath -Value $state
}

if ($state.stage -eq 'selected') {
    if (Test-Path -LiteralPath $state.incoming_path) {
        Move-Item -LiteralPath $state.incoming_path -Destination $state.destination_path
    }
    if ($state.PSObject.Properties.Name -contains 'media_incoming_path' -and (Test-Path -LiteralPath $state.media_incoming_path)) {
        Move-Item -LiteralPath $state.media_incoming_path -Destination $state.media_destination_path
    }
    $state.stage = 'moved'
    Write-JsonAtomic -Path $statePath -Value $state
    Write-Output "Moved $($state.filename) to $($state.relative_path)$(if ($state.PSObject.Properties.Name -contains 'media_relative_path') { " and its media to $($state.media_relative_path)" })."
}

if (-not (Test-Path -LiteralPath $state.destination_path)) { throw "Active ingestion source is missing: $($state.destination_path)" }
$sources = Read-JsonLines -Path $sourcePath
$sourceById = @{}
foreach ($source in $sources) { $sourceById[$source.source_id] = $source }

if ($state.stage -eq 'moved') {
    $file = Get-Item -LiteralPath $state.destination_path
    $normalizedText = Get-NormalizedContent -Content (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8)
    if ([string]::IsNullOrWhiteSpace($normalizedText)) {
        Append-JsonLine -Path $logPath -Value ([ordered]@{ completed_at=(Get-Date).ToUniversalTime().ToString('o'); filename=$state.filename; source_type=$state.source_type; status='skipped_empty' })
        Remove-Item -LiteralPath $statePath -Force
        Write-Output "Skipped empty $($state.source_type) $($state.filename); any associated media was still moved to data/media/audio and video/."
        exit 0
    }
    $normalizedHash = Get-Sha256 -Value $normalizedText
    $existing = @($sources | Where-Object { $_.relative_path -eq $state.relative_path } | Select-Object -First 1)
    if ($existing.Count) {
        $state.source_id = $existing[0].source_id
        $state.normalized_text = $existing[0].normalized_text
        $state.stage = if ($existing[0].included_in_synthesis) { 'source_recorded' } else { 'duplicate_skipped' }
    } else {
        $canonical = @($sources | Where-Object { $_.normalized_content_hash_sha256 -eq $normalizedHash -and $_.included_in_synthesis } | Sort-Object source_id | Select-Object -First 1)
        $sourceId = Get-NextNumericId -Rows $sources -Property 'source_id' -Prefix 'S' -Digits 4
        $record = [ordered]@{
            source_id = $sourceId
            source_type = $state.source_type
            relative_path = $state.relative_path
            filename = $file.Name
            recorded_at = Get-RecordedAt -File $file
            file_bytes = $file.Length
            word_count = ([regex]::Matches($normalizedText, '\S+')).Count
            character_count = $normalizedText.Length
            file_hash_sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            normalized_content_hash_sha256 = $normalizedHash
            normalized_text = $normalizedText
            duplicate_status = if ($canonical.Count) { 'exact_duplicate' } else { 'unique' }
            canonical_source_id = if ($canonical.Count) { $canonical[0].source_id } else { $null }
            exact_duplicate_group = $null
            included_in_synthesis = if ($canonical.Count) { $false } else { $true }
            near_duplicate_candidates = @()
            associations = @()
        }
        Append-JsonLine -Path $sourcePath -Value $record
        $sources += [pscustomobject]$record; $sourceById[$sourceId] = [pscustomobject]$record
        $state.source_id = $sourceId
        $state.normalized_text = $normalizedText
        $state.stage = if ($canonical.Count) { 'duplicate_skipped' } else { 'source_recorded' }
    }
    Write-JsonAtomic -Path $statePath -Value $state
}

# Rebuild the citation target as soon as the source file is recorded, including
# exact duplicates that are not sent to the LLM.
if ($state.stage -in @('source_recorded', 'duplicate_skipped')) {
    & (Join-Path $repo 'scripts\build_all_texts.ps1') -RepositoryRoot $repo
}

if ($state.stage -eq 'duplicate_skipped') {
    Append-JsonLine -Path $logPath -Value ([ordered]@{ completed_at=(Get-Date).ToUniversalTime().ToString('o'); filename=$state.filename; source_id=$state.source_id; status='skipped_exact_duplicate' })
    Remove-Item -LiteralPath $statePath -Force
    Write-Output "Skipped exact-duplicate source $($state.source_id); no LLM calls were made."
    exit 0
}

if ($state.stage -eq 'source_recorded') {
    $topics = Get-Content -LiteralPath (Join-Path $repo 'artifacts\topics.md') -Raw -Encoding UTF8
    $classificationSystem = @'
Classify the supplied text into exactly one of the 25 supplied KB topics. Return JSON only: {"primary_topic_id":1,"confidence":"high|medium|low","rationale":"brief source-grounded reason"}. Do not return secondary topics, ambiguity analysis, rewritten text, or facts not in the input. Topic 25 is only for non-substantive promotion, banter, low-context media, or topical commentary with no self-contained broader lesson.
'@
    $classificationRequest = Invoke-GroqJson -KeyEntries $keyEntries -ModelNames $models -System ($classificationSystem + "`n`nTOPICS:`n" + $topics) -User $state.normalized_text -WorkLabel "classification for $($state.filename)"
    $classification = $classificationRequest.value
    $topicId = [int]$classification.primary_topic_id
    if ($topicId -notin 1..25 -or [string]::IsNullOrWhiteSpace([string]$classification.rationale) -or [string]$classification.confidence -notin @('high','medium','low')) { throw 'Classification response did not match the required schema.' }
    $passages = Read-JsonLines -Path $passagePath
    $passageId = Get-NextNumericId -Rows $passages -Property 'passage_id' -Prefix 'P' -Digits 6
    $state.primary_topic_id = $topicId
    $state.confidence = [string]$classification.confidence
    $state.rationale = [string]$classification.rationale
    $state.passage_id = $passageId
    $state.classification_model = $classificationRequest.model
    $state.classification_api_key_name = $classificationRequest.api_key_name
    $state.stage = 'classified'
    Append-JsonLine -Path $passagePath -Value ([ordered]@{
        passage_id = $passageId; source_id = $state.source_id; source_type = $state.source_type; relative_path = $state.relative_path
        recorded_at = $sourceById[$state.source_id].recorded_at; segment_index = 1; text = $state.normalized_text
        word_count = ([regex]::Matches($state.normalized_text, '\S+')).Count; primary_topic_id = $topicId; secondary_topic_ids = @()
        candidate_topics = @([ordered]@{ topic_id=$topicId; title=$null; score=$null; matched_terms=@() })
        non_substantive_signals = @(); routing = if ($topicId -eq 25) { 'non_substantive' } else { 'substantive' }
        routing_reasons = @('single_llm_classification'); classification_confidence = $state.confidence; review_required = $false
    })
    Write-JsonAtomic -Path $statePath -Value $state
    Write-Output "Classified $($state.source_id) as topic $topicId using $($state.classification_api_key_name) / $($state.classification_model)."
}

if ($state.stage -eq 'classified') {
    $maps = Read-JsonLines -Path $mapPath
    $existingMap = @($maps | Where-Object { $_.passage_id -eq $state.passage_id -and $_.assignment_role -eq 'primary' } | Select-Object -First 1)
    if (-not $existingMap.Count) {
        $topicRow = @($maps | Where-Object { [int]$_.topic_id -eq [int]$state.primary_topic_id } | Select-Object -First 1)
        if (-not $topicRow.Count) { throw "Topic $($state.primary_topic_id) is absent from the source map." }
        $source = $sourceById[$state.source_id]
        Append-JsonLine -Path $mapPath -Value ([ordered]@{
            topic_id = [int]$state.primary_topic_id; topic_title = $topicRow[0].topic_title; assignment_role = 'primary'
            assignment_method = 'llm_single_classification'; routing = if ([int]$state.primary_topic_id -eq 25) { 'non_substantive' } else { 'substantive' }
            confidence = $state.confidence; rationale = $state.rationale; passage_id = $state.passage_id; passage_text = $state.normalized_text
            passage_word_count = ([regex]::Matches($state.normalized_text, '\S+')).Count; segment_index = 1; source_id = $source.source_id
            source_type = $source.source_type; relative_path = $source.relative_path; recorded_at = $source.recorded_at
            source_sha256 = $source.file_hash_sha256; reviewed_model = $state.classification_model; reviewed_at = (Get-Date).ToUniversalTime().ToString('o')
        })
    }
    $state.stage = 'source_mapped'
    Write-JsonAtomic -Path $statePath -Value $state
    Write-Output "Added primary source-map entry for $($state.passage_id)."
}

if ($state.stage -eq 'source_mapped') {
    $maps = Read-JsonLines -Path $mapPath
    $topicRows = @($maps | Where-Object { [int]$_.topic_id -eq [int]$state.primary_topic_id -and $_.assignment_role -eq 'primary' })
    $topicTitle = [string]$topicRows[0].topic_title
    $topicFile = Get-TopicFile -KbPath $kbPath -TopicId ([int]$state.primary_topic_id)
    $currentDocument = Get-Content -LiteralPath $topicFile.FullName -Raw -Encoding UTF8
    $originalBody = Get-TopicBody -Document $currentDocument
    $currentBody = Remove-CitationsForGroq -Text $originalBody
    $topicSourceCount = @($topicRows | Select-Object -ExpandProperty source_id -Unique).Count
    $updateSystem = @'
Return JSON only: {"markdown":"..."}. Update the supplied knowledge-base document with the supplied new source text. The markdown value must start with "## Overview" and contain exactly these sections in order: Overview, Core ideas, Principles and mental models, Recommended practices, Examples and stories, Tensions and contradictions, Caveats. Make the smallest possible line-level change: retain every unaffected line verbatim, and add or revise a line only when the new source directly supports it. Do not rewrite, reorder, summarize, or polish unaffected material. Use the KB's established editorial voice: integrate claims directly, and never write source-note phrasing such as "the source states," "the source asserts," or "this source explains." Do not include citations, source IDs, links, YAML, a document title, a Sources section, code fences, or reasoning. Do not invent facts. Attribute contested claims to the creator; label speculative health/scientific claims, strongly gendered framing, political claims, and unsafe advice appropriately.
'@
    $updateInput = @"
INCOMING TEXT:
$($state.normalized_text)

CURRENT KB DOCUMENT:
$currentBody
"@
    $updateRequest = Invoke-GroqJson -KeyEntries $keyEntries -ModelNames $models -System $updateSystem -User $updateInput -WorkLabel "KB update for topic $($state.primary_topic_id)"
    $body = [string]$updateRequest.value.markdown
    Assert-CitationFreeTopicBody -Body $body
    Assert-MinimalLineEdits -OriginalBody $currentBody -UpdatedBody $body
    $linkedBody = Restore-DeterministicCitations -OriginalBody $originalBody -UpdatedBody $body -NewSourceId $state.source_id -SourceById $sourceById
    Write-TopicDocument -Path $topicFile.FullName -TopicId ([int]$state.primary_topic_id) -Title $topicTitle -Body $linkedBody -SourceCount $topicSourceCount
    $state.kb_update_model = $updateRequest.model
    $state.kb_update_api_key_name = $updateRequest.api_key_name
    $state.stage = 'kb_updated'
    Write-JsonAtomic -Path $statePath -Value $state
    Write-Output "Updated $($topicFile.Name) using $($state.kb_update_api_key_name) / $($state.kb_update_model)."
}

if ($state.stage -eq 'kb_updated') {
    & (Join-Path $repo 'scripts\validate_kb.ps1') -RepositoryRoot $repo
    $validationExitCode = if (Test-Path -LiteralPath 'Variable:\LASTEXITCODE') { $LASTEXITCODE } else { 0 }
    if ($validationExitCode -ne 0) { throw 'KB validation failed; the active ingestion state was retained for inspection.' }
    $state.stage = 'validated'
    $state.completed_at = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonAtomic -Path $statePath -Value $state
}

if ($state.stage -eq 'validated') {
    Append-JsonLine -Path $logPath -Value ([ordered]@{
        completed_at=$state.completed_at; filename=$state.filename; source_id=$state.source_id; passage_id=$state.passage_id
        topic_id=$state.primary_topic_id; confidence=$state.confidence
        classification_model=$state.classification_model; classification_api_key_name=$state.classification_api_key_name
        kb_update_model=$state.kb_update_model; kb_update_api_key_name=$state.kb_update_api_key_name; status='completed'
    })
    Remove-Item -LiteralPath $statePath -Force
    Write-Output "Ingestion complete: $($state.filename) -> topic $($state.primary_topic_id)."
}
