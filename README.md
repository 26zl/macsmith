# macsmith

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
update      # upgrade everything (Homebrew, casks, language toolchains, global packages)
verify      # health-check every installed tool
versions    # print versions on one screen
upgrade     # pull the latest macsmith release (signed, SHA-256 verified)
```

## What you get

- **Shell**: Homebrew, Oh My Zsh (plugins only), Starship prompt, syntax highlighting, autosuggestions, FZF
- **Languages**: Python (pyenv + uv), Node (nvm + pnpm + bun + deno), Ruby (chruby), Rust (rustup), Swift (swiftly), Go, Java, .NET
- **Opt-in sysadmin profiles**: power-user CLI (btop, ripgrep, bat, gh, lazygit, tmux, neovim, …), crypto/secrets (age, sops, 1password-cli), netsec (nmap, wireshark, …), devops/SRE (kubectl, terraform, ansible, awscli, colima, orbstack, …)
- **Maintenance**: `update` keeps every formula, cask, and language runtime current; `verify` shows gaps; project-local files (`package.json`, `go.mod`, `.swift-version`, …) are never touched

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

## License

[MIT](LICENSE).

---

If macsmith saved you an afternoon, a ⭐ is the tip jar.

[![GitHub stars](https://img.shields.io/github/stars/26zl/macsmith?style=social)](https://github.com/26zl/macsmith/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/26zl/macsmith?style=social)](https://github.com/26zl/macsmith/fork)
