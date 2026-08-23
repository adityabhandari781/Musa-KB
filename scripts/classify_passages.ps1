[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [int]$TargetTranscriptPassageWords = 180,
    [int]$MaximumTranscriptPassageWords = 260
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WordCount {
    param([AllowEmptyString()][string]$Text)
    return ([regex]::Matches($Text, '\S+')).Count
}

function Get-Sentences {
    param([Parameter(Mandatory)][string]$Text)

    $flatText = [regex]::Replace($Text, '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($flatText)) { return @() }
    return @([regex]::Matches($flatText, '(?s).+?(?:[.!?]+(?=\s|$)|$)') |
        ForEach-Object { $_.Value.Trim() } |
        Where-Object { $_ })
}

function Split-OversizeUnit {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$MaximumWords
    )

    if ((Get-WordCount -Text $Text) -le $MaximumWords) {
        return @($Text)
    }

    $units = [System.Collections.Generic.List[string]]::new()
    $current = [System.Collections.Generic.List[string]]::new()
    $currentWords = 0
    foreach ($clause in ([regex]::Split($Text, '(?<=[,;:])\s+') | Where-Object { $_ })) {
        $clauseWords = Get-WordCount -Text $clause
        if ($clauseWords -gt $MaximumWords) {
            if ($currentWords -gt 0) {
                $units.Add(($current -join ' '))
                $current.Clear()
                $currentWords = 0
            }
            $words = @($clause -split '\s+' | Where-Object { $_ })
            for ($index = 0; $index -lt $words.Count; $index += $MaximumWords) {
                $lastIndex = [math]::Min($index + $MaximumWords - 1, $words.Count - 1)
                $units.Add(($words[$index..$lastIndex] -join ' '))
            }
            continue
        }
        if ($currentWords -gt 0 -and $currentWords + $clauseWords -gt $MaximumWords) {
            $units.Add(($current -join ' '))
            $current.Clear()
            $currentWords = 0
        }
        $current.Add($clause)
        $currentWords += $clauseWords
    }
    if ($currentWords -gt 0) {
        $units.Add(($current -join ' '))
    }
    return @($units)
}

function Get-CoherentPassages {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$SourceType,
        [Parameter(Mandatory)][int]$TargetWords,
        [Parameter(Mandatory)][int]$MaximumWords
    )

    $sourceWordCount = Get-WordCount -Text $Text
    if ($SourceType -eq 'text' -or $sourceWordCount -le $MaximumWords) {
        return @($Text.Trim())
    }

    $passages = [System.Collections.Generic.List[string]]::new()
    $current = [System.Collections.Generic.List[string]]::new()
    $currentWords = 0
    foreach ($rawSentence in (Get-Sentences -Text $Text)) {
        foreach ($sentence in (Split-OversizeUnit -Text $rawSentence -MaximumWords $MaximumWords)) {
            $sentenceWords = Get-WordCount -Text $sentence
            if ($currentWords -gt 0 -and $currentWords + $sentenceWords -gt $MaximumWords) {
                $passages.Add(($current -join ' '))
                $current.Clear()
                $currentWords = 0
            }

            $current.Add($sentence)
            $currentWords += $sentenceWords
            if ($currentWords -ge $TargetWords) {
                $passages.Add(($current -join ' '))
                $current.Clear()
                $currentWords = 0
            }
        }
    }

    if ($currentWords -gt 0) {
        $trailing = $current -join ' '
        $lastPassageWords = if ($passages.Count -gt 0) { Get-WordCount -Text $passages[$passages.Count - 1] } else { 0 }
        if ($passages.Count -gt 0 -and $currentWords -lt 60 -and $lastPassageWords + $currentWords -le $MaximumWords) {
            $passages[$passages.Count - 1] = "$($passages[$passages.Count - 1]) $trailing"
        }
        else {
            $passages.Add($trailing)
        }
    }
    return @($passages)
}

function Get-TermMatchCount {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Term
    )

    $escaped = [regex]::Escape($Term).Replace('\ ', '\s+')
    $pattern = "(?i)(?<![\p{L}\p{N}])$escaped(?![\p{L}\p{N}])"
    return ([regex]::Matches($Text, $pattern)).Count
}

