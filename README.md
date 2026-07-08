  # 🎵 Lyra-Producer

  **A zero-UI PowerShell pipeline + Claude Code skill for turning Markdown prompt catalogues into 
  full-song audio with Google's Gemini Lyria music model.**

  Lyra-Producer takes plain Markdown files full of music-generation prompts and produces finished `.mp3`
  audio on disk — no frontend, no database, no clicking through a UI. You write (or AI-generate) a
  catalogue of track prompts in Markdown; Lyra-Producer reads them, calls the Gemini Lyria model, and
  writes numbered audio files straight to a folder.

  It ships as two cooperating pieces:

  - a **PowerShell CLI** (`Invoke-LyraProducer.ps1`) — the generation queue and audio-delivery engine, and
  - a **Claude Code skill** (`lyra-producer`) — an orchestration layer that lets Claude read, understand,
  and extract prompts from any Markdown shape and drive the CLI for you in natural language.

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
  - **Zero UI.** Pure PowerShell orchestration plus a small config file. No app, no server, no browser.
  - **Full songs.** Targets the Lyria Pro model for complete arrangements, with synchronous inference
  straight to inline audio.
  - **Optional lyrics & timed structure.** If a track carries custom lyrics or a timestamped structure,
  they're detected and folded into the prompt; purely instrumental tracks just send the prompt.
  - **Safe, resumable batches.** Strictly sequential generation (never parallel), automatic retries on
  transient failures, skip-existing so interrupted runs resume cleanly, and clear per-track **OK / SKIP /
  FAILED** reporting.
  - **Preview before you spend.** A dry-run mode lists exactly what would be generated — track count,
  output filenames, and any detected lyrics/structure — without calling the paid API.

  ## The two components

  ### 1. The PowerShell CLI — `Invoke-LyraProducer.ps1`

  The engine. Given a catalogue it:

  - parses each track (a heading + a fenced prompt block, plus any optional lyrics / structure),
  - slugifies each track title into a safe, numbered filename,
  - writes audio into a per-catalogue output subfolder beside the source Markdown,
  - calls Gemini Lyria and streams the returned audio to `.mp3`,
  - runs the whole set as a sequential queue with retries and skip-existing.

  Settings — API key, model, output format, request timeout, retry count, inter-track delay — come from a
  small JSON config placed beside the script, so the tool is self-contained.

  **Two input modes:**

  - **Markdown mode** — the CLI parses uniform catalogues directly (each track = a heading followed by a
  fenced prompt). Fast, no manual work.
  - **Manifest mode** — for irregular files a rigid parser can't read reliably, the language model reads
  and extracts each track into a small JSON manifest, and the CLI simply runs inference over it. This is
  the deliberate split at the heart of the design: **PowerShell does the inference; the language model
  does the reading and understanding.**

  ### 2. The Claude Code skill — `lyra-producer`

  The orchestration layer. Installed as a Claude Code skill, it lets you just say *"generate the Wagner
  tracks"* or *"run Lyria on this prompt file"*. The skill:

  - locates the right catalogue and the CLI,
  - makes sure an API key is configured,
  - **always dry-runs first** and shows you the plan,
  - picks markdown vs manifest mode based on the file's shape,
  - confirms scope/cost, then runs the generation and reports results.

  It bundles a portable copy of the CLI plus reference docs — the catalogue format, a lyrics/structure
  template, and the manifest schema — so Claude has everything it needs to handle new prompt formats
  without guessing.

  ## Requirements

  - **Windows PowerShell 5.1+**
  - A **Google Gemini / Lyria API key** with access to the Lyria model
  - *(Optional)* **Claude Code** — only needed for the natural-language skill layer; the CLI works
  standalone

  ## Getting started

  1. **Add your API key.** Copy the example config to `lyra-config.json` (next to the CLI) and paste your
  Google API key into the `apiKey` field. The key can also be supplied via an environment variable or a
  command-line switch.
  2. **Preview a catalogue** — no key needed, no cost:
     ```powershell
     ./Invoke-LyraProducer.ps1 -Path .\my-prompts.md -DryRun
     ```
     Confirm the track count and filenames look right.
  3. **Generate:**
     ```powershell
     ./Invoke-LyraProducer.ps1 -Path .\my-prompts.md
     ```
     Or point `-Path` at a whole folder of catalogues, or generate a single track with `-Index N`.
  4. **(Optional) Install the skill** by placing the `lyra-producer` skill directory in your user Claude
  Code skills folder. Then simply ask Claude to generate the tracks.

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

  ## Output

  For each catalogue, audio is written into its own subfolder next to the source Markdown. Files are named
  by catalogue position plus a slug of the track title — e.g. `01-a-gentle-morning-waltz.mp3`, `02-…` —
  so they sort in order and never collide. A returned-text sidecar can optionally be saved alongside each
  track.

  ## Configuration

  A small JSON config controls: the API key, the model, output format (`mp3`/`wav`), request timeout,
  delay between tracks, retry count, whether to save the text sidecar, and the maximum filename-slug
  length. Sensible defaults ship in the example config.

  ## Notes & tips

  - **Sequential by design.** Tracks generate one at a time to stay friendly to rate limits and cost. Use
  `-Index` / `-Limit` while testing.
  - **Resumable.** Re-running skips anything already on disk, so an interrupted batch just picks up where
  it left off.
  - **Retries.** Transient errors (server hiccups, empty responses) are retried automatically.
  - **Content policy.** Lyria refuses prompts that ask it to imitate a *named* artist ("in the style of
  [artist]"). Describe the era or genre instead (e.g. "late-Romantic", "impressionist") to stay clear of
  the filter.
  - **Big files, small repos.** Generated audio is large — keep it out of Git and back it up separately.

  ## License

  Released under the MIT License. See `LICENSE` for details.

  ---

  ## 📚 Citation

  ### Academic Citation

  If you use this codebase in your research or project, please cite:

  ```bibtex
  @software{lyra_producer_2026,
    title = {Lyra-Producer: a zero-UI PowerShell pipeline and Claude skill for Gemini Lyria music
  generation},
    author = {Drift Johnson},
    year = {2026},
    url = {https://github.com/MushroomFleet/Lyra-Producer-skill},
    version = {1.0.0}
  }
