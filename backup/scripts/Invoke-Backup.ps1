<#
.SYNOPSIS
    Incremental Discord server backup driver for Windows (Task Scheduler friendly).

.DESCRIPTION
    First run for a guild   -> full history export.
    Every run after that    -> only messages newer than the last successful run,
                               using DiscordChatExporter's --after option.

    Output is written as a folder tree:
        <outputRoot>\<Server>\<Category>\<Channel>\<Channel>_<timestamp>.<ext>
    Each run is timestamped so nothing is ever overwritten.

.PARAMETER ConfigPath
    Path to config.json. Defaults to ..\config.json next to this script,
    or the DCE_CONFIG environment variable.

.PARAMETER CliPath
    Path to DiscordChatExporter.Cli.exe. Falls back to DCE_CLI env var, then
    cliPath in config, then "DiscordChatExporter.Cli.exe" on PATH.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Backup.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$CliPath
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupDir = Split-Path -Parent $ScriptDir

if (-not $ConfigPath) {
    $ConfigPath = if ($env:DCE_CONFIG) { $env:DCE_CONFIG } else { Join-Path $BackupDir 'config.json' }
}
$StateDir = if ($env:DCE_STATE_DIR) { $env:DCE_STATE_DIR } else { Join-Path $BackupDir 'state' }
$LogDir   = if ($env:DCE_LOG_DIR)   { $env:DCE_LOG_DIR }   else { Join-Path $BackupDir 'logs' }
$StateFile = Join-Path $StateDir 'state.json'

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir   | Out-Null

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath  (copy config.example.json to config.json)" }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not $CliPath) {
    if     ($env:DCE_CLI) { $CliPath = $env:DCE_CLI }
    elseif ($cfg.cliPath) { $CliPath = $cfg.cliPath }
    else                  { $CliPath = 'DiscordChatExporter.Cli.exe' }
}

$token = if ($env:DCE_TOKEN) { $env:DCE_TOKEN } elseif ($cfg.token) { $cfg.token } else { $null }
if (-not $token -or $token -eq 'YOUR_DISCORD_TOKEN_HERE') {
    throw "No token. Set the DCE_TOKEN environment variable or 'token' in config.json."
}

$outputRoot = if ($cfg.outputRoot) { $cfg.outputRoot } else { Join-Path $BackupDir 'exports' }
if (-not [System.IO.Path]::IsPathRooted($outputRoot)) { $outputRoot = Join-Path $BackupDir $outputRoot }
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$outputRoot = (Resolve-Path $outputRoot).Path

$format  = if ($cfg.format) { $cfg.format } else { 'Json' }
$media   = if ($null -ne $cfg.downloadMedia) { [bool]$cfg.downloadMedia } else { $true }
$threads = if ($cfg.includeThreads) { $cfg.includeThreads } else { 'all' }
$vc      = if ($null -ne $cfg.includeVoice) { [bool]$cfg.includeVoice } else { $true }

$ext = switch ($format) {
    'Json'      { 'json' }
    'HtmlDark'  { 'html' }
    'HtmlLight' { 'html' }
    'PlainText' { 'txt'  }
    'Csv'       { 'csv'  }
    default     { 'dat'  }
}

$runStamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd_HHmmss')
$nowIso   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$log      = Join-Path $LogDir "backup-$runStamp.log"

# Load state (guildId -> last successful run timestamp) into a hashtable
if (-not (Test-Path $StateFile)) { '{}' | Set-Content -Path $StateFile -Encoding utf8 }
$stateRaw = Get-Content $StateFile -Raw
$state = @{}
if (-not [string]::IsNullOrWhiteSpace($stateRaw)) {
    $obj = $stateRaw | ConvertFrom-Json
    foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value }
}

if (-not $cfg.guilds -or $cfg.guilds.Count -eq 0) { throw "config.guilds is empty." }

"=== DiscordChatExporter incremental backup ===" | Tee-Object -FilePath $log -Append
"run: $runStamp   format: $format   guilds: $($cfg.guilds.Count)   output: $outputRoot" | Tee-Object -FilePath $log -Append

# Native CLI emits to stderr; don't let that terminate the script.
$ErrorActionPreference = 'Continue'
$overall = 0

foreach ($guild in $cfg.guilds) {
    $guild = "$guild"
    $last  = if ($state.ContainsKey($guild)) { $state[$guild] } else { $null }
    "==> Guild $guild  (since: $(if ($last) { $last } else { 'FULL HISTORY' }))" | Tee-Object -FilePath $log -Append

    $outTemplate = Join-Path $outputRoot "%G\%T\%C\%C_$runStamp.$ext"
    $cliArgs = @('exportguild','-t',$token,'-g',$guild,'-f',$format,'-o',$outTemplate,
                 '--include-threads',$threads,'--include-vc',("$vc".ToLower()),'--fuck-russia')
    if ($media) {
        $mediaDir = Join-Path $outputRoot "_media\guild-$guild\"
        $cliArgs += @('--media','--reuse-media','--media-dir',$mediaDir)
    }
    if ($last) { $cliArgs += @('--after',$last) }

    & $CliPath @cliArgs 2>&1 | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -eq 0) {
        $state[$guild] = $nowIso
        "    OK - state advanced to $nowIso" | Tee-Object -FilePath $log -Append
    } else {
        "    ERROR exporting guild $guild (exit $LASTEXITCODE; state NOT advanced)" | Tee-Object -FilePath $log -Append
        $overall = 1
    }
}

# Persist state
($state | ConvertTo-Json -Depth 5) | Set-Content -Path $StateFile -Encoding utf8

# Optional remote sync via rclone
if ($cfg.remote -and $cfg.remote.enabled -eq $true) {
    $remote = $cfg.remote.rcloneRemote
    if ($remote -and (Get-Command rclone -ErrorAction SilentlyContinue)) {
        "==> Syncing to remote: $remote" | Tee-Object -FilePath $log -Append
        & rclone copy $outputRoot $remote 2>&1 | Tee-Object -FilePath $log -Append
        if ($LASTEXITCODE -ne 0) { $overall = 1 }
    } else {
        "WARN: remote.enabled=true but rclone missing or remote unset." | Tee-Object -FilePath $log -Append
    }
}

"=== done (exit $overall) ===" | Tee-Object -FilePath $log -Append
exit $overall
