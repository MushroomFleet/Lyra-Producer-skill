# Lyria prompt-catalogue format & CLI behaviour

Reference for the markdown "prompt catalogue" files that the LyraProducer CLI
consumes (`LyraProducer.exe`, or `Invoke-LyraProducer.ps1` as a fallback — both
behave identically here), and exactly how the CLI turns them into audio. Read this
when a file's structure looks unusual, when the dry-run track count is surprising,
or when a catalogue contains lyrics / timed structure.

## What a catalogue file looks like

These files are hand-written catalogues of imagined music. A typical one opens
with a `#` title, an italic subtitle, some intro prose, a `## How this catalogue
works` notes section, then one or more `## The Catalogue ...` sections holding the
actual tracks, and often a closing `## Author your own` section with templates.

Each **track** is a level-3 heading, an optional blockquote tagline, then a fenced
code block holding the generation prompt:

```markdown
### Vorspiel zu *"Die Nebelkönigin"*, WWV 2,204
> A single unresolved chord, stretched out until it becomes a world.

​```
Late-Romantic orchestral prelude, Wagnerian tradition, for full orchestra. ...
Instrumental only, no vocals.
​```
```

Heading styles vary between files — all of these are valid track headings:

- `### Vorspiel zu *"Die Nebelkönigin"*, WWV 2,204` (Wagner)
- `### Nocturne No. 1,021 in D-Flat Major, Op. 388 No. 2 — *"Almost Morning"*` (Chopin)
- `### No. 1,204: *Phobos, the Bringer of Dread* — from *The Planets*, Op. 990` (Holst)

## Extraction rule (how the CLI decides what is a track)

**A track = a `###` heading followed by a fenced code block.** The heading is the
title; the first fenced block under it is the prompt.

Code blocks that are **not** under a `###` heading are ignored. This is what keeps
the template blocks out of the run:

- `## How this catalogue works` — bullet notes, usually no code blocks.
- `## Author your own` — contains a "prompt skeleton" and "naming grammar" fenced
  block, but these sit under a `##` heading with no `###`, so they are skipped.

A `#` or `##` heading ends the current track section, so a template block after the
last real track is never mis-attributed to it.

**Sanity check:** after a dry-run, the reported track count should match the number
of `###` headings that have a prompt under them. If it's higher, a template/example
block is leaking in; if lower, a track heading may not be level-3 or its prompt may
not be fenced. Inspect the file and reconcile before generating.

## Filenames (numbered + slug)

Each track becomes `NN-<slug>.<ext>`:

- `NN` = the track's 1-based position in the full catalogue, zero-padded to the
  width of the largest index (10 tracks → `01`..`10`). Numbering is stable and
  does **not** change when `-Index` / `-Limit` select a subset.
- `<slug>` = the heading, lowercased, ASCII-folded (`ö → o`, `ß → ss`), markdown
  stripped, thousands-separator commas removed (`2,204 → 2204`), and every run of
  non-`[a-z0-9]` collapsed to a single hyphen. Capped at `slugMaxLength` (default 80).

Example: `### Vorspiel zu *"Die Nebelkönigin"*, WWV 2,204` →
`01-vorspiel-zu-die-nebelkonigin-wwv-2204.mp3`.

## Output folder (first 4 filename words)

Audio is written next to the source markdown, inside a subfolder named from the
**first 4 hyphen/underscore/space-separated words of the filename**:

```
composers/
  wagner-preludes-that-never-were-lyria-prompts.md
  wagner-preludes-that-never/            <- wagner + preludes + that + never
    01-vorspiel-zu-die-nebelkonigin-wwv-2204.mp3
    ...
```

When `-Path` is a folder, every `.md` in it is processed and each gets its own
per-file subfolder beside it.

With `-Clip`, audio goes one level deeper, into `<folder>/clips/` (the `clipSubfolder`
config key), so 30-second previews and full songs never share a filename:

```
composers/
  wagner-preludes-that-never/
    01-vorspiel-zu-die-nebelkonigin-wwv-2204.mp3      <- full song (lyria-3.5)
    clips/
      01-vorspiel-zu-die-nebelkonigin-wwv-2204.mp3    <- 30-second preview (-Clip)
```

