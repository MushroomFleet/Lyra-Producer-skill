---
name: lyra-producer
description: This skill should be used when the user wants to generate music audio (.mp3) from a Lyria "prompt catalogue" markdown file — e.g. "generate the Wagner tracks", "produce the mp3s from chopin-nocturnes-that-never-were-lyria-prompts.md", "run Lyria on the composers folder", "make the audio for this prompt file" — or from ANY markdown file or folder holding labelled music-track prompts ("turn these track prompts into actual music files", "batch this folder of catalogues into mp3s overnight"). Also use it to regenerate or re-run specific tracks ("regenerate 04-storm-choral.mp3", "track 3 got safety-filtered, run it again") and for catalogue files the rigid parser can't read (## Track headers, prose prompts), where Claude extracts a manifest JSON before generating. Mentions of "Lyra Producer", Gemini Lyria music generation, or any *-lyria-prompts.md file always trigger it. It detects each track's prompt (plus optional lyrics and timed structure), previews the extraction with a dry-run, and orchestrates the LyraProducer CLI (native LyraProducer.exe, or the Invoke-LyraProducer.ps1 PowerShell fallback) to deliver full-song audio straight to disk.
---

# Lyra Producer

Turn a Lyria "prompt catalogue" markdown file into full-song `.mp3` audio on disk.
This skill is the orchestration layer over the LyraProducer CLI — a zero-UI tool
that parses a catalogue, extracts each track's prompt (plus any lyrics / timed
structure it finds), calls the Gemini Lyria model, and writes numbered audio files
into a per-file output subfolder next to the markdown. The CLI ships as two
functionally-identical, flag-compatible implementations: a native `LyraProducer.exe`
(preferred — no PowerShell or .NET runtime required to run it) and the original
`Invoke-LyraProducer.ps1` PowerShell script (used as a fallback when no exe is
present). Both were built from, and proven against, the same specification, so this
skill's instructions apply identically to either.

Generation calls a paid API and each full song takes ~30-120s, so the guiding
principle is **preview before you spend**: always dry-run and confirm scope before
generating.

## Prerequisites

- The CLI itself: `LyraProducer.exe` needs nothing else installed (self-contained,
  no PowerShell or .NET runtime required). Only the `.ps1` fallback needs Windows
  PowerShell 5.1+ (`powershell.exe`) to run. Prefer a project-local copy of either;
  a bundled copy of both ships with this skill.
- A Google Gemini/Lyria API key with access to the Lyria model.

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
  varies per track. This is the zero-UI design point — the CLI (exe or script,
  either one) does the inference; Claude does the reading and extraction. Schema +
  example: `references/manifest-schema.md`.

A dry-run decides which (step 4): preview `-Path` first; if it reads the file
correctly, stay in markdown mode; otherwise extract a manifest.

## Workflow

### 1. Identify the target markdown file(s)

Determine which catalogue the user means. If they named a file or composer, resolve
it. If they were vague ("generate the tracks"), glob the working project for
`*lyria-prompts.md` (or `*.md` in a `composers/`-style folder) and confirm which
one — or whether they want a whole folder processed at once.

### 2. Locate the CLI

Prefer, in order: (1) the project's own compiled `LyraProducer.exe` (commonly
`./lyra-producer/LyraProducer.exe`) -- a native executable, no PowerShell needed;
(2) the project's own `Invoke-LyraProducer.ps1` (commonly
`./lyra-producer/Invoke-LyraProducer.ps1`); (3) this skill's bundled copy, again
preferring `scripts/LyraProducer.exe` over `scripts/Invoke-LyraProducer.ps1` if
both are present. Whichever is found, the invocation flags are identical (`-Path`,
`-DryRun`, `-Index`, etc.) -- only the executable/interpreter prefix changes:

```powershell
# PowerShell script:
& <ps1-path> -Path <markdown-path> -DryRun

# Native exe (no call operator needed, no PowerShell required):
<exe-path> -Path <markdown-path> -DryRun
```

### 3. Ensure an API key is configured

The CLI reads its key from, in order: `-ApiKey`, then `apiKey` in the
`lyra-config.json` beside the executable (or script), then `$env:GEMINI_API_KEY`,
then `$env:LYRIA_API_KEY`. A dry-run needs no key; generating does.

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

## Instrumental output must be asked for in the prompt

Per [Google's Lyria docs](https://ai.google.dev/gemini-api/docs/generate-content/music-generation),
the model **generates vocals and its own lyrics by default when the prompt doesn't
specify otherwise**. On the `:generateContent` surface this CLI uses there is no
instrumental flag, no `negative_prompt` and no lyrics field — vocal behaviour is
controlled entirely by the prompt text. The documented phrasing for an instrumental is:

> `Instrumental only, no vocals.`

**Omitting the `lyrics` field does not request an instrumental** — it only means no
lyric text is appended. So when a track has no lyrics and the music is meant to be
instrumental, say so:

- **Whole set instrumental** → pass `-Instrumental`; the CLI appends exactly that
  sentence to any prompt not already containing "instrumental".
- **Mixed set** → don't use the flag (it appends regardless of whether lyrics exist).
  Put the sentence in the `prompt` text of the instrumental tracks instead.

Note that `-DryRun` shows the *base* prompt's character count, not the text finally
posted — it confirms track count, boundaries and filenames, not prompt content.

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
| `-Instrumental` | Append "Instrumental only, no vocals." when not already present. Backup, not a cure — it does not remove vocal requests already in the prompt, and it is appended even when lyrics exist. |
| `-Recurse` | Recurse into subfolders when `-Path` is a folder. |

## Troubleshooting

- **Unwanted singing on tracks meant to be instrumental:** the prompt never asked for
  an instrumental, so the model supplied vocals and wrote its own lyrics — its
  documented default. Add `Instrumental only, no vocals.` (or pass `-Instrumental`) and
  regenerate with `-Force`. `-DryRun` cannot reveal this, as it does not show the
  posted prompt text.
- **No audio / "No candidates" / finishReason error:** the prompt may have been
  safety-filtered, or the model returned a long-running operation instead of inline
  audio. The exact API message is surfaced — read it. Inline-audio is the proven
  path; if a model starts returning an operation handle, both implementations would
  need a polling branch added (see `references/catalogue-format.md`).
- **Auth errors:** confirm the key is present and has Lyria access; re-check which
  config the CLI is reading (project vs bundled).
- **TLS / connection errors when running the `.ps1` fallback on PowerShell 5.1:**
  the script forces TLS 1.2 at start; a failure here usually means a proxy or
  network issue, not the script. This does not apply to `LyraProducer.exe`, which
  negotiates TLS automatically via .NET and has no equivalent failure mode.

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

## Bundled tools

- **`scripts/LyraProducer.exe`** — the portable, self-contained native CLI, used
  when a project has no local copy of either implementation. Preferred over the
  `.ps1` below when both are present (see step 2).
- **`scripts/Invoke-LyraProducer.ps1`** — the portable PowerShell fallback, used
  only when no exe is available (project-local or bundled).
- **`scripts/lyra-config.example.json`** — the config template (copy to
  `lyra-config.json` and add the key); the same schema works for both
  implementations.
