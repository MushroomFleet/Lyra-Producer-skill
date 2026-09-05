# 🎵 Lyra-Producer

**A zero-UI pipeline + Claude Code skill for turning Markdown prompt catalogues into full-song audio
with Google's Gemini Lyria 3.5 music models.**

Lyra-Producer takes plain Markdown files full of music-generation prompts and produces finished `.mp3`
audio on disk — no frontend, no database, no clicking through a UI. You write (or AI-generate) a
catalogue of track prompts in Markdown; Lyra-Producer reads them, calls Lyria 3.5 through the Gemini
Interactions API, and writes numbered audio files straight to a folder.

It ships as three cooperating pieces:

- a **native Windows CLI** (`LyraProducer.exe`, from the [Releases](https://github.com/MushroomFleet/Lyra-Producer-skill/releases/latest)
  page) — a self-contained single file that needs no PowerShell or .NET runtime,
- a **PowerShell CLI** (`Invoke-LyraProducer.ps1`) — the same engine as a readable script, flag-compatible
  with the exe and printing identical output, and
- a **Claude Code skill** (`lyra-producer`) — an orchestration layer that lets Claude read, understand,
  and extract prompts from any Markdown shape and drive either CLI for you in natural language.

---

## Why

Music-generation interfaces are slow to click through when you have dozens of tracks to make.
Lyra-Producer removes the interface entirely: the "UI" is a Markdown file and a one-line command.
Prompts live as text you can version, diff, hand-author, or generate with an LLM; generation is a batch
queue that runs unattended and delivers audio to disk. It was built to produce large, themed collections
— for example an entire "phantom catalogue" of a composer's imaginary works — in a single sitting.

## What it does

- **Markdown → MP3.** Point it at a `.md` file (or a folder of them) and it generates one full song per
  track.
- **Zero UI.** One executable (or one script) plus a small config file. No app, no server, no browser.
- **Full songs, or 30-second clips.** Targets `lyria-3.5` for complete arrangements a couple of minutes
  long, and `lyria-3-clip-preview` (via `-Clip`) for fast previews written to a `clips/` subfolder so you
  can audition prompts before spending on full songs.
- **Optional lyrics, timed structure, and reference images.** If a track carries custom lyrics or a
  timestamped structure, they're detected and folded into the prompt. In manifest mode a track can also
  point at up to ten images for Lyria to draw mood and colour from.
- **Safe, resumable batches.** Strictly sequential generation (never parallel), automatic retries on
  transient failures, skip-existing so interrupted runs resume cleanly, and clear per-track **OK / SKIP /
  FAILED** reporting.
- **Preview before you spend.** A dry-run mode lists exactly what would be generated — track count,
  output filenames, and any detected lyrics / structure / images — without calling the paid API.
- **Honest output.** The file extension always follows the bytes the API actually returned, API error
  messages are surfaced verbatim, and any lyrics or song-structure text the model returns is saved as a
  sidecar beside the audio.

## The three components

### 1. The native CLI — `LyraProducer.exe`

Download it from the [latest release](https://github.com/MushroomFleet/Lyra-Producer-skill/releases/latest)
and drop it next to a `lyra-config.json`. It is a self-contained win-x64 single file; nothing else needs
to be installed. Every release lists the file's SHA256 and the toolchain it was built with. The exe is
built from a private source tree and is not part of this repository.

### 2. The PowerShell CLI — `Invoke-LyraProducer.ps1`

The same engine as a script, for anyone who wants to read or adapt it (`lyra-producer/scripts/`, mirrored
in `CLI/lyra-producer/`). Given a catalogue it:

- parses each track (a heading + a fenced prompt block, plus any optional lyrics / structure),
- slugifies each track title into a safe, numbered filename,
- writes audio into a per-catalogue output subfolder beside the source Markdown,
- calls Lyria 3.5 (or the Clip model) and writes the returned audio to `.mp3` or `.wav`,
- runs the whole set as a sequential queue with retries and skip-existing.

Both CLIs take exactly the same flags and print exactly the same output, so anything written for one
works with the other.

**Two input modes:**

- **Markdown mode** (`-Path`) — the CLI parses uniform catalogues directly (each track = a heading followed
  by a fenced prompt). Fast, no manual work.
- **Manifest mode** (`-Manifest`) — for irregular files a rigid parser can't read reliably, the language
  model reads and extracts each track into a small JSON manifest, and the CLI simply runs inference over
  it. This is the deliberate split at the heart of the design: **the CLI does the inference; the language
  model does the reading and understanding.**

### 3. The Claude Code skill — `lyra-producer`

The orchestration layer. Installed as a Claude Code skill, it lets you just say *"generate the Wagner
tracks"*, *"clip-preview these first"*, or *"run Lyria on this prompt file"*. The skill:

- locates the right catalogue and the CLI (project-local exe or script first, then its bundled copy),
- makes sure an API key is configured,
- **always dry-runs first** and shows you the plan,
- picks markdown vs manifest mode based on the file's shape,
- offers a Clip pass when prompts are new or uncertain,
- confirms scope/cost, then runs the generation and reports results.

It bundles a portable copy of the script plus reference docs — the catalogue format, a lyrics/structure
template, and the manifest schema — so Claude has everything it needs to handle new prompt formats
without guessing.

## Requirements

- **Windows.** The exe runs on its own; the script needs **Windows PowerShell 5.1+** (PowerShell 7 works
  too).
- A **Google Gemini API key** with access to the Lyria 3.5 models (`lyria-3.5`, `lyria-3-clip-preview`).
- *(Optional)* **Claude Code** — only needed for the natural-language skill layer; either CLI works
  standalone.

## Getting started

1. **Pick a CLI.** Download `LyraProducer.exe` from the latest release, or use
   `lyra-producer/scripts/Invoke-LyraProducer.ps1` from this repo. The commands below show the exe;
   for the script, prefix with `& ` and use the `.ps1` path.
2. **Add your API key.** Copy `lyra-config.example.json` to `lyra-config.json` next to the CLI and paste
   your Google API key into the `apiKey` field. The key can also be supplied via `$env:GEMINI_API_KEY`
   or the `-ApiKey` switch.
3. **Preview a catalogue** — no key needed, no cost:
   ```powershell
   .\LyraProducer.exe -Path .\my-prompts.md -DryRun
   ```
   Confirm the track count and filenames look right.
4. **Audition with clips (optional):**
   ```powershell
   .\LyraProducer.exe -Path .\my-prompts.md -Clip -Index 1
   ```
   A 30-second preview of track 1 lands in `clips/` beside where the full songs will go.
5. **Generate:**
   ```powershell
   .\LyraProducer.exe -Path .\my-prompts.md
   ```
   Or point `-Path` at a whole folder of catalogues, or generate a single track with `-Index N`.
6. **(Optional) Install the skill** by placing the `lyra-producer` skill directory in your user Claude
   Code skills folder (`~/.claude/skills/`), and the exe in its `scripts/` subfolder. Then simply ask
   Claude to generate the tracks.

### Flags

| Flag | Meaning |
|---|---|
| `-Path` | Markdown mode: a `.md` file, or a folder of `.md` files. |
| `-Manifest` | Manifest mode: a JSON of already-extracted tracks (see `lyra-producer/references/manifest-schema.md`). |
| `-DryRun` | List what would be generated; no API call, no key. |
| `-Clip` | 30-second `lyria-3-clip-preview` previews, written to `clips/`. |
| `-Index N` / `-Limit N` | Generate only track N / at most N tracks. |
| `-Force` | Overwrite audio that already exists. |
| `-Model` | Override the model id (default `lyria-3.5`; `lyria-3-pro-*` ids use the legacy endpoint). |
| `-Format` | `mp3` (default) or `wav`. |
| `-Instrumental` | Append "Instrumental only, no vocals." to prompts that don't already say so. |
| `-ApiKey` / `-ConfigPath` | Supply the key inline / use a specific config file. |
| `-Recurse` | Recurse into subfolders when `-Path` is a folder. |

## The prompt catalogue format

A catalogue is ordinary Markdown. In the simplest form, each track is a level-3 heading followed by a
fenced code block holding the music prompt:

````markdown
### A Gentle Morning Waltz
> optional one-line description

```
A warm, unhurried solo-piano waltz, gentle rubato, intimate close-miked felt piano. Instrumental only,
no vocals.
```
````

- The heading becomes the output filename (slugified and numbered by position).
- Text that isn't a track — intro notes, "how this works" sections, author-your-own templates — is
  ignored.
- **Lyrics** and a **timed structure** are optional and per-track. Add them under the track (labelled
  `**Lyrics**` / `**Timed structure**`, or via `[Verse]`/`[Chorus]` tags and `[0:00]` timestamps) and
  they're detected automatically and appended to the prompt. Most instrumental catalogues have neither.
- Irregular formats (different headers, prose prompts, plain-text lyrics, varying order) are handled
  through **manifest mode**, where the reading is done by the language model rather than a fixed parser.
  Manifest tracks may also list `images` (up to ten local files) for Lyria to take mood from.
- Lyria sings by default. A track meant to be instrumental must say so in its prompt (or the run must
  pass `-Instrumental`); leaving lyrics out does not make a track instrumental.

## Output

For each catalogue, audio is written into its own subfolder next to the source Markdown, named from the
first four words of the catalogue's filename. Files are named by catalogue position plus a slug of the
track title — e.g. `01-a-gentle-morning-waltz.mp3`, `02-…` — so they sort in order and never collide.
Clip previews go one level deeper, into `clips/`, so they never collide with full songs. When the model
returns lyrics, they are saved as `NN-slug.txt`; when it returns a JSON song structure, that goes to
`NN-slug.structure.json`. Sidecars never block regeneration; only existing audio does.

## Configuration

`lyra-config.json` sits beside the CLI. Every key is optional; the example config carries the defaults.

| Key | Default | Meaning |
|---|---|---|
| `apiKey` | `""` | Falls back to `-ApiKey`, then `$env:GEMINI_API_KEY`, then `$env:LYRIA_API_KEY`. |
| `model` / `clipModel` | `lyria-3.5` / `lyria-3-clip-preview` | Full-song model, and the model `-Clip` uses. |
| `apiMode` | `auto` | Route by model id, or force `interactions` / `generateContent`. |
| `endpointBase` | Gemini `v1beta` root | Older configs ending in `/models` still work. |
| `outputFormat` | `mp3` | `mp3` or `wav`. |
| `timeoutSeconds` / `pollIntervalSeconds` | `600` / `5` | Per-request timeout, and poll cadence if the API answers asynchronously. |
| `instrumentalByDefault` | `false` | Same as passing `-Instrumental` every run. |
| `defaultDurationHint` | `""` | Sentence appended to prompts that say nothing about length (never in Clip mode). |
| `clipSubfolder` | `clips` | Where `-Clip` output goes. |
| `delayBetweenTracksSeconds` / `maxRetries` | `2` / `2` | Pause between tracks; retries per track. |
| `saveLyricsSidecar` | `true` | Write the `.txt` / `.structure.json` sidecars. |
| `slugMaxLength` | `80` | Filename slug cap. |

## Notes & tips

- **Preview with Clip first.** `-Clip` renders 30-second previews into `clips/` for a fraction of the
  cost of full songs. Iterate on prompts there, then run the full set.
- **Sequential by design.** Tracks generate one at a time to stay friendly to rate limits and cost. Use
  `-Index` / `-Limit` while testing.
- **Resumable.** Re-running skips anything already on disk, so an interrupted batch just picks up where
  it left off.
- **Retries.** Transient errors (server hiccups, policy blocks, empty responses) are retried
  automatically; a polling timeout is not, because the server may still finish the job.
- **WAV today.** `-Format wav` sends the correct request, but the API currently declines WAV for
  `lyria-3.5`; the CLI says so and delivers mp3 instead of failing. It will start returning `.wav` the day
  Google enables it, with no update needed.
- **Content policy.** Lyria refuses prompts that ask it to imitate a *named* artist ("in the style of
  [artist]") or reproduce copyrighted lyrics. Describe the era or genre instead (e.g. "late-Romantic",
  "impressionist") to stay clear of the filter.
- **Big files, small repos.** Generated audio is large — keep it out of Git and back it up separately.

## Repository layout

| Path | What it is |
|---|---|
| `lyra-producer/` | The Claude Code skill: `SKILL.md`, `references/`, and `scripts/` (the script and the example config). Copy this folder into `~/.claude/skills/`. |
| `CLI/lyra-producer/` | The standalone CLI folder: the same script, its README, and the example config, for use without the skill. |
| `Features.md` | Code-free manifest of every feature and the stack, for readers without source access. |

## Changelog

### 2.0.0
- Lyria 3.5 (`lyria-3.5`) is the default model, served by the Gemini Interactions API.
- `-Clip` renders 30-second `lyria-3-clip-preview` previews into a `clips/` subfolder.
- Manifest tracks may carry up to 10 reference `images`.
- `defaultDurationHint` config appends a length instruction to prompts that lack one.
- `lyria-3-pro-*` model ids still work through the legacy endpoint (automatic routing).
- Extension is chosen from the returned bytes; JSON structure blocks are saved as
  `NN-slug.structure.json`; sidecars no longer block regeneration.
- `-Format wav` sends the correct `response_format` request; while the API declines WAV for
  `lyria-3.5`, the CLI warns and delivers mp3 instead of failing.
- API error messages are surfaced verbatim; default timeout raised to 600 s with polling for
  asynchronous responses.
- Native `LyraProducer.exe` published on the Releases page with a SHA256 checksum.

## License

Released under the MIT License. See `LICENSE` for details.

---

## 📚 Citation

### Academic Citation

If you use this codebase in your research or project, please cite:

```bibtex
@software{lyra_producer_2026,
  title = {Lyra-Producer: a zero-UI pipeline and Claude skill for Gemini Lyria music generation},
  author = {Drift Johnson},
  year = {2026},
  url = {https://github.com/MushroomFleet/Lyra-Producer-skill},
  version = {2.0.0}
}
```
