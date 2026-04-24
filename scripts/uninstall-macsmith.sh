#!/usr/bin/env bash
# uninstall-macsmith.sh — remove macsmith artifacts from your home directory.
#
# Removes only what macsmith installed:
#   - ~/.local/bin/macsmith, uninstall-nix-macos, uninstall-macsmith
#   - ~/.local/share/macsmith/ (install-state, version, script copies)
#   - The "Managed by macsmith" PATH block in ~/.zprofile (backup first)
#   - Optionally: restores ~/.zshrc from the oldest non-macsmith-managed backup
#   - Optionally: removes ~/.config/starship.toml
#
# Leaves alone (your property):
#   - Homebrew and any installed formulae/casks
#   - Oh My Zsh, language toolchains (pyenv/nvm/chruby/rustup/swiftly/go/...)
#   - ~/.zshrc.local and any other user-created files
#   - Language state dirs (~/.nvm, ~/.pyenv, ~/.rustup, ...)
#
# --dry-run prints every intended action without changing anything.
# --yes skips confirmation prompts (read the script before using this).

set -euo pipefail

# --------------------------------------------------------------------------
# Colours + logging
# --------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info()    { printf '%b[INFO]%b %s\n'  "$BLUE"   "$NC" "$*"; }
log_ok()      { printf '%b[ OK ]%b %s\n'  "$GREEN"  "$NC" "$*"; }
log_warn()    { printf '%b[WARN]%b %s\n'  "$YELLOW" "$NC" "$*" >&2; }
log_err()     { printf '%b[FAIL]%b %s\n'  "$RED"    "$NC" "$*" >&2; }
log_dry()     { printf '%b[DRY ]%b %s\n'  "$YELLOW" "$NC" "$*"; }
log_section() { printf '\n%b== %s ==%b\n' "$BLUE"   "$*" "$NC"; }

# --------------------------------------------------------------------------
# CLI args
# --------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: uninstall-macsmith.sh [--dry-run] [--yes]

  --dry-run   Print every intended action, change nothing.
  --yes, -y   Skip confirmation prompts.
  -h, --help  Show this help.

Removes macsmith artifacts from your home directory:
  - ~/.local/bin/macsmith + bundled uninstallers
  - ~/.local/share/macsmith/
  - The "Managed by macsmith" PATH block from ~/.zprofile (with backup)
  - Optionally: restores ~/.zshrc from the oldest non-macsmith-managed backup
  - Optionally: removes ~/.config/starship.toml

Does NOT touch: Homebrew, formulae, Oh My Zsh, language toolchains,
~/.zshrc.local, or any user-created files.
USAGE
      exit 0
      ;;
    *)
      log_err "Unknown argument: $1"
      printf 'Run with --help for usage.\n' >&2
      exit 2
      ;;
  esac
done

# --------------------------------------------------------------------------
# Platform check
# --------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  log_err "This script is macOS-only. Detected: $(uname -s)"
  exit 1
fi

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
LOCAL_BIN="$HOME/.local/bin"
DATA_DIR="$HOME/.local/share/macsmith"
ZPROFILE="$HOME/.zprofile"
ZSHRC="$HOME/.zshrc"
STARSHIP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"

# Trackers for accurate summary (never flip to 1 unless the change truly ran).
ZPROFILE_BACKUP=""
ZPROFILE_BACKUP_CREATED=0
ZPROFILE_CHANGED=0
ZSHRC_RESTORED=0
ZSHRC_RESTORED_FROM=""
STARSHIP_REMOVED=0

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    local fmt=""
    local a
    for a in "$@"; do
      fmt+=" $(printf '%q' "$a")"
    done
    log_dry "${fmt# }"
  else
    log_info "$*"
    "$@"
  fi
}

