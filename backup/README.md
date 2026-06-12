# Server Backup (incremental + scheduled)

This module turns DiscordChatExporter into an **automatic, incremental, whole-server
archiver**. It exports an entire Discord server as an on-disk folder tree and keeps it
up to date on a schedule — hourly, daily, weekly, or monthly — either on your Windows
machine or headless on a server.

It is a thin, self-contained layer on top of the existing `DiscordChatExporter.Cli`
(no extra database or language runtime). It replaces the need for separate community
wrappers by driving the CLI directly.

## What you get

| Goal | How |
|------|-----|
| Export the **whole server with file structure** | `exportguild` + output template `%G/%T/%C` → `Server/Category/Channel/...` |
| **Only new data** each run (no re-downloading) | Per-guild state file + the CLI's `--after` option |
| **Scheduled** hourly/daily/weekly/monthly | Windows Task Scheduler *or* the bundled Docker cron container |
| **Auto-download onto a server for backup** | Docker container writes to a mounted volume + optional `rclone` push to cloud/remote |
| Media (avatars, images, files) | `--media --reuse-media` with a stable per-guild media dir |
| Threads & forum posts | `--include-threads all` |

### How "incremental" works
- **First run** for a server → full history is exported.
- The timestamp of each successful run is saved in `state/state.json`, keyed by guild ID.
- **Next run** passes that timestamp to `--after`, so only messages newer than the last
  run are fetched.
- Each run writes into its own timestamped files, so nothing is ever overwritten — you
  get a complete, append-only archive made of dated slices.
- If a run fails, its guild's timestamp is **not** advanced, so the next run retries the
  same window (no gaps).

