# PHPSwitcher

A menu bar app for macOS that switches the Homebrew PHP version — both the CLI link and
the running php-fpm service — in one click.

The menu bar shows an elephant and nothing else. Its appearance carries the state:

- solid (adapts to light/dark) — CLI and FPM are on the same version
- orange — they disagree, or FPM is stopped
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

## Detection

No `brew` call on the hot path, so the menu is instant:

- installed versions — directory listing of `$(brew --prefix)/Cellar/php*`
- CLI version — resolves the `$(brew --prefix)/bin/php` symlink back to its keg
- FPM version — `launchctl list` for the `sh.brew.php*` / `homebrew.mxcl.php*` label,
  cross-checked against the live master process's `php-fpm.conf` path so a loaded-but-dead
  job reads as stopped

## Terminal flags

Useful for debugging; both use the same code as the menu.

```sh
./.build/release/PHPSwitcher --probe            # print detected state and exit
./.build/release/PHPSwitcher --switch php@8.4   # run the switch sequence and exit
./PHPSwitcher.app/Contents/MacOS/PHPSwitcher --icon   # check the artwork resolves
```
