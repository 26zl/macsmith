# macsmith

**Forge a fresh Mac into a complete dev box — and keep it sharp.**

One command installs everything from Homebrew to Starship, language toolchains, and opt-in sysadmin profiles. A second command (`update`) keeps every formula, cask, and language runtime current. Atomic file writes mean `Ctrl-C` never corrupts your shell config.

[![macOS Test](https://github.com/26zl/macsmith/actions/workflows/macos-test.yml/badge.svg)](https://github.com/26zl/macsmith/actions/workflows/macos-test.yml)
[![Checks](https://github.com/26zl/macsmith/actions/workflows/checks.yml/badge.svg)](https://github.com/26zl/macsmith/actions/workflows/checks.yml)
[![Security Scan](https://github.com/26zl/macsmith/actions/workflows/security.yml/badge.svg)](https://github.com/26zl/macsmith/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

![Terminal preview](background/image.png)

---

## Quick Start

> Before you pipe anything to a shell, read the script. [bootstrap.sh](bootstrap.sh) is ~170 lines and does exactly what it says: clone this repo to a temp dir, run `install.sh` from there, clean up. All persistent writes are atomic. High-risk prompts (MacPorts, Nix, netsec, devops, Java, .NET) default to "no"; common power-user/language-tool prompts default to "yes" — you can see the defaults inline in each prompt (`[Y/n]` vs `[y/N]`).

**Recommended — pin to a release** (reproducible, auditable, survives a compromised `main`):

```bash
curl -fsSL https://raw.githubusercontent.com/26zl/macsmith/v2026.04.23-abc1234/bootstrap.sh \
  | MACSMITH_REF=v2026.04.23-abc1234 zsh
```

Replace `v2026.04.23-abc1234` with a tag from [Releases](https://github.com/26zl/macsmith/releases). This pins both the bootstrap script *and* the repo it clones.

**Convenience — from `main`** (use only after reviewing and for personal/dev Macs):

```bash
curl -fsSL https://raw.githubusercontent.com/26zl/macsmith/main/bootstrap.sh | zsh
```

The bootstrap shows a 5-second abort window before doing anything. Set `MACSMITH_YES=1` to skip it (CI/automated setups).

**Safest — clone and review first:**

```bash
git clone https://github.com/26zl/macsmith.git
cd macsmith
less install.sh dev-tools.sh zsh.sh   # or read on GitHub
./install.sh                           # Core: shell, Homebrew, Starship, sysadmin profiles
./dev-tools.sh                         # Optional: language toolchains
source ~/.zshrc
```

---

## Daily commands

After install, these aliases are in your shell:

| Command | What it does |
|---|---|
| `update` | Update Homebrew, casks, pyenv/nvm/chruby/rustup/swiftly toolchains, global packages |
| `verify` | Health check for everything installed (languages, runtimes, daemons) |
| `versions` | Print every tool version on one screen |
| `upgrade` | Pull latest macsmith release and re-install the managed config |
| `sys-install` | Re-run `install.sh` (named `sys-install` to not collide with `/usr/bin/install`) |
| `dev-tools` | Re-run `dev-tools.sh` |
| `reload` | Re-source `.zprofile` and `.zshrc` in current shell |

---

## What you get

### Core (install.sh)

- **Xcode CLT**, **Homebrew** (Apple Silicon and Intel detected automatically)
- **Starship prompt** with language/cloud/k8s segments baked in (`config/starship.toml`)
- **Oh My Zsh** as plugin host only (theme disabled — Starship wins); `zsh-syntax-highlighting` + `zsh-autosuggestions`
- **`macsmith` binary** in `~/.local/bin/` for ongoing maintenance
- **Optional**: MacPorts, Nix, mas, FZF
- **Sysadmin profiles** (prompted — opt in per profile):
  - **Power-user**: `btop`, `ripgrep`, `bat`, `eza`, `fd`, `zoxide`, `jq`, `yq`, `gh`, `lazygit`, `tmux`, `neovim`, `chezmoi`, `tldr`, `mtr`, `bandwhich`, `direnv`, `shellcheck`, `shfmt`, `pre-commit`, and more
  - **Crypto/secrets**: `age`, `sops`, `gnupg`, `pinentry-mac`, `1password-cli`
  - **Netsec**: `nmap`, `masscan`, `iperf3`, `nikto`, `sqlmap`, `wireshark` (cask)
  - **DevOps/SRE**: `kubernetes-cli`, `helm`, `k9s`, `kubectx`, `kustomize`, `stern`, `terraform`, `terragrunt`, `tflint`, `ansible`, `awscli`, `azure-cli`, `doctl`, `argocd`, `skaffold`, `colima`, `docker`, `docker-compose`, `google-cloud-sdk`, `orbstack` (cask), `multipass` (cask)

### Language layer (dev-tools.sh)

- **Python**: `pyenv` + latest CPython, `pipx`, `uv` (the fast one)
- **Node.js**: `nvm` + LTS, `pnpm`, `bun`, `deno`
- **Ruby**: `chruby` + `ruby-install` + latest stable
- **Rust**: `rustup` + stable toolchain
- **Swift**: `swiftly` + latest stable (isolated to `$HOME`, no stray `.swift-version` in project dirs)
- **Go**, **Java** (OpenJDK), **.NET SDK**
- **JVM extras** (opt-in batch): Kotlin, Scala, Clojure, Gradle, Maven, Groovy
- **Conda/Miniforge** (opt-in)

### Maintenance layer (macsmith binary)

Run `update` and watch everything self-heal:

- `brew update && brew upgrade` + `brew upgrade --cask --greedy`
- `pyenv`, `nvm`, `chruby` version cleanup with configurable retention
- Rust toolchain and Cargo-installed binaries
- `swiftly` Swift updates (with dev-snapshot opt-in)
- `gem`, `npm -g`, `pipx` package refreshes
- `go` toolchain auto-bump + PATH fixup
- Ruby gem repair after chruby activation
- MacPorts `selfupdate` + `upgrade outdated`
- Nix-daemon channel + profile updates

All with project-safety heuristics: `~/.local/share/macsmith/` tracks install state, and the update logic never touches project-local `package.json` / `go.mod` / `Gemfile` / `.swift-version` etc. — only global/system packages.

---

## Why macsmith instead of …

| Tool | Does | macsmith adds |
|---|---|---|
| **`brew bundle`** | Install packages from a Brewfile | + language version managers, + shell config, + `update` that knows about every ecosystem, + atomic Ctrl-C safety |
| **`chezmoi`** | Sync dotfiles across machines | macsmith installs chezmoi itself in the power-user profile. Use it alongside for dotfile sync. Orthogonal. |
| **`nix-darwin`** | Fully declarative macOS config | Higher ceiling, much higher floor. macsmith is imperative but idempotent; no Nix language, no 2-day learning curve. Use nix-darwin if you want reproducibility across 10 Macs. |
| **Your own dotfiles repo** | You already know what you want | macsmith is a starting point and a maintenance loop. Fork it and make it yours — the harvest step in `install.sh` preserves your old aliases into `~/.zshrc.local`. |

---

## Safety guarantees

- **Fresh vs upgrade detection** via `~/.local/share/macsmith/.install-state`. Re-running install won't re-ask questions you answered or double-harvest aliases.
- **Atomic file writes**: `~/.zshrc`, `~/.zprofile`, `~/.local/bin/macsmith`, and `~/.config/starship.toml` are written via tempfile + `mv`. Ctrl-C leaves them either as the old version or the new one — never a half-written file.
- **Ctrl-C anywhere** prints a friendly message pointing at backups and resumption steps.
- **Lock files** (`/tmp/macsmith-*.lock`) prevent two concurrent installs from stomping on each other.
- **Backups**: every time install.sh rewrites `~/.zshrc` or `~/.zprofile`, it timestamps the old one as `.backup.<YYYYMMDD_HHMMSS>`.
- **Release gating**: publishing artifacts requires `Checks`, `macOS Test`, and `Security Scan` workflows to have passed on the exact commit SHA being released (closes a supply-chain bypass where manual/workflow_dispatch could skip CI).
- **No phone-home by default**: the shell startup update check is opt-in (`MACSMITH_UPDATE_CHECK=1`). No `api.github.com` calls during daily use unless you ask.

---

## Configuration

### Environment variables

**Bootstrap / install:**

- `MACSMITH_REF=<tag|branch|sha>` — pin `bootstrap.sh` to a specific ref
- `MACSMITH_REPO=<url>` — override repo URL (must be `https://`)
- `MACSMITH_YES=1` — skip the 5-second abort window in `bootstrap.sh`
- `NONINTERACTIVE=1` / `CI=1` — auto-answer "yes" to all prompts
- `FORCE_INTERACTIVE=1` — force real prompts even in CI

**Shell-local overrides:**

- `~/.zshrc.local` — sourced last by the managed `~/.zshrc`. Put personal aliases/exports here so they survive re-installs. On fresh installs, pre-existing user aliases are automatically harvested into this file.

**Maintenance cleanup** (set to `0` to disable):

- `MACSMITH_CLEAN_PYENV`, `MACSMITH_CLEAN_NVM`, `MACSMITH_CLEAN_CHRUBY`
- `MACSMITH_PYENV_KEEP="3.11.8,3.10.14"` — keep specific Python versions
- `MACSMITH_NVM_KEEP="v18.19.1"` — keep specific Node.js versions
- `MACSMITH_CHRUBY_KEEP="ruby-3.4.6"` — keep specific Ruby versions
- `MACSMITH_SWIFT_SNAPSHOTS=1` — enable Swift development snapshot updates
- `MACSMITH_UPDATE_CHECK=1` — opt in to daily update check on shell start (off by default)
- `MACSMITH_ALLOW_UNSIGNED_UPGRADE=1` — opt in to accept GitHub's unsigned zipball when no signed release asset exists (off by default; normal releases ship a `.sha256`)

---

## Compatibility

| Requirement | Details |
|---|---|
| **macOS** | macOS 13 Ventura or later (may work on older versions) |
| **Architecture** | Apple Silicon (M1 through M5) and Intel x86_64 |
| **Shell** | Zsh (macOS default since Catalina) |
| **Disk space** | ~15–30 GB for Xcode CLT + Homebrew + the full language layer |
| **Network** | Required during install (GitHub, Homebrew, language toolchain registries) |
| **Permissions** | MacPorts, Nix, and some casks require `sudo` |

---

## Ghostty setup (optional)

macsmith ships a pre-tuned Ghostty config with SSH terminfo auto-install so `xterm-ghostty` never fails on remote hosts:

```bash
brew install --cask ghostty
mkdir -p ~/.config/ghostty
cp "Ghostty config.txt" ~/.config/ghostty/config
cp background/terminal-background.png ~/.config/ghostty/terminal-background.png
```

---

## FAQ

**Will this touch project files?**
No. Maintenance commands update only global/system packages. `package.json`, `go.mod`, `Gemfile`, `.swift-version`, etc. are never modified.

**Is it safe for CI?**
Yes. `NONINTERACTIVE=1` or `CI=1` auto-answers every prompt. A full macOS integration test runs on every PR.

**Intel and Apple Silicon?**
Both. `_detect_brew_prefix()` resolves `/opt/homebrew` vs `/usr/local` on startup and throughout.

**What if I already have Oh My Zsh, Homebrew, or Starship?**
macsmith detects and skips. Re-running is idempotent — it only installs what's missing and updates what it manages.

**How do I roll back after install?**
Your previous `~/.zshrc` is at `~/.zshrc.backup.<timestamp>`. Your previous `~/.zprofile` at `~/.zprofile.backup.<timestamp>`. Restore with `cp`.

---

## Contributing

1. Fork, clone, make changes
2. Run `./quick-test.sh` — it checks syntax on every script
3. CI runs: ShellCheck, Gitleaks, macOS integration test, Trivy scan
4. Open a PR

The codebase is four Zsh scripts + one tiny Bash helper for Nix. No dependencies beyond standard macOS tooling. Read `CLAUDE.md` for the architecture tour.

---

## License

[MIT](LICENSE) — fork it, rebrand it, ship it.

---

If macsmith saved you an afternoon of manual setup, a ⭐ is the tip jar.

[![GitHub stars](https://img.shields.io/github/stars/26zl/macsmith?style=social)](https://github.com/26zl/macsmith/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/26zl/macsmith?style=social)](https://github.com/26zl/macsmith/fork)