> Output format defaults to **Json** — it's the most useful for backups because the dated
> slices can be merged and browsed later (e.g. with
> [DiscordChatExporter-frontend](https://github.com/slatinsky/DiscordChatExporter-frontend),
> a Discord-like viewer for these JSON exports). Switch to `HtmlDark` in the config if you
> prefer self-contained readable pages instead.

---

## Files

```
backup/
├─ config.example.json      # copy to config.json and edit
├─ scripts/
│  ├─ Invoke-Backup.ps1      # Windows runner (Task Scheduler)
│  └─ backup.sh              # Linux/macOS/Docker runner
├─ docker/
│  ├─ Dockerfile             # builds the CLI from THIS fork + cron + rclone
│  ├─ docker-compose.yml     # one-command self-hosted deploy
│  ├─ entrypoint.sh          # runs backup, then schedules it via cron
│  └─ .env.example           # token + schedule
└─ README.md                 # this file
```

---

## 1. Get your inputs

**Token** — see the project's `guide` command or the wiki on obtaining a token.
**Guild IDs** — list servers you can access:

```
DiscordChatExporter.Cli guilds -t YOUR_TOKEN
```

Copy the config and fill it in:

```
# from the backup/ folder
cp config.example.json config.json
```

Edit `config.json`: put your guild ID(s) in `guilds`. Leave `token` empty and supply it
via the `DCE_TOKEN` environment variable if you'd rather not store it in the file.

---

## 2A. Run it on Windows (Task Scheduler)

You need `DiscordChatExporter.Cli.exe`. Either download a release or build it:

```powershell
dotnet publish DiscordChatExporter.Cli -c Release -o C:\Tools\DCE
```

Point `cliPath` in `config.json` at that `DiscordChatExporter.Cli.exe` (or set `DCE_CLI`).

Test a single run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-Backup.ps1
```

Schedule it (example: **hourly**). Run in an elevated PowerShell, adjust the path:

```powershell
$script = "C:\Users\steve\DiscordChatExporter\backup\scripts\Invoke-Backup.ps1"
schtasks /Create /SC HOURLY /TN "DCE Server Backup" `
  /TR "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`""
```

Other cadences: `/SC DAILY /ST 03:00`, `/SC WEEKLY /D SUN /ST 03:00`,
`/SC MONTHLY /D 1 /ST 03:00`.

To keep the token out of the config file, set it once for the task's account:
`setx DCE_TOKEN "your-token"` (then recreate the task so it inherits the variable).

---

## 2B. Run it on a server (Docker — recommended for "always-on" backup)

This builds an image from **your fork's** CLI, runs the backup immediately, then keeps
running it on a cron schedule, writing to a folder on the host. Optionally it pushes to
cloud/remote storage with `rclone`.

```bash
cd backup
cp config.example.json config.json     # edit guild IDs; leave token empty
cd docker
cp .env.example .env                    # set DCE_TOKEN and CRON_SCHEDULE
docker compose up -d --build
```

- Backups appear in `backup/docker/dce-data/exports/` on the host
  (change with `BACKUP_DATA_DIR` in `.env`).
- Logs: `docker compose logs -f` or `backup/docker/dce-data/logs/`.
- Change the schedule by editing `CRON_SCHEDULE` in `.env`, then
  `docker compose up -d` again.

**Schedules** (UTC unless you change `TZ`):

| Cadence | `CRON_SCHEDULE` |
|---------|-----------------|
| Hourly  | `0 * * * *` |
| Daily 03:00 | `0 3 * * *` |
| Weekly Sun 03:00 | `0 3 * * 0` |
| Monthly 1st 03:00 | `0 3 1 * *` |

### Push backups to remote/cloud storage (optional)
Set up an [rclone](https://rclone.org) remote (S3, Backblaze, Google Drive, an SFTP box,
etc.), then in `config.json`:

```json
"remote": { "enabled": true, "rcloneRemote": "mybackup:discord-archive" }
```

After each run the exports are copied to that remote. (On the host/Windows path, just make
sure `rclone` is installed and configured; it's already in the Docker image.)

---

## Config reference (`config.json`)

| Key | Meaning | Default |
|-----|---------|---------|
| `token` | Discord token. Or set `DCE_TOKEN` env var instead. | — |
| `cliPath` | Path to the CLI (host runs only; ignored in Docker). | `DiscordChatExporter.Cli.exe` |
| `outputRoot` | Root folder for the exported tree. | `./exports` |
| `format` | `Json`, `HtmlDark`, `HtmlLight`, `PlainText`, `Csv`. | `Json` |
| `downloadMedia` | Download avatars/images/attachments. | `true` |
| `includeThreads` | `none`, `active`, or `all`. | `all` |
| `includeVoice` | Include voice channels' text. | `true` |
| `guilds` | Array of server IDs to back up. | — |
| `remote.enabled` | rclone push after each run. | `false` |
| `remote.rcloneRemote` | rclone destination, e.g. `s3:bucket/path`. | — |

Environment overrides: `DCE_TOKEN`, `DCE_CLI`, `DCE_CONFIG`, `DCE_OUTPUT_ROOT`,
`DCE_STATE_DIR`, `DCE_LOG_DIR`.

---

## Bonus: extract & download the links inside exports

`scripts/Extract-DiscordLinks.ps1` scans a folder of exports and pulls every external
link into categorized lists, ready for bulk downloading:

```powershell
.\scripts\Extract-DiscordLinks.ps1 -Root "C:\path\to\exported server" -Crawljob -IncludeJson
```

Writes to `<Root>\_LINKS\`:

| File | What |
|------|------|
| `MASTER-filehost-links.txt` | Mega, Google Drive, GoFile, OneDrive, Dropbox, MediaFire, WeTransfer… (the real files) |
| `MASTER-video-links.txt` | YouTube / video links |
| `MASTER-discord-attachments.txt` | Files uploaded straight to Discord (newer ones use signed URLs and may be expired) |
| `MASTER-webpage-links.txt` | Everything else (reference) |
| `MASTER-ALL-links.txt` | Combined |
| `SUMMARY.txt` | Counts + per-host breakdown |
| `filehosts.crawljob` | Drop into JDownloader's `folderwatch` folder to auto-queue the file hosts |
| `download-videos.cmd` | Runs `yt-dlp` over the video list |

**Downloading:**
- **File hosts → [JDownloader 2](https://jdownloader.org)** — paste `MASTER-filehost-links.txt`
  (auto-grabbed from clipboard) or drop `filehosts.crawljob` into its `folderwatch` folder.
  JDownloader surfaces Mega/Drive captchas, manages the free-Mega ~5 GB/day quota, and resumes.
- **Videos → [yt-dlp](https://github.com/yt-dlp/yt-dlp)** — run `download-videos.cmd`, or:
  `yt-dlp -a "<_LINKS>\MASTER-video-links.txt" -o "...\%(title)s.%(ext)s" -i`
- **WeTransfer (`we.tl`) links expire after 7 days** — old ones are already dead.

In the GUI, the **link icon** in the top bar runs this for any folder you pick.

## Notes & caveats

- **Terms of Service.** Automating exports with a **user token** is against Discord's ToS
  and can put the account at risk. Prefer a **bot token** on servers where the bot is a
  member. Use this on data you're allowed to archive.
- **First run can be large** — it pulls full history. Subsequent runs are small deltas.
- **`state/`, `logs/`, `exports/`, `config.json`, and `.env` are gitignored** so you never
  commit your token or your archive.
- **Reset a server to full re-export:** delete its entry from `state/state.json`.