confirm() {
  local prompt="${1:-Proceed?}"
  if [[ $ASSUME_YES -eq 1 ]]; then
    log_info "$prompt [auto-yes]"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_dry "(would ask) $prompt"
    return 0
  fi
  local reply=""
  printf '%s [y/N]: ' "$prompt"
  if [[ -r /dev/tty ]]; then
    IFS= read -r reply </dev/tty 2>/dev/null || return 1
  else
    IFS= read -r reply || return 1
  fi
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# DANGEROUS: recursive delete. Whitelist ensures we only ever touch the
# specific paths macsmith itself created.
safe_rm() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    log_err "safe_rm: refusing empty path"
    return 1
  fi
  case "$target" in
    "$LOCAL_BIN/macsmith") ;;
    "$LOCAL_BIN/uninstall-nix-macos") ;;
    "$LOCAL_BIN/uninstall-macsmith") ;;
    "$DATA_DIR"|"$DATA_DIR"/*) ;;
    "$STARSHIP_CONFIG") ;;
    *)
      log_err "safe_rm: path not in whitelist: $target"
      return 1
      ;;
  esac
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    log_info "skip (not present): $target"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_dry "rm -rf $(printf '%q' "$target")"
  else
    # :? is a last-ditch guard against surprise empty expansion.
    rm -rf "${target:?}" && log_ok "removed: $target"
  fi
}

# --------------------------------------------------------------------------
# Pre-flight summary
# --------------------------------------------------------------------------
log_section "Planned actions"
cat <<EOF
  1. Remove macsmith binaries from $LOCAL_BIN:
       - macsmith
       - uninstall-nix-macos (if installed)
       - uninstall-macsmith (this script — removed last)
  2. Remove $DATA_DIR
  3. Strip the "Managed by macsmith" block from $ZPROFILE (backup first)
  4. Offer to restore $ZSHRC from the oldest non-macsmith-managed backup
  5. Offer to remove $STARSHIP_CONFIG

NOT removed:
  - Homebrew or any installed formulae/casks
  - Oh My Zsh, language toolchains (pyenv, nvm, chruby, rustup, swiftly, go, …)
  - ~/.zshrc.local and any other files you created
  - Language state dirs (~/.nvm, ~/.pyenv, ~/.rustup, …)

Mode: dry-run=${DRY_RUN}, assume-yes=${ASSUME_YES}
EOF

if ! confirm "Proceed?"; then
  log_warn "Aborted by user."
  exit 0
fi

# --------------------------------------------------------------------------
# 1. Binaries
# --------------------------------------------------------------------------
log_section "1. Removing macsmith binaries"
safe_rm "$LOCAL_BIN/macsmith"
safe_rm "$LOCAL_BIN/uninstall-nix-macos"
# uninstall-macsmith (self) is handled at the very end.

# --------------------------------------------------------------------------
# 2. Data dir
# --------------------------------------------------------------------------
log_section "2. Removing $DATA_DIR"
safe_rm "$DATA_DIR"

# --------------------------------------------------------------------------
# 3. .zprofile managed block
# --------------------------------------------------------------------------
log_section "3. Cleaning $ZPROFILE"
if [[ -f "$ZPROFILE" ]]; then
  # The managed block is bounded by the start header and the explicit
  # "# End macsmith managed block" marker (added to install.sh for clean
  # removal). Older installs lacked the end marker; those get a warning
  # and manual-cleanup hint rather than a guessed range.
  _start='^# =+ FINAL PATH CLEANUP \(FOR \.ZPROFILE\) =+$'
  _end='^# End macsmith managed block$'

  if grep -qE "$_start" "$ZPROFILE"; then
    if grep -qE "$_end" "$ZPROFILE"; then
      ZPROFILE_BACKUP="${ZPROFILE}.backup-before-macsmith-uninstall-${TS}"
      run cp -p "$ZPROFILE" "$ZPROFILE_BACKUP"
      if [[ -f "$ZPROFILE_BACKUP" ]]; then
        ZPROFILE_BACKUP_CREATED=1
      fi

      if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "awk strip between '$_start' and '$_end' in $ZPROFILE"
      else
        local_tmp="$(mktemp)"
        awk -v start_re="$_start" -v end_re="$_end" '
          $0 ~ start_re { in_block=1; next }
          in_block && $0 ~ end_re { in_block=0; next }
          !in_block { print }
        ' "$ZPROFILE" > "$local_tmp"
        mv "$local_tmp" "$ZPROFILE"
        log_ok "stripped managed block from $ZPROFILE"
        ZPROFILE_CHANGED=1
      fi
    else
      log_warn "Found start marker in $ZPROFILE but no '# End macsmith managed block' line."
      log_warn "This is an older install format. The managed block was designed"
      log_warn "to live at the end of the file, so it can be removed from the"
      log_warn "'FINAL PATH CLEANUP (FOR .ZPROFILE)' header to EOF."
      if confirm "Strip this legacy macsmith block from $ZPROFILE?"; then
        ZPROFILE_BACKUP="${ZPROFILE}.backup-before-macsmith-uninstall-${TS}"
        run cp -p "$ZPROFILE" "$ZPROFILE_BACKUP"
        if [[ -f "$ZPROFILE_BACKUP" ]]; then
          ZPROFILE_BACKUP_CREATED=1
        fi

        if [[ $DRY_RUN -eq 1 ]]; then
          log_dry "awk strip from '$_start' to EOF in $ZPROFILE"
        else
          local_tmp="$(mktemp)"
          awk -v start_re="$_start" '
            $0 ~ start_re { exit }
            { print }
          ' "$ZPROFILE" > "$local_tmp"
          mv "$local_tmp" "$ZPROFILE"
          log_ok "stripped legacy managed block from $ZPROFILE"
          ZPROFILE_CHANGED=1
        fi
      else
        log_warn "Keeping legacy block. Remove it manually later if desired."
      fi
    fi
  else
    log_info "no managed block in $ZPROFILE"
  fi
else
  log_info "skip (not present): $ZPROFILE"
fi

# --------------------------------------------------------------------------
# 4. .zshrc restore
# --------------------------------------------------------------------------
log_section "4. Restoring $ZSHRC from backup"
# Pick the OLDEST backup that doesn't look macsmith-managed. Reason: every
# re-run of install.sh creates a new .zshrc.backup.TIMESTAMP of whatever was
# at $HOME/.zshrc at that moment. After the first install the backups are
# snapshots of the macsmith-managed zshrc, not the user's original. Restoring
# the "newest" of those gets the user right back where they started.
# The user's true pre-macsmith config is in the OLDEST backup — OR in
# whichever backup doesn't contain macsmith's signature line. We prefer the
# signature check since it's content-based (robust if they ran some other
# tool that also made .zshrc.backup.* files).
# Our backups are named .zshrc.backup.YYYYMMDD_HHMMSS — pure alphanumeric
# + underscore + dot, so ls+sort is safe. shellcheck disable=SC2012 for that.
# shellcheck disable=SC2012
_all_backups="$(ls -1 "$HOME"/.zshrc.backup.* 2>/dev/null | sort || true)"
_chosen_backup=""
if [[ -n "$_all_backups" ]]; then
  # Walk from oldest to newest, take the first that isn't macsmith-managed
  # (no `^macsmith_bin=` signature line).
  while IFS= read -r _b; do
    [[ -z "$_b" ]] && continue
    [[ -f "$_b" ]] || continue
    if ! grep -q '^macsmith_bin=' "$_b" 2>/dev/null; then
      _chosen_backup="$_b"
      break
    fi
  done <<<"$_all_backups"
fi

if [[ -z "$_chosen_backup" ]]; then
  if [[ -n "$_all_backups" ]]; then
    log_info "All backups look macsmith-managed — no pre-macsmith config to restore"
    log_info "Backups on disk (pick one manually if you know which is yours):"
    printf '%s\n' "$_all_backups" | sed 's/^/    /'
  else
    log_info "no ~/.zshrc.backup.* found — leaving $ZSHRC as-is"
  fi
  log_info "$ZSHRC is macsmith-managed; edit/remove it manually if you like"
else
  log_info "chose oldest non-managed backup: $_chosen_backup"
  if [[ "$_chosen_backup" != "$(printf '%s\n' "$_all_backups" | tail -n1)" ]]; then
    log_info "(newer backups exist but look macsmith-managed — skipping those)"
  fi
  if confirm "Restore $ZSHRC from this backup?"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_dry "cp -p $(printf '%q' "$_chosen_backup") $(printf '%q' "$ZSHRC")"
    else
      cp -p "$_chosen_backup" "$ZSHRC"
      log_ok "restored: $ZSHRC ← $_chosen_backup"
      ZSHRC_RESTORED=1
      ZSHRC_RESTORED_FROM="$_chosen_backup"
    fi
  else
    log_info "Keeping $ZSHRC unchanged. All backups remain intact on disk."
  fi
fi
unset _all_backups _chosen_backup _b

# --------------------------------------------------------------------------
# 5. Starship config
# --------------------------------------------------------------------------
log_section "5. Starship config"
if [[ -f "$STARSHIP_CONFIG" ]]; then
  log_info "found: $STARSHIP_CONFIG"
  log_info "(Starship itself is a Homebrew formula — this is just the config file.)"
  if confirm "Remove $STARSHIP_CONFIG?"; then
    safe_rm "$STARSHIP_CONFIG"
    # Flag only when the file is truly gone (safe_rm is a no-op under --dry-run).
    if [[ ! -e "$STARSHIP_CONFIG" && ! -L "$STARSHIP_CONFIG" ]]; then
      STARSHIP_REMOVED=1
    fi
  else
    log_info "keeping $STARSHIP_CONFIG"
  fi
else
  log_info "skip (not present): $STARSHIP_CONFIG"
fi

# --------------------------------------------------------------------------
# Summary (before self-delete so we still have $0 for the message)
# --------------------------------------------------------------------------
log_section "Uninstall complete"
printf 'Summary:\n'
printf '  - Binaries:         removed (if present)\n'
printf '  - Data dir:         removed (if present)\n'
if [[ $ZPROFILE_CHANGED -eq 1 && $ZPROFILE_BACKUP_CREATED -eq 1 ]]; then
  printf '  - .zprofile block:  stripped, backup: %s\n' "$ZPROFILE_BACKUP"
else
  printf '  - .zprofile block:  no managed block found (or manual cleanup needed)\n'
fi
if [[ $ZSHRC_RESTORED -eq 1 ]]; then
  printf '  - .zshrc:           restored from %s\n' "$ZSHRC_RESTORED_FROM"
else
  printf '  - .zshrc:           left as-is\n'
fi
if [[ $STARSHIP_REMOVED -eq 1 ]]; then
  printf '  - starship.toml:    removed\n'
else
  printf '  - starship.toml:    left as-is\n'
fi
printf '\n'
printf 'Next steps:\n'
printf '  1. Open a new terminal (or run: exec zsh) so PATH picks up the .zprofile change.\n'
printf '  2. If you want to remove Homebrew packages macsmith installed, use:\n'
printf '       brew leaves    # list top-level formulae\n'
printf '       brew list      # list everything\n'
printf "     then 'brew uninstall <formula>' for anything you no longer want.\n"
printf '  3. If you installed language tools via dev-tools.sh, they stay installed\n'
printf '     (pyenv, nvm, chruby, rustup, swiftly, go, …). Remove them individually\n'
printf '     if desired (e.g., brew uninstall pyenv + rm -rf ~/.pyenv).\n'

# --------------------------------------------------------------------------
# 6. Self-delete (only if we were invoked as the installed binary).
# If the user ran the repo's scripts/uninstall-macsmith.sh directly,
# leave their copy alone.
# --------------------------------------------------------------------------
if [[ "$0" == "$LOCAL_BIN/uninstall-macsmith" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log_dry "rm -f $(printf '%q' "$LOCAL_BIN/uninstall-macsmith")  # self-delete"
  else
    # Unix lets us unlink an open file; the running process keeps going.
    rm -f "$LOCAL_BIN/uninstall-macsmith" 2>/dev/null || true
  fi
fi
