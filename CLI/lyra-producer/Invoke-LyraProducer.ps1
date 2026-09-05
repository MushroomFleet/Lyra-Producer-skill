<#
.SYNOPSIS
    Lyra Producer - a zero-UI PowerShell CLI that turns Gemini Lyria "prompt
    catalogue" markdown files into full-song .mp3 audio on disk.

.DESCRIPTION
    Parses one markdown file (or a folder of them), extracts each track's prompt
    (and any optional lyrics / timed structure found under the track heading),
    then calls Google's Lyria 3.5 models through the Gemini Interactions API
    (default model lyria-3.5; lyria-3-clip-preview via -Clip) and writes the
    returned audio next to the source markdown. Model ids beginning
    lyria-3-pro- are routed to the legacy models/{model}:generateContent
    endpoint automatically, so v1 configs keep working.

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
    Override the model id from config (default lyria-3.5). Ids starting
    lyria-3-pro- use the legacy generateContent route.

.PARAMETER Format
    Override output format: mp3 (default) or wav (Lyria 3.5 only; ignored
    with -Clip). The saved extension always matches the bytes returned.

.PARAMETER Clip
    Preview mode: use the 30-second lyria-3-clip-preview model (config
    clipModel) and write into a clips\ subfolder beside the full songs.
    Cheap way to audition prompts before a full run.

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

.EXAMPLE
    .\Invoke-LyraProducer.ps1 -Path ..\composers\wagner-preludes-that-never-were-lyria-prompts.md -Clip -Index 1
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

    [switch]$Clip,

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
        model                     = 'lyria-3.5'
        clipModel                 = 'lyria-3-clip-preview'
        apiMode                   = 'auto'
        endpointBase              = 'https://generativelanguage.googleapis.com/v1beta'
        outputFormat              = 'mp3'
        timeoutSeconds            = 600
        pollIntervalSeconds       = 5
        instrumentalByDefault     = $false
        defaultDurationHint       = ''
        clipSubfolder             = 'clips'
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

function Get-ApiRoot {
    # Normalises endpointBase to the API root (".../v1beta"). v1 configs pointed
    # at ".../v1beta/models"; strip that suffix so both shapes work.
    param([string]$EndpointBase)
    $root = $EndpointBase.TrimEnd('/')
    if ($root -match '(?i)/models$') { $root = $root.Substring(0, $root.Length - 7) }
    return $root
}

function Resolve-ApiRoute {
    # 'interactions' (Lyria 3.5 / Clip) or 'generateContent' (legacy lyria-3-pro-*).
    param([string]$ApiMode, [string]$Model)
    switch (("$ApiMode").Trim().ToLowerInvariant()) {
        'interactions'    { return 'interactions' }
        'generatecontent' { return 'generateContent' }
    }
    if ($Model -match '^(?i)lyria-3-pro-') { return 'generateContent' }
    return 'interactions'
}

function Get-WavResponseFormat {
    # Lyria 3.5 WAV request. Probed live on 2026-09-05: the Interactions API
    # rejects unknown parameters, and the field it understands here is
    # mime_type. It currently answers "Audio MIME type AUDIO_WAV is not
    # supported for models/lyria-3.5"; Invoke-LyriaInteraction falls back to
    # mp3 (with a warning) when that happens, and the saved extension always
    # follows the bytes actually returned (Get-AudioExtension).
    return @{ type = 'audio'; mime_type = 'audio/wav' }
}

function Get-ImageMimeType {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.jpg'  { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.png'  { return 'image/png' }
        '.webp' { return 'image/webp' }
        '.gif'  { return 'image/gif' }
    }
    throw "Unsupported image type '$Path' (use .jpg, .jpeg, .png, .webp or .gif)."
}

function Get-AudioExtension {
    # Decide the file extension from the bytes first, the mime type second, the
    # requested format last. Never trust the request alone.
    param([byte[]]$Bytes, [string]$MimeType, [string]$RequestedFormat)
    if ($Bytes.Length -ge 12 -and
        $Bytes[0] -eq 0x52 -and $Bytes[1] -eq 0x49 -and $Bytes[2] -eq 0x46 -and $Bytes[3] -eq 0x46 -and
        $Bytes[8] -eq 0x57 -and $Bytes[9] -eq 0x41 -and $Bytes[10] -eq 0x56 -and $Bytes[11] -eq 0x45) {
        return 'wav'                                                    # RIFF....WAVE
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0x49 -and $Bytes[1] -eq 0x44 -and $Bytes[2] -eq 0x33) {
        return 'mp3'                                                    # ID3 tag
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and (($Bytes[1] -band 0xE0) -eq 0xE0)) {
        return 'mp3'                                                    # MPEG frame sync
    }
    if ($MimeType) {
        if ($MimeType -match 'wav') { return 'wav' }
        if ($MimeType -match 'mpeg|mp3') { return 'mp3' }
    }
    return $RequestedFormat
}

