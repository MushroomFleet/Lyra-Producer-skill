---
artifact: Features.md
standard_version: 1.0
project: Lyra-Producer
project_version: 2.0.0
last_curated: 2026-09-05
curation_trigger: scan
source_of_truth: true
contains_code: false
---

> This file is the public source of truth for Lyra-Producer. It is deliberately code-free and
> redacted: it states what the system does, not how. The absence of internal detail here does not
> imply the absence of a capability.

## 1. System Summary

Lyra-Producer turns Markdown "prompt catalogues" — plain text files in which each track is a heading
followed by a music-generation prompt — into finished full-song audio files on disk, using Google's
Lyria 3.5 music models through the Gemini API. It is a zero-UI batch tool: there is no app, server, or
browser, only a command-line engine, a small configuration file, and an optional Claude Code skill that
lets a person drive the engine in natural language. Its guiding rule is *preview before you spend*:
every run can be rehearsed for free, cheap 30-second clip previews can be made before full songs, and
generation is strictly sequential, resumable, and honest about what it produced.

## 2. Stack Profile

- **Engine, two interchangeable implementations:** a native, self-contained Windows command-line
  executable built from a typed, compiled, managed-runtime language (no runtime installation needed on
  the target machine), and a readable script implementation for the Windows shell scripting environment.
  Both accept identical flags and print identical output; either can be used alone.
- **Orchestration layer:** a Claude Code skill — Markdown instructions plus bundled reference documents
  and a portable copy of the script engine — that a language-model assistant follows to plan and run
  generations conversationally.
- **Generative backend:** a hosted music-generation service (Google Gemini API, Lyria 3.5 model family)
  reached over HTTPS with JSON request and response bodies. Two model tiers are used: a full-song model
  and a 30-second clip model. An older model tier remains reachable through a legacy endpoint.
- **Datastore:** none. Inputs are Markdown or JSON files; outputs are audio and text files written
  beside the inputs. Settings live in one JSON file beside the engine.
- **Platform:** Windows. The executable runs on its own; the script needs the Windows shell scripting
  environment present on all current Windows releases.
- **Distribution:** the script, the skill, and the documentation are published in a public source
  repository; the executable is published as a release artifact with a checksum and is built from a
  private source tree.

## 3. Feature Manifest

### Catalogue input (Markdown mode)

- **Heading-anchored track extraction** — treats each level-3 heading followed by a fenced code block as
  one track; the heading is the title, the block is the prompt. `stable`
- **Template-block exclusion** — ignores fenced blocks that are not under a track heading (intro notes,
  "how this works" sections, author-your-own templates), and ends a track at the next level-1 or
  level-2 heading so trailing templates are never mis-attributed. `stable`
- **Informational taglines** — captures a blockquote line under a heading as a description that is shown
  but never sent to the model. `stable`
- **Optional per-track lyrics and timed structure** — detects extra material under a track two ways: by
  label (bold or plain "Lyrics" / "Timed structure" labels, or a level-4 sub-heading) or by content
  (song-section tags such as verse/chorus mark lyrics; timestamp rows mark a structure). Both fenced
  and plain-text forms are accepted. Nothing is invented for tracks that lack them. `stable`
- **Single-file, folder, and recursive input** — accepts one Markdown file, every Markdown file in a
  folder, or every Markdown file in a folder tree. `stable`

### Catalogue input (Manifest mode)

- **Pre-extracted manifest input** — accepts a small JSON file of already-extracted tracks (title,
  prompt, optional lyrics, optional structure) so that a language model can do the reading for
  catalogues whose layout the fixed parser cannot handle; the engine then only generates. `stable`
- **Reference images per track** — a manifest track may name up to ten local image files that the
  full-song model uses for mood and colour. Files, types, and count are validated before any request is
  made. `stable`
- **Output-folder control** — a manifest may name an explicit output folder, or the engine derives one
  from the source catalogue exactly as in Markdown mode. `stable`
- **Fail-before-spend validation** — a missing prompt, a missing image, an unsupported image type, or
  too many images is a hard error raised before any paid call. `stable`

### Prompt assembly

- **Composite prompt** — sends the track prompt followed by its lyrics and its timed structure as one
  request text. `stable`