Skip-existing looks only at `NN-slug.mp3` / `NN-slug.wav` in the folder being written;
sidecar files never cause a SKIP.

## Lyrics & timed structure (optional, per-track)

Lyrics and a timed structure are **optional and independent** — most catalogues (all
the composer sets) have neither, and their prompts already end with "Instrumental
only, no vocals." The `###` header is the boundary: whatever lies between one `###`
and the next belongs to that track, so a track has lyrics only if they're actually
written under its heading. Nothing is invented.

The parser recognises them two ways:

1. **By label** (preferred, unambiguous) — a line that introduces the section:
   - `**Lyrics**`, `**Lyrics:**`, `Lyrics:`, or a `#### Lyrics` sub-heading
   - `**Timed structure**`, `**Structure:**`, or a `#### Timed structure` sub-heading

   The label targets what follows it — either a fenced code block, or plain lines up
   to the next label / sub-heading / fence / next `###`.
2. **By content** (fallback for an unlabelled extra fenced block) — a block with song
   tags `[Verse]` / `[Chorus]` / `[Bridge]` / `[Intro]` / `[Outro]` / `[Hook]` /
   `[Refrain]` → lyrics; a block with timestamps like `[0:00 ...]` → structure.

Detected lyrics/structure are appended to the prompt sent to Lyria (prompt + lyrics +
structure), matching the proven Stage 12 behaviour. The dry-run tags any track that
carried them with `[+lyrics]` / `[+structure]`, so a glance confirms detection before
spending anything.

See **`example-with-lyrics.md`** in this folder for a 3-track template: one pure
instrumental, one with labelled fenced lyrics + structure, one with plain-text lyrics
under a `#### Lyrics` sub-heading. Recommend that layout to anyone writing a catalogue
with words — it is the least ambiguous. If a file clearly intends lyrics but the
dry-run doesn't tag it, the layout is off; normalise it to this convention and
re-run the dry-run rather than guessing.

## Output sidecar

This is *output*, separate from the input lyrics above. Lyria returns text alongside
the audio. For instrumental prompts it's only the model's own section markers like
`[[A0]] [[A1]] [[B3]]` — noise. The CLI auto-skips writing a sidecar when the returned
text is markers-only, so instrumental tracks produce no `.txt`. When a vocal track
comes back with real sung lyrics and `saveLyricsSidecar` is true, those are written to
`NN-slug.txt` beside the audio. Lyria 3.5 may additionally return a JSON description
of the song structure; that block is written to `NN-slug.structure.json` under the same
setting. Set `saveLyricsSidecar` false to never write either.

## Model / API shape

Defaults target `lyria-3.5` through the Gemini **Interactions API**:
`POST https://generativelanguage.googleapis.com/v1beta/interactions` with header
`x-goog-api-key`, body `{ "model": "lyria-3.5", "input": "<prompt>" }` (or an `input`
array of `{type:"text"}` / `{type:"image"}` blocks when a manifest track carries
images; `"response_format": {"type":"audio","mime_type":"audio/wav"}` is added for WAV,
which the API currently declines for `lyria-3.5` — the CLI then warns and re-sends the
track as MP3). The response is a
list of `steps`; the `model_output` step's `content` holds `{type:"audio", data:<base64>}`
and `{type:"text", text:...}` blocks (lyrics, and sometimes a JSON structure). The CLI
takes the last audio block, decides the file extension from the bytes, and writes the
text blocks as sidecars. If the API answers with a non-terminal `status`, the CLI polls
`GET .../interactions/{id}` every `pollIntervalSeconds` until `timeoutSeconds` elapse.

`-Clip` swaps the model for `lyria-3-clip-preview` (always 30 seconds) on the same
endpoint. Model ids beginning `lyria-3-pro-` are routed to the legacy
`POST .../v1beta/models/{model}:generateContent` endpoint with the v1 body and the
`candidates[0].content.parts[].inlineData` response, so old configs keep working; that
route cannot take images.