function Test-IsJsonText {
    # True when a returned text block is a JSON document (Lyria 3.5 may return a
    # JSON description of the song structure alongside the lyrics).
    param([string]$Text)
    if (-not $Text) { return $false }
    $t = $Text.Trim()
    if (-not ($t.StartsWith('{') -or $t.StartsWith('['))) { return $false }
    try { [void]($t | ConvertFrom-Json); return $true } catch { return $false }
}

function Test-HasDurationWording {
    # True when the prompt already says how long the piece should be, either via
    # [m:ss] timestamps or a number + time unit ("3 minutes", "90-second").
    param([string]$Text)
    if (-not $Text) { return $false }
    if ($Text -match '\[\s*\d{1,2}:\d{2}') { return $true }
    if ($Text -match '(?i)\b\d+(?:[.,]\d+)?\s*(?:-|to)?\s*(?:minute|min|second|sec)s?\b') { return $true }
    return $false
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
            Images    = @()
        })
    }

    return $tracks
}

function Build-FullPrompt {
    param([object]$Track, [bool]$AppendInstrumental, [string]$DurationHint)

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
    if ($DurationHint -and $DurationHint.Trim() -and -not (Test-HasDurationWording $full)) {
        $full += "`n`n" + $DurationHint.Trim()
    }
    return $full
}

# ---------------------------------------------------------------------------
# Lyria API  -- shared
# ---------------------------------------------------------------------------

function Resolve-ApiError {
    param($ErrorRecord)
    # Gemini returns a JSON error body. PowerShell often surfaces it in
    # ErrorDetails.Message; on 5.1 it may only be readable from the WebException's
    # response stream. Fall back to the raw exception message.
    $detail = $null
    $body = $null
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $body = $ErrorRecord.ErrorDetails.Message
        } elseif (($ErrorRecord.Exception.PSObject.Properties.Name -contains 'Response') -and $ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                if ($stream.CanSeek) { $stream.Position = 0 }
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                $reader.Dispose()
            }
        }
        if ($body) {
            $parsed = $body | ConvertFrom-Json
            # The Interactions endpoint wraps error bodies in a one-element array:
            # [{ "error": { ... } }]. Unwrap it; generateContent returns a bare object.
            if ($parsed -is [System.Array]) { $parsed = @($parsed)[0] }
            $detail = Get-Prop (Get-Prop $parsed @('error')) @('message', 'status')
        }
    } catch { }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    return $detail
}

# ---------------------------------------------------------------------------
# Lyria API  -- legacy route: models/{model}:generateContent (lyria-3-pro-*)
# ---------------------------------------------------------------------------

function Invoke-LyriaGenerateContent {
    param(
        [object]$Config, [string]$ApiKey, [string]$Model, [string]$Format,
        [string]$Prompt, [int]$TimeoutSec
    )

    $endpoint = "$(Get-ApiRoot $Config.endpointBase)/models/$($Model):generateContent"

    $bodyObj = @{ contents = @(@{ parts = @(@{ text = $Prompt }) }) }
    if ($Format -eq 'wav') {
        $bodyObj.generationConfig = @{
            responseModalities = @('AUDIO', 'TEXT')
            responseMimeType   = 'audio/wav'
        }
    }

    $json = $bodyObj | ConvertTo-Json -Depth 12
    $headers = @{ 'x-goog-api-key' = $ApiKey }

    return Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $TimeoutSec
}

function Read-GenerateContentResponse {
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

    return [pscustomobject]@{
        AudioBytes    = $audioBytes
        MimeType      = $mime
        Text          = $text
        StructureJson = $null
        Extension     = (Get-AudioExtension -Bytes $audioBytes -MimeType $mime -RequestedFormat $RequestedFormat)
    }
}