- **Instrumental clause** — on request (a flag or a config default), appends the model's documented
  "instrumental only" phrasing to any prompt that does not already mention "instrumental". `stable`
- **Default duration hint** — an optional configured sentence (for example a target length) appended to
  any prompt that says nothing about its own length; never applied to clip previews. `stable`

### Generation

- **Full-song generation** — produces complete arrangements a couple of minutes long, with verses,
  choruses, and bridges, whose length can be steered from the prompt. `stable`
- **30-second clip previews** — a single flag switches to the clip model and writes previews into a
  dedicated subfolder so prompts can be auditioned cheaply before a full run. `stable`
- **Automatic model routing** — chooses the modern endpoint or the legacy endpoint from the model
  identifier, so older model identifiers and older configuration files keep working; a config setting
  can force either route. `stable`
- **Asynchronous-response polling** — if the service answers with a job still in progress, the engine
  polls until it settles or a deadline passes, reporting progress as it waits. `stable`
- **Retries with backoff** — transient failures, policy blocks, and empty responses are retried a
  configurable number of times with increasing pauses; a polling deadline is deliberately not retried
  because the service may still complete the job. `stable`
- **WAV request with graceful fallback** — a WAV output can be requested; if the service declines WAV
  for the model, the engine says so and delivers MP3 for that track instead of failing. `stable`
- **Strictly sequential queue** — one track at a time, with a configurable pause between tracks; never
  parallel. `stable`

### Output files

- **Per-catalogue output folder** — audio is written into a subfolder beside the source Markdown, named
  from the first four words of the catalogue's filename. `stable`
- **Numbered, slugified filenames** — each file is the track's catalogue position plus a lower-case,
  hyphenated, accent-folded slug of its title, so files sort in order and never collide; numbering is
  stable even when only a subset is generated. `stable`
- **Clips subfolder** — previews live one level below the full songs so the two never share a
  filename. `stable`
- **Extension follows the bytes** — the saved extension is decided from the audio actually returned, so
  a file is never mislabelled regardless of what was requested. `stable`
- **Lyrics sidecar** — when the model returns sung lyrics, they are saved as a text file beside the
  audio; the model's bare section markers for instrumental tracks are recognised and not saved. `stable`
- **Structure sidecar** — when the model returns a JSON description of the song's structure, it is
  saved as a separate JSON file beside the audio. `stable`
- **Skip-existing and force** — tracks whose audio already exists are skipped so interrupted batches
  resume cleanly; sidecar files never cause a skip; a flag forces regeneration. `stable`

### Preview, selection, and reporting

- **Dry run** — lists exactly what a run would do (track count, output folder, filenames, prompt sizes,
  and which tracks carry lyrics, structure, images, or a duration hint) without any network call and
  without an API key. `stable`
- **Track selection** — generate a single track by position, or cap the number of tracks. `stable`
- **Per-track and run reporting** — a header line naming the model, route, format, input mode, and run
  mode; a per-track OK / SKIP / FAILED line with file size and elapsed time; and a closing summary of
  generated, skipped, and failed counts. `stable`

### Configuration and credentials

- **Single JSON configuration file** — model identifiers, routing mode, endpoint root, output format,
  timeout and poll interval, instrumental default, duration hint, clips folder name, inter-track delay,
  retry count, sidecar switch, and filename length cap; every key is optional with a shipped default.
  `stable`
- **Command-line overrides** — model, format, key, and configuration-file location can be overridden
  per run. `stable`
- **Key resolution chain** — the API key is taken from the command line, then the configuration file,
  then either of two environment variables; a dry run needs none. `stable`
- **Backward-compatible configuration** — configuration files written for the previous major version
  are accepted unchanged. `stable`

### Diagnostics

- **Service messages surfaced verbatim** — the service's own error text (invalid key, policy block,
  unsupported option, refusal text) is shown rather than a generic status. `stable`
- **Clear hard errors** — missing input, unknown flags, missing prompts, and unresolvable output
  locations stop the run with a plain-language message and a non-zero exit code. `stable`

### Claude Code skill

- **Natural-language orchestration** — the skill lets a person ask for catalogues to be generated,
  previewed, or regenerated in plain language and drives the engine on their behalf. `stable`