function Get-TopicScore {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$Topic
    )

    $score = 0.0
    $matches = [System.Collections.Generic.List[string]]::new()
    foreach ($term in $Topic.phrases) {
        $count = Get-TermMatchCount -Text $Text -Term $term
        if ($count -gt 0) {
            $score += 2.0 * [math]::Min($count, 3)
            $matches.Add($term)
        }
    }
    foreach ($term in $Topic.keywords) {
        $count = Get-TermMatchCount -Text $Text -Term $term
        if ($count -gt 0) {
            $score += 1.0 * [math]::Min($count, 2)
            if (-not $matches.Contains($term)) { $matches.Add($term) }
        }
    }
    return [pscustomobject]@{
        topic_id = $Topic.id
        title = $Topic.title
        score = [math]::Round($score, 2)
        matched_terms = @($matches | Select-Object -First 12)
    }
}

function Get-NonSubstantiveSignals {
    param([Parameter(Mandatory)][string]$Text)

    $rules = [ordered]@{
        promotion = @('giveaway', 'subscribe', 'join telegram', 'telegram', 'comment below', 'like and share', 'course launch', 'mentorship', 'hiring', 'poll', 'launching')
        banter = @('good morning boys', 'good night boys', 'lol', 'lmao', 'haha', 'fuck you', 'shut up', 'versus', 'vs.')
        low_context = @('watch this', 'listen to this', 'thoughts?', 'what do you think', 'repost', 'meme')
        topical_commentary = @('andrew tate', 'donald trump', 'ufc', 'covid', 'ukraine', 'israel', 'war', 'scammer', 'lawsuit')
    }
    $signals = [System.Collections.Generic.List[object]]::new()
    $score = 0.0
    foreach ($category in $rules.Keys) {
        foreach ($term in $rules[$category]) {
            $count = Get-TermMatchCount -Text $Text -Term $term
            if ($count -gt 0) {
                $score += [math]::Min($count, 2)
                $signals.Add([ordered]@{ category = $category; term = $term })
            }
        }
    }
    return [pscustomobject]@{
        score = [math]::Round($score, 2)
        signals = @($signals)
    }
}

