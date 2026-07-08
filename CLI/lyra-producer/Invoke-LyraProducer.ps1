<#
.SYNOPSIS
    Lyra Producer - a zero-UI PowerShell CLI that turns Gemini Lyria "prompt
    catalogue" markdown files into full-song .mp3 audio on disk.

.DESCRIPTION
    Parses one markdown file (or a folder of them), extracts each track's prompt
    (and any optional lyrics / timed structure found under the track heading),
    then calls the Gemini Lyria model (default lyria-3-pro-preview, synchronous
    generateContent) and writes the returned audio next to the source markdown.

    Extraction rule (heading-anchored): a track is a level-3 heading (### ...)
    followed by a fenced ``` code block. Code blocks that are NOT under a ###
    heading (e.g. "How this catalogue works" bullet notes, "Author your own"
    prompt-skeleton / naming-grammar templates) are ignored.

    Output layout: for each markdown file, audio is written into a subfolder
    named from the first 4 hyphen/underscore/space separated words of the
    filename, placed next to the markdown file. Each track is named
    NN-<slugified-heading>.<ext> where NN is its 1-based catalogue position.

.PARAMETER Path
    Path to a single .md file, or a folder containing .md files.

.PARAMETER ConfigPath
    Path to the JSON config. Defaults to lyra-config.json next to this script.

.PARAMETER Index
    1-based index of a single track to generate (0 = all). Use -Index 1 to
    generate just the first track (handy for a proof run).

.PARAMETER Limit
    Generate at most this many tracks (0 = no limit). Applied after -Index.

.PARAMETER Model
    Override the model id from config (e.g. lyria-3-pro-preview).

.PARAMETER Format
    Override output format: mp3 (default) or wav (Pro model only).

.PARAMETER ApiKey
    Override the API key (otherwise config.apiKey, then $env:GEMINI_API_KEY,
    then $env:LYRIA_API_KEY).

.PARAMETER Instrumental
    Append " Instrumental only, no vocals." to prompts that don't already say so.

.PARAMETER Force
    Overwrite existing .mp3 files (default: skip tracks already on disk).

.PARAMETER DryRun
    Parse and list what WOULD be generated, without calling the API. No key needed.

.PARAMETER Recurse
    When Path is a folder, search subfolders for .md files too.

.EXAMPLE
    .\Invoke-LyraProducer.ps1 -Path ..\composers\wagner-preludes-that-never-were-lyria-prompts.md -DryRun

.EXAMPLE
    .\Invoke-LyraProducer.ps1 -Path ..\composers\wagner-preludes-that-never-were-lyria-prompts.md -Index 1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [string]$Manifest,

    [string]$ConfigPath,

    [int]$Index = 0,

    [int]$Limit = 0,

    [string]$Model,

    [ValidateSet('mp3', 'wav')]
    [string]$Format,

    [string]$ApiKey,

    [switch]$Instrumental,

    [switch]$Force,

    [switch]$DryRun,

    [switch]$Recurse
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Lyria endpoint requires TLS 1.2; Windows PowerShell 5.1 may default lower.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

function Get-LyraConfig {
    param([string]$ConfigPath)

    $defaults = [ordered]@{
        apiKey                    = ''
        model                     = 'lyria-3-pro-preview'
        endpointBase              = 'https://generativelanguage.googleapis.com/v1beta/models'
        outputFormat              = 'mp3'
        timeoutSeconds            = 300
        instrumentalByDefault     = $false
        delayBetweenTracksSeconds = 2
        maxRetries                = 2
        saveLyricsSidecar         = $true
        slugMaxLength             = 80
    }

    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $PSScriptRoot 'lyra-config.json'
    }

    if (Test-Path -LiteralPath $ConfigPath) {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if ($raw.Trim()) {
            $loaded = $raw | ConvertFrom-Json
            foreach ($key in @($defaults.Keys)) {
                if ($loaded.PSObject.Properties.Name -contains $key -and $null -ne $loaded.$key) {
                    $defaults[$key] = $loaded.$key
                }
            }
        }
    } else {
        Write-Warning "Config not found at '$ConfigPath'. Using built-in defaults."
    }

    return [pscustomobject]$defaults
}

# ---------------------------------------------------------------------------
# String helpers
# ---------------------------------------------------------------------------

function ConvertTo-Slug {
    param([string]$Text, [int]$MaxLength = 80)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'untitled' }

    $s = $Text
    # Drop markdown emphasis / code characters.
    $s = $s -replace '[*_`~]', ''
    # Collapse thousands-separator commas inside numbers (2,204 -> 2204).
    $s = $s -replace '(?<=\d),(?=\d)', ''
    # Expand a few letters that Unicode decomposition won't split on its own.
    # (Kept as code points so this script stays pure-ASCII and parses under
    #  Windows PowerShell 5.1 regardless of file encoding.)
    $expand = [ordered]@{
        ([char]0x00DF) = 'ss'   # sharp s
        ([char]0x00F8) = 'o'    # o with stroke (lower)
        ([char]0x00D8) = 'o'    # o with stroke (upper)
        ([char]0x00E6) = 'ae'   # ae ligature (lower)
        ([char]0x00C6) = 'ae'   # ae ligature (upper)
        ([char]0x0153) = 'oe'   # oe ligature (lower)
        ([char]0x0152) = 'oe'   # oe ligature (upper)
    }
    foreach ($k in $expand.Keys) { $s = $s.Replace([string]$k, [string]$expand[$k]) }

    # Strip diacritics (accented letter -> base letter) via Unicode decomposition.
    $norm = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $norm.ToCharArray()) {
        $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $s = $sb.ToString().Normalize([Text.NormalizationForm]::FormC)

    $s = $s.ToLowerInvariant()
    # Any run of non [a-z0-9] becomes a single hyphen.
    $s = $s -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')

    if ([string]::IsNullOrWhiteSpace($s)) { return 'untitled' }
    if ($s.Length -gt $MaxLength) {
        $s = $s.Substring(0, $MaxLength).Trim('-')
    }
    return $s
}