- **Engine discovery** — finds the engine in a fixed order: a project-local executable, a project-local
  script, then the skill's bundled copies. `stable`
- **Dry-run-first workflow** — always previews before generating, and chooses Markdown mode or manifest
  mode from what the preview shows. `stable`
- **Clip audition step** — offers a preview pass with the clip model when prompts are new or
  uncertain. `stable`
- **Scope and key confirmation** — confirms how many tracks will be generated and that a key is
  available before any paid call. `stable`
- **Bundled references** — ships the catalogue-format reference, a lyrics/structure template that also
  serves as a test fixture, the manifest schema, and troubleshooting guidance so the assistant never
  has to guess a format. `stable`

## 4. Capabilities & Limits

- **Input formats:** Markdown catalogues (`.md`) in Markdown mode; JSON manifests in manifest mode;
  image references of type JPEG, PNG, WebP, or GIF (up to ten per track, manifest mode only).
- **Output formats:** MP3 (44.1 kHz stereo as delivered by the service). WAV can be requested; the
  service currently declines it for the full-song model, in which case MP3 is delivered with a warning.
  Text sidecars are UTF-8 plain text or JSON.
- **Durations:** clip previews are always 30 seconds; full songs are a couple of minutes and can be
  steered by the prompt or the configured duration hint.
- **Observed timings (typical, not guaranteed):** a clip returns in roughly ten seconds; a full song in
  roughly half a minute to a minute. The per-request wait and the polling deadline default to ten
  minutes.
- **Concurrency:** none by design — one request in flight at a time, with a short configurable pause
  between tracks.
- **Retries:** two per track by default, with pauses that grow and cap at half a minute.
- **Filenames:** slugs are capped at 80 characters by default; numbering is zero-padded to the width of
  the catalogue.
- **Platform:** Windows only. The executable needs nothing installed; the script needs the standard
  Windows shell scripting environment.
- **Content policy:** the service refuses prompts that imitate a named artist or reproduce copyrighted
  lyrics; the engine surfaces the refusal and moves on.
- **Cost model:** every generation is a paid call to the hosted service; dry runs are free.

## 5. Integration Surfaces

### 5.1 Command-line contract (both implementations)

Invocation is `<engine> -Path <file-or-folder>` or `<engine> -Manifest <json>` with optional flags:
`-DryRun`, `-Clip`, `-Index <n>`, `-Limit <n>`, `-Force`, `-Model <id>`, `-Format mp3|wav`,
`-Instrumental`, `-Recurse`, `-ApiKey <key>`, `-ConfigPath <file>`. Flags are single-dash and
case-insensitive; exactly one of `-Path` or `-Manifest` is required. Exit code is zero when the run
completes (individual track failures are reported in the output, not the exit code) and non-zero when
the run itself cannot proceed.

### 5.2 Console output contract

Orchestrators parse the engine's standard output. The lines that carry meaning, in order:

- `Lyra Producer`, then a header line beginning `Model:` that also carries `API:`, `Format:`, `Input:`,
  and `Mode:` fields, with a trailing `Clip:` field when previewing.
- Per input file: a banner `=== <file name> ===`, then `Tracks: <count>   ->   output: <folder>`.
- Per track: `  [<nn>] <title>` optionally followed by a tag such as `[+lyrics+structure+images+hint]`;
  in a dry run the next line is `        -> <file name>   (<n> chars)` plus the same tag; in a real
  run the next line is one of `        OK  <file>  (<size> KB, <seconds>s)`,
  `  [<nn>] SKIP (exists): <file>`, or `        FAILED: <message>`, with optional
  `        + lyrics sidecar: <file>` and `        + structure sidecar: <file>` lines after an OK.
- Closing line: `Dry run complete. <n> track(s) would be generated.` or
  `Done. Generated: <n>  Skipped: <n>  Failed: <n>`.

### 5.3 Manifest file (input an integrator produces)

