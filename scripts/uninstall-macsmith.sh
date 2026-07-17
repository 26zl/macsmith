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
#   - Language toolchains (pyenv/nvm/chruby/rustup/swiftly/go/...)
#   - ~/.zshrc.local and any other user-created files
#   - Language state dirs (~/.nvm, ~/.pyenv, ~/.rustup, ...)
#
# --dry-run prints every intended action without changing anything.
# --yes skips confirmation prompts (read the script before using this).

set -euo pipefail

# Colours + logging
if [[ -n "${NO_COLOR:-}" ]]; then
  readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''
else
  readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
  readonly BLUE='\033[0;34m' NC='\033[0m'
fi

log_info()    { printf '%b[INFO]%b %s\n'  "$BLUE"   "$NC" "$*"; }
log_ok()      { printf '%b[ OK ]%b %s\n'  "$GREEN"  "$NC" "$*"; }
log_warn()    { printf '%b[WARN]%b %s\n'  "$YELLOW" "$NC" "$*" >&2; }
log_err()     { printf '%b[FAIL]%b %s\n'  "$RED"    "$NC" "$*" >&2; }
log_dry()     { printf '%b[DRY ]%b %s\n'  "$YELLOW" "$NC" "$*"; }
log_section() { printf '\n%b== %s ==%b\n' "$BLUE"   "$*" "$NC"; }

# CLI args
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
  --yes, -y   Skip confirmation prompts. Exception: removing
              ~/.config/starship.toml is never auto-confirmed (it may be
              user-edited) — it is kept under --yes; delete it manually.
  -h, --help  Show this help.

Removes macsmith artifacts from your home directory:
  - ~/.local/bin/macsmith + bundled uninstallers
  - ~/.local/share/macsmith/
  - The "Managed by macsmith" PATH block from ~/.zprofile (with backup)
  - Optionally: restores ~/.zshrc from the oldest non-macsmith-managed backup
  - Optionally: removes ~/.config/starship.toml

Does NOT touch: Homebrew, formulae, language toolchains, ~/.zshrc.local,
or any user-created files.
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

# Platform check
if [[ "$(uname -s)" != "Darwin" ]]; then
  log_err "This script is macOS-only. Detected: $(uname -s)"
  exit 1
fi

# Require a valid HOME before deriving destructive paths.
if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
  log_err "HOME is unset, empty, or not a directory; refusing to run."
  exit 1
fi

# State
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
ERRORS=0

# Helpers
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

# Restrict recursive deletion to paths created by macsmith.
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
    if rm -rf "${target:?}"; then
      log_ok "removed: $target"
    else
      log_warn "could not fully remove: $target"
      return 1
    fi
  fi
}

# Pre-flight summary
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
  - Language toolchains (pyenv, nvm, chruby, rustup, swiftly, go, …)
  - ~/.zshrc.local and any other files you created
  - Language state dirs (~/.nvm, ~/.pyenv, ~/.rustup, …)

Mode: dry-run=${DRY_RUN}, assume-yes=${ASSUME_YES}
EOF

if ! confirm "Proceed?"; then
  log_warn "Aborted by user."
  exit 0
fi

# 1. Binaries
log_section "1. Removing macsmith binaries"
safe_rm "$LOCAL_BIN/macsmith" || ERRORS=$((ERRORS + 1))
safe_rm "$LOCAL_BIN/uninstall-nix-macos" || ERRORS=$((ERRORS + 1))
# uninstall-macsmith (self) is handled at the very end.

# 2. Data dir
log_section "2. Removing $DATA_DIR"
safe_rm "$DATA_DIR" || ERRORS=$((ERRORS + 1))

