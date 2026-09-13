# Musa’s Gems Knowledge Base

A structured, source-linked knowledge base generated from the Telegram channels [@MusaRAW](https://t.me/MusaRAW) and [@UnchainedReality](https://t.me/UnchainedReality).

- Browse the published knowledge base: https://adityabhandari781.github.io/Musa-KB/
- 25 synthesized topic documents
- Citations linked to the underlying texts and transcripts
- Cross-platform Python pipeline
- Cloud and local transcription modes

## How it works

```text
Telegram
   ↓
Fetch posts and media
   ↓
Transcribe audio/video
   ↓
Normalize and deduplicate sources
   ↓
Segment and classify passages
   ↓
Review uncertain assignments
   ↓
Synthesize 25 topic documents
   ↓
Link citations and validate
   ↓
Publish with MkDocs
```

## Requirements

- Python 3.10 or newer
- Telegram API credentials
- Groq API keys
- Internet access for Telegram, cloud transcription, and LLM processing

Cloud transcription uses Groq Whisper. Local transcription additionally requires `openai-whisper` and `torch`, which remain commented in `requirements.txt`.

## Installation

```bash
git clone https://github.com/adityabhandari781/Musa-KB.git
cd Musa-KB

python -m venv .venv
python -m pip install -r requirements.txt
```

Then copy `.env.example` to `.env` and supply:

```dotenv
TELEGRAM_API_ID=
TELEGRAM_API_HASH=

GROQ_API_KEY=
```

The README should warn users never to commit `.env` or Telegram session files.

## Running the pipeline

```bash
python scripts/run_pipeline.py
```

The pipeline fetches new Telegram material, transcribes media, processes queued sources oldest-first, updates the appropriate KB topic, rebuilds the source appendix, and validates the result.

It should also mention that `data/incoming/` is removed after the entire queue completes successfully.

## Individual commands

A short table would describe the important scripts:

| Script | Purpose |
|---|---|
| `run_pipeline.py` | Run the complete incremental pipeline |
| `fetch.py` | Download new Telegram posts and media |
| `cloud_transcription.py` | Transcribe media through Groq |
| `local_transcription.py` | Transcribe with local Whisper |
| `ingest_oldest_incoming.py` | Process one queued source |
| `inventory_sources.py` | Normalize, hash, and deduplicate the corpus |
| `segment_passages_with_groq.py` | Find semantic passage boundaries |
| `classify_passages.py` | Classify passages into 25 topics |
| `review_topics_with_groq.py` | Review uncertain classifications |
| `build_kb_source_map.py` | Create topic-to-source mappings |
| `synthesize_kb_hierarchical_with_groq.py` | Generate the topic documents |
| `build_all_texts.py` | Build the cited source appendix |
| `inline_kb_citations.py` | Convert source IDs into links |
| `validate_kb.py` | Validate structure, citations, and coverage |

Each command supports `--help`.

## Repository layout

```text
artifacts/                Topic definitions
build/longterm/           Durable source, passage, and mapping manifests
build/useful/             Operational logs and checkpoints
build/useless/            Archived intermediate artifacts
data/texts/               Telegram text posts
data/transcripts/         Media transcripts
data/media/               Archived audio and video
kb/                       Published knowledge-base documents
scripts/                  Cross-platform Python pipeline
scripts/powershell_scripts/
                          Retained legacy PowerShell implementations
```

## Building the documentation

```bash
python -m pip install -r requirements-docs.txt
mkdocs serve
```

Production check:

```bash
mkdocs build --strict
```

## Knowledge-base chat

The chat feature is split into the static MkDocs interface and a small Python API
service. This is required because GitHub Pages cannot keep `GROQ_API_KEY` secret.
The API sends Groq only the user's **current** question and relevant excerpts
retrieved from `kb/*.md`; it stores neither conversation history nor messages.

For local development, use two terminals:

```bash
python scripts/chat_server.py
mkdocs serve
```

Set `window.MUSA_CHAT_API_URL` in `kb/javascripts/chat-config.js` to
`http://127.0.0.1:8001/api/chat` for that setup. For a deployed site, host
`scripts/chat_server.py` on a Python-capable service, set `GROQ_API_KEY` there
(never in GitHub Pages), set `CHAT_ALLOWED_ORIGINS` to the Pages URL, and replace
the same value with the service's public `/api/chat` URL.

The server enforces one request per minute for both the browser-generated client
ID and the requesting IP address. The browser also persists the visible countdown
across reloads. The cooldown is deliberately applied before the LLM call, so failed
requests also protect the API limit. It is in-memory, which is correct for a single
service process; use a shared store such as Redis if deploying multiple instances
or if cooldowns must survive service restarts.

Chat defaults to Groq's `openai/gpt-oss-120b`. On a timeout, provider error, or
invalid/empty response, it retries once with `openai/gpt-oss-20b`. Override either
model with `GROQ_CHAT_MODEL` or `GROQ_CHAT_FALLBACK_MODEL` in the service environment.

GitHub Actions deploys changes under `kb/` to GitHub Pages.

## Resumability and API usage

The README should explain that Groq workflows use JSONL checkpoints and can resume after interruption. It should also warn that full segmentation, review, or synthesis runs can make many paid or rate-limited API requests.

## Content and safety notice

The knowledge base summarizes a creator’s content; it does not independently endorse every claim. Health, scientific, political, financial, relationship, and strongly gendered claims may require additional evidence and context. The material should not be treated as professional advice.

## Contributing

Include expectations such as:

- Keep files UTF-8.
- Preserve stable source IDs.
- Run `python scripts/validate_kb.py` before submitting KB changes.
- Run `mkdocs build --strict` for documentation changes.
- Do not commit credentials, session files, downloaded media, or temporary checkpoints.

One issue should be resolved before documenting a complete rebuild command: some batch scripts currently read and write directly under `build/`, while incremental ingestion uses `build/longterm/` and `build/useful/`. The README should not promise a clean full-rebuild sequence until that artifact-path convention is unified.
