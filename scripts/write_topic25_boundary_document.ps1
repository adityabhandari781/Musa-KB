[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$rows = @(Get-Content -LiteralPath (Join-Path $repo 'build\kb-source-map.jsonl') -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { [int]$_.topic_id -eq 25 -and $_.assignment_role -eq 'primary' })
if ($rows.Count -eq 0) { throw 'Topic 25 has no primary source-map rows.' }
$topic = $rows[0]; $sourceCount = @($rows | Select-Object -ExpandProperty source_id -Unique).Count
$examples = @($rows | Select-Object -ExpandProperty source_id -Unique | Sort-Object | Select-Object -First 4)
$sources = @{}
foreach ($row in $rows) { $sources[$row.source_id] = $row.relative_path }
$sourceList = (($sources.Keys | Sort-Object | ForEach-Object { "- [$_](../$(([string]$sources[$_]).Replace('\\','/')))" }) -join "`n")
$citations = ($examples | ForEach-Object { "[$_]" }) -join ''
$body = @"
## Overview

This document records the material intentionally excluded from the substantive knowledge base: promotions, engagement requests, banter, low-context media, and topical commentary that does not contain a self-contained lesson. It remains traceable to the source corpus, but is not presented as practical, scientific, financial, or relationship guidance. $citations

## Core ideas

- The category preserves source traceability without promoting short, context-dependent, or engagement-driven material into a general principle.
- It separates announcements, giveaways, jokes, reactions, and incomplete media from passages whose substantive lesson belongs in one of Topics 1–24.
- A topical reference may be useful only when its broader lesson is explicit; otherwise it remains here as contextual material.

## Principles and mental models

- **Traceability without endorsement:** retention in the KB does not imply that a claim is supported, advisable, or representative of a broader framework.
- **Context threshold:** a passage needs enough self-contained reasoning to support a topic document; a slogan, title, or reaction clip generally does not meet that threshold.
- **Boundary-first routing:** where a clear lesson exists, it belongs with that lesson's substantive topic rather than being retained here merely because its delivery is humorous or provocative.

## Recommended practices

There are no recommended practices in this category. Treat these entries as source records and review the original material before relying on any claim or anecdote.

## Examples and stories

Representative entries include engagement-led posts, short promotional messages, low-context references, and commentary without sufficient supporting explanation. $citations

## Tensions and contradictions

Some source items mix commentary with a possible lesson. The source map assigns a passage to a substantive topic when the lesson is clear enough to stand alone; Topic 25 remains a safeguard against turning rhetorical style, publicity, or fragmented context into advice.

## Caveats

This category may contain unverified medical, political, financial, interpersonal, or strongly gendered claims. None should be treated as established fact or followed literally without appropriate independent evidence and context. The category is descriptive of corpus handling, not an endorsement of the creator's rhetoric.
"@
$header = "---`ntopic_id: 25`ntitle: Non-substantive material`nstatus: synthesized`nsource_count: $sourceCount`nsource_scope:`n  - data/texts`n  - data/transcripts`n---`n`n# Non-substantive material`n`n"
$path = Join-Path $repo 'kb\25-non-substantive-material.md'
[System.IO.File]::WriteAllText($path, $header + $body.Trim() + "`n`n## Sources`n`n" + $sourceList + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Output "Wrote Topic 25 boundary document with $sourceCount source links."