# 3. .zprofile managed block
log_section "3. Cleaning $ZPROFILE"
if [[ -f "$ZPROFILE" ]]; then
  # Remove only complete managed blocks and warn before handling legacy blocks.
  _start='^# =+ FINAL PATH CLEANUP \(FOR \.ZPROFILE\) =+$'
  _end='^# End macsmith managed block$'

  if grep -qE "$_start" "$ZPROFILE"; then
    if grep -qE "$_end" "$ZPROFILE"; then
      ZPROFILE_BACKUP="${ZPROFILE}.backup-before-macsmith-uninstall-${TS}"
      if ! run cp -p "$ZPROFILE" "$ZPROFILE_BACKUP"; then
        log_err "Backup failed; refusing to modify $ZPROFILE"
        ERRORS=$((ERRORS + 1))
        continue_profile_cleanup=0
      else
        continue_profile_cleanup=1
      fi
      if [[ -f "$ZPROFILE_BACKUP" ]]; then
        ZPROFILE_BACKUP_CREATED=1
      fi

      if [[ $continue_profile_cleanup -eq 0 ]]; then
        :
      elif [[ $DRY_RUN -eq 1 ]]; then
        log_dry "awk strip between '$_start' and '$_end' in $ZPROFILE"
      else
        _old_umask="$(umask)"
        umask 077
        local_tmp="$(mktemp "${ZPROFILE}.macsmith.XXXXXX")"
        umask "$_old_umask"
        _orig_perms="$(stat -f '%Lp' "$ZPROFILE" 2>/dev/null || echo "")"
        # Match the full marker lines with anchored regexes so a stray copy of
        # the marker text elsewhere can't start (or fail to close) the strip.
        awk '
          /^# =+ FINAL PATH CLEANUP \(FOR \.ZPROFILE\) =+$/ { in_block=1; next }
          in_block && /^# End macsmith managed block$/ { in_block=0; next }
          !in_block { print }
        ' "$ZPROFILE" > "$local_tmp"
        if [[ -n "$_orig_perms" ]]; then
          chmod "$_orig_perms" "$local_tmp"
        fi
        if mv -f "$local_tmp" "$ZPROFILE"; then
          log_ok "stripped managed block from $ZPROFILE"
          ZPROFILE_CHANGED=1
        else
          rm -f "$local_tmp" 2>/dev/null || true
          log_err "Failed to replace $ZPROFILE (original + backup preserved)"
          ERRORS=$((ERRORS + 1))
        fi
      fi
    else
      log_warn "Found start marker in $ZPROFILE but no '# End macsmith managed block' line."
      log_warn "This is an older install format. The managed block was designed"
      log_warn "to live at the end of the file, so it can be removed from the"
      log_warn "'FINAL PATH CLEANUP (FOR .ZPROFILE)' header to EOF."
      if [[ $ASSUME_YES -eq 1 && $DRY_RUN -eq 0 ]]; then
        log_warn "Legacy block uses an unbounded strip-to-EOF; --yes does NOT auto-confirm it."
        log_warn "Re-run without --yes to review and strip it, or remove it manually."
      elif confirm "Strip this legacy macsmith block from $ZPROFILE?"; then
        ZPROFILE_BACKUP="${ZPROFILE}.backup-before-macsmith-uninstall-${TS}"
        if ! run cp -p "$ZPROFILE" "$ZPROFILE_BACKUP"; then
          log_err "Backup failed; refusing to modify $ZPROFILE"
          ERRORS=$((ERRORS + 1))
          continue_profile_cleanup=0
        else
          continue_profile_cleanup=1
        fi
        if [[ -f "$ZPROFILE_BACKUP" ]]; then
          ZPROFILE_BACKUP_CREATED=1
        fi

        # Report how many lines the legacy strip-to-EOF operation removes.
        _legacy_lines="$(awk 'index($0, "FINAL PATH CLEANUP (FOR .ZPROFILE)") { f=1 } f { c++ } END { print c+0 }' "$ZPROFILE")"
        log_warn "this removes $_legacy_lines line(s): the header through end-of-file"
        if [[ $continue_profile_cleanup -eq 0 ]]; then
          :
        elif [[ $DRY_RUN -eq 1 ]]; then
          log_dry "awk strip from '$_start' to EOF in $ZPROFILE"
        else
          _old_umask="$(umask)"
          umask 077
          local_tmp="$(mktemp "${ZPROFILE}.macsmith.XXXXXX")"
          umask "$_old_umask"
          _orig_perms="$(stat -f '%Lp' "$ZPROFILE" 2>/dev/null || echo "")"
          awk '
            index($0, "FINAL PATH CLEANUP (FOR .ZPROFILE)") { exit }
            { print }
          ' "$ZPROFILE" > "$local_tmp"
          if [[ -n "$_orig_perms" ]]; then
            chmod "$_orig_perms" "$local_tmp"
          fi
          if mv -f "$local_tmp" "$ZPROFILE"; then
            log_ok "stripped legacy managed block from $ZPROFILE"
            ZPROFILE_CHANGED=1
          else
            rm -f "$local_tmp" 2>/dev/null || true
            log_err "Failed to replace $ZPROFILE (original + backup preserved)"
            ERRORS=$((ERRORS + 1))
          fi
        fi
      else
        log_warn "Keeping legacy block. Remove it manually later if desired."
      fi
    fi
  else
    log_info "no managed block in $ZPROFILE"
  fi

  # Remove the independent legacy Go block not covered by PATH cleanup.
  _go_marker='^# Managed by macsmith - Go configuration$'
  if grep -qE "$_go_marker" "$ZPROFILE"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_dry "remove Go configuration block from $ZPROFILE"
    else
      if [[ $ZPROFILE_BACKUP_CREATED -eq 0 ]]; then
        ZPROFILE_BACKUP="${ZPROFILE}.backup-before-macsmith-uninstall-${TS}"
        if cp -p "$ZPROFILE" "$ZPROFILE_BACKUP"; then
          ZPROFILE_BACKUP_CREATED=1
        else
          log_err "Backup failed; refusing to remove the Go block from $ZPROFILE"
          ERRORS=$((ERRORS + 1))
        fi
      fi
      if [[ $ZPROFILE_BACKUP_CREATED -eq 1 ]]; then
        _old_umask="$(umask)"
        umask 077
        _go_tmp="$(mktemp "${ZPROFILE}.macsmith.XXXXXX")"
        umask "$_old_umask"
        _go_perms="$(stat -f '%Lp' "$ZPROFILE" 2>/dev/null || echo "")"
        awk '
          /^# Managed by macsmith - Go configuration$/          { in_go=1; next }
          in_go && /^[[:space:]]*$/                              { next }
          in_go && /^[[:space:]]*export[[:space:]]+GOROOT/       { next }
          in_go && /^[[:space:]]*export[[:space:]]+PATH.*GOROOT/ { next }
          { in_go=0; print }
        ' "${ZPROFILE:?}" > "$_go_tmp"
        [[ -n "$_go_perms" ]] && chmod "$_go_perms" "$_go_tmp"
        if mv -f "$_go_tmp" "$ZPROFILE"; then
          log_ok "removed Go configuration block from $ZPROFILE"
          ZPROFILE_CHANGED=1
        else
          rm -f "$_go_tmp" 2>/dev/null || true
          log_err "Failed to replace $ZPROFILE (original + backup preserved)"
          ERRORS=$((ERRORS + 1))
        fi
      fi
    fi
  fi