function Get-OutputFolderName {
    param([string]$FileBaseName)

    $parts = $FileBaseName -split '[-_\s]+' | Where-Object { $_ -ne '' }
    $first4 = $parts | Select-Object -First 4
    return (($first4 -join '-')).ToLowerInvariant()
}

function Get-Prop {
    # Case/style-tolerant property fetch (inlineData vs inline_data, etc.)
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        if ($Object.PSObject.Properties.Name -contains $n) { return $Object.$n }
    }
    return $null
}

function Test-IsStructureMarkerOnly {
    # Lyria returns a text part alongside the audio. For instrumental prompts it's
    # just its own section markers (e.g. "[[A0]] [[A1]] [[B3]]"), which is noise
    # worth suppressing. Real returned lyrics survive this test.
    param([string]$Text)
    if (-not $Text) { return $true }
    $stripped = ($Text -replace '\[\[[^\]]*\]\]', '') -replace '\s', ''
    return [string]::IsNullOrEmpty($stripped)
}

# ---------------------------------------------------------------------------
# Markdown parsing  (heading-anchored track extraction)
# ---------------------------------------------------------------------------

function Get-RoleFromLabel {
    # Recognise a section label a human would write to introduce lyrics or a
    # timed structure, e.g. "**Lyrics**", "**Timed structure:**", "Lyrics:",
    # or the heading text "Lyrics" / "Timed structure". Returns 'prompt',
    # 'lyrics', 'structure', or $null.
    param([string]$Text)
    $t = $Text.Trim()
    $m = [regex]::Match($t, '(?i)^(?:\*\*|__)\s*(prompt|lyrics|timed\s+structure|structure)\s*:?\s*(?:\*\*|__)\s*$')
    if (-not $m.Success) {
        $m = [regex]::Match($t, '(?i)^(prompt|lyrics|timed\s+structure|structure)\s*:\s*$')
    }
    if (-not $m.Success) { return $null }
    $k = $m.Groups[1].Value.ToLowerInvariant()
    if ($k -like '*structure') { return 'structure' }
    if ($k -eq 'lyrics') { return 'lyrics' }
    if ($k -eq 'prompt') { return 'prompt' }
    return $null
}

function Get-RoleFromContent {
    # Classify an unlabelled block by what's inside it: song-section tags mean
    # lyrics; timestamps mean a timed structure.
    param([string]$Block)
    if ($Block -match '(?im)\[(verse|chorus|bridge|intro|outro|pre-?chorus|hook|refrain)\]') { return 'lyrics' }
    if ($Block -match '\[\s*\d{1,2}:\d{2}') { return 'structure' }
    return $null
}

