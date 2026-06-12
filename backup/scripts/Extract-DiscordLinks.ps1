<#
.SYNOPSIS
    Scan DiscordChatExporter exports and build categorized link lists for bulk downloading.

.DESCRIPTION
    Recursively scans a folder of exports (HTML, optionally JSON), pulls every external
    link, de-duplicates, and sorts them into:
        MASTER-filehost-links.txt        Mega, Google Drive, GoFile, OneDrive, Dropbox, etc. (the real files)
        MASTER-video-links.txt           YouTube / video links (feed to yt-dlp)
        MASTER-discord-attachments.txt   Files uploaded straight to Discord (may be expired)
        MASTER-webpage-links.txt         Everything else (reference)
        MASTER-ALL-links.txt             Everything combined
        SUMMARY.txt                      Counts + per-host breakdown
    Optionally writes a JDownloader '.crawljob' so JDownloader's Folder Watch auto-imports
    the file-host links, and a 'download-videos.cmd' that runs yt-dlp over the video list.

    Asset sub-folders ('*_Files') are skipped so saved page assets don't pollute the lists.

.EXAMPLE
    .\Extract-DiscordLinks.ps1 -Root "C:\Users\steve\Desktop\Demi Discord Download"

.EXAMPLE
    .\Extract-DiscordLinks.ps1 -Root "...\Demi Discord Download" -Crawljob -IncludeJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Root,

    # Where the link lists are written. Default: <Root>\_LINKS
    [string]$OutDir,

    # Where downloaded files should land (used in the crawljob / yt-dlp command).
    [string]$DownloadRoot,

    # Also scan .json exports.
    [switch]$IncludeJson,

    # Write a JDownloader Folder-Watch .crawljob for the file-host links.
    [switch]$Crawljob,

    # JDownloader Folder-Watch directory (where .crawljob files are dropped).
    [string]$JDownloaderWatchDir
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Root)) { throw "Root folder not found: $Root" }
$Root = (Resolve-Path -LiteralPath $Root).Path
if (-not $OutDir)       { $OutDir = Join-Path $Root '_LINKS' }
if (-not $DownloadRoot) { $DownloadRoot = Join-Path $Root '_Downloads' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---- Gather source files (skip the *_Files asset folders) -------------------
$patterns = @('*.html')
if ($IncludeJson) { $patterns += '*.json' }

$sourceFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Include $patterns |
    Where-Object { $_.FullName -notmatch '_Files[\\/]' }

Write-Host "Scanning $($sourceFiles.Count) export file(s) under:`n  $Root`n"

# ---- Extract URLs -----------------------------------------------------------
$hrefRegex = [regex]'(?i)href\s*=\s*"([^"]+)"'
$bareRegex = [regex]'(?i)\bhttps?://[^\s"''<>\)\]]+'

$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$urls = New-Object System.Collections.Generic.List[string]

function Add-Url([string]$u) {
    if ([string]::IsNullOrWhiteSpace($u)) { return }
    $u = [System.Net.WebUtility]::HtmlDecode($u).Trim()
    # Strip trailing punctuation that often clings to URLs in prose
    $u = $u -replace '[.,;:!]+$', ''
    $u = $u.TrimEnd(')', ']', '}', '"', "'")
    if ($u -notmatch '^(?i)https?://') { return }
    if ($seen.Add($u)) { $urls.Add($u) }
}

# Read with shared access so files open in a browser/editor don't block the scan
function Read-FileShared([string]$path) {
    $fs = [System.IO.FileStream]::new(
        $path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    try {
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8, $true)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
}

foreach ($f in $sourceFiles) {
    try { $text = Read-FileShared $f.FullName }
    catch { Write-Warning "Skipped (unreadable): $($f.Name) -- $($_.Exception.Message)"; continue }
    foreach ($m in $hrefRegex.Matches($text)) { Add-Url $m.Groups[1].Value }
    foreach ($m in $bareRegex.Matches($text)) { Add-Url $m.Value }
}

# ---- Categorize -------------------------------------------------------------
# Noise we never want in any list (Discord chrome, emojis, avatars, invites, gifs)
$noise = @(
    'discord\.com/channels', 'discord\.gg/', 'discordapp\.com/(emojis|avatars|icons|stickers|role-icons|app-assets|banners|guilds)',
    'cdn\.discordapp\.com/(emojis|avatars|icons|stickers|role-icons|app-assets|banners|guild)',
    # Discord image/link proxies embed the target URL in their path -> exclude so they
    # don't get mis-filed as the real file host (the real link is captured separately).
    'images-ext-\d*\.discordapp\.net', 'media\.discordapp\.net/external', 'images\.discordapp\.net',
    # Host static assets (css/icons), not actual files
    'static\.mediafire\.com', 'cms\d*\.mega\.nz',
    'tenor\.com', 'giphy\.com', 'fonts\.g(static|oogleapis)\.com', 'w3\.org', 'schema\.org'
)
$filehost = @(
    'mega\.(nz|co\.nz|io)', 'drive\.google\.com', 'drive\.usercontent\.google\.com', 'gofile\.io',
    '1drv\.ms', 'onedrive\.live\.com', '[-\w]+-my\.sharepoint\.com', 'dropbox\.com', 'db\.tt',
    'we\.tl', 'wetransfer\.com', 'mediafire\.com', 'pixeldrain\.com', '1fichier\.com', 'anonfiles',
    'krakenfiles\.com', 'send\.cm', 'sendspace\.com', 'files\.fm', 'zippyshare', 'terabox|teraboxapp',
    'box\.com', 'icedrive\.net', 'pcloud\.(com|link)', 'catbox\.moe', 'litterbox\.catbox', 'workupload\.com',
    'filen\.io', 'bayfiles', 'uploadhaven', 'racaty', 'userscloud', 'filefactory', 'turbobit', 'nitroflare'
)
$video = @('youtube\.com/(watch|shorts|playlist)', 'youtu\.be/', 'vimeo\.com/\d', 'streamable\.com',
           'dailymotion\.com/video', 'rumble\.com/v', 'twitch\.tv/videos')
$discordFiles = @('cdn\.discordapp\.com/attachments', 'media\.discordapp\.net/attachments')

function Test-Any([string]$u, [string[]]$pats) {
    foreach ($p in $pats) { if ($u -match $p) { return $true } }
    return $false
}

$catFilehost = New-Object System.Collections.Generic.List[string]
$catVideo    = New-Object System.Collections.Generic.List[string]
$catDiscord  = New-Object System.Collections.Generic.List[string]
$catWebpage  = New-Object System.Collections.Generic.List[string]

foreach ($u in $urls) {
    if (Test-Any $u $noise)         { continue }
    if (Test-Any $u $filehost)      { $catFilehost.Add($u); continue }
    if (Test-Any $u $video)         { $catVideo.Add($u);    continue }
    if (Test-Any $u $discordFiles)  { $catDiscord.Add($u);  continue }
    $catWebpage.Add($u)
}

# ---- Write lists ------------------------------------------------------------
function Save-List($list, [string]$name) {
    $path = Join-Path $OutDir $name
    ($list | Sort-Object -Unique) -join "`r`n" | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

$pFile  = Save-List $catFilehost 'MASTER-filehost-links.txt'
$pVid   = Save-List $catVideo    'MASTER-video-links.txt'
$pDisc  = Save-List $catDiscord  'MASTER-discord-attachments.txt'
$pWeb   = Save-List $catWebpage  'MASTER-webpage-links.txt'
$pAll   = Save-List ($catFilehost + $catVideo + $catDiscord + $catWebpage) 'MASTER-ALL-links.txt'

# ---- Per-host breakdown for the file-host list ------------------------------
function Get-Host2([string]$u) { try { ([uri]$u).Host -replace '^www\.', '' } catch { 'unknown' } }
$hostBreakdown = $catFilehost |
    ForEach-Object { Get-Host2 $_ } |
    Group-Object | Sort-Object Count -Descending |
    ForEach-Object { '{0,5}  {1}' -f $_.Count, $_.Name }

$summary = @(
    "DiscordChatExporter link extraction"
    "Root : $Root"
    "Files scanned : $($sourceFiles.Count)"
    ""
    "File-host links     : $($catFilehost.Count)   -> MASTER-filehost-links.txt"
    "Video links         : $($catVideo.Count)   -> MASTER-video-links.txt"
    "Discord attachments : $($catDiscord.Count)   -> MASTER-discord-attachments.txt  (may be expired)"
    "Webpage links       : $($catWebpage.Count)   -> MASTER-webpage-links.txt"
    "TOTAL unique        : $($catFilehost.Count + $catVideo.Count + $catDiscord.Count + $catWebpage.Count)"
    ""
    "File-host breakdown (count  host):"
) + $hostBreakdown
$pSum = Join-Path $OutDir 'SUMMARY.txt'
$summary -join "`r`n" | Set-Content -LiteralPath $pSum -Encoding UTF8

# ---- Optional: JDownloader crawljob for the file-host links -----------------
if ($Crawljob -and $catFilehost.Count -gt 0) {
    $links = ($catFilehost | Sort-Object -Unique) -join '\n'
    $job = @"
[
  {
    "packageName": "Demi Discord - filehosts",
    "text": "$links",
    "downloadFolder": "$($DownloadRoot -replace '\\','\\')",
    "autoConfirm": "TRUE",
    "autoStart": "TRUE",
    "overwritePackagizerEnabled": "TRUE"
  }
]
"@
    $jobLocal = Join-Path $OutDir 'filehosts.crawljob'
    $job | Set-Content -LiteralPath $jobLocal -Encoding UTF8
    if ($JDownloaderWatchDir -and (Test-Path -LiteralPath $JDownloaderWatchDir)) {
        Copy-Item -LiteralPath $jobLocal -Destination (Join-Path $JDownloaderWatchDir 'demi-filehosts.crawljob') -Force
        Write-Host "Crawljob copied to JDownloader Folder Watch: $JDownloaderWatchDir"
    } else {
        Write-Host "Crawljob written: $jobLocal  (drop it into JDownloader's 'folderwatch' folder, or just paste the links into JDownloader)"
    }
}

# ---- Optional: a ready yt-dlp command --------------------------------------
if ($catVideo.Count -gt 0) {
    $videoOut = Join-Path $DownloadRoot '_Videos'
    $cmd = "yt-dlp -a `"$pVid`" -o `"$videoOut\%(title)s.%(ext)s`" --download-archive `"$videoOut\.downloaded.txt`" -i"
    $cmdFile = Join-Path $OutDir 'download-videos.cmd'
    "@echo off`r`nmd `"$videoOut`" 2>nul`r`n$cmd`r`npause" | Set-Content -LiteralPath $cmdFile -Encoding ASCII
}

# ---- Report -----------------------------------------------------------------
Write-Host ""
Write-Host "==================== RESULTS ===================="
Get-Content -LiteralPath $pSum | Write-Host
Write-Host "================================================="
Write-Host "Lists written to: $OutDir"
