# Prerequisites

> **Locked assumption:** Target machine has **only Claude Code** preinstalled. The installer handles every other dependency.

This document covers what `@ordex/sprint-harness install` expects on the host machine and how to set up each supported OS.

## Tier 1 (hard requirements)

The installer hard-fails if any of these are missing. Install them first.

| Tool | macOS | Linux (Ubuntu/Debian) |
|------|-------|-----------------------|
| node ≥ 20 | `brew install node` | `curl -fsSL https://deb.nodesource.com/setup_20.x \| sudo -E bash - && sudo apt-get install -y nodejs` |
| git | `brew install git` | `sudo apt-get install -y git` |
| Claude Code | [install from claude.ai/code](https://claude.ai/code) | same |

`jq`, `pnpm`/`npm`, `ruflo`, and `husky` are auto-installed if missing.

## Tier 2 (recommended)

These unlock optional surfaces. The installer prompts before installing each.

| Tool | Purpose | Notes |
|------|---------|-------|
| gh (GitHub CLI) | sprint-pr-body, sprint-gh-mirror, label creation | Run `gh auth login` after install; the installer prompts for this. |
| Docker | SonarQube container | macOS: `brew install --cask docker`; Linux: see [docker.com/engine/install](https://docs.docker.com/engine/install/). The installer can run the brew cask install on macOS. |
| sonar-scanner | Code quality scans | macOS: `brew install sonar-scanner`. Native arm64 binary — **do NOT use the Docker scanner on Apple Silicon**. |
| Playwright | E2E test suite | Auto-installed via `pnpm dlx playwright install` when prompted. |

## Linux specifics

The Linux branch of the installer auto-copies systemd-user units (`.service` + `.timer`) under `~/.config/systemd/user/` and runs `systemctl --user enable --now` for each timer. Requirements:

- systemd (most modern distros)
- `XDG_RUNTIME_DIR` set (most desktop sessions handle this; headless servers may need `loginctl enable-linger $USER`)

## WSL2

WSL2 is supported via the Linux branch. `systemctl --user` requires:

1. systemd enabled in `/etc/wsl.conf`:
   ```
   [boot]
   systemd=true
   ```
2. `wsl --shutdown` from PowerShell, then reopen WSL.

Without those steps the installer warns and skips the systemd-user timers.

## Windows native

**Not supported in v0.4.** The installer exits with a clear error if it detects `process.platform === 'win32'`. Use WSL2 instead.

## macOS specifics

The macOS branch:

- Copies launchd plists to `~/Library/LaunchAgents/` (required by macOS 12+ — `launchctl bootstrap` from arbitrary paths is unreliable).
- Runs `launchctl bootstrap gui/$(id -u) <plist>` for each.
- Mirrors a copy at `<target>/scripts/launchd/` for reference + uninstall.

## After install

Run the verifier:

```
npx @ordex/sprint-harness doctor
```

It reports Tier 1 + Tier 2 + installed surfaces (launchctl/systemd/Sonar/Playwright/gh labels/ruflo init/MCP). All-green = ready to sprint.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ruflo: command not found` | `npm install -g ruflo@latest` |
| Sonar token missing | check `$HOME/.sprint-harness/sonar-token` (0600). If absent, re-run installer — Sonar bootstrap is idempotent. |
| launchctl: `bootstrap failed` on macOS 14+ | Make sure the plist is in `~/Library/LaunchAgents/`, not the repo's `scripts/launchd/`. The installer handles this in v0.4+. |
| systemd-user timers don't fire on WSL | Confirm `/etc/wsl.conf` has `systemd=true` and you've shut down + restarted WSL. |
| `gh label create: not authenticated` | Run `gh auth login` — the installer prompts; if you said no, run manually and re-invoke the install step. |

## Running the 71-AC self-test

The package vendors the original proof fixtures at `lib/proof/`. To verify the installer:

```
npm test                              # full chain: smoke + matrix + 71-ACs
node tests/run-all-71-acs.mjs         # 71/71 PRODUCTION
node tests/install-matrix.mjs         # 3/3 sample shapes
```