function Add-ToTrackRole {
    param([object]$Track, [string]$Role, [string]$Text)
    $val = $Text.Trim()
    if (-not $val) { return }
    switch ($Role) {
        'prompt'    { if ($Track.Prompt)    { $Track.Prompt    = "$($Track.Prompt)`n$val" }    else { $Track.Prompt = $val } }
        'lyrics'    { if ($Track.Lyrics)    { $Track.Lyrics    = "$($Track.Lyrics)`n$val" }    else { $Track.Lyrics = $val } }
        'structure' { if ($Track.Structure) { $Track.Structure = "$($Track.Structure)`n$val" } else { $Track.Structure = $val } }
    }
}

function Get-TrackPrompts {
    param([string[]]$Lines)

    # The `###` heading is the only track boundary. Everything from one `###` to
    # the next belongs to that track: a music prompt (always, in a fenced block),
    # and optionally lyrics and/or a timed structure -- present only if the author
    # wrote them in. Those extras are recognised two ways: by an explicit label
    # (**Lyrics**, **Timed structure**, #### Lyrics, "Lyrics:") that targets the
    # block/lines after it, or by content (section tags -> lyrics, timestamps ->
    # structure). Files that are pure prompts stay exactly as before -- no labels,
    # no extra blocks, so lyrics/structure simply stay empty.

    $sections = New-Object System.Collections.Generic.List[object]
    $current = $null
    $role = $null        # target role set by the most recent label (or $null)
    $inFence = $false
    $fenceLines = $null

    foreach ($line in $Lines) {
        $lead = $line.TrimStart()

        if ($inFence) {
            if ($lead.StartsWith('```')) {
                if ($null -ne $current) {
                    $block = ($fenceLines -join "`n")
                    $assign = $role
                    if (-not $assign) {
                        if (-not $current.Prompt) { $assign = 'prompt' }
                        else {
                            $assign = Get-RoleFromContent $block
                            if (-not $assign) { $assign = 'lyrics' }
                        }
                    }
                    Add-ToTrackRole -Track $current -Role $assign -Text $block
                }
                $inFence = $false
                $fenceLines = $null
                $role = $null   # a label applies only to its immediate block
            } else {
                [void]$fenceLines.Add($line)
            }
            continue
        }

        if ($lead.StartsWith('```')) {
            $inFence = $true
            $fenceLines = New-Object System.Collections.Generic.List[string]
            continue
        }

        $m = [regex]::Match($line, '^(#{1,6})\s+(.*)$')
        if ($m.Success) {
            $level = $m.Groups[1].Value.Length
            $text = $m.Groups[2].Value.Trim()
            if ($level -eq 3) {
                # Start a new track.
                $current = [pscustomobject]@{
                    Title = $text; Tagline = $null; Prompt = ''; Lyrics = $null; Structure = $null
                }
                [void]$sections.Add($current)
                $role = $null
            } elseif ($level -le 2) {
                # `#` / `##` end the current track, so template blocks under
                # ## Author your own are never captured.
                $current = $null
                $role = $null
            } else {
                # `####`+ is a sub-element of the current track. A role heading
                # like "#### Lyrics" or "#### Timed structure" targets what
                # follows; a bare keyword counts here (the `###` boundary already
                # scopes it to this track). Anything else leaves the track intact.
                $rr = $text.Trim().ToLowerInvariant()
                $r = $null
                if ($rr -match '^(timed\s+structure|structure)$') { $r = 'structure' }
                elseif ($rr -eq 'lyrics') { $r = 'lyrics' }
                elseif ($rr -eq 'prompt') { $r = 'prompt' }
                if (-not $r) { $r = Get-RoleFromLabel $text }
                if ($r -and $null -ne $current) { $role = $r }
            }
            continue
        }

        if ($null -eq $current) { continue }

        # A label line (e.g. **Lyrics**) targets what follows it.
        $rl = Get-RoleFromLabel $line
        if ($rl) { $role = $rl; continue }

        # Blockquote tagline before the prompt exists (purely informational).
        if ($lead.StartsWith('>') -and -not $current.Prompt) {
            $tl = $lead.TrimStart('>').Trim()
            if ($tl) {
                if ($current.Tagline) { $current.Tagline = "$($current.Tagline) $tl" }
                else { $current.Tagline = $tl }
            }
            continue
        }

        # Labelled, non-fenced prose for lyrics/structure (label then plain text).
        if (($role -eq 'lyrics' -or $role -eq 'structure') -and $lead) {
            Add-ToTrackRole -Track $current -Role $role -Text $line
        }
        # Any other ordinary prose is ignored.
    }

    # Keep only sections that actually carry a prompt; number them 1-based.
    $tracks = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($sec in $sections) {
        if (-not $sec.Prompt) { continue }
        $n++
        [void]$tracks.Add([pscustomobject]@{
            Index     = $n
            Title     = $sec.Title
            Tagline   = $sec.Tagline
            Prompt    = $sec.Prompt.Trim()
            Lyrics    = $(if ($sec.Lyrics)    { $sec.Lyrics.Trim() }    else { $null })
            Structure = $(if ($sec.Structure) { $sec.Structure.Trim() } else { $null })
        })
    }

    return $tracks
}

