[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('cloud', 'local')][string]$TranscriptionMode = 'cloud'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$incomingRoot = Join-Path $repo 'data\incoming'
$dataRoot = (Resolve-Path -LiteralPath (Join-Path $repo 'data')).Path
Push-Location $repo
try {
    & python .\scripts\fetch.py
    if ($LASTEXITCODE -ne 0) { throw 'Fetch failed.' }
    $transcriptionScript = if ($TranscriptionMode -eq 'cloud') { '.\scripts\cloud_transcription.py' } else { '.\scripts\local_transcription.py' }
    & python $transcriptionScript
    if ($LASTEXITCODE -ne 0) { throw 'Transcription failed.' }

    while ($true) {
        $pending = @(
            Get-ChildItem -LiteralPath (Join-Path $repo 'data\incoming\texts') -File -Filter '*.txt' -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath (Join-Path $repo 'data\incoming\transcripts') -File -Filter '*.txt' -ErrorAction SilentlyContinue
        )
        if ($pending.Count -eq 0) { break }
        & .\scripts\ingest_oldest_incoming.ps1 -RepositoryRoot $repo
        if ($LASTEXITCODE -ne 0) { throw 'Ingestion failed.' }
    }
    if (Test-Path -LiteralPath $incomingRoot) {
        $resolvedIncoming = (Resolve-Path -LiteralPath $incomingRoot).Path
        $expectedIncoming = Join-Path $dataRoot 'incoming'
        if ($resolvedIncoming -ne $expectedIncoming) { throw "Refusing to delete unexpected incoming path: $resolvedIncoming" }
        Remove-Item -LiteralPath $resolvedIncoming -Recurse -Force
        Write-Output 'Removed completed data/incoming queue.'
    }
    Write-Output 'Integrated pipeline complete.'
}
finally { Pop-Location }
