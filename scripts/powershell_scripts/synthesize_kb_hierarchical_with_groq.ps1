[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [int]$EvidenceChunkWords = 3500,
    [string]$SourceAppendix = '26-all-texts.md'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Get-EnvValue([string]$Path, [string]$Name) { $line=Get-Content -LiteralPath $Path -Encoding UTF8|Where-Object {$_ -match "^\s*$([regex]::Escape($Name))\s*="}|Select-Object -First 1; if($null -eq $line){return $null}; return (($line -replace "^\s*$([regex]::Escape($Name))\s*=",'').Trim()).Trim('"').Trim("'") }
function Get-HeaderValue($Headers,[string]$Name){try{return (($Headers.GetValues($Name))-join ',')}catch{return $null}}
function Get-WaitSeconds($Headers){foreach($name in @('retry-after','x-ratelimit-reset-tokens','x-ratelimit-reset-requests')){$value=Get-HeaderValue $Headers $name;if($value -match '^\s*(\d+(?:\.\d+)?)\s*$'){return [math]::Ceiling([double]$Matches[1])};if($value -match '^\s*(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?\s*$'){return [math]::Ceiling((if($Matches[1]){[double]$Matches[1]}else{0})*60+(if($Matches[2]){[double]$Matches[2]}else{0}))}};return 60}
function Invoke-Groq([string]$Key,[string]$Model,[string]$System,[string]$User,[int]$MaxTokens){
    $effort=if($Model -like 'qwen/*'){'default'}else{'low'}
    $body=[ordered]@{model=$Model;reasoning_effort=$effort;temperature=0.2;max_completion_tokens=$MaxTokens;messages=@(@{role='system';content=$System},@{role='user';content=$User})}|ConvertTo-Json -Depth 8 -Compress
    $client=[System.Net.Http.HttpClient]::new();$client.Timeout=[timespan]::FromSeconds(45);$cancellation=[System.Threading.CancellationTokenSource]::new();$cancellation.CancelAfter(45000)
    $request=[System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post,'https://api.groq.com/openai/v1/chat/completions')
    $request.Headers.Authorization=[System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Key)
    $request.Content=[System.Net.Http.StringContent]::new($body,[System.Text.Encoding]::UTF8,'application/json')
    try{$response=$client.SendAsync($request,$cancellation.Token).GetAwaiter().GetResult();try{return [pscustomobject]@{status=[int]$response.StatusCode;headers=$response.Headers;body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()}}finally{$response.Dispose()}}
    catch{return [pscustomobject]@{status=599;headers=$null;body=$_.Exception.Message}}
    finally{$cancellation.Dispose();$request.Dispose();$client.Dispose()}
}
function Read-JsonLines([string]$Path){return @(Get-Content -LiteralPath $Path -Encoding UTF8|Where-Object {$_.Trim()}|ForEach-Object {$_|ConvertFrom-Json})}
function Get-KbFiles([string]$Path){$files=@{};foreach($file in (Get-ChildItem -LiteralPath $Path -Filter '*.md')){$line=Get-Content -LiteralPath $file.FullName -Encoding UTF8 -TotalCount 8|Where-Object {$_ -match '^topic_id:\s*\d+\s*$'}|Select-Object -First 1;if($line -notmatch '^topic_id:\s*(\d+)\s*$'){throw "Missing topic_id in $($file.Name)"};$files[[int]$Matches[1]]=$file.FullName};if($files.Count -ne 25){throw 'kb/ must contain exactly 25 topic files.'};return $files}
function Get-DisplayTopicTitle([int]$TopicId,[string]$CanonicalTitle){$property=$script:topicEmojis.PSObject.Properties[[string]$TopicId];$emoji=if($null -eq $property){''}else{[string]$property.Value};return "$emoji $CanonicalTitle".Trim()}
function Format-LinkedCitationRuns([string]$Text){
    $citationLink='\[S\d{4}\]\([^\)]+\)';$gap='[ \t\u00A0\u202F]*'
    $cluster='(?<!\w)\(*'+$gap+$citationLink+'(?:'+$gap+'\)*'+$gap+'(?:,'+$gap+')?\(*'+$gap+$citationLink+')*'+$gap+'\)*'
    return [regex]::Replace($Text,$cluster,{param($match) $links=@([regex]::Matches($match.Value,$citationLink)|ForEach-Object Value);'('+($links -join ', ')+')'})
}
function Write-TopicDocument([string]$Path,$Topic,[string]$Body,$Rows){
    $count=@($Rows|Select-Object -ExpandProperty source_id -Unique).Count
    $body=($Body.Trim() -replace '^```(?:markdown|md)?\s*','' -replace '\s*```\s*$','').Trim()
    $body=[regex]::Replace($body,'\[(S\d{4})\](?:\([^\)]*\))?',{param($match)$id=$match.Groups[1].Value;"[$id]($script:SourceAppendix#$($id.ToLowerInvariant()))"})
    $body=Format-LinkedCitationRuns $body
    $title=Get-DisplayTopicTitle ([int]$Topic.topic_id) ([string]$Topic.topic_title)
    $header="---`ntopic_id: $($Topic.topic_id)`ntitle: $title`nsource_count: $count`nsource_scope:`n  - data/texts`n  - data/transcripts`n---`n`n# $title`n`n"
    [System.IO.File]::WriteAllText($Path,$header+$body+"`n",[System.Text.UTF8Encoding]::new($false))
}
function Split-TopicRows($Rows,[int]$Limit){$chunks=[System.Collections.Generic.List[object]]::new();$current=[System.Collections.Generic.List[object]]::new();$words=0;$index=1;foreach($row in ($Rows|Sort-Object source_id,segment_index)){$rowWords=[int]$row.passage_word_count;if($current.Count -gt 0 -and $words+$rowWords -gt $Limit){$chunks.Add([pscustomobject]@{index=$index;rows=$current.ToArray()});$index++;$current=[System.Collections.Generic.List[object]]::new();$words=0};$current.Add($row);$words+=$rowWords};if($current.Count){$chunks.Add([pscustomobject]@{index=$index;rows=$current.ToArray()})};return @($chunks.ToArray())}
function Invoke-ResilientText([string]$WorkId,[int]$TopicId,[string]$System,[string]$User,$Rows,[int]$MaxTokens,[string[]]$RequiredSections){
    $validSources=@($Rows|Select-Object -ExpandProperty source_id -Unique)
    while($true){$now=[datetime]::UtcNow;$state=$null;for($offset=0;$offset -lt $script:pairStates.Count;$offset++){$candidate=$script:pairStates[($script:pairCursor+$offset)%$script:pairStates.Count];if($candidate.available_at -le $now){$state=$candidate;break}};if($null -eq $state){$earliest=$script:pairStates|Sort-Object available_at|Select-Object -First 1;$seconds=[math]::Max(1,[math]::Ceiling(($earliest.available_at-$now).TotalSeconds));Write-Host "All key/model pairs are cooling down; waiting $seconds second(s) for key slot $($earliest.key_index+1) on $($script:models[$earliest.model_index]).";while($seconds -gt 0){$sleep=[math]::Min(60,$seconds);Start-Sleep -Seconds $sleep;$seconds-=$sleep};continue}
        $slot=$state.key_index;$model=$script:models[$state.model_index];Write-Host "Requesting $WorkId with key slot $($slot+1) / $model.";$response=Invoke-Groq $script:keys[$slot] $model $System $User $MaxTokens;$script:logger.WriteLine(([ordered]@{timestamp=(Get-Date).ToUniversalTime().ToString('o');work_id=$WorkId;topic_id=$TopicId;key_slot=$slot+1;model=$model;status=$response.status;source_passages=$Rows.Count}|ConvertTo-Json -Compress));$script:logger.Flush()
        if($response.status -eq 429){$seconds=Get-WaitSeconds $response.headers;$state.available_at=[datetime]::UtcNow.AddSeconds($seconds);$script:pairCursor=($state.pair_index+1)%$script:pairStates.Count;Write-Host "Rate limited for $WorkId on key slot $($slot+1) / $model; pair cooling down for $seconds second(s).";continue}
        if($response.status -lt 200 -or $response.status -ge 300){$seconds=if($response.status -ge 500){60}else{300};$state.available_at=[datetime]::UtcNow.AddSeconds($seconds);$script:pairCursor=($state.pair_index+1)%$script:pairStates.Count;Write-Host "HTTP $($response.status) for $WorkId on key slot $($slot+1) / $model; pair cooling down for $seconds second(s).";continue}
        try{$text=((($response.body|ConvertFrom-Json).choices|Select-Object -First 1).message.content).Trim();if([string]::IsNullOrWhiteSpace($text)-or $text.Length -lt 180){throw 'Response is too short.'};foreach($section in $RequiredSections){if($text -notmatch [regex]::Escape($section)){throw "Missing required section: $section"}};$citations=@([regex]::Matches($text,'\[S\d{4}\]')|ForEach-Object {$_.Value.Trim('[',']')}|Sort-Object -Unique);$invalidCitations=@($citations|Where-Object {$_ -notin $validSources});foreach($citation in $invalidCitations){$text=$text.Replace("[$citation]",'')};$citations=@([regex]::Matches($text,'\[S\d{4}\]')|ForEach-Object {$_.Value.Trim('[',']')}|Sort-Object -Unique);if($citations.Count -eq 0){throw 'Response has no valid source citations.'}}catch{$seconds=300;$state.available_at=[datetime]::UtcNow.AddSeconds($seconds);$script:pairCursor=($state.pair_index+1)%$script:pairStates.Count;Write-Host "Malformed response for $WorkId from key slot $($slot+1) / $model; pair cooling down for $seconds second(s): $($_.Exception.Message)";continue}
        $script:pairCursor=$state.pair_index;return [pscustomobject]@{text=$text;model=$model;key_slot=$slot+1}
    }
}

$repo=(Resolve-Path -LiteralPath $RepositoryRoot).Path;$script:SourceAppendix=$SourceAppendix;$script:topicEmojis=Get-Content -LiteralPath (Join-Path $repo 'artifacts\topic-emojis.json') -Raw -Encoding UTF8|ConvertFrom-Json;$build=Join-Path $repo 'build';$kbPath=Join-Path $repo 'kb';$envPath=Join-Path $repo '.env';$mapPath=Join-Path $build 'kb-source-map.jsonl';$checkpointPath=Join-Path $build 'llm-kb-hierarchical-synthesis-checkpoint.jsonl';$logPath=Join-Path $build 'groq-kb-hierarchical-synthesis-requests.jsonl'
foreach($path in @($envPath,$mapPath,$kbPath)){if(-not(Test-Path -LiteralPath $path)){throw "Required input is missing: $path"}}
$script:keys=@('GROQ_API_KEY6'|ForEach-Object {$key=Get-EnvValue $envPath $_;if([string]::IsNullOrWhiteSpace($key)){throw "Missing $_ in .env."};$key});$script:models=@('openai/gpt-oss-120b','openai/gpt-oss-20b','qwen/qwen3.6-27b');$kbFiles=Get-KbFiles $kbPath;$mapRows=Read-JsonLines $mapPath
$topicRows=@{};foreach($topicId in 1..25){$topicRows[$topicId]=@($mapRows|Where-Object {[int]$_.topic_id -eq $topicId -and $_.assignment_role -eq 'primary'});if($topicRows[$topicId].Count -eq 0){throw "No primary passages for topic $topicId"}}
$done=@{};if(Test-Path -LiteralPath $checkpointPath){foreach($entry in (Read-JsonLines $checkpointPath)){$done[$entry.work_id]=$entry}}
foreach($topicId in 1..25){$finalId='T{0:D2}-FINAL' -f $topicId;if($done.ContainsKey($finalId)){Write-TopicDocument $kbFiles[$topicId] $topicRows[$topicId][0] $done[$finalId].content $topicRows[$topicId]}}
$evidenceSystem='Return concise Markdown evidence notes from the supplied source passages. Every bullet must retain one or more inline [S0001] citations. Capture claims, practices, examples, contradictions, and cautions; distinguish the creator''s claims from established facts. Do not add facts or advice. Do not write a title, front matter, Sources section, or code fence.'
$finalSystem=@'
Write a rigorous, source-grounded knowledge-base document from the cited evidence notes. Return Markdown only, beginning with "## Overview"; do not include a title, YAML front matter, a Sources section, or a code fence.
Use exactly these sections in order: ## Overview, ## Core ideas, ## Principles and mental models, ## Recommended practices, ## Examples and stories, ## Tensions and contradictions, ## Caveats.
Synthesize rather than concatenate. Every substantive paragraph needs one or more supplied [S0001] citations. Do not invent facts, advice, evidence, or examples. Attribute contested assertions to the creator. Clearly label speculative health/scientific claims, strongly gendered or misogynistic framing, political claims, and advice that could be unsafe if followed literally. For topic 25, describe exclusions and boundaries without turning promotional, banter, or low-context content into advice.
'@
$script:pairStates=[System.Collections.Generic.List[object]]::new();for($keyIndex=0;$keyIndex -lt $script:keys.Count;$keyIndex++){for($modelIndex=0;$modelIndex -lt $script:models.Count;$modelIndex++){$script:pairStates.Add([pscustomobject]@{pair_index=$script:pairStates.Count;key_index=$keyIndex;model_index=$modelIndex;available_at=[datetime]::UtcNow})}};$script:pairCursor=0;$utf8=[System.Text.UTF8Encoding]::new($false);$writer=[System.IO.StreamWriter]::new($checkpointPath,$true,$utf8);$script:logger=[System.IO.StreamWriter]::new($logPath,$true,$utf8)
try{foreach($topicId in 1..25){$rows=$topicRows[$topicId];$topic=$rows[0];$chunkWordLimit=if($topicId -eq 25){800}else{$EvidenceChunkWords};$evidenceMaxTokens=if($topicId -eq 25){450}else{900};$chunks=Split-TopicRows $rows $chunkWordLimit;foreach($chunk in $chunks){$workId='T{0:D2}-E{1:D3}' -f $topicId,$chunk.index;if(-not $done.ContainsKey($workId)){$passages=@($chunk.rows|ForEach-Object {"[$($_.source_id)] ($($_.relative_path))`n$($_.passage_text)"});$result=Invoke-ResilientText $workId $topicId $evidenceSystem ("Topic ${topicId}: $($topic.topic_title)`n`nSource passages:`n`n"+($passages -join "`n`n")) $chunk.rows $evidenceMaxTokens @();$entry=[ordered]@{work_id=$workId;kind='evidence';topic_id=$topicId;chunk_index=$chunk.index;content=$result.text;model=$result.model;key_slot=$result.key_slot;completed_at=(Get-Date).ToUniversalTime().ToString('o')};$writer.WriteLine(($entry|ConvertTo-Json -Depth 4 -Compress));$writer.Flush();$done[$workId]=[pscustomobject]$entry;Write-Output "Extracted evidence $workId with key slot $($result.key_slot) on $($result.model)."}}
        $evidence=@($chunks|ForEach-Object {$done[('T{0:D2}-E{1:D3}' -f $topicId,$_.index)].content})
        $finalEvidence=$evidence
        if($topicId -eq 25){
            $mergeSystem='Return compact Markdown evidence notes from the supplied cited notes. Retain only source-supported category patterns, boundary cases, and caveats. Every bullet must retain one or more [S0001] citations. Do not add facts, a title, front matter, Sources section, or code fence.'
            $merged=[System.Collections.Generic.List[string]]::new()
            for($start=0;$start -lt $evidence.Count;$start+=4){
                $mergeIndex=[int]($start/4)+1;$mergeId='T25-M{0:D3}' -f $mergeIndex;$end=[math]::Min($start+3,$evidence.Count-1)
                if(-not $done.ContainsKey($mergeId)){
                    $mergeInput=@($evidence[$start..$end]) -join "`n`n---`n`n"
                    $mergeResult=Invoke-ResilientText $mergeId $topicId $mergeSystem ("Topic 25: $($topic.topic_title)`n`nCited evidence notes:`n`n"+$mergeInput) $rows 300 @()
                    $mergeEntry=[ordered]@{work_id=$mergeId;kind='merge';topic_id=$topicId;content=$mergeResult.text;model=$mergeResult.model;key_slot=$mergeResult.key_slot;completed_at=(Get-Date).ToUniversalTime().ToString('o')}
                    $writer.WriteLine(($mergeEntry|ConvertTo-Json -Depth 4 -Compress));$writer.Flush();$done[$mergeId]=[pscustomobject]$mergeEntry;Write-Output "Merged Topic 25 evidence $mergeIndex with key slot $($mergeResult.key_slot) on $($mergeResult.model)."
                }
                $merged.Add([string]$done[$mergeId].content)
            }
            $finalEvidence=@($merged.ToArray())
        }
        $finalId='T{0:D2}-FINAL' -f $topicId;if(-not $done.ContainsKey($finalId)){$required=@('## Overview','## Core ideas','## Principles and mental models','## Recommended practices','## Examples and stories','## Tensions and contradictions','## Caveats');$result=Invoke-ResilientText $finalId $topicId $finalSystem ("Topic ${topicId}: $($topic.topic_title)`n`nCited evidence notes:`n`n"+($finalEvidence -join "`n`n---`n`n")) $rows 3000 $required;Write-TopicDocument $kbFiles[$topicId] $topic $result.text $rows;$entry=[ordered]@{work_id=$finalId;kind='final';topic_id=$topicId;content=$result.text;model=$result.model;key_slot=$result.key_slot;completed_at=(Get-Date).ToUniversalTime().ToString('o')};$writer.WriteLine(($entry|ConvertTo-Json -Depth 4 -Compress));$writer.Flush();$done[$finalId]=[pscustomobject]$entry;Write-Output "Synthesized topic $topicId/25 with key slot $($result.key_slot) on $($result.model)."}}
}finally{$writer.Dispose();$script:logger.Dispose()}
Write-Output 'Hierarchical LLM KB synthesis complete.'