```json
{
  "sourceFile": "path/to/catalogue.md",        // string; required unless outputDir is given
  "outputDir":  "path/to/output-folder",       // string; optional, overrides the derived folder
  "tracks": [                                  // array; required, at least one entry, order = numbering
    {
      "title":     "Track title",              // string; expected (falls back to a numbered name)
      "prompt":    "Music prompt text",        // string; required, non-empty
      "lyrics":    "Sung lines",               // string; optional
      "structure": "[0:00 - 0:10] Intro ...",  // string; optional
      "images":    ["cover.jpg"]               // array of strings; optional, max 10, absolute or manifest-relative paths
    }
  ]
}
```

### 5.4 Catalogue convention (input an author produces)

A track is a level-3 heading followed by a fenced block containing the prompt. Optional lyrics and a
timed structure follow under the same heading, introduced by a "Lyrics" or "Timed structure" label (bold,
plain with a colon, or a level-4 sub-heading), or recognisable by content (section tags for lyrics,
timestamp rows for structure). Anything under a level-1 or level-2 heading is not a track.

### 5.5 Configuration file (input an operator produces)

A JSON object placed beside the engine. All keys optional: `apiKey` (string), `model` (string),
`clipModel` (string), `apiMode` (`auto` | `interactions` | `generateContent`), `endpointBase` (string),
`outputFormat` (`mp3` | `wav`), `timeoutSeconds` (integer), `pollIntervalSeconds` (integer),
`instrumentalByDefault` (boolean), `defaultDurationHint` (string), `clipSubfolder` (string),
`delayBetweenTracksSeconds` (integer), `maxRetries` (integer), `saveLyricsSidecar` (boolean),
`slugMaxLength` (integer). A shipped example file carries the defaults. The key value must never be
committed to source control.

### 5.6 Output naming contract

`<catalogue folder>/<first four filename words>/<nn>-<slug>.<mp3|wav>`, with previews under an extra
`clips/` level and sidecars as `<nn>-<slug>.txt` and `<nn>-<slug>.structure.json` beside the audio.

### 5.7 Upstream dependency

The engine consumes Google's Gemini API (Lyria 3.5 family) as an external service; that API's contract
belongs to Google and is not restated here. A valid key for that service is the only credential the
system uses.

## 6. Extension Notes

- **Manifest mode is the extension point for new catalogue layouts.** Rather than making the parser
  smarter, a new format is supported by having a reader (a language model or another tool) emit the
  manifest shape in §5.3. The engine is intentionally kept "dumb": it processes, queues, and delivers.
- **New models plug in through configuration.** The full-song and clip model identifiers and the routing
  mode are configuration values; a future model that speaks the same service contract needs no engine
  change.
- **WAV output is wired and waiting.** The request is already sent in the shape the service expects;
  when the service enables WAV for the full-song model, files will start arriving as WAV with no update.
- **Orchestrator embedding.** The console output contract (§5.2) is stable so that external
  orchestrators can wrap the engine; one such consumer is the author's TINA orchestration toolbox, which
  wraps the engine as a function that always dry-runs first and requires an explicit opt-in to generate.
- **Two implementations must stay in step.** Any behavioural change lands in both the script and the
  executable, with identical console output, so the skill's instructions apply to either.
- **Private executable source.** The executable's source is maintained outside this repository; the
  script in this repository is the readable reference for its behaviour.

## 7. Glossary

- **Catalogue** — a Markdown file listing tracks as headings with fenced prompt blocks.
- **Track** — one heading-plus-prompt unit in a catalogue; becomes one audio file.
- **Prompt** — the text describing the music to generate; may be extended with lyrics, a structure, an
  instrumental clause, and a duration hint before sending.
- **Timed structure** — timestamp rows telling the model what happens when in the piece.
- **Manifest** — a JSON file of already-extracted tracks, used when a catalogue's layout defeats the
  fixed parser.
- **Clip** — a 30-second preview from the clip model, written to the clips subfolder.
- **Dry run** — a free, keyless rehearsal that lists what a run would produce.
- **Route** — which service endpoint a request uses: the modern one for current models, the legacy one
  for older model identifiers.
- **Sidecar** — a text or JSON file saved beside an audio file, holding returned lyrics or structure.
- **Skip-existing** — the behaviour of leaving already-generated audio alone unless forced.
- **Slug** — the lower-case, hyphenated, accent-folded form of a track title used in filenames.
- **Tagline** — a blockquote description under a track heading; shown, never sent.
