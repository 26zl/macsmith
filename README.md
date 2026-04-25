# macsmith

```text
                                                        \ \ \
                                                         \ \ \
                                    _ _   _              _\_\_\___
 _ __ ___   __ _  ___ ___ _ __ ___ (_) |_| |__          |         |
| '_ ` _ \ / _` |/ __/ __| '_ ` _ \| | __| '_ \         |         |
| | | | | | (_| | (__\__ \ | | | | | | |_| | | |      **|_________|
|_| |_| |_|\__,_|\___|___/_| |_| |_|_|\__|_| |_| * * **
                                                * **  *
                 ⚒  forge your Mac  ⚒          * *
```

**Forge a fresh Mac into a complete dev box — and keep it sharp.**

One command installs Homebrew, Starship, language toolchains, and optional sysadmin profiles. A second command (`update`) keeps everything current.

[![macOS Test](https://github.com/26zl/macsmith/actions/workflows/macos-test.yml/badge.svg)](https://github.com/26zl/macsmith/actions/workflows/macos-test.yml)
[![Checks](https://github.com/26zl/macsmith/actions/workflows/checks.yml/badge.svg)](https://github.com/26zl/macsmith/actions/workflows/checks.yml)
[![Security Scan](https://github.com/26zl/macsmith/actions/workflows/security.yml/badge.svg)](https://github.com/26zl/macsmith/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

![Terminal preview](background/image.png)

---

## Install

Pin to a release (recommended):

```bash
curl -fsSL https://raw.githubusercontent.com/26zl/macsmith/<TAG>/bootstrap.sh \
  | MACSMITH_REF=<TAG> zsh
```

Or clone and review:

```bash
git clone https://github.com/26zl/macsmith.git
cd macsmith
./install.sh
./dev-tools.sh    # optional language toolchains
```

Pick a tag from [Releases](https://github.com/26zl/macsmith/releases).

## Daily use

```text
update [target]    # upgrade everything (default) or a single target: brew/node/python/ruby/rust/swift/go/dotnet/nix/mas (try: update help)
verify             # health-check every installed tool
versions           # print versions on one screen
doctor             # diagnose common setup issues (read-only)
upgrade            # pull the latest macsmith release (SHA-256 verified against the release checksum)
sys-install        # re-run install.sh (add/remove sysadmin profiles, pick up core updates)
dev-tools          # re-run dev-tools.sh (add/remove language toolchains)
uninstall-profile  # brew-uninstall a sysadmin profile's packages (power-user/crypto/netsec/devops/databases)
uninstall-nix      # bundled macOS Nix uninstaller (--dry-run / --yes)
uninstall-macsmith # remove macsmith itself (keeps Homebrew, language tools, your customizations)
reload             # reload ~/.zprofile and ~/.zshrc after editing either
```

## What you get

Everything optional is behind a y/n prompt with a sensible default (press Enter to accept). Defaults shown in brackets.

**Installed automatically** (core shell foundation):

- Xcode Command Line Tools, Homebrew, Starship prompt, zsh-syntax-highlighting, zsh-autosuggestions (both via Homebrew, no Oh My Zsh), FZF
- The `macsmith` maintenance binary at `~/.local/bin/macsmith`
- A managed `~/.zshrc` (your existing one is backed up with a timestamp)

**Asked per tool during `./install.sh`**:

- macOS package sources: `mas` **[N]**, `MacPorts` **[N]**, `Nix` **[N]**
- Sysadmin profiles: power-user CLI **[Y]** (btop, ripgrep, bat, gh, lazygit, tmux, neovim, …), crypto/secrets **[Y]** (age, sops, gnupg, pinentry-mac), netsec **[N]** (nmap, masscan, iperf3, Wireshark), devops/SRE **[N]** (kubectl, Terraform via HashiCorp tap, ansible, awscli, orbstack, …), databases **[N]** (mysql, postgresql)

**Asked per tool during `./dev-tools.sh`**:

- Languages **[Y]**: Python (pyenv + pipx + uv), Node (nvm + pnpm + bun), Ruby (chruby + ruby-install), Rust (rustup), Go
- Languages **[N]**: Swift (swiftly), Java (openjdk), .NET SDK, Conda/Miniforge, deno
- JVM extras batch **[N]**: Kotlin, Scala, Clojure, Gradle, Maven, Groovy

**Maintenance**: `update` keeps every formula, cask, and language runtime current; `verify` shows gaps. Project-local files (`package.json`, `go.mod`, `.swift-version`, …) are never touched.

## What changes on your machine

Concrete footprint before you commit to `curl | zsh`. Everything destructive to existing files creates a timestamped backup first.

**Always written** (critical install, no prompt):

- `~/.zshrc` — **overwritten** with macsmith's shell config. Previous file saved to `~/.zshrc.backup.YYYYMMDD_HHMMSS`. User-defined `alias`/`export` lines are harvested into `~/.zshrc.local` (secret-shaped exports — `*_TOKEN`, `*_SECRET`, `*_KEY` — are deliberately skipped).
- `~/.zprofile` — managed block appended between `# FINAL PATH CLEANUP` and `# End macsmith managed block` markers. Previous file saved to `~/.zprofile.backup.YYYYMMDD_HHMMSS`.
- `~/.local/bin/` — adds 3 binaries: `macsmith`, `uninstall-nix-macos`, `uninstall-macsmith`.
- `~/.local/share/macsmith/` — created. Stores install-state marker, version file, and mirror of all repo scripts (used by `upgrade` and `uninstall-macsmith`).
- `~/.config/starship.toml` — written **only if missing**. Existing configs are never overwritten.
- **Homebrew** — installed at `/opt/homebrew` (Apple Silicon) or `/usr/local` (Intel) if not already present. The Homebrew installer itself requests `sudo`.

**Written only if you say yes** (per-tool `[Y]`/`[N]` prompt):

- **Homebrew packages**, by profile:
  - `power-user` **[Y]**: 24 formulae (btop, ripgrep, bat, gh, lazygit, tmux, neovim, chezmoi, …)
  - `crypto/secrets` **[Y]**: 4 formulae (age, sops, gnupg, pinentry-mac)
  - `netsec` **[N]**: 3 formulae + 1 cask (nmap, masscan, iperf3, Wireshark app) — strictly network-layer tools; web-app / DB-exploit scanners are deliberately excluded
  - `devops/SRE` **[N]**: 17 formulae + 3 casks (kubectl, Terraform via `hashicorp/tap`, ansible, awscli, docker, orbstack, google-cloud-sdk, multipass, …)
  - `databases` **[N]**: 2 formulae (mysql, postgresql@17)
- **Language toolchains** (via `./dev-tools.sh`, each one its own `[Y]`/`[N]` prompt):
  - Python → `~/.pyenv/`
  - Node.js → `~/.nvm/`
  - Ruby → `~/.rubies/`, `~/.local/share/chruby/`, `~/.local/share/ruby-install/`
  - Rust → `~/.rustup/`, `~/.cargo/`
  - Swift → `~/.swiftly/`
  - .NET → `/usr/local/share/dotnet/` (via brew cask; `sudo` for first install)
  - Java (OpenJDK), Go, Conda/Miniforge, uv, bun, pnpm, deno — individual prompts
- **MacPorts** → `/opt/local/`. Every install and every update needs `sudo`.
- **Nix** → `/nix/` APFS volume + `/etc/nix/` + `LaunchDaemons` + `_nixbld1..32` users + `nixbld` group + edits to `/etc/synthetic.conf` and `/etc/fstab`. **System-wide, daemon-based, `sudo` required, 10–20 min.** Largest footprint of anything we offer.

**Never touched**:

- Existing Homebrew formulae/casks you installed yourself (`update` only upgrades; never uninstalls).
- Project-local files (`package.json`, `Gemfile`, `go.mod`, `.swift-version`, `.python-version`, `.nvmrc`, …).
- System Ruby at `/usr/bin/ruby`, system Python, macOS defaults, login items.
- `~/.ssh/`, `~/.gnupg/`, `~/.aws/`, and everything in `~/.config/` except `starship.toml` when it's missing.
- `/Applications/`, `/Library/`, `/System/`.

**Reversing it**:

- `uninstall-macsmith` — removes the 3 binaries, `~/.local/share/macsmith/`, the managed `.zprofile` block, and offers to restore `~/.zshrc` from the oldest non-macsmith backup. Does NOT touch Homebrew or language toolchains.
- `uninstall-profile <name>` — `brew uninstall` a sysadmin profile's formulae + casks.
- `uninstall-nix` — full Nix removal including the APFS volume (the volume-delete step always requires typing `yes` — `--yes` on everything else, never there).
- Language toolchains: removed by their own tools (`rm -rf ~/.pyenv`, `brew uninstall go`, `rustup self uninstall`, …).

## Why not just …

| Tool | macsmith adds |
| --- | --- |
| **`brew bundle`** | Language version managers, shell config, an `update` that understands every ecosystem |
| **`chezmoi`** | macsmith installs chezmoi itself for dotfile sync — they're orthogonal |
| **`nix-darwin`** | No Nix language to learn; imperative but idempotent |
| **Your own dotfiles repo** | A starting point + a maintenance loop. Fork it |

## Options

- `MACSMITH_REF=<tag>` — pin the bootstrap to a specific release (reproducible installs)
- `MACSMITH_UPDATE_CHECK=1` — opt in to a daily update check on shell start (off by default)
- `NONINTERACTIVE=1` — auto-answer "yes" to every prompt (for CI / unattended re-runs)
- `MACSMITH_FIX_RUBY_GEMS=1` — auto-fix Ruby gem permissions during `update` (on by default; set `0` to disable)

## Your own customizations

macsmith manages `~/.zshrc`. Put your aliases and exports in `~/.zshrc.local` — it's sourced last so your edits survive reinstalls. Fresh installs also harvest existing `alias`/`export` lines from your old `~/.zshrc` into `~/.zshrc.local` automatically; secret-shaped exports (`*_TOKEN`, `*_SECRET`, `*_KEY`, …) are deliberately skipped — grab those from the timestamped backup next to your new `~/.zshrc`.

**Prompt themes:** `starship preset --list` to browse, `starship preset <name> -o ~/.config/starship.toml` to apply. Examples: `tokyo-night`, `gruvbox-rainbow`, `pastel-powerline`, `catppuccin-powerline`, `pure-preset`.

## Ghostty terminal (optional)

```bash
brew install --cask ghostty
mkdir -p ~/.config/ghostty
cp "Ghostty config.txt" ~/.config/ghostty/config
cp background/terminal-background.png ~/.config/ghostty/terminal-background.png
```

The bundled config auto-installs macsmith's terminfo over SSH, so `xterm-ghostty: unknown terminal type` never appears on remote hosts.

## Requirements

macOS 13 Ventura or later. Apple Silicon or Intel. That's it.

## Uninstalling

Two bundled scripts, both defensive with `--dry-run` and `--yes` flags. Run `--dry-run` first to see exactly what will change.

### Remove macsmith itself

`uninstall-macsmith` removes what macsmith installed (binaries in `~/.local/bin/`, `~/.local/share/macsmith/`, the managed PATH block in `~/.zprofile`) and offers to restore `~/.zshrc` from the oldest non-macsmith-managed backup (skips `.zshrc.backup.*` files that look like they were made by a prior macsmith run so you get your original pre-macsmith config, not a macsmith template). Also offers to remove `~/.config/starship.toml`. It **keeps** Homebrew, any installed formulae/casks, language toolchains (pyenv/nvm/chruby/rustup/swiftly/go/…), `~/.zshrc.local`, and every file you created.

```bash
uninstall-macsmith --dry-run     # show what will change
uninstall-macsmith               # interactive
uninstall-macsmith --yes         # non-interactive
```

### Remove Nix (macOS)

`uninstall-nix` cleanly removes a multi-user Nix install: launch daemons, `_nixbld*` users, `/etc/nix`, `/etc/synthetic.conf`, `/etc/fstab`, and the `Nix Store` APFS volume. Auto-detects the Determinate Systems installer and prefers `sudo /nix/nix-installer uninstall` when present.

```bash
uninstall-nix --dry-run
uninstall-nix
uninstall-nix --yes
```

Both scripts are installed to `~/.local/bin/` by `./install.sh`. From a clone, you can also run `./scripts/uninstall-macsmith.sh` or `./scripts/uninstall-nix-macos.sh` directly. **macOS-only.** The Nix script re-execs under `sudo`; the APFS volume deletion always requires interactive confirmation typed as `yes` — `--yes` on `uninstall-nix` skips the other prompts but never that one. Read the scripts before running. A reboot is recommended after uninstalling Nix.

## License

[MIT](LICENSE).

---

If macsmith saved you an afternoon, a ⭐ is the tip jar.

[![GitHub stars](https://img.shields.io/github/stars/26zl/macsmith?style=social)](https://github.com/26zl/macsmith/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/26zl/macsmith?style=social)](https://github.com/26zl/macsmith/fork)
