[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$SourceAppendix = '26-all-texts.md'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonLines([string]$Path) {
    @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Format-LinkedCitationRuns {
    param([Parameter(Mandatory)][string]$Text)

    $citationLink = '\[S\d{4}\]\([^\)]+\)'
    $separator = '[ \t\u00A0\u202F]*'
    # First unwrap a citation-only parenthetical list so the formatter remains
    # idempotent when the script is run again.
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

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$kbPath = Join-Path $repo 'kb'
$artifactRoot = if (Test-Path -LiteralPath (Join-Path $repo 'build\longterm\source-manifest.jsonl')) { Join-Path $repo 'build\longterm' } else { Join-Path $repo 'build' }
$sourceRows = Read-JsonLines (Join-Path $artifactRoot 'source-manifest.jsonl')
$sourceById = @{}
foreach ($source in $sourceRows) { $sourceById[$source.source_id] = $source }

$files = @(Get-ChildItem -LiteralPath $kbPath -File -Filter '*.md' | Where-Object { $_.Name -match '^(0[1-9]|1\d|2[0-5])-.+\.md$' } | Sort-Object Name)
if ($files.Count -ne 25) { throw "Expected 25 numbered topic documents; found $($files.Count)." }

foreach ($file in $files) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    # Sources are retained in the source map, not repeated as an unlinked appendix.
    $text = [regex]::Replace($text, '(?ms)^## Sources\s*$.*\z', '').TrimEnd()
    $unknown = [System.Collections.Generic.List[string]]::new()
    $text = [regex]::Replace($text, '\[(S\d{4})\](?:\([^\)]*\))?', {
        param($match)
        $id = $match.Groups[1].Value
        if (-not $sourceById.ContainsKey($id)) { $unknown.Add($id); return $match.Value }
        return "[$id]($SourceAppendix#$($id.ToLowerInvariant()))"
    })
    $text = Format-LinkedCitationRuns -Text $text
    if ($unknown.Count) { throw "$($file.Name) contains unknown source ID(s): $($unknown -join ', ')." }
    [System.IO.File]::WriteAllText($file.FullName, $text.TrimEnd() + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Output "Linked citations and removed Sources: $($file.Name)"
}