$taxonomy = @(
    [pscustomobject]@{ id = 1; title = 'Identity and self-reinvention'; phrases = @('old self', 'self image', 'self-image', 'alter ego', 'limiting belief', 'inner child', 'family name', 'reinvent yourself'); keywords = @('identity', 'reinvention', 'self-talk', 'self talk', 'becoming', 'underdog') }
    [pscustomobject]@{ id = 2; title = 'Ghost Mode and environmental separation'; phrases = @('ghost mode', 'change your circle', 'cut off', 'work in silence', 'working silently', 'bad environment', 'people around you'); keywords = @('isolate', 'isolation', 'withdraw', 'circle', 'environment', 'distracting') }
    [pscustomobject]@{ id = 3; title = 'Vision, purpose, and goal-setting'; phrases = @('definiteness of purpose', '12 week year', 'core values', 'three planning horizons', 'desired reality', 'set goals', 'goal setting'); keywords = @('vision', 'purpose', 'mission', 'priority', 'priorities', 'visualization', 'visualize', 'goals', 'manifestation') }
    [pscustomobject]@{ id = 4; title = 'Discipline, execution, and productivity'; phrases = @('deep work', 'one big thing', 'weekly review', 'daily system', 'phone addiction', 'reduce friction', 'self imposed penalty'); keywords = @('discipline', 'consistent', 'consistency', 'habit', 'routine', 'execute', 'execution', 'productivity', 'journal', 'procrastination') }
    [pscustomobject]@{ id = 5; title = 'Professionalism and mastery of craft'; phrases = @('professional versus amateur', 'deliberate practice', 'feedback loop', 'respect the process', 'master your craft', 'high standards'); keywords = @('professional', 'amateur', 'craft', 'preparation', 'practice', 'standards', 'mastery', 'mistakes') }
    [pscustomobject]@{ id = 6; title = 'Resilience and adversity'; phrases = @('bounce back', 'refuse to be a victim', 'turn pain into', 'childhood trauma', 'keep going', 'got rejected'); keywords = @('resilience', 'adversity', 'failure', 'rejection', 'humiliation', 'trauma', 'pain', 'loss', 'victim', 'perseverance') }
    [pscustomobject]@{ id = 7; title = 'Confidence, boldness, and action'; phrases = @('take up space', 'overcome fear', 'be more confident', 'self respect', 'take action', 'stop hesitating'); keywords = @('confidence', 'confident', 'bold', 'boldness', 'fear', 'hesitation', 'assertive', 'decisive', 'confrontation', 'courage') }
    [pscustomobject]@{ id = 8; title = 'Money and entrepreneurship'; phrases = @('make money online', 'financial freedom', 'provide value', 'escape the 9', 'rich people', 'broke people', 'start a business', 'invest in yourself'); keywords = @('money', 'rich', 'broke', 'wealth', 'market', 'sales', 'entrepreneur', 'business', 'income', 'leverage', 'investment') }
    [pscustomobject]@{ id = 9; title = 'YouTube and content businesses'; phrases = @('youtube channel', 'faceless channel', 'automated channel', 'video hook', 'audience retention', 'youtube automation', 'content business'); keywords = @('youtube', 'thumbnail', 'retention', 'monetization', 'monetize', 'channel', 'video', 'hook') }
    [pscustomobject]@{ id = 10; title = 'Personal branding and audience-building'; phrases = @('personal brand', 'build an audience', 'tell your story', 'social proof', 'be authentic', 'content positioning'); keywords = @('branding', 'brand', 'audience', 'followers', 'storytelling', 'authenticity', 'positioning', 'memorable') }
    [pscustomobject]@{ id = 11; title = 'Persuasion and communication'; phrases = @('body language', 'emotion before logic', 'loss aversion', 'social proof', 'clear point', 'frame the conversation', 'public speaking'); keywords = @('persuasion', 'persuade', 'communication', 'charisma', 'negotiate', 'negotiation', 'framing', 'urgency', 'speak', 'speaking') }
    [pscustomobject]@{ id = 12; title = 'Networking and social hierarchy'; phrases = @('high status', 'provide value to', 'social hierarchy', 'build relationships', 'power dynamics', 'network with'); keywords = @('networking', 'network', 'status', 'hierarchy', 'connections', 'competence', 'influential', 'relationship') }
    [pscustomobject]@{ id = 13; title = 'Fitness and physical capability'; phrases = @('strength training', 'combat sports', 'progressive overload', 'ice bath', 'assault bike', 'hybrid athlete', 'martial arts'); keywords = @('fitness', 'gym', 'workout', 'bodybuilding', 'strength', 'wrestling', 'running', 'conditioning', 'burpees', 'sprint', 'training') }
    [pscustomobject]@{ id = 14; title = 'Health, testosterone, and vitality'; phrases = @('natural testosterone', 'sperm health', 'sleep quality', 'sunlight exposure', 'diet and nutrition', 'supplement stack', 'energy management'); keywords = @('testosterone', 'sleep', 'nutrition', 'diet', 'sunlight', 'fertility', 'sperm', 'supplements', 'posture', 'health', 'vitality') }
    [pscustomobject]@{ id = 15; title = 'Youth, energy, and aging'; phrases = @('while you are young', 'while you''re young', 'high energy', 'get older', 'waste your youth', 'young and hungry'); keywords = @('youth', 'young', 'aging', 'ageing', 'stamina', 'recovery', 'regret', 'energy', 'old') }
    [pscustomobject]@{ id = 16; title = 'Masculinity, responsibility, and power'; phrases = @('be a man', 'men need', 'male duty', 'controlled aggression', 'warrior mindset', 'wild man', 'take responsibility'); keywords = @('masculinity', 'masculine', 'manhood', 'men', 'warrior', 'responsibility', 'power', 'respect', 'aggression', 'passive') }
    [pscustomobject]@{ id = 17; title = 'Brotherhood, friendship, and loyalty'; phrases = @('real friends', 'bro code', 'loyal through', 'cut off friends', 'your brothers', 'yes men', 'strong circle'); keywords = @('brotherhood', 'brother', 'friends', 'friendship', 'loyalty', 'loyal', 'betrayal', 'betrayed', 'circle') }
    [pscustomobject]@{ id = 18; title = 'Family and fatherhood'; phrases = @('become a father', 'raise your children', 'lead by example', 'fatherless', 'protect your children', 'bloodline standard', 'home school'); keywords = @('fatherhood', 'father', 'dad', 'family', 'children', 'child', 'parenting', 'homeschooling', 'bloodline') }
    [pscustomobject]@{ id = 19; title = 'Marriage, women, and gender dynamics'; phrases = @('find a wife', 'red flags', 'green flags', 'traditional roles', 'gender dynamics', 'choose a partner', 'get married'); keywords = @('marriage', 'wife', 'woman', 'women', 'girlfriend', 'dating', 'relationship', 'reproduction', 'loyalty') }
    [pscustomobject]@{ id = 20; title = 'Spirituality and consciousness'; phrases = @('law of attraction', 'higher consciousness', 'power of prayer', 'talk to god', 'subconscious mind', 'spiritual development', 'law of assumption'); keywords = @('god', 'faith', 'prayer', 'gratitude', 'meditation', 'meditate', 'spirituality', 'spiritual', 'consciousness', 'dreams', 'fate', 'duality', 'placebo') }
    [pscustomobject]@{ id = 21; title = 'Technology, algorithms, and attention'; phrases = @('phone addiction', 'doom scrolling', 'doomscrolling', 'algorithmic control', 'artificial intelligence', 'social media', 'protect your attention'); keywords = @('technology', 'algorithm', 'algorithms', 'dopamine', 'phone', 'scrolling', 'attention', 'ai', 'internet', 'online') }
    [pscustomobject]@{ id = 22; title = 'Social conditioning and Genjutsu'; phrases = @('social conditioning', 'life script', 'societal hypnosis', 'escape the matrix', 'government control', 'mass media', 'covid era', 'genjutsu'); keywords = @('conformity', 'conditioning', 'school', 'government', 'influencers', 'media', 'security', 'society') }
    [pscustomobject]@{ id = 23; title = 'Learning and thinking skills'; phrases = @('learn the fundamentals', 'skill stacking', 'critical thinking', 'learn from role models', 'higher education', 'go to college', 'process information'); keywords = @('learning', 'learn', 'education', 'college', 'university', 'fundamentals', 'skill', 'skills', 'thinking', 'curiosity', 'inspiration') }
    [pscustomobject]@{ id = 24; title = 'Community and alternative living'; phrases = @('far from weak', 'unchained movement', 'build a village', 'tax haven', 'alternative living', 'real world brotherhood', 'independent community'); keywords = @('community', 'village', 'homeschooling', 'homeschool', 'unchained', 'independent', 'movement') }
)

