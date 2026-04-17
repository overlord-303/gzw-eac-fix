# gzw-eac-fix

Automatically applies the EAC cache fix for **Gray Zone Warfare** on Linux after each Steam update.

After an update, EAC leaves two stale cache files that prevent the game from launching. The fix is to delete them, let Steam verify and restore them, then lock them read-only. This repo automates that via a background watcher registered with your init system.

## Requirements

- Steam installed (native or Flatpak)
- Gray Zone Warfare installed
- `inotify-tools` - only required for non-systemd init systems

## Install

```bash
git clone https://github.com/youruser/gzw-eac-fix.git
cd gzw-eac-fix
bash setup.sh
```

`setup.sh` will:
- Auto-detect your Steam install and GZW location (including Flatpak and custom library paths)
- Substitute all configuration into the installed scripts
- Register a watcher appropriate for your init system
- Run an initial fix immediately so the game is ready to launch right away

## Expected output (systemd)

```
$> bash setup.sh
[gzw-eac-fix] Found manifest: /home/user/.local/share/Steam/steamapps/appmanifest_2479810.acf
[gzw-eac-fix] Installing scripts to /home/user/.local/share/gzw-eac-fix...
[gzw-eac-fix]   Installed fix.sh
[gzw-eac-fix]   Installed watch.sh
[gzw-eac-fix] Detected init system: systemd
[gzw-eac-fix]   Installed gzw-eac-fix.path
[gzw-eac-fix]   Installed gzw-eac-fix.service
Created symlink '/home/user/.config/systemd/user/default.target.wants/gzw-eac-fix.path' → '/home/user/.config/systemd/user/gzw-eac-fix.path'.
[gzw-eac-fix] systemd path watcher enabled.
● gzw-eac-fix.path - Watch for Gray Zone Warfare updates
     Loaded: loaded (/home/user/.config/systemd/user/gzw-eac-fix.path; enabled; preset: enabled)
     Active: active (waiting) since Fri 2026-04-17 14:20:13 CEST; 5ms ago
   Triggers: ● gzw-eac-fix.service
[gzw-eac-fix] Logs: journalctl --user -u gzw-eac-fix.service
[gzw-eac-fix]       or: /home/user/.local/share/gzw-eac-fix/gzw-eac-fix.log
[gzw-eac-fix] Setup complete.
[gzw-eac-fix] Running initial fix...
[gzw-eac-fix] GZW found at: /home/user/.local/share/Steam/steamapps/common/Gray Zone Warfare/GZW/Content/SKALLA/PrebuildWorldData/World/cache
[gzw-eac-fix] No previous state - running fix and recording baseline.
[gzw-eac-fix] Flushing disk before delete...
[gzw-eac-fix] Removing EAC cache files...
[gzw-eac-fix]   Removed: 0xb9af63cee2e43b6c_0x3cb3b3354fb31606.dat
[gzw-eac-fix]   Removed: 0xaf497c273f87b6e4_0x7a22fc105639587d.dat
[gzw-eac-fix] Triggering Steam verify integrity (app 2479810)...
[gzw-eac-fix] Waiting for Steam to restore files...
[gzw-eac-fix]   Restored: 0xb9af63cee2e43b6c_0x3cb3b3354fb31606.dat
[gzw-eac-fix]   Restored: 0xaf497c273f87b6e4_0x7a22fc105639587d.dat
[gzw-eac-fix] Flushing disk after restore...
[gzw-eac-fix] Setting files read-only...
[gzw-eac-fix]   chmod 400: 0xb9af63cee2e43b6c_0x3cb3b3354fb31606.dat
[gzw-eac-fix]   chmod 400: 0xaf497c273f87b6e4_0x7a22fc105639587d.dat
[gzw-eac-fix] Done.
```

After this completes the game is ready to launch.

## How it works

1. Steam rewrites `appmanifest_2479810.acf` when an update completes.
2. The watcher detects the change and calls `fix.sh`.
3. `fix.sh` computes a fingerprint from the `buildid` + all `InstalledDepots` manifest IDs. If unchanged since the last run it exits early - prevents spurious runs from non-update manifest writes.
4. If an update is confirmed: `sync`, delete the two EAC cache files, trigger `steam://validate/` to restore them, `sync` again, then `chmod 400` both.

## Supported init systems

| Init system | Mechanism |
|-------------|-----------|
| **systemd** | `.path` unit - event-driven, no polling |
| **OpenRC** | XDG autostart + `inotifywait` loop |
| **runit** | User sv service + `inotifywait` loop |
| **s6** | User sv service + `inotifywait` loop |
| **Other** | XDG autostart + `inotifywait` loop |

## Configuration

All options live at the top of `setup.sh`. Re-run `setup.sh` to apply any changes.

| Option | Default | Description |
|--------|---------|-------------|
| `NOTIFY` | `false` | Desktop notifications via `notify-send` |
| `LOG_MAX_LINES` | `200` | Max lines retained in the log file |
| `POLL_INTERVAL` | `3` | Seconds between file-exists checks during Steam verify |
| `POST_RESTORE_WAIT` | `2` | Seconds to wait after files reappear before `chmod` |

## Files installed

```
~/.local/share/gzw-eac-fix/
   fix.sh                # fix logic, config baked in at install time
   watch.sh              # inotifywait loop - non-systemd only
   gzw-eac-fix.log       # appended on every run
   .last_known_state     # build fingerprint for update detection
   log/                  # svlogd log dir - runit only
```

## Logs

```bash
# systemd
journalctl --user -u gzw-eac-fix.service

# all init systems
tail -f ~/.local/share/gzw-eac-fix/gzw-eac-fix.log
```

## Uninstall

```bash
bash uninstall.sh
```

Detects and removes everything that was created by `setup.sh` - unit files, autostart entries, sv directories, and the install directory.

## Repository structure

```
gzw-eac-fix/
   README.md
   setup.sh        # install - edit this to configure
   uninstall.sh    # removes everything setup.sh created
   scripts/
      fix.sh        # EAC fix logic (@@TOKEN@@ placeholders, substituted at install)
      watch.sh      # inotifywait watcher (non-systemd only)
   init/
      systemd/
         gzw-eac-fix.path
         gzw-eac-fix.service
      openrc/
         gzw-eac-fix.desktop
      runit/
         run
         log/run
      s6/
         run
```