else
  log_info "skip (not present): $ZPROFILE"
fi

# 4. .zshrc restore
log_section "4. Restoring $ZSHRC from backup"
# Restore the oldest backup without macsmith's signature.
# shellcheck disable=SC2012
_all_backups="$(ls -1 "$HOME"/.zshrc.backup.* 2>/dev/null | sort || true)"
_chosen_backup=""
if [[ -n "$_all_backups" ]]; then
  # Select the first unsigned backup in chronological order.
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
      restore_ready=1
      # Snapshot the current .zshrc before restoring a backup.
      if [[ -f "$ZSHRC" ]]; then
        if ! cp -p "$ZSHRC" "$ZSHRC.pre-restore-${TS}"; then
          log_err "Could not snapshot current $ZSHRC; refusing to restore over it"
          ERRORS=$((ERRORS + 1))
          restore_ready=0
        fi
      fi
      if [[ $restore_ready -eq 1 ]]; then
        cp -p "$_chosen_backup" "$ZSHRC"
        log_ok "restored: $ZSHRC ← $_chosen_backup"
        ZSHRC_RESTORED=1
        ZSHRC_RESTORED_FROM="$_chosen_backup"
      fi
    fi
  else
    log_info "Keeping $ZSHRC unchanged. All backups remain intact on disk."
  fi
fi
unset _all_backups _chosen_backup _b

# 5. Starship config
log_section "5. Starship config"
if [[ -f "$STARSHIP_CONFIG" ]]; then
  log_info "found: $STARSHIP_CONFIG"
  log_info "(Starship itself is a Homebrew formula — this is just the config file.)"
  # Require interactive confirmation before deleting a possibly edited prompt config.
  if [[ $ASSUME_YES -eq 1 ]]; then
    log_info "keeping $STARSHIP_CONFIG (--yes does not auto-remove it; 'rm $STARSHIP_CONFIG' to delete)"
  elif confirm "Remove $STARSHIP_CONFIG?"; then
    safe_rm "$STARSHIP_CONFIG" || ERRORS=$((ERRORS + 1))
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

# Summary (before self-delete so we still have $0 for the message)
if [[ $DRY_RUN -eq 1 ]]; then
  log_section "Dry-run complete"
elif [[ $ERRORS -gt 0 ]]; then
  log_section "Uninstall incomplete ($ERRORS error(s))"
else
  log_section "Uninstall complete"
fi
printf 'Summary:\n'
if [[ $DRY_RUN -eq 1 ]]; then
  printf '  - Binaries:         would remove (if present)\n'
  printf '  - Data dir:         would remove (if present)\n'
else
  printf '  - Binaries:         removed (if present)\n'
  printf '  - Data dir:         removed (if present)\n'
fi
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

# 6. Self-delete only when invoked as the installed binary.
# Resolve relative invocations before deciding whether to self-delete.
_self_path=""
if _self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"; then
  _self_path="$_self_dir/$(basename "$0")"
fi
if [[ "$0" == "$LOCAL_BIN/uninstall-macsmith" || "$_self_path" == "$LOCAL_BIN/uninstall-macsmith" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log_dry "rm -f $(printf '%q' "$LOCAL_BIN/uninstall-macsmith")  # self-delete"
  else
    # Unix lets us unlink an open file; the running process keeps going.
    if ! rm -f "$LOCAL_BIN/uninstall-macsmith" 2>/dev/null; then
      log_warn "could not self-delete: $LOCAL_BIN/uninstall-macsmith"
      ERRORS=$((ERRORS + 1))
    fi
  fi
fi

(( ERRORS == 0 ))
