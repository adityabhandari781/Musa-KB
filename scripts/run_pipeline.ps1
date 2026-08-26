[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('cloud', 'local')][string]$TranscriptionMode = 'cloud'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
Push-Location $repo
try {
    & python .\scripts\fetch.py
    if ($LASTEXITCODE -ne 0) { throw 'Fetch failed.' }
    $transcriptionScript = if ($TranscriptionMode -eq 'cloud') { '.\scripts\cloud_transcription.py' } else { '.\scripts\transcription.py' }
    & python $transcriptionScript
    if ($LASTEXITCODE -ne 0) { throw 'Transcription failed.' }

    while ($true) {
        $pending = @(
            Get-ChildItem -LiteralPath (Join-Path $repo 'incoming\texts') -File -Filter '*.txt' -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath (Join-Path $repo 'incoming\transcripts') -File -Filter '*.txt' -ErrorAction SilentlyContinue
        )
        if ($pending.Count -eq 0) { break }
        & .\scripts\ingest_oldest_incoming.ps1 -RepositoryRoot $repo
        if ($LASTEXITCODE -ne 0) { throw 'Ingestion failed.' }
    }
    Write-Output 'Integrated pipeline complete.'
}
finally { Pop-Location }