if ($taxonomy.Count -ne 24 -or @($taxonomy.id | Sort-Object -Unique).Count -ne 24) {
    throw 'The substantive topic taxonomy must contain exactly one definition for topics 1–24.'
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$buildRoot = Join-Path $repo 'build'
$manifestPath = Join-Path $buildRoot 'source-manifest.jsonl'
$passagePath = Join-Path $buildRoot 'passage-manifest.jsonl'
$summaryPath = Join-Path $buildRoot 'passage-summary.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Source manifest not found. Run scripts/inventory_sources.ps1 first: $manifestPath"
}

$records = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8 |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.included_in_synthesis })
$passages = @()
$passageNumber = 0

foreach ($record in $records) {
    $segments = Get-CoherentPassages -Text $record.normalized_text -SourceType $record.source_type -TargetWords $TargetTranscriptPassageWords -MaximumWords $MaximumTranscriptPassageWords
    $segmentIndex = 0
    foreach ($segment in $segments) {
        $segmentIndex++
        $passageNumber++
        $wordCount = Get-WordCount -Text $segment
        $scores = @($taxonomy | ForEach-Object { Get-TopicScore -Text $segment -Topic $_ } | Where-Object { $_.score -gt 0 } | Sort-Object @{ Expression = 'score'; Descending = $true }, topic_id)
        $topSubstantive = $scores | Select-Object -First 1
        $secondSubstantive = $scores | Select-Object -Skip 1 -First 1
        $nonSubstantive = Get-NonSubstantiveSignals -Text $segment

        $lowContext = $wordCount -lt 10
        $weakSubstantive = ($null -eq $topSubstantive -or $topSubstantive.score -lt 2)
        $promotionSignal = @($nonSubstantive.signals | Where-Object category -eq 'promotion').Count -gt 0
        $topicalSignal = @($nonSubstantive.signals | Where-Object category -eq 'topical_commentary').Count -gt 0
        $routeToNonSubstantive = $lowContext -or $null -eq $topSubstantive -or (($promotionSignal -or $topicalSignal) -and $weakSubstantive)
        $routingReasons = [System.Collections.Generic.List[string]]::new()
        if ($lowContext) { $routingReasons.Add('low_context') }
        if ($null -eq $topSubstantive) { $routingReasons.Add('no_substantive_topic_signal') }
        if ($promotionSignal -and $weakSubstantive) { $routingReasons.Add('promotion_without_substantive_lesson') }
        if ($topicalSignal -and $weakSubstantive) { $routingReasons.Add('topical_commentary_without_substantive_lesson') }

        $primaryTopicId = $null
        $secondaryTopicIds = @()
        $candidateTopics = @($scores)
        if ($routeToNonSubstantive) {
            $primaryTopicId = 25
            $candidateTopics += [pscustomobject]@{
                topic_id = 25
                title = 'Non-substantive material'
                score = [math]::Max(1, $nonSubstantive.score)
                matched_terms = @($nonSubstantive.signals | ForEach-Object term | Select-Object -Unique)
            }
            $candidateTopics = @($candidateTopics | Sort-Object @{ Expression = 'score'; Descending = $true }, topic_id)
        }
        else {
            $primaryTopicId = $topSubstantive.topic_id
            $secondaryTopicIds = @($scores |
                Where-Object { $_.topic_id -ne $primaryTopicId -and $_.score -ge ($topSubstantive.score * 0.45) } |
                Select-Object -First 3 |
                ForEach-Object topic_id)
        }

        $confidence = 'low'
        if ($primaryTopicId -eq 25 -and ($lowContext -or $nonSubstantive.score -ge 2)) {
            $confidence = 'high'
        }
        elseif ($null -ne $topSubstantive) {
            $scoreRatio = if ($null -eq $secondSubstantive) { 1.0 } else { $topSubstantive.score / ($topSubstantive.score + $secondSubstantive.score) }
            if ($topSubstantive.score -ge 5 -and $scoreRatio -ge 0.65) { $confidence = 'high' }
            elseif ($topSubstantive.score -ge 2) { $confidence = 'medium' }
        }

        $reviewRequired = $primaryTopicId -eq 25 -or $confidence -eq 'low' -or ($null -ne $secondSubstantive -and [math]::Abs($topSubstantive.score - $secondSubstantive.score) -lt 1) -or $secondaryTopicIds.Count -gt 2
        $passages += [pscustomobject][ordered]@{
            passage_id = ('P{0:D6}' -f $passageNumber)
            source_id = $record.source_id
            source_type = $record.source_type
            relative_path = $record.relative_path
            recorded_at = $record.recorded_at
            segment_index = $segmentIndex
            text = $segment
            word_count = $wordCount
            primary_topic_id = $primaryTopicId
            secondary_topic_ids = $secondaryTopicIds
            candidate_topics = $candidateTopics
            non_substantive_signals = $nonSubstantive.signals
            routing = if ($routeToNonSubstantive) { 'non_substantive' } else { 'substantive' }
            routing_reasons = @($routingReasons)
            classification_confidence = $confidence
            review_required = $reviewRequired
        }
    }
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$writer = [System.IO.StreamWriter]::new($passagePath, $false, $utf8NoBom)
try {
    foreach ($passage in $passages) {
        $writer.WriteLine(($passage | ConvertTo-Json -Depth 8 -Compress))
    }
}
finally {
    $writer.Dispose()
}

$sourceIdsWithPassages = @($passages | Select-Object -ExpandProperty source_id -Unique)
$topicCounts = @(1..25 | ForEach-Object {
    $topic = $_
    [ordered]@{
        topic_id = $topic
        primary_passage_count = @($passages | Where-Object primary_topic_id -eq $topic).Count
        secondary_passage_count = @($passages | Where-Object { $_.secondary_topic_ids -contains $topic }).Count
    }
})
$summary = [ordered]@{
    schema_version = 1
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    input_canonical_source_count = $records.Count
    sources_with_passages = $sourceIdsWithPassages.Count
    passage_count = $passages.Count
    review_required_count = @($passages | Where-Object review_required).Count
    non_substantive_primary_count = @($passages | Where-Object primary_topic_id -eq 25).Count
    confidence = [ordered]@{
        high = @($passages | Where-Object classification_confidence -eq 'high').Count
        medium = @($passages | Where-Object classification_confidence -eq 'medium').Count
        low = @($passages | Where-Object classification_confidence -eq 'low').Count
    }
    topic_counts = $topicCounts
    files = [ordered]@{
        passage_manifest = 'build/passage-manifest.jsonl'
        source_manifest = 'build/source-manifest.jsonl'
    }
}
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 8), $utf8NoBom)

Write-Output "Classification complete: $($summary.passage_count) passages from $($summary.input_canonical_source_count) canonical sources."
Write-Output "Primary topic 25 passages: $($summary.non_substantive_primary_count); review required: $($summary.review_required_count)."
Write-Output "Artifacts: build/passage-manifest.jsonl, build/passage-summary.json"
