# Lyra Producer

A zero-UI PowerShell CLI that turns Gemini **Lyria** "prompt catalogue" markdown
files into full-song `.mp3` audio on disk. No frontend, no database — just
`markdown in → audio out`. This is the CLI layer that the future
`Lyra-Producer.skill` will orchestrate.

## Files

| File | Purpose |
|---|---|
| `Invoke-LyraProducer.ps1` | The CLI. |
| `lyra-config.json` | Your config **with the API key** (git-ignored). |
| `lyra-config.example.json` | Template to copy from. |

## Setup

1. Put your Google Gemini/Lyria API key into `lyra-config.json`:
   ```json
   { "apiKey": "AIza..." }
   ```
   (Or leave it blank and set `$env:GEMINI_API_KEY`, or pass `-ApiKey`.)
2. That's it. Defaults target `lyria-3-pro-preview` (full songs), `mp3` output.

## How it reads a markdown file

- A **track** = a level-3 heading (`### ...`) followed by a fenced ` ``` ` code
  block (the prompt). The heading becomes the filename; the blockquote tagline
  under it is informational only.
- Code blocks **not** under a `###` heading are ignored — so the
  "How this catalogue works" notes and the "Author your own" prompt-skeleton /
  naming-grammar templates are never treated as tracks.
- If a track heading has **extra** code blocks, they're auto-classified:
  blocks with `[Verse]` / `[Chorus]` tags → **lyrics**, blocks with `[0:00 ...]`
  timestamps → **timed structure**. Both are appended to the prompt when found.
  (The example catalogues are pure-instrumental, so nothing extra is detected.)

## Output layout

For `composers/wagner-preludes-that-never-were-lyria-prompts.md`, audio is
written next to it, in a subfolder named from the **first 4 filename words**:

```
composers/
  wagner-preludes-that-never-were-lyria-prompts.md
  wagner-preludes-that-never/           <- first 4 words of the filename
    01-vorspiel-zu-die-nebelkonigin-wwv-2204.mp3
    02-vorspiel-zu-der-runenritter-wwv-3517.mp3
    ...
```

Filenames are `NN-<slugified-heading>.mp3` where `NN` is the track's 1-based
position in the catalogue (stable regardless of `-Index`/`-Limit`). Slugs are
lowercase, hyphen-separated, ASCII-folded (`ö → o`, `ß → ss`). Existing files
are skipped unless you pass `-Force`.

## Usage

Dry run (parse + list, no API call, no key needed) — always do this first:

```powershell
.\Invoke-LyraProducer.ps1 -Path ..\composers\wagner-preludes-that-never-were-lyria-prompts.md -DryRun
```

Generate just the first track (proof run):

```powershell
.\Invoke-LyraProducer.ps1 -Path ..\composers\wagner-preludes-that-never-were-lyria-prompts.md -Index 1
```

Generate a whole file:

```powershell
.\Invoke-LyraProducer.ps1 -Path ..\composers\wagner-preludes-that-never-were-lyria-prompts.md
```

Generate every `.md` in a folder:

```powershell
.\Invoke-LyraProducer.ps1 -Path ..\composers
```

### Parameters

| Param | Meaning |
|---|---|
| `-Path` | A `.md` file, or a folder of `.md` files. |
| `-DryRun` | List what would be generated; no API call. |
| `-Index N` | Generate only track N (1-based). |
| `-Limit N` | Generate at most N tracks (after `-Index`). |
| `-Force` | Overwrite existing audio files. |
| `-Model` | Override model id (default `lyria-3-pro-preview`). |
| `-Format` | `mp3` (default) or `wav` (Pro only). |
| `-ApiKey` | Override the key. |
| `-Instrumental` | Append "Instrumental only, no vocals." if not already present. |
| `-Recurse` | Recurse into subfolders when `-Path` is a folder. |

## Notes

- Generation is **synchronous** per track (matches the proven Stage 12 plan);
  Pro full songs typically take ~30–120s. Requests use a 5-minute timeout and
  retry twice on transient failures.
- Runs sequentially with a small delay between tracks to stay friendly to rate
  limits. Cost scales with the number of tracks — use `-Index`/`-Limit` while
  testing.
