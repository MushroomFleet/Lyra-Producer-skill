---
name: lyra-producer
description: This skill should be used when the user wants to generate music audio (.mp3) from a Lyria "prompt catalogue" markdown file — e.g. "generate the Wagner tracks", "produce the mp3s from chopin-nocturnes-that-never-were-lyria-prompts.md", "run Lyria on the composers folder", "make the audio for this prompt file", or when they mention "Lyra Producer", Gemini Lyria music generation, or any *-lyria-prompts.md file. It detects each track's prompt (and any custom lyrics or timed structure), previews the extraction, and orchestrates the Invoke-LyraProducer.ps1 PowerShell CLI to generate full-song audio straight to disk. Use it whenever a markdown file holds labelled music-generation prompts and the user wants the actual audio produced, even if they don't name the tool explicitly.
---

# Lyra Producer

Turn a Lyria "prompt catalogue" markdown file into full-song `.mp3` audio on disk.
This skill is the orchestration layer over `Invoke-LyraProducer.ps1` — a zero-UI
PowerShell CLI that parses a catalogue, extracts each track's prompt (plus any
lyrics / timed structure it finds), calls the Gemini Lyria model, and writes
numbered audio files into a per-file output subfolder next to the markdown.

Generation calls a paid API and each full song takes ~30-120s, so the guiding
principle is **preview before you spend**: always dry-run and confirm scope before
generating.

## Prerequisites

- Windows PowerShell 5.1+ (`powershell.exe`) — the CLI is written for it.
- A Google Gemini/Lyria API key with access to the Lyria model.
- The CLI itself. Prefer a project-local copy; a bundled copy ships with this skill.

## Two input modes: markdown vs manifest

The CLI accepts tracks two ways — choose by the file's shape:

- **Markdown mode (`-Path`)** — the CLI parses the file itself. Use it for *uniform*
  catalogues where each track is a `###` heading followed by a fenced prompt (the
  composer sets, the `example-with-lyrics.md` template). Fast, no manual extraction.
- **Manifest mode (`-Manifest`)** — **Claude reads, understands, and extracts** each
  track (title, prompt, lyrics, structure) into a small JSON, and the CLI just runs
  inference over it. Use it for any file the markdown parser can't reliably read:
  `## Track N` headers instead of `###`, the prompt written as prose after a
  `**Paste-ready prompt:**` label, plain-text lyrics/structure, or an order that
  varies per track. This is the zero-UI design point — PowerShell does the inference;
  Claude does the reading and extraction. Schema + example:
  `references/manifest-schema.md`.

A dry-run decides which (step 4): preview `-Path` first; if it reads the file
correctly, stay in markdown mode; otherwise extract a manifest.

## Workflow

### 1. Identify the target markdown file(s)

Determine which catalogue the user means. If they named a file or composer, resolve
it. If they were vague ("generate the tracks"), glob the working project for
`*lyria-prompts.md` (or `*.md` in a `composers/`-style folder) and confirm which
one — or whether they want a whole folder processed at once.

### 2. Locate the CLI

Prefer the project's own copy so it uses the config/key that already lives beside
it. Search the working tree for `Invoke-LyraProducer.ps1` (commonly
`./lyra-producer/Invoke-LyraProducer.ps1`). If none exists in the project, fall
back to this skill's bundled copy at `scripts/Invoke-LyraProducer.ps1`.

### 3. Ensure an API key is configured

The CLI reads its key from, in order: `-ApiKey`, then `apiKey` in the
`lyra-config.json` beside the script, then `$env:GEMINI_API_KEY`, then
`$env:LYRIA_API_KEY`. A dry-run needs no key; generating does.

Before generating, confirm a key is available. If the project CLI's
`lyra-config.json` has a non-empty `apiKey`, use it. If using the bundled CLI (whose
config has no key), pass `-ConfigPath` pointing at the project config, or `-ApiKey`,
or rely on the env var — and if none is set, ask the user to add their key to
`lyra-config.json` rather than guessing.

### 4. Dry-run, and choose the input mode (always)

Preview the markdown parser first — no API call, no key needed:

```powershell
& <cli-path> -Path <markdown-path> -DryRun
```

Review the track count, numbered filenames, and any `[+lyrics]` / `[+structure]`
tags with the user. If it all looks right — count matches the real tracks, no
template blocks leaked in (see `references/catalogue-format.md`), and each prompt is
the actual prompt — stay in **markdown mode**.

If it looks wrong — the file uses `## Track` headers, prose prompts, prose lyrics,
sub-headings being treated as tracks, or the count is off — switch to **manifest
mode**. Read the file, extract each track's title / prompt / lyrics / structure
yourself, write a manifest JSON (schema in `references/manifest-schema.md`; a
scratchpad path is fine), and dry-run that instead:

