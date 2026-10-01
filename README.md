# PHPSwitcher

A menu bar app for macOS that switches the Homebrew PHP version — both the CLI link and
the running php-fpm service — in one click. It does the same for Homebrew MySQL (the `mysql`
CLI link and the running mysqld).

The menu bar shows an elephant and nothing else. Its appearance carries the state:

- solid (adapts to light/dark) — CLI and FPM are on the same version
- orange — they disagree, or FPM is stopped; or MySQL is installed and its CLI and server
  disagree, or the server is stopped
- dimmed — a switch is running

Hover for a tooltip with both exact versions; the menu header shows them too.

The artwork is `Resources/elephant.svg`, a hand-drawn silhouette used as a template image
(macOS 13+ loads SVG into `NSImage` directly, so there is no generated PNG to keep in sync).

## Build

```sh
./build.sh              # produces ./PHPSwitcher.app
./build.sh --install    # also copies it to /Applications
open PHPSwitcher.app
```

Requires macOS 13+ and Xcode command line tools. The app is ad-hoc signed and **not**
sandboxed — it has to exec `brew` and `launchctl`.

## Menu

- **Version list** — every php keg under `$(brew --prefix)/Cellar`. A checkmark means that
  version is both linked and serving; a dash means only one of the two matches.
- **MySQL section** — shown when any `mysql`/`mysql@x.y` keg is installed. A header with the
  linked CLI and running server versions, then one item per keg (same checkmark/dash rule as PHP;
  the tooltip shows each keg's data folder and version), then **Copy Database to 8.4 ▸** and
  **Restart MySQL**.
- **Restart FPM** — `brew services restart <current>`.
- **Restart nginx** — `brew services restart nginx`. Only shown when nginx is installed via Homebrew.
- **Refresh** — re-detects immediately (it also re-detects every 10s and whenever the menu opens).
- **Open PHP Config Folder** — opens `$(brew --prefix)/etc/php/<version>`.
- **Open Sites Folder** — opens the nginx vhost folder in Finder: `etc/nginx/sites-available`
  if that layout is in use, otherwise Homebrew's `etc/nginx/servers`. Hidden when neither exists;
  the tooltip shows the resolved path.
- **Launch at Login** — registers the app with `SMAppService`.

## What a switch does

1. `brew services stop <every running php formula>`
2. `brew unlink <currently linked php formula>`
3. `brew link --force --overwrite <target>`
4. `brew services start <target>`

If the link step fails, the previous version is re-linked and restarted so the machine is
never left without a `php` on `PATH`. Any brew failure is shown verbatim in an alert —
deprecated formulas (`php@7.1`, `php@7.4`, `php@8.0`) are listed like any other, and if brew
refuses them you see exactly why.

### MySQL and the shared data dir

A MySQL switch runs the same four steps (`link --force` is what links a keg-only formula), then
waits up to 30s for a new mysqld to answer `mysqladmin ping`. If it never does, the alert
shows the last lines of `var/mysql/*.err`.

Homebrew MySQL versions all use `$(brew --prefix)/var/mysql`, and MySQL upgrades a data dir one
way and never downgrades it. The version that last upgraded a dir is read from its
`mysql_upgrade_history`, and before switching:

- **newer** target — asks first: the upgrade is one way
- **older** target — warns that mysqld will refuse to start (Cancel is the default)

### MySQL 8.4's own data folder

`mysql@8.4` keeps its data in `var/mysql@8.4` instead (the set is `MySQLDetector.separateDataDirs`).
Homebrew's service for it hard-codes the shared dir, so the app runs it from its own LaunchAgent,
`~/Library/LaunchAgents/com.classcreative.phpswitcher.mysql@8.4.plist` (brew's plist with the other
`--datadir`). Switching away from 8.4 boots it out and deletes the plist, so it does not start at
login next to the other version. The first switch to 8.4 asks, then creates the folder with
`mysqld --initialize-insecure` (root, no password — Homebrew's default).

**Copy Database to 8.4 ▸** lists the databases in the shared folder (checked = already in 8.4).
Picking one dumps it with `mysqldump --single-transaction --routines --triggers --events
--add-drop-database` and loads it into 8.4 as `root`. Whichever side is not the live server is
started temporarily on `/tmp/phpswitcher-<formula>.sock` with networking off, then shut down, so
the real server and port 3306 are never disturbed. Only the database is copied, not MySQL users
or grants.

## Detection

No `brew` call on the hot path, so the menu is instant:

- installed versions — directory listing of `$(brew --prefix)/Cellar/php*`
- CLI version — resolves the `$(brew --prefix)/bin/php` symlink back to its keg
- FPM version — `launchctl list` for the `sh.brew.php*` / `homebrew.mxcl.php*` label,
  cross-checked against the live master process's `php-fpm.conf` path so a loaded-but-dead
  job reads as stopped
- MySQL CLI — resolves `$(brew --prefix)/bin/mysql`; server — the `.../bin/mysqld` process in `ps`
  (temporary copy servers are ignored); data version — the last entry of each data dir's
  `mysql_upgrade_history`

## Terminal flags

Useful for debugging; both use the same code as the menu.

```sh
./.build/release/PHPSwitcher --probe            # print detected state and exit
./.build/release/PHPSwitcher --switch php@8.4   # run the switch sequence and exit
./.build/release/PHPSwitcher --switch mysql@9.7 # same for MySQL; refuses a data dir upgrade
                                                # or downgrade unless --force is added
./.build/release/PHPSwitcher --copy-db mydb     # copy a database into the 8.4 data folder
./PHPSwitcher.app/Contents/MacOS/PHPSwitcher --icon   # check the artwork resolves
```
