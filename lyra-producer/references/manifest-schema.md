# Manifest schema (Claude-extracted input for the CLI)

When a catalogue's shape can't be read reliably by the markdown parser, Claude reads
and understands the file, extracts each track, and writes a **manifest JSON**. The
CLI's `-Manifest` mode consumes it and does only the API inference + delivery — the
zero-UI split: PowerShell infers, Claude extracts.

## Schema

```json
{
  "sourceFile": "C:/abs/path/to/the-source.md",
  "outputDir":  "C:/abs/path/to/custom-folder",
  "tracks": [
    {
      "title":     "Built To Be Remade",
      "prompt":    "A high-energy Super Eurobeat opening-theme at 158 BPM ...",
      "lyrics":    "[Intro]\nRemade (remade)\n...",
      "structure": "[00:00 - 00:10] Intro - A major, 158 BPM ...\n..."
    }
  ]
}
```

Fields:

- **`tracks`** (required) — ordered array. Track order = the `NN-` file numbering.
- **`title`** (per track, expected) — becomes the filename after `NN-` + slugify. Give
  it the clean song title, not "Track 1 — ...". Slugging handles the rest.
- **`prompt`** (per track, required) — the music/generation prompt text only. Do NOT
  fold lyrics or timestamps into it; the CLI concatenates prompt + lyrics + structure.
- **`lyrics`** (per track, optional) — omit or leave empty for instrumental tracks.
- **`structure`** (per track, optional) — the timed-structure text if the file has one.
- **`sourceFile`** (required unless `outputDir` given) — the original `.md`. The CLI
  derives the output folder from it: the file's directory + the first-4-filename-words
  rule (e.g. `spirit-of-racing-eurobeat-ost.md` → `spirit-of-racing-eurobeat/`).
- **`outputDir`** (optional) — explicit output folder; overrides the `sourceFile`
  derivation when a different location is wanted.

The CLI validates each track has a non-empty `prompt`; a missing one is a hard error
(better to fail than generate a mystery). `-Index` / `-Limit` select a subset exactly
as in markdown mode.

## How to extract (the reading step)

Read the whole file and find, per track:
- the **track boundary** — whatever the file uses as a new-track marker (a `##`/`###`
  heading, a horizontal rule, a bold title). It's usually visually obvious.
- the **prompt** — the paragraph the author intends as the generation prompt (often
  under a label like `**Paste-ready prompt:**`, or simply the prose/fenced block).
- the **lyrics** — the block of verse/chorus text, if any.
- the **structure** — the timestamped block, if any.

Order varies (structure may precede lyrics or vice-versa) but the *grammatical shape*
makes each unmistakable: a prompt is descriptive prose, lyrics are sung lines, a timed
structure is `[mm:ss - mm:ss]` rows. Extract by meaning, not by a fixed position.

## Worked example: `spirit-of-racing-eurobeat-ost.md`

That file uses `## Track N — Title` headers, a `**Paste-ready prompt:**` prose prompt,
a fenced `**Optional — timestamped structure:**` block, and a `### Lyrics` prose
section (structure before lyrics). The markdown parser mis-reads it (it treats `##` as
a track break and would grab the structure block as the prompt), so it goes through
manifest mode. Extracted, its 6 tracks produce:

```
01-built-to-be-remade.mp3        [+lyrics+structure]
02-faster-than-my-mind.mp3       [+lyrics+structure]
03-before-i-see-you.mp3          [+lyrics+structure]
04-race-the-sunrise.mp3          [+lyrics+structure]
05-the-road-above-the-lake.mp3   [+lyrics+structure]
06-clumsy-fortune.mp3            [+lyrics+structure]
```

into `spirit-of-racing-eurobeat/` beside the source. Always dry-run the manifest
(`-Manifest <path> -DryRun`) and confirm this list with the user before generating.
