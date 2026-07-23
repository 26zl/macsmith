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

One command installs Homebrew, Starship, language toolchains, and optional sysadmin profiles, while `update` keeps everything current.

[![macOS Test](https://github.com/26zl/macsmith/actions/workflows/macos-test.yml/badge.svg)](https://github.com/26zl/macsmith/actions/workflows/macos-test.yml)
[![Checks](https://github.com/26zl/macsmith/actions/workflows/checks.yml/badge.svg)](https://github.com/26zl/macsmith/actions/workflows/checks.yml)
[![Security Scan](https://github.com/26zl/macsmith/actions/workflows/security.yml/badge.svg)](https://github.com/26zl/macsmith/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

![Terminal preview](background/image.png)

---

## Install

Recommended — pin to a release. Grab the newest tag from
[Releases](https://github.com/26zl/macsmith/releases/latest) and set it once:

```bash
MACSMITH_REF=<TAG>   # copy the latest immutable tag from Releases
curl -fsSL "https://raw.githubusercontent.com/26zl/macsmith/${MACSMITH_REF}/bootstrap.sh" \
  | MACSMITH_REF="$MACSMITH_REF" zsh
```

**Just want to try it?** One line, no tag to pick (tracks the latest `main`):

```bash
curl -fsSL https://raw.githubusercontent.com/26zl/macsmith/main/bootstrap.sh | zsh
```

Prefer to read before you run? Clone and review (every optional step is a y/n prompt):

```bash
git clone https://github.com/26zl/macsmith.git
cd macsmith
./install.sh
./dev-tools.sh    # optional language toolchains
```

Pick newer tags from [Releases](https://github.com/26zl/macsmith/releases).

## Safety model

- macOS-only: scripts abort on non-Darwin systems.
- Conservative automation: `NONINTERACTIVE=1` accepts each prompt's default; use `MACSMITH_YES=1` only when you explicitly want "yes" to every prompt.
- Existing shell files are backed up before replacement, and managed writes use temp-file + rename where corruption would hurt.
- Remote installer scripts and MacPorts source are version/digest pinned; self-upgrade also verifies GitHub build provenance.
- Project files are not edited by `update`; it maintains global tools only and moves package-manager work to a private safe directory when launched inside a project.
- Nix/APFS removal is guarded: the APFS volume delete always requires typing `yes`, even with `--yes`.
- `doctor` and `verify` are read-only diagnostics.

## Daily use

```text
update [target]    # upgrade everything (default) or a single target: brew/macports/node/python/ruby/rust/swift/go/dotnet/nix/mas (try: update help)
verify             # health-check every installed tool
versions           # print versions on one screen
doctor             # diagnose common setup issues (read-only)
upgrade            # pull the latest release (SHA-256 + GitHub provenance verified)
sys-install        # re-run install.sh (add/remove sysadmin profiles, pick up core updates)
dev-tools          # re-run dev-tools.sh (add/remove language toolchains)
uninstall-profile  # brew-uninstall a sysadmin profile's packages (power-user/crypto/netsec/devops/databases)
setup-github       # log in to GitHub (gh) and derive your global git identity from the account
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
- Sysadmin profiles: power-user CLI **[Y]** (btop, ripgrep, bat, gh, lazygit, tmux, neovim, ghostty, …), crypto/secrets **[Y]** (age, sops, gnupg, pinentry-mac), netsec **[N]** (nmap, masscan, iperf3, Wireshark), devops/SRE **[N]** (kubectl, Terraform via HashiCorp tap, ansible, awscli, powershell, orbstack, …), databases **[N]** (mysql, postgresql)

**Asked per tool during `./dev-tools.sh`**:

- Languages **[Y]**: Python (pyenv + pipx + uv), Node (nvm + pnpm + bun), Ruby (chruby + ruby-install), Rust (rustup), Go
- Languages **[N]**: Swift (swiftly), Java (openjdk), .NET SDK, Conda/Miniforge, deno
- AI tools **[Y]**: Claude Code, Ollama, OpenCode (via official installers), llm (via Homebrew)
- JVM extras batch **[N]**: Kotlin, Scala, Clojure, Gradle, Maven, Groovy

**Maintenance**: `update` keeps every formula, cask, and language runtime current; `verify` shows gaps. Project-local files (`package.json`, `go.mod`, `.swift-version`, …) are never touched.

## What changes on your machine

Concrete footprint before you commit to `curl | zsh`. Everything destructive to existing files creates a timestamped backup first.

<details>
<summary><strong>Expand the full footprint</strong> — every file and system change, what's automatic vs. prompted, and how to reverse it.</summary>

**Always written** (critical install, no prompt):

- `~/.zshrc` — **overwritten** with macsmith's shell config. Previous file saved to `~/.zshrc.backup.YYYYMMDD_HHMMSS`. User-defined `alias`/`export` lines are harvested into `~/.zshrc.local` (secret-shaped exports — `*_TOKEN`, `*_SECRET`, `*_KEY` — are deliberately skipped).
- `~/.zprofile` — managed block appended between `# FINAL PATH CLEANUP` and `# End macsmith managed block` markers. Previous file saved to `~/.zprofile.backup.YYYYMMDD_HHMMSS`.
- `~/.local/bin/` — adds 4 binaries: `macsmith`, `uninstall-nix-macos`, `uninstall-macsmith`, `setup-github`.
- `~/.local/share/macsmith/` — created. Stores install-state marker, version file, and mirror of all repo scripts (used by `upgrade` and `uninstall-macsmith`).
- `~/.config/starship.toml` — written **only if missing**. Existing configs are never overwritten.
- **Homebrew** — installed at `/opt/homebrew` (Apple Silicon) or `/usr/local` (Intel) if not already present. The Homebrew installer itself requests `sudo`.

**Written only if you say yes** (per-tool `[Y]`/`[N]` prompt):

- **Homebrew packages**, by profile:
  - `power-user` **[Y]**: 29 formulae + 1 cask (btop, ripgrep, bat, gh, lazygit, tmux, neovim, chezmoi, wget, just, cmake, coreutils, ghostty, …)
  - `crypto/secrets` **[Y]**: 4 formulae (age, sops, gnupg, pinentry-mac)
  - `netsec` **[N]**: 3 formulae + 1 cask (nmap, masscan, iperf3, Wireshark app) — strictly network-layer tools; web-app / DB-exploit scanners are deliberately excluded
  - `devops/SRE` **[N]**: 18 formulae + 3 casks (kubectl, Terraform via `hashicorp/tap`, ansible, awscli, docker, powershell, orbstack, google-cloud-sdk, multipass, …)
  - `databases` **[N]**: 2 formulae (mysql, postgresql@17)
- **Language toolchains** (via `./dev-tools.sh`, each one its own `[Y]`/`[N]` prompt):
  - Python → `~/.pyenv/`
  - Node.js → `~/.nvm/`
  - Ruby → installed rubies in `~/.rubies/`; `chruby` + `ruby-install` are Homebrew-managed (`$HOMEBREW_PREFIX/share/chruby`, `$HOMEBREW_PREFIX/bin`)
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
- `/Applications/`, `/Library/`, `/System/` — macsmith never edits existing files here. (Package managers you opt into still write their own: Homebrew casks install apps, Nix/MacPorts add system components and launch daemons.)

**Reversing it**:

- `uninstall-macsmith` — removes the 4 binaries, `~/.local/share/macsmith/`, the managed `.zprofile` block, and offers to restore `~/.zshrc` from the oldest non-macsmith backup. Does NOT touch Homebrew or language toolchains.
- `uninstall-profile <name>` — `brew uninstall` a sysadmin profile's formulae + casks.
- `uninstall-nix` — full Nix removal including the APFS volume (the volume-delete step always requires typing `yes` — `--yes` on everything else, never there).
- Language toolchains: removed by their own tools (`rm -rf ~/.pyenv`, `brew uninstall go`, `rustup self uninstall`, …).

</details>

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
- `NONINTERACTIVE=1` — run without prompts, accepting each prompt's default (`[Y]` => yes, `[N]` => no)
- `MACSMITH_YES=1` — explicit unattended mode; answer "yes" to every prompt
- `MACSMITH_FIX_RUBY_GEMS=1` — auto-fix Ruby gem permissions during `update` (on by default; set `0` to disable)
- `MACSMITH_ALLOW_CHECKSUM_ONLY_UPGRADE=1` — ⚠️ allow `upgrade` when GitHub provenance cannot be verified (off by default)
- `MACSMITH_ALLOW_UNSIGNED_UPGRADE=1` — ⚠️ opt `upgrade` into downloading GitHub's **unverified** zipball when a tag has no checksummed release asset (off by default; normal releases ship a verified `.sha256`)
- `MACSMITH_CLEAN_PYENV=1` / `MACSMITH_CLEAN_NVM=1` / `MACSMITH_CLEAN_CHRUBY=1` — **opt in** to pruning old language-runtime versions during `update` (off by default, so a version another project pins via `.python-version`/`.nvmrc`/`.ruby-version` is never deleted). Pair with `MACSMITH_{PYENV,NVM,CHRUBY}_KEEP="ver1,ver2"` to keep extra versions.
- `MACSMITH_UPDATE_WORKDIR=<dir>` — safe working directory for `update` package-manager calls
- `MACSMITH_ALLOW_PROJECT_MODIFY=1` — explicit opt-in to run `update` from the current project directory

## Your own customizations

macsmith manages `~/.zshrc`. Put your aliases and exports in `~/.zshrc.local` — it's sourced last so your edits survive reinstalls. Fresh installs also harvest existing `alias`/`export` lines from your old `~/.zshrc` into `~/.zshrc.local` automatically; secret-shaped exports (`*_TOKEN`, `*_SECRET`, `*_KEY`, …) are deliberately skipped — grab those from the timestamped backup next to your new `~/.zshrc`.

**Prompt themes:** `starship preset --list` to browse, `starship preset <name> -o ~/.config/starship.toml` to apply. Examples: `tokyo-night`, `gruvbox-rainbow`, `pastel-powerline`, `catppuccin-powerline`, `pure-preset`.

## Ghostty terminal (optional)

The optional image assets are available only in a source checkout and are
excluded from release ZIPs until their redistribution provenance is documented
in `ASSETS.md`.

```bash
brew install --cask ghostty
mkdir -p ~/.config/ghostty
cp "Ghostty config.txt" ~/.config/ghostty/config
cp background/terminal-background.png ~/.config/ghostty/terminal-background.png
# Ghostty doesn't expand ~ or $HOME — point the background image at your real home:
sed -i '' "s|/Users/CHANGE_ME|$HOME|" ~/.config/ghostty/config
```

The bundled config enables Ghostty's `ssh-terminfo` shell-integration feature, which installs Ghostty's own `xterm-ghostty` terminfo on remote hosts on first connect, so `xterm-ghostty: unknown terminal type` never appears over SSH.

## Troubleshooting

If the VS Code terminal shows corrupted glyphs, use its canvas renderer and an installed Nerd Font:

```jsonc
"terminal.integrated.gpuAcceleration": "canvas",
"terminal.integrated.fontFamily": "MesloLGS NF"
```

Reload VS Code after changing the settings, or use `"gpuAcceleration": "off"` if corruption remains.

## Requirements

macOS 13 Ventura or later, on Apple Silicon or Intel. CI runs full tests on
macOS 14/Apple Silicon and macOS 15/Intel, with macOS 13 covered by the manual
disposable-VM checklist.

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