function Build-FullPrompt {
    param([object]$Track, [bool]$AppendInstrumental)

    $full = $Track.Prompt.Trim()

    if ($AppendInstrumental -and ($full -inotmatch 'instrumental')) {
        $full += ' Instrumental only, no vocals.'
    }
    if ($Track.Lyrics -and $Track.Lyrics.Trim()) {
        $full += "`n`n" + $Track.Lyrics.Trim()
    }
    if ($Track.Structure -and $Track.Structure.Trim()) {
        $full += "`n`n" + $Track.Structure.Trim()
    }
    return $full
}

# ---------------------------------------------------------------------------
# Lyria API
# ---------------------------------------------------------------------------

function Resolve-ApiError {
    param($ErrorRecord)
    # Gemini returns a JSON error body; PowerShell often surfaces it in
    # ErrorDetails.Message. Fall back to the raw exception message.
    $detail = $null
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $parsed = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
            $detail = Get-Prop (Get-Prop $parsed @('error')) @('message', 'status')
        }
    } catch { }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    return $detail
}

function Invoke-LyriaGenerate {
    param(
        [object]$Config,
        [string]$ApiKey,
        [string]$Model,
        [string]$Format,
        [string]$Prompt,
        [int]$TimeoutSec
    )

    $endpoint = "$($Config.endpointBase.TrimEnd('/'))/$($Model):generateContent"

    $bodyObj = @{ contents = @(@{ parts = @(@{ text = $Prompt }) }) }
    if ($Format -eq 'wav') {
        # Matches the proven Stage 12 plan for WAV (Pro only).
        $bodyObj.generationConfig = @{
            responseModalities = @('AUDIO', 'TEXT')
            responseMimeType   = 'audio/wav'
        }
    }

    $json = $bodyObj | ConvertTo-Json -Depth 12
    $headers = @{ 'x-goog-api-key' = $ApiKey }

    return Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec $TimeoutSec
}

function Read-LyriaResponse {
    param($Response, [string]$RequestedFormat)

    $candidates = Get-Prop $Response @('candidates')
    if (-not $candidates -or @($candidates).Count -eq 0) {
        # Surface a prompt/safety block if the model refused.
        $pf = Get-Prop $Response @('promptFeedback')
        $blk = Get-Prop $pf @('blockReason')
        if ($blk) { throw "Generation blocked: $blk" }
        throw 'No candidates returned by the model.'
    }

    $first = @($candidates)[0]
    $content = Get-Prop $first @('content')
    $parts = Get-Prop $content @('parts')

    $audioBytes = $null
    $mime = $null
    $text = $null

    foreach ($p in @($parts)) {
        $inline = Get-Prop $p @('inlineData', 'inline_data')
        if ($inline) {
            $data = Get-Prop $inline @('data')
            if ($data) {
                $audioBytes = [Convert]::FromBase64String($data)
                $mime = Get-Prop $inline @('mimeType', 'mime_type')
            }
        } else {
            $t = Get-Prop $p @('text')
            if ($t) { if ($text) { $text = "$text`n$t" } else { $text = $t } }
        }
    }

    if (-not $audioBytes) {
        $fr = Get-Prop $first @('finishReason')
        if ($fr) { throw "No audio in response (finishReason: $fr)." }
        throw 'No audio data in the model response.'
    }

    $ext = $RequestedFormat
    if ($mime) {
        if ($mime -match 'wav') { $ext = 'wav' }
        elseif ($mime -match 'mpeg|mp3') { $ext = 'mp3' }
    }

    return [pscustomobject]@{
        AudioBytes = $audioBytes
        MimeType   = $mime
        Text       = $text
        Extension  = $ext
    }
}