# ---------------------------------------------------------------------------
# Lyria API  -- Interactions route: POST {root}/interactions (lyria-3.5, Clip)
# ---------------------------------------------------------------------------

function Invoke-LyriaInteraction {
    param(
        [object]$Config, [string]$ApiKey, [string]$Model, [string]$Format,
        [string]$Prompt, [string[]]$ImagePaths, [int]$TimeoutSec
    )

    $root = Get-ApiRoot $Config.endpointBase
    $endpoint = "$root/interactions"
    $headers = @{ 'x-goog-api-key' = $ApiKey }

    # NB: $input is a PowerShell automatic variable -- never use it as a name.
    if ($ImagePaths -and @($ImagePaths).Count -gt 0) {
        $blocks = @()
        $blocks += @{ type = 'text'; text = $Prompt }
        foreach ($img in $ImagePaths) {
            $bytes = [System.IO.File]::ReadAllBytes($img)
            $blocks += @{
                type      = 'image'
                mime_type = (Get-ImageMimeType $img)
                data      = [Convert]::ToBase64String($bytes)
            }
        }
        $bodyObj = @{ model = $Model; input = $blocks }
    } else {
        $bodyObj = @{ model = $Model; input = $Prompt }
    }
    if ($Format -eq 'wav') {
        $bodyObj.response_format = Get-WavResponseFormat
    }

    $json = $bodyObj | ConvertTo-Json -Depth 12
    try {
        $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $TimeoutSec
    } catch {
        $msg = Resolve-ApiError $_
        if ($Format -eq 'wav' -and ($msg -match '(?i)mime type .* not supported')) {
            # The API declined WAV for this model. Say so and deliver MP3 instead
            # of failing the track; the file is named by its real bytes.
            Write-Warning "WAV is not supported for $Model ($msg). Falling back to mp3."
            $bodyObj.Remove('response_format')
            $json = $bodyObj | ConvertTo-Json -Depth 12
            $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers `
                -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $TimeoutSec
        } else {
            throw
        }
    }

    return Wait-LyriaInteraction -Config $Config -ApiKey $ApiKey -Response $resp -TimeoutSec $TimeoutSec
}

function Wait-LyriaInteraction {
    # Google's Lyria samples answer synchronously. If the API ever answers with
    # an in-progress object instead, poll GET {root}/interactions/{id} until it
    # settles. A response with no status field is treated as complete.
    param([object]$Config, [string]$ApiKey, $Response, [int]$TimeoutSec)

    $terminal = @('completed', 'failed', 'cancelled', 'canceled', 'incomplete', 'requires_action')
    $status = [string](Get-Prop $Response @('status'))
    if (-not $status -or ($terminal -contains $status.ToLowerInvariant())) { return $Response }

    $id = [string](Get-Prop $Response @('id'))
    if (-not $id) { return $Response }

    $root = Get-ApiRoot $Config.endpointBase
    $headers = @{ 'x-goog-api-key' = $ApiKey }
    $interval = [Math]::Max(1, [int]$Config.pollIntervalSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        $Response = Invoke-RestMethod -Uri "$root/interactions/$id" -Method Get -Headers $headers -TimeoutSec 60
        $status = [string](Get-Prop $Response @('status'))
        if (-not $status -or ($terminal -contains $status.ToLowerInvariant())) { return $Response }
        Write-Host ("        ... {0} ({1})" -f $status, $id) -ForegroundColor DarkGray
    }
    throw "Timed out after ${TimeoutSec}s waiting for interaction $id (last status: $status). GET $root/interactions/$id to recover it."
}

function Read-InteractionResponse {
    param($Response, [string]$RequestedFormat)

    $status = [string](Get-Prop $Response @('status'))
    if ($status -and ($status.ToLowerInvariant() -in @('failed', 'cancelled', 'canceled'))) {
        $err = Get-Prop $Response @('error')
        $msg = Get-Prop $err @('message', 'status')
        if (-not $msg) { $msg = $status }
        throw "Interaction ${status}: $msg"
    }

    $audioB64 = $null
    $mime = $null
    $texts = @()
    $jsons = @()

    foreach ($step in @(Get-Prop $Response @('steps'))) {
        $stype = [string](Get-Prop $step @('type'))
        if ($stype -and $stype -ne 'model_output') { continue }
        foreach ($block in @(Get-Prop $step @('content'))) {
            $btype = [string](Get-Prop $block @('type'))
            if ($btype -eq 'audio') {
                $d = Get-Prop $block @('data')
                if ($d) {
                    $audioB64 = [string]$d                      # last audio block wins
                    $mime = [string](Get-Prop $block @('mime_type', 'mimeType'))
                }
            } elseif ($btype -eq 'text') {
                $t = [string](Get-Prop $block @('text'))
                if ($t) {
                    if (Test-IsJsonText $t) { $jsons += $t } else { $texts += $t }
                }
            }
        }
    }

    if (-not $audioB64) {
        $oa = Get-Prop $Response @('output_audio')
        if ($oa) {
            $audioB64 = [string](Get-Prop $oa @('data'))
            $mime = [string](Get-Prop $oa @('mime_type', 'mimeType'))
        }
    }

    if (-not $audioB64) {
        $shown = if ($status) { $status } else { 'n/a' }
        $hint = ''
        if ($texts.Count -gt 0) {
            $joined = ($texts -join ' ')
            $hint = ' Text returned: ' + $joined.Substring(0, [Math]::Min(200, $joined.Length))
        }
        throw "No audio block in interaction response (status: $shown).$hint"
    }

    $audioBytes = [Convert]::FromBase64String($audioB64)
    return [pscustomobject]@{
        AudioBytes    = $audioBytes
        MimeType      = $mime
        Text          = $(if ($texts.Count) { $texts -join "`n" } else { $null })
        StructureJson = $(if ($jsons.Count) { $jsons -join "`n" } else { $null })
        Extension     = (Get-AudioExtension -Bytes $audioBytes -MimeType $mime -RequestedFormat $RequestedFormat)
    }
}

# ---------------------------------------------------------------------------
# Generation queue  (shared by markdown-parse mode and Claude-manifest mode)
# ---------------------------------------------------------------------------

function Invoke-TrackQueue {
    param(
        [object[]]$Tracks,
        [string]$OutDir,
        [string]$OutSubfolder,
        [string]$DisplayName,
        [object]$Config,
        [string]$ApiKey,
        [string]$Model,
        [string]$ApiRoute,
        [string]$Format,
        [bool]$AppendInstrumental,
        [string]$DurationHint,
        [int]$Index,
        [int]$Limit,
        [bool]$Force,
        [bool]$DryRun,
        [hashtable]$Totals
    )

    if ($OutSubfolder) { $OutDir = Join-Path $OutDir $OutSubfolder }

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

    # Images need the Interactions route. Fail before any spend.
    if ($ApiRoute -eq 'generateContent') {
        foreach ($t in @($selected)) {
            if ($t.Images -and @($t.Images).Count -gt 0) {
                throw "Track $($t.Index) has images, which require the Interactions API; model '$Model' routes to generateContent."
            }
        }
    }

    foreach ($t in $selected) {
        $num = $t.Index.ToString().PadLeft($width, '0')
        $slug = ConvertTo-Slug -Text $t.Title -MaxLength ([int]$Config.slugMaxLength)
        $baseName = "$num-$slug"
        $extras = @()
        if ($t.Lyrics) { $extras += 'lyrics' }
        if ($t.Structure) { $extras += 'structure' }
        if ($t.Images -and @($t.Images).Count -gt 0) { $extras += 'images' }
        if ($DurationHint -and -not (Test-HasDurationWording "$($t.Prompt) $($t.Structure)")) { $extras += 'hint' }
        $extraTag = if ($extras.Count) { "  [+" + ($extras -join '+') + "]" } else { '' }

        if ($DryRun) {
            Write-Host ("  [{0}] {1}" -f $num, $t.Title) -ForegroundColor White
            Write-Host ("        -> {0}.{1}   ({2} chars){3}" -f `
                $baseName, $Format, $t.Prompt.Length, $extraTag) -ForegroundColor DarkGray
            $Totals.Planned++
            continue
        }

        # Skip if audio with this base already exists (mp3/wav) unless -Force.
        # Sidecars (.txt / .structure.json) never count as existing output.
        $existing = @(Get-ChildItem -LiteralPath $OutDir -Filter "$baseName.*" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.mp3', '.wav') })
        if ($existing.Count -gt 0 -and -not $Force) {
            Write-Host ("  [{0}] SKIP (exists): {1}" -f $num, $existing[0].Name) -ForegroundColor Yellow
            $Totals.Skipped++
            continue
        }

        $fullPrompt = Build-FullPrompt -Track $t -AppendInstrumental $AppendInstrumental -DurationHint $DurationHint

        Write-Host ("  [{0}] {1}{2}" -f $num, $t.Title, $extraTag) -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $attempt = 0
        $result = $null
        while ($true) {
            $attempt++
            try {
                if ($ApiRoute -eq 'generateContent') {
                    $resp = Invoke-LyriaGenerateContent -Config $Config -ApiKey $ApiKey -Model $Model `
                        -Format $Format -Prompt $fullPrompt -TimeoutSec ([int]$Config.timeoutSeconds)
                    $result = Read-GenerateContentResponse -Response $resp -RequestedFormat $Format
                } else {
                    $resp = Invoke-LyriaInteraction -Config $Config -ApiKey $ApiKey -Model $Model `
                        -Format $Format -Prompt $fullPrompt -ImagePaths @($t.Images) `
                        -TimeoutSec ([int]$Config.timeoutSeconds)
                    $result = Read-InteractionResponse -Response $resp -RequestedFormat $Format
                }
                break
            } catch {
                $msg = Resolve-ApiError $_
                # A polling timeout is terminal: the server may still finish the
                # job, and re-posting would double-spend.
                $noRetry = ($msg -like 'Timed out after*waiting for interaction*')
                if ($noRetry -or $attempt -gt [int]$Config.maxRetries) {
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

        if ($Format -eq 'wav' -and $result.Extension -ne 'wav') {
            Write-Warning "Requested wav but the API returned $($result.Extension); saved with the real extension."
        }

        $outFile = Join-Path $OutDir "$baseName.$($result.Extension)"
        [System.IO.File]::WriteAllBytes($outFile, $result.AudioBytes)
        $sw.Stop()

        $sizeKb = [Math]::Round($result.AudioBytes.Length / 1KB, 1)
        Write-Host ("        OK  {0}  ({1} KB, {2:n1}s)" -f (Split-Path $outFile -Leaf), $sizeKb, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        $Totals.Generated++

        if ($Config.saveLyricsSidecar) {
            if ($result.Text -and -not (Test-IsStructureMarkerOnly $result.Text)) {
                $sidecar = Join-Path $OutDir "$baseName.txt"
                Set-Content -LiteralPath $sidecar -Value $result.Text -Encoding UTF8
                Write-Host ("        + lyrics sidecar: {0}" -f (Split-Path $sidecar -Leaf)) -ForegroundColor DarkGray
            }
            if ($result.StructureJson) {
                $sj = Join-Path $OutDir "$baseName.structure.json"
                Set-Content -LiteralPath $sj -Value $result.StructureJson -Encoding UTF8
                Write-Host ("        + structure sidecar: {0}" -f (Split-Path $sj -Leaf)) -ForegroundColor DarkGray
            }
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
        [object]$Config, [string]$ApiKey, [string]$Model, [string]$ApiRoute, [string]$Format,
        [bool]$AppendInstrumental, [string]$DurationHint, [string]$OutSubfolder,
        [int]$Index, [int]$Limit, [bool]$Force, [bool]$DryRun,
        [hashtable]$Totals
    )

    $lines = Get-Content -LiteralPath $File.FullName -Encoding UTF8
    $tracks = Get-TrackPrompts -Lines $lines
    $outDir = Join-Path $File.DirectoryName (Get-OutputFolderName -FileBaseName $File.BaseName)

    Invoke-TrackQueue -Tracks $tracks -OutDir $outDir -OutSubfolder $OutSubfolder -DisplayName $File.Name `
        -Config $Config -ApiKey $ApiKey -Model $Model -ApiRoute $ApiRoute -Format $Format `
        -AppendInstrumental $AppendInstrumental -DurationHint $DurationHint `
        -Index $Index -Limit $Limit -Force:$Force -DryRun:$DryRun -Totals $Totals
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
#       { "title": "Built To Be Remade", "prompt": "...", "lyrics": "...", "structure": "...",
#         "images": ["cover.jpg"] }
#     ]
#   }
# lyrics, structure and images are optional per track; prompt and title are expected.
# images (max 10) are file paths, absolute or relative to the manifest file.
# ---------------------------------------------------------------------------

function Invoke-Manifest {
    param(
        [string]$ManifestPath,
        [object]$Config, [string]$ApiKey, [string]$Model, [string]$ApiRoute, [string]$Format,
        [bool]$AppendInstrumental, [string]$DurationHint, [string]$OutSubfolder,
        [int]$Index, [int]$Limit, [bool]$Force, [bool]$DryRun,
        [hashtable]$Totals
    )

    $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
    $mf = $raw | ConvertFrom-Json
    $mfDir = Split-Path -Parent $ManifestPath

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

        # Images: validate now, before any request is made.
        $imgList = @()
        $imgs = Get-Prop $mt @('images')
        if ($imgs) {
            foreach ($ip in @($imgs)) {
                $p = "$ip"
                if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $mfDir $p }
                if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Manifest track $n image not found: $p" }
                [void](Get-ImageMimeType $p)
                $imgList += (Resolve-Path -LiteralPath $p).Path
            }
            if ($imgList.Count -gt 10) { throw "Manifest track $n has $($imgList.Count) images; Lyria accepts at most 10." }
        }

        [void]$tracks.Add([pscustomobject]@{
            Index     = $n
            Title     = $(if ($title) { "$title" } else { "track-$n" })
            Tagline   = $null
            Prompt    = "$prompt".Trim()
            Lyrics    = $(if ($lyr -and "$lyr".Trim()) { "$lyr".Trim() } else { $null })
            Structure = $(if ($str -and "$str".Trim()) { "$str".Trim() } else { $null })
            Images    = $imgList
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

    Invoke-TrackQueue -Tracks $tracks -OutDir $outDir -OutSubfolder $OutSubfolder -DisplayName $display `
        -Config $Config -ApiKey $ApiKey -Model $Model -ApiRoute $ApiRoute -Format $Format `
        -AppendInstrumental $AppendInstrumental -DurationHint $DurationHint `
        -Index $Index -Limit $Limit -Force:$Force -DryRun:$DryRun -Totals $Totals
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$config = Get-LyraConfig -ConfigPath $ConfigPath

$effModel = if ($Model) { $Model } elseif ($Clip) { [string]$config.clipModel } else { [string]$config.model }
$effFormat = if ($Format) { $Format } else { [string]$config.outputFormat }
if ($Clip -and $effFormat -eq 'wav') {
    Write-Warning 'The Clip model returns MP3 only; using mp3.'
    $effFormat = 'mp3'
}
$apiRoute = Resolve-ApiRoute -ApiMode ([string]$config.apiMode) -Model $effModel
$appendInstrumental = [bool]$Instrumental -or [bool]$config.instrumentalByDefault
$durationHint = if ($Clip) { '' } else { [string]$config.defaultDurationHint }
$outSubfolder = if ($Clip) { [string]$config.clipSubfolder } else { '' }

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
$clipLabel = if ($Clip) { '   Clip: ON (30s previews)' } else { '' }
Write-Host "Lyra Producer" -ForegroundColor Magenta
Write-Host ("Model: {0}   API: {1}   Format: {2}   Input: {3}   Mode: {4}{5}" -f `
    $effModel, $apiRoute, $effFormat, $modeLabel, ($(if ($DryRun) { 'DRY-RUN' } else { 'GENERATE' })), $clipLabel) -ForegroundColor DarkGray

$totals = @{ Planned = 0; Generated = 0; Skipped = 0; Failed = 0 }

$common = @{
    Config = $config; ApiKey = $effKey; Model = $effModel; ApiRoute = $apiRoute; Format = $effFormat
    AppendInstrumental = $appendInstrumental; DurationHint = $durationHint; OutSubfolder = $outSubfolder
    Index = $Index; Limit = $Limit; Force = [bool]$Force; DryRun = [bool]$DryRun; Totals = $totals
}

if ($Manifest) {
    $mfPath = (Resolve-Path -LiteralPath $Manifest).Path
    Invoke-Manifest -ManifestPath $mfPath @common
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
        Invoke-MarkdownFile -File $f @common
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host ("Dry run complete. {0} track(s) would be generated." -f $totals.Planned) -ForegroundColor Magenta
} else {
    Write-Host ("Done. Generated: {0}  Skipped: {1}  Failed: {2}" -f `
        $totals.Generated, $totals.Skipped, $totals.Failed) -ForegroundColor Magenta
}
