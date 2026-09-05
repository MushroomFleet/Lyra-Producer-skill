# Lyra Producer

A zero-UI PowerShell CLI that turns Gemini **Lyria** "prompt catalogue" markdown
files into full-song `.mp3` audio on disk. No frontend, no database — just
`markdown in → audio out`. This is the CLI layer that the future
`Lyra-Producer.skill` will orchestrate.

## Files

| File | Purpose |
|---|---|
| `Invoke-LyraProducer.ps1` | The CLI. |
| `lyra-config.json` | Your config **with the API key** (git-ignored; copy from the example). |
| `lyra-config.example.json` | Template to copy from. |

## Setup

1. Put your Google Gemini/Lyria API key into `lyra-config.json`:
   ```json
   { "apiKey": "AIza..." }
   ```
   (Or leave it blank and set `$env:GEMINI_API_KEY`, or pass `-ApiKey`.)
2. That's it. Defaults target `lyria-3.5` (full songs) via the Gemini Interactions API,
   `mp3` output. Add `-Clip` for 30-second `lyria-3-clip-preview` previews.

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
are skipped unless you pass `-Force`. With `-Clip`, previews land in a `clips/`
subfolder beside the full songs.

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
| `-Clip` | 30-second preview mode (`lyria-3-clip-preview`), output to `clips/`. |
| `-Model` | Override model id (default `lyria-3.5`; `lyria-3-pro-*` ids use the legacy endpoint). |
| `-Format` | `mp3` (default) or `wav` (Lyria 3.5 only; ignored with `-Clip`; the API currently declines WAV, in which case the CLI warns and delivers mp3). |
| `-ApiKey` | Override the key. |
| `-Instrumental` | Append "Instrumental only, no vocals." if not already present. |
| `-Recurse` | Recurse into subfolders when `-Path` is a folder. |

## Notes

- Generation is **synchronous per track** and strictly sequential. Lyria 3.5 full songs
  are a couple of minutes long and can take several minutes to render; requests wait up
  to `timeoutSeconds` (default 600) and poll if the API answers asynchronously. Clips
  return much faster. Transient failures retry twice with backoff.
- Runs sequentially with a small delay between tracks to stay friendly to rate
  limits. Cost scales with the number of tracks — use `-Index`/`-Limit` while
  testing.
- The native `LyraProducer.exe` is built from a private source tree and is not committed
  here; the script and the exe accept identical flags and print identical output.