# ---------------------------------------------------------------------------
# Generation queue  (shared by markdown-parse mode and Claude-manifest mode)
# ---------------------------------------------------------------------------

function Invoke-TrackQueue {
    param(
        [object[]]$Tracks,
        [string]$OutDir,
        [string]$DisplayName,
        [object]$Config,
        [string]$ApiKey,
        [string]$Model,
        [string]$Format,
        [bool]$AppendInstrumental,
        [int]$Index,
        [int]$Limit,
        [bool]$Force,
        [bool]$DryRun,
        [hashtable]$Totals
    )

    Write-Host ''
    Write-Host "=== $DisplayName ===" -ForegroundColor Cyan

    $Tracks = @($Tracks)
    if ($Tracks.Count -eq 0) {
        Write-Warning "No tracks to generate for '$DisplayName'."
        return
    }

    Write-Host "Tracks: $($Tracks.Count)   ->   output: $OutDir" -ForegroundColor DarkGray

    if (-not $DryRun -and -not (Test-Path -LiteralPath $OutDir)) {
        [void](New-Item -ItemType Directory -Path $OutDir -Force)
    }

    $width = [Math]::Max(2, "$($Tracks.Count)".Length)

    # Select which tracks to act on (numbering stays based on the full set).
    $selected = $Tracks
    if ($Index -gt 0) {
        $selected = $Tracks | Where-Object { $_.Index -eq $Index }
        if (-not $selected) { Write-Warning "No track at index $Index (set has $($Tracks.Count))."; return }
    }
    if ($Limit -gt 0) {
        $selected = $selected | Select-Object -First $Limit
    }

    foreach ($t in $selected) {
        $num = $t.Index.ToString().PadLeft($width, '0')
        $slug = ConvertTo-Slug -Text $t.Title -MaxLength ([int]$Config.slugMaxLength)
        $baseName = "$num-$slug"
        $extras = @()
        if ($t.Lyrics) { $extras += 'lyrics' }
        if ($t.Structure) { $extras += 'structure' }
        $extraTag = if ($extras.Count) { "  [+" + ($extras -join '+') + "]" } else { '' }

        if ($DryRun) {
            Write-Host ("  [{0}] {1}" -f $num, $t.Title) -ForegroundColor White
            Write-Host ("        -> {0}.{1}{2}   ({3} chars){4}" -f `
                $baseName, $Format, '', $t.Prompt.Length, $extraTag) -ForegroundColor DarkGray
            $Totals.Planned++
            continue
        }

        # Skip if any file with this base already exists (mp3/wav) unless -Force.
        $existing = Get-ChildItem -LiteralPath $outDir -Filter "$baseName.*" -File -ErrorAction SilentlyContinue
        if ($existing -and -not $Force) {
            Write-Host ("  [{0}] SKIP (exists): {1}" -f $num, $existing[0].Name) -ForegroundColor Yellow
            $Totals.Skipped++
            continue
        }

        $fullPrompt = Build-FullPrompt -Track $t -AppendInstrumental $AppendInstrumental

        Write-Host ("  [{0}] {1}{2}" -f $num, $t.Title, $extraTag) -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $attempt = 0
        $result = $null
        while ($true) {
            $attempt++
            try {
                $resp = Invoke-LyriaGenerate -Config $Config -ApiKey $ApiKey -Model $Model `
                    -Format $Format -Prompt $fullPrompt -TimeoutSec ([int]$Config.timeoutSeconds)
                $result = Read-LyriaResponse -Response $resp -RequestedFormat $Format
                break
            } catch {
                $msg = Resolve-ApiError $_
                if ($attempt -gt [int]$Config.maxRetries) {
                    Write-Host ("        FAILED: {0}" -f $msg) -ForegroundColor Red
                    $Totals.Failed++
                    break
                }
                $backoff = [Math]::Min(30, 3 * $attempt)
                Write-Host ("        attempt {0} failed: {1} - retrying in {2}s" -f $attempt, $msg, $backoff) -ForegroundColor DarkYellow
                Start-Sleep -Seconds $backoff
            }
        }

        if (-not $result) { continue }

        $outFile = Join-Path $outDir "$baseName.$($result.Extension)"
        [System.IO.File]::WriteAllBytes($outFile, $result.AudioBytes)
        $sw.Stop()

        $sizeKb = [Math]::Round($result.AudioBytes.Length / 1KB, 1)
        Write-Host ("        OK  {0}  ({1} KB, {2:n1}s)" -f (Split-Path $outFile -Leaf), $sizeKb, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        $Totals.Generated++

        if ($Config.saveLyricsSidecar -and $result.Text -and -not (Test-IsStructureMarkerOnly $result.Text)) {
            $sidecar = Join-Path $outDir "$baseName.txt"
            Set-Content -LiteralPath $sidecar -Value $result.Text -Encoding UTF8
            Write-Host ("        + lyrics sidecar: {0}" -f (Split-Path $sidecar -Leaf)) -ForegroundColor DarkGray
        }

        if ([int]$Config.delayBetweenTracksSeconds -gt 0) {
            Start-Sleep -Seconds ([int]$Config.delayBetweenTracksSeconds)
        }
    }
}

# ---------------------------------------------------------------------------
# Mode A: parse a markdown catalogue directly (uniform "### + fenced prompt" files)
# ---------------------------------------------------------------------------

function Invoke-MarkdownFile {
    param(
        [System.IO.FileInfo]$File,
        [object]$Config, [string]$ApiKey, [string]$Model, [string]$Format,
        [bool]$AppendInstrumental, [int]$Index, [int]$Limit, [bool]$Force, [bool]$DryRun,
        [hashtable]$Totals
    )

    $lines = Get-Content -LiteralPath $File.FullName -Encoding UTF8
    $tracks = Get-TrackPrompts -Lines $lines
    $outDir = Join-Path $File.DirectoryName (Get-OutputFolderName -FileBaseName $File.BaseName)

    Invoke-TrackQueue -Tracks $tracks -OutDir $outDir -DisplayName $File.Name `
        -Config $Config -ApiKey $ApiKey -Model $Model -Format $Format `
        -AppendInstrumental $AppendInstrumental -Index $Index -Limit $Limit `
        -Force:$Force -DryRun:$DryRun -Totals $Totals
}

# ---------------------------------------------------------------------------
# Mode B: consume a Claude-authored manifest. For varied/complex files, Claude
# reads/understands/extracts each track (title, prompt, lyrics, structure) and
# writes a JSON manifest; the CLI here is a pure inference+delivery engine.
#
# Manifest shape:
#   {
#     "sourceFile": "C:/.../spirit-of-racing-eurobeat-ost.md",   // for output folder + display
#     "outputDir":  "C:/.../custom-folder",                       // optional; overrides sourceFile
#     "tracks": [
#       { "title": "Built To Be Remade", "prompt": "...", "lyrics": "...", "structure": "..." }
#     ]
#   }
# lyrics and structure are optional per track; prompt and title are expected.
# ---------------------------------------------------------------------------

function Invoke-Manifest {
    param(
        [string]$ManifestPath,
        [object]$Config, [string]$ApiKey, [string]$Model, [string]$Format,
        [bool]$AppendInstrumental, [int]$Index, [int]$Limit, [bool]$Force, [bool]$DryRun,
        [hashtable]$Totals
    )

    $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
    $mf = $raw | ConvertFrom-Json

    $mfTracks = Get-Prop $mf @('tracks')
    if (-not $mfTracks -or @($mfTracks).Count -eq 0) {
        throw "Manifest '$ManifestPath' has no 'tracks' array."
    }

    # Normalise manifest entries into the internal track shape.
    $tracks = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($mt in @($mfTracks)) {
        $prompt = Get-Prop $mt @('prompt')
        if (-not $prompt -or -not "$prompt".Trim()) {
            throw "Manifest track $($n + 1) is missing a non-empty 'prompt'."
        }
        $n++
        $title = Get-Prop $mt @('title')
        $lyr = Get-Prop $mt @('lyrics')
        $str = Get-Prop $mt @('structure')
        [void]$tracks.Add([pscustomobject]@{
            Index     = $n
            Title     = $(if ($title) { "$title" } else { "track-$n" })
            Tagline   = $null
            Prompt    = "$prompt".Trim()
            Lyrics    = $(if ($lyr -and "$lyr".Trim()) { "$lyr".Trim() } else { $null })
            Structure = $(if ($str -and "$str".Trim()) { "$str".Trim() } else { $null })
        })
    }

    # Output directory: explicit outputDir wins, else derive from sourceFile
    # (its folder + the first-4-filename-words rule), matching markdown mode.
    $outDir = Get-Prop $mf @('outputDir')
    $srcFile = Get-Prop $mf @('sourceFile')
    if (-not $outDir) {
        if (-not $srcFile) {
            throw "Manifest needs 'outputDir' or 'sourceFile' so the output folder is known."
        }
        $srcDir = Split-Path -Parent $srcFile
        if (-not $srcDir) { $srcDir = '.' }
        $srcBase = [System.IO.Path]::GetFileNameWithoutExtension($srcFile)
        $outDir = Join-Path $srcDir (Get-OutputFolderName -FileBaseName $srcBase)
    }

    $display = $(if ($srcFile) { Split-Path $srcFile -Leaf } else { Split-Path $ManifestPath -Leaf })

    Invoke-TrackQueue -Tracks $tracks -OutDir $outDir -DisplayName $display `
        -Config $Config -ApiKey $ApiKey -Model $Model -Format $Format `
        -AppendInstrumental $AppendInstrumental -Index $Index -Limit $Limit `
        -Force:$Force -DryRun:$DryRun -Totals $Totals
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$config = Get-LyraConfig -ConfigPath $ConfigPath

$effModel = if ($Model) { $Model } else { $config.model }
$effFormat = if ($Format) { $Format } else { $config.outputFormat }
$appendInstrumental = [bool]$Instrumental -or [bool]$config.instrumentalByDefault

# Resolve API key (only strictly required when actually generating).
$effKey = $ApiKey
if (-not $effKey) { $effKey = $config.apiKey }
if (-not $effKey) { $effKey = $env:GEMINI_API_KEY }
if (-not $effKey) { $effKey = $env:LYRIA_API_KEY }

if (-not $DryRun -and [string]::IsNullOrWhiteSpace($effKey)) {
    throw "No API key. Set 'apiKey' in lyra-config.json, pass -ApiKey, or set `$env:GEMINI_API_KEY."
}

if (-not $Manifest -and -not $Path) {
    throw "Provide -Path <markdown-or-folder> or -Manifest <json>."
}

$modeLabel = if ($Manifest) { 'MANIFEST (Claude-extracted)' } else { 'MARKDOWN' }
Write-Host "Lyra Producer" -ForegroundColor Magenta
Write-Host ("Model: {0}   Format: {1}   Input: {2}   Mode: {3}" -f `
    $effModel, $effFormat, $modeLabel, ($(if ($DryRun) { 'DRY-RUN' } else { 'GENERATE' }))) -ForegroundColor DarkGray

$totals = @{ Planned = 0; Generated = 0; Skipped = 0; Failed = 0 }

if ($Manifest) {
    $mfPath = (Resolve-Path -LiteralPath $Manifest).Path
    Invoke-Manifest -ManifestPath $mfPath -Config $config -ApiKey $effKey -Model $effModel `
        -Format $effFormat -AppendInstrumental $appendInstrumental -Index $Index -Limit $Limit `
        -Force:$Force -DryRun:$DryRun -Totals $totals
} else {
    # Resolve input files.
    $resolved = Resolve-Path -LiteralPath $Path
    $item = Get-Item -LiteralPath $resolved
    if ($item.PSIsContainer) {
        $files = Get-ChildItem -LiteralPath $item.FullName -Filter '*.md' -File -Recurse:$Recurse |
            Sort-Object FullName
    } else {
        $files = @($item)
    }

    if (-not $files -or @($files).Count -eq 0) {
        throw "No .md files found at '$Path'."
    }

    foreach ($f in $files) {
        Invoke-MarkdownFile -File $f -Config $config -ApiKey $effKey -Model $effModel `
            -Format $effFormat -AppendInstrumental $appendInstrumental -Index $Index -Limit $Limit `
            -Force:$Force -DryRun:$DryRun -Totals $totals
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host ("Dry run complete. {0} track(s) would be generated." -f $totals.Planned) -ForegroundColor Magenta
} else {
    Write-Host ("Done. Generated: {0}  Skipped: {1}  Failed: {2}" -f `
        $totals.Generated, $totals.Skipped, $totals.Failed) -ForegroundColor Magenta
}