```powershell
& <cli-path> -Manifest <manifest-path> -DryRun
```

Confirm the manifest dry-run shows the right tracks before generating. This is where
Claude's reading does the work the rigid parser cannot.

### 5. Confirm scope before generating

Generation is metered. Agree with the user on how much to produce:

- One track (proof / spot-check): `-Index N`
- First few: `-Limit N`
- A whole file: no selection flags
- A whole folder: point `-Path` at the folder

State the rough cost/time (tracks × ~30-120s) so the user opts in deliberately.

### 6. Generate and report

Drop `-DryRun` from whichever mode you settled on:

```powershell
& <cli-path> -Path <markdown-path>      [-Index N | -Limit N]   # markdown mode
& <cli-path> -Manifest <manifest-path>  [-Index N | -Limit N]   # manifest mode
```

Both modes share the same engine: sequential, skips files already on disk (unless
`-Force`), retries transient failures, and prints per-track OK/SKIP/FAILED plus a
summary. `-Index` / `-Limit` select a subset in either mode. Report the output folder
and the files produced, and surface any failures verbatim rather than smoothing over
them.

## Lyrics & timed structure are optional, per-track

The `###` header is the track boundary, so a track carries lyrics or a timed
structure only if they are written under its heading — most tracks (all the composer
sets) have neither and send just the prompt. Nothing is invented for a track that
doesn't have them. When present, the CLI picks them up by label (`**Lyrics**`,
`**Timed structure**`, `#### Lyrics`, `Lyrics:`) or by content (`[Verse]`/`[Chorus]`
tags → lyrics, `[0:00]` timestamps → structure), and appends them to the prompt. The
dry-run tags such tracks `[+lyrics]` / `[+structure]`, so a glance at the preview
confirms detection before generating.

If a file clearly intends lyrics/structure but the dry-run doesn't tag them, the
layout is ambiguous — don't silently drop them. Read the file, confirm intent with
the user, and normalise to the labelled convention (see the
`references/example-with-lyrics.md` template), then re-run the dry-run.

## Command reference

| Flag | Meaning |
|---|---|
| `-Path` | Markdown mode: a `.md` file, or a folder of `.md` files (CLI parses it). |
| `-Manifest` | Manifest mode: a Claude-extracted JSON of tracks (CLI just infers). |
| `-DryRun` | Preview extraction; no API call, no key. |
| `-Index N` | Generate only track N (1-based catalogue position). |
| `-Limit N` | Generate at most N tracks (applied after `-Index`). |
| `-Force` | Overwrite audio that already exists. |
| `-Model` | Override model id (default `lyria-3-pro-preview`). |
| `-Format` | `mp3` (default) or `wav` (Pro model only). |
| `-ApiKey` | Provide the key inline. |
| `-ConfigPath` | Use a specific `lyra-config.json` (e.g. the project's). |
| `-Instrumental` | Append "Instrumental only, no vocals." when not already present. |
| `-Recurse` | Recurse into subfolders when `-Path` is a folder. |

## Troubleshooting

- **No audio / "No candidates" / finishReason error:** the prompt may have been
  safety-filtered, or the model returned a long-running operation instead of inline
  audio. The exact API message is surfaced — read it. Inline-audio is the proven
  path; if a model starts returning an operation handle, the script needs a polling
  branch (see `references/catalogue-format.md`).
- **Auth errors:** confirm the key is present and has Lyria access; re-check which
  config the CLI is reading (project vs bundled).
- **TLS / connection errors on PowerShell 5.1:** the script forces TLS 1.2 at start;
  a failure here usually means a proxy or network issue, not the script.

## Reference files

- **`references/catalogue-format.md`** — the markdown catalogue format, the exact
  extraction/slug/output rules, and how lyrics/structure detection works. Read it
  when a file's structure is unusual or a dry-run count is surprising.
- **`references/example-with-lyrics.md`** — a 3-track template showing an
  instrumental track, a labelled fenced lyrics + timed-structure track, and a
  plain-text `#### Lyrics` track. Copy its layout when a catalogue needs words.
- **`references/manifest-schema.md`** — the JSON schema + worked example for
  manifest mode (Claude-extracted input). Read it before writing a manifest for a
  file the markdown parser can't read.

## Bundled script

- **`scripts/Invoke-LyraProducer.ps1`** — the portable copy of the CLI, used when a
  project has no local copy. **`scripts/lyra-config.example.json`** — the config
  template (copy to `lyra-config.json` and add the key).
