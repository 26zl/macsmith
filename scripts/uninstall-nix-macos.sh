#!/usr/bin/env bash
# Safely remove multi-user or Determinate Nix installs with strict confirmation for destructive steps.

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# --------------------------------------------------------------------------
# Colours + logging
# --------------------------------------------------------------------------
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

# --------------------------------------------------------------------------
# CLI args
# --------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
ORIGINAL_ARGV=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: uninstall-nix-macos.sh [--dry-run] [--yes]

  --dry-run   Print every intended action, change nothing.
  --yes, -y   Skip confirmation prompts (read the script first).
              Does NOT auto-confirm the three high-risk steps — each always
              requires interactive confirmation typed as 'yes': the APFS volume
              deletion, the orphan /nix removal, and the Determinate Systems
              '/nix/nix-installer uninstall' shortcut.
  -h, --help  Show this help.

Removes a multi-user Nix install from macOS:
  - Unloads + removes Nix launch daemons
  - Removes the nixbld group and _nixbld* users
  - Removes /etc/nix and per-user .nix-* state
  - Strips the "nix" line from /etc/synthetic.conf (backup first)
  - Strips /nix mount lines from /etc/fstab (backup first)
  - Offers to delete the "Nix Store" APFS volume (never without confirmation)

If /nix/nix-installer exists, uses the Determinate Systems uninstaller.
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
# Platform + command prerequisites
# --------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  log_err "This script is macOS-only. Detected: $(uname -s)"
  exit 1
fi

_missing=()
for _cmd in diskutil launchctl dscl sed grep awk; do
  command -v "$_cmd" >/dev/null 2>&1 || _missing+=("$_cmd")
done
if (( ${#_missing[@]} > 0 )); then
  log_err "Required commands not found: ${_missing[*]}"
  exit 1
fi
unset _missing _cmd

# --------------------------------------------------------------------------
# Re-exec under sudo (real runs only — dry-run should work rootless so you
# can inspect the plan without typing a password)
# --------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "Dry-run: not re-execing under sudo; some inspections may be limited."
  else
    log_info "Need root. Re-running under sudo..."
    # Re-exec without preserving the caller's environment.
    if [[ ${#ORIGINAL_ARGV[@]} -gt 0 ]]; then
      exec sudo bash "$0" "${ORIGINAL_ARGV[@]}"
    else
      exec sudo bash "$0"
    fi
  fi
fi

# --------------------------------------------------------------------------
# Shared state
# --------------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
ERRORS=0

# Resolve the invoking user's home through dscl when running under sudo.
USER_HOME=""
if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
  USER_HOME="$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory 2>/dev/null \
              | awk '/NFSHomeDirectory/ { print $2 }' || true)"
  # Do NOT fall back to $HOME under sudo: that is root's home, and we'd "clean"
  # /var/root/.nix-* (already handled) instead of the invoking user's state.
  if [[ -z "$USER_HOME" ]]; then
    log_warn "Could not resolve ${SUDO_USER}'s home via dscl; per-user ~/.nix-* cleanup will be skipped."
  fi
else
  # Not under sudo: $HOME is the invoking user's own home.
  USER_HOME="${HOME:-}"
fi

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Run a command or display its shell-quoted dry-run form.
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

# Confirm through /dev/tty, with --yes and dry-run shortcuts.
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

# Require a typed `yes` for irreversible operations regardless of --yes.
strict_confirm() {
  local prompt="${1:-Proceed?}"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_dry "(would ask, no auto-yes) $prompt"
    return 0
  fi
  if [[ $ASSUME_YES -eq 1 ]]; then
    log_warn "$prompt"
    log_warn "--yes does NOT auto-confirm this destructive operation."
  fi
  local reply=""
  printf '%s (type yes): ' "$prompt"
  if [[ -r /dev/tty ]]; then
    IFS= read -r reply </dev/tty 2>/dev/null || return 1
  else
    # Refuse piped input for irreversible operations.
    log_err "No interactive terminal available; refusing irreversible operation."
    return 1
  fi
  # Must type full "yes" — not just "y" — for irreversible ops.
  [[ "$reply" == "yes" ]]
}

# DANGEROUS: recursive delete. Defences in order:
#   1. refuse empty argument
#   2. whitelist of known Nix-related paths (never anything else)
#   3. skip silently if the target does not exist
#   4. ${target:?} expansion guards against surprise empty expansion at runtime
safe_rm() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    log_err "safe_rm: refusing empty path"
    return 1
  fi
  case "$target" in
    /etc/nix|/etc/nix/*) ;;
    /nix|/nix/*) ;;
    /var/root/.nix-profile|/var/root/.nix-defexpr|/var/root/.nix-channels) ;;
    */.nix-profile|*/.nix-defexpr|*/.nix-channels) ;;
    *)
      log_err "safe_rm: refusing path outside allowed list: $target"
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
    # :? guarantees we never run rm -rf on an accidentally-empty expansion
    rm -rf "${target:?}" && log_ok "removed: $target"
  fi
}

# --------------------------------------------------------------------------
# Determinate Systems installer shortcut
# --------------------------------------------------------------------------
if [[ -x /nix/nix-installer ]]; then
  log_section "Determinate Systems installer detected"
  log_info  "/nix/nix-installer is present. This is the canonical uninstaller"
  log_info  "for Determinate installs and handles every step correctly."
  log_info  "Note: invoking it also deletes the APFS volume. Using strict_confirm"
  log_info  "so --yes cannot auto-trigger an irreversible system-wide uninstall."
  # Require typed confirmation before invoking Determinate's destructive uninstaller.
  if strict_confirm "Use 'sudo /nix/nix-installer uninstall' and exit?"; then
    if run /nix/nix-installer uninstall; then
      log_ok "Determinate uninstall finished. A restart is still recommended."
      exit 0
    fi
    log_err "Determinate uninstall failed"
    exit 1
  fi
  log_warn "User chose to continue with the manual path. OK, proceeding."
fi

# --------------------------------------------------------------------------
# Pre-flight summary
# --------------------------------------------------------------------------
log_section "Planned actions"
cat <<EOF
  1. Unload + remove:
       /Library/LaunchDaemons/org.nixos.nix-daemon.plist
       /Library/LaunchDaemons/org.nixos.darwin-store.plist
  2. Remove _nixbld* users and the nixbld group (if present)
  3. Remove:
       /etc/nix
       /var/root/.nix-profile, .nix-defexpr, .nix-channels
       ${USER_HOME:-<no user home resolved>}/.nix-profile, .nix-defexpr, .nix-channels
  4. Strip the exact line "nix" from /etc/synthetic.conf (backup first)
  5. Strip /nix mount lines from /etc/fstab (backup first)
  6. Locate + (with confirmation) delete the "Nix Store" APFS volume

Backups will be written to:
  /etc/synthetic.conf.backup-before-nix-uninstall-${TS}
  /etc/fstab.backup-before-nix-uninstall-${TS}

Mode: dry-run=${DRY_RUN}, assume-yes=${ASSUME_YES}
EOF

if ! confirm "Proceed?"; then
  log_warn "Aborted by user."
  exit 0
fi

# --------------------------------------------------------------------------
# 1. Launch daemons
# --------------------------------------------------------------------------
log_section "1. Unloading Nix launch daemons"
for _plist in \
    /Library/LaunchDaemons/org.nixos.nix-daemon.plist \
    /Library/LaunchDaemons/org.nixos.darwin-store.plist; do
  if [[ -f "$_plist" ]]; then
    _label="$(basename "$_plist" .plist)"
    # bootout is the modern API; unload -w is the fallback for older macOS.
    # Both return non-zero for an already-unloaded daemon, which is NOT a
    # failure — only attempt (and count) the unload when it's actually loaded.
    if [[ $DRY_RUN -eq 1 ]] || launchctl print "system/$_label" >/dev/null 2>&1; then
      if ! run launchctl bootout system "$_plist" 2>/dev/null \
        && ! run launchctl unload -w "$_plist" 2>/dev/null; then
        log_warn "Could not unload $_plist; refusing to report a clean uninstall"
        ERRORS=$((ERRORS + 1))
      fi
    else
      log_info "$_plist present but daemon not loaded; skipping unload"
    fi
    # Not safe_rm: this is a single known file, rm -f is narrow enough.
    if [[ $DRY_RUN -eq 1 ]]; then
      log_dry "rm -f $(printf '%q' "$_plist")"
    else
      if rm -f "$_plist"; then
        log_ok "removed: $_plist"
      else
        log_err "could not remove: $_plist"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  else
    log_info "skip (not present): $_plist"
  fi
done
unset _plist

# --------------------------------------------------------------------------
# 2. nixbld users + group
# --------------------------------------------------------------------------
log_section "2. Removing _nixbld* users and nixbld group"
# `|| true` absorbs grep's exit 1 when no match (pipefail is on).
_nixbld_list="$(dscl . -list /Users 2>/dev/null \
               | grep -E '^_nixbld[0-9]+$' || true)"
if [[ -n "${_nixbld_list// /}" ]]; then
  while IFS= read -r _uid; do
    [[ -z "$_uid" ]] && continue
    if ! run dscl . -delete "/Users/$_uid"; then
      log_err "could not remove user: $_uid"
      ERRORS=$((ERRORS + 1))
    fi
  done <<<"$_nixbld_list"
else
  log_info "no _nixbld* users to remove"
fi
unset _nixbld_list _uid

if dscl . -read /Groups/nixbld >/dev/null 2>&1; then
  if ! run dscl . -delete /Groups/nixbld; then
    log_err "could not remove group: nixbld"
    ERRORS=$((ERRORS + 1))
  fi
else
  log_info "skip (not present): /Groups/nixbld"
fi

# --------------------------------------------------------------------------
# 3. Nix directories and per-user state
# --------------------------------------------------------------------------
log_section "3. Removing Nix config and per-user state"
safe_rm /etc/nix || ERRORS=$((ERRORS + 1))
safe_rm /var/root/.nix-profile || ERRORS=$((ERRORS + 1))
safe_rm /var/root/.nix-defexpr || ERRORS=$((ERRORS + 1))
safe_rm /var/root/.nix-channels || ERRORS=$((ERRORS + 1))
if [[ -n "$USER_HOME" ]]; then
  safe_rm "$USER_HOME/.nix-profile" || ERRORS=$((ERRORS + 1))
  safe_rm "$USER_HOME/.nix-defexpr" || ERRORS=$((ERRORS + 1))
  safe_rm "$USER_HOME/.nix-channels" || ERRORS=$((ERRORS + 1))
else
  log_info "invoking-user home unresolved — skipping per-user state"
fi

# --------------------------------------------------------------------------
# 4. /etc/synthetic.conf
# --------------------------------------------------------------------------
# Track real backups and edits separately from dry-run output.
SYNTHETIC_BACKUP=""
SYNTHETIC_BACKUP_CREATED=0
SYNTHETIC_CHANGED=0
FSTAB_BACKUP=""
FSTAB_BACKUP_CREATED=0
FSTAB_CHANGED=0

log_section "4. Cleaning /etc/synthetic.conf"
SYNTHETIC=/etc/synthetic.conf
if [[ -f "$SYNTHETIC" ]]; then
  # Match bare or two-field nix firmlink entries with an exact field boundary.
  if grep -qE '^nix([[:space:]].*)?$' "$SYNTHETIC"; then
    SYNTHETIC_BACKUP="${SYNTHETIC}.backup-before-nix-uninstall-${TS}"
    backup_ready=1
    if ! run cp -p "$SYNTHETIC" "$SYNTHETIC_BACKUP"; then
      log_err "Backup failed; refusing to modify $SYNTHETIC"
      ERRORS=$((ERRORS + 1))
      backup_ready=0
    fi
    # Flag only when the backup truly exists (run is a no-op under --dry-run).
    if [[ -f "$SYNTHETIC_BACKUP" ]]; then
      SYNTHETIC_BACKUP_CREATED=1
    fi
    if [[ $backup_ready -eq 0 ]]; then
      :
    elif [[ $DRY_RUN -eq 1 ]]; then
      log_dry "sed -i '' -E '/^nix([[:space:]].*)?\$/d' $SYNTHETIC"
    else
      if sed -i '' -E '/^nix([[:space:]].*)?$/d' "$SYNTHETIC"; then
        log_ok "stripped 'nix' entry from $SYNTHETIC"
        SYNTHETIC_CHANGED=1
      else
        log_err "could not modify $SYNTHETIC"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  else
    log_info "no 'nix' entry in $SYNTHETIC"
  fi
else
  log_info "skip (not present): $SYNTHETIC"
fi

# --------------------------------------------------------------------------
# 5. /etc/fstab
# --------------------------------------------------------------------------
log_section "5. Cleaning /etc/fstab"
FSTAB=/etc/fstab
if [[ -f "$FSTAB" ]]; then
  # Match only active fstab entries whose mountpoint field is exactly /nix.
  _fstab_pattern='^[^#[:space:]][^[:space:]]*[[:space:]]+\/nix([[:space:]]|$)'
  if grep -qE "$_fstab_pattern" "$FSTAB"; then
    FSTAB_BACKUP="${FSTAB}.backup-before-nix-uninstall-${TS}"
    backup_ready=1
    if ! run cp -p "$FSTAB" "$FSTAB_BACKUP"; then
      log_err "Backup failed; refusing to modify $FSTAB"
      ERRORS=$((ERRORS + 1))
      backup_ready=0
    fi
    if [[ -f "$FSTAB_BACKUP" ]]; then
      FSTAB_BACKUP_CREATED=1
    fi
    if [[ $backup_ready -eq 0 ]]; then
      :
    elif [[ $DRY_RUN -eq 1 ]]; then
      log_dry "sed -i '' -E '/$_fstab_pattern/d' $FSTAB"
    else
      if sed -i '' -E "/$_fstab_pattern/d" "$FSTAB"; then
        log_ok "stripped /nix mount line(s) from $FSTAB"
        FSTAB_CHANGED=1
      else
        log_err "could not modify $FSTAB"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  else
    log_info "no /nix mount line in $FSTAB"
  fi
  unset _fstab_pattern
else
  log_info "skip (not present): $FSTAB"
fi

# --------------------------------------------------------------------------
# 6. APFS volume
# --------------------------------------------------------------------------
log_section "6. Nix APFS volume"

# Detection order:
#   (a) diskutil info /nix — works when the synthetic mount is active
#   (b) diskutil apfs list — parse for a volume literally named "Nix Store"
#   (c) diskutil list      — final fallback to find the identifier
NIX_VOLUME_ID=""
ORPHAN_NIX_REMOVED=0

if diskutil info /nix >/dev/null 2>&1; then
  NIX_VOLUME_ID="$(diskutil info /nix 2>/dev/null \
                  | awk -F': *' '/Device Identifier/ { print $2; exit }' \
                  | awk '{ print $1 }')"
fi

# Trust /nix volume detection only when the exact volume name is "Nix Store".
if [[ -n "$NIX_VOLUME_ID" ]]; then
  _vname="$(diskutil info "$NIX_VOLUME_ID" 2>/dev/null \
            | awk -F': *' '/Volume Name/ { print $2; exit }' || true)"
  if [[ "$_vname" != "Nix Store" ]]; then
    log_info "/nix resolves to volume '${_vname:-unknown}' (not 'Nix Store'); ignoring path match."
    NIX_VOLUME_ID=""
  fi
  unset _vname
fi

if [[ -z "$NIX_VOLUME_ID" ]]; then
  # Match the exact Nix Store name while allowing diskutil's case-sensitivity suffix.
  NIX_VOLUME_ID="$(diskutil apfs list 2>/dev/null | awk '
    /APFS Volume Disk/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^disk[0-9]+s[0-9]+$/) { id = $i }
      }
    }
    /Name:[[:space:]]+Nix Store([[:space:]]+\([^)]*\))?[[:space:]]*$/ { print id; exit }
  ' || true)"
fi

if [[ -z "$NIX_VOLUME_ID" ]]; then
  # Confirm the exact volume name before accepting the fallback candidate.
  _cand="$(diskutil list 2>/dev/null | awk '/Nix Store/ { print $NF; exit }' || true)"
  if [[ -n "$_cand" ]] && diskutil info "$_cand" 2>/dev/null \
       | awk -F': *' '/Volume Name/ { print $2; exit }' | grep -qx 'Nix Store'; then
    NIX_VOLUME_ID="$_cand"
  fi
  unset _cand
fi

if [[ -z "$NIX_VOLUME_ID" ]]; then
  log_info "No Nix APFS volume found."
  if [[ -e /nix || -L /nix ]]; then
    if mount | grep -q ' on /nix '; then
      # Never recursively remove an unidentified live /nix mount.
      log_err "/nix is currently mounted but no Nix APFS volume was detected."
      log_err "Refusing to rm -rf a live mount. Unmount and delete it manually:"
      log_err "  diskutil unmount force /nix"
    else
      log_warn "Found orphan /nix path but no Nix APFS volume."
      log_warn "This is usually a leftover mountpoint from a partial/old install."
      # strict_confirm so --yes can never auto-delete a system path.
      if strict_confirm "Remove orphan /nix directory/symlink?"; then
        safe_rm /nix || ERRORS=$((ERRORS + 1))
        if [[ ! -e /nix && ! -L /nix ]]; then
          ORPHAN_NIX_REMOVED=1
        fi
      else
        log_info "Keeping /nix. install.sh/doctor may report a partial Nix install."
      fi
    fi
  fi
else
  _final_vname="$(diskutil info "$NIX_VOLUME_ID" 2>/dev/null \
                  | awk -F': *' '/Volume Name/ { print $2; exit }' || true)"
  log_warn "Found Nix APFS volume: ${NIX_VOLUME_ID} (name: '${_final_vname:-unknown}')"
  log_warn "Deleting this volume is irreversible and frees the disk space."
  # Uses strict_confirm so --yes cannot auto-delete the volume; README promises
  # "never deletes the APFS volume without confirmation" and we enforce that.
  # The volume name is surfaced so a wrong target can be caught before typing yes.
  if strict_confirm "Delete APFS volume '${NIX_VOLUME_ID}' (name: '${_final_vname:-unknown}')?"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_dry "diskutil apfs deleteVolume $(printf '%q' "$NIX_VOLUME_ID")"
    else
      if diskutil apfs deleteVolume "$NIX_VOLUME_ID"; then
        log_ok "deleted APFS volume: $NIX_VOLUME_ID"
      else
        log_warn "deleteVolume failed. If the volume is FileVault-locked or"
        log_warn "busy, try: diskutil unmount force /nix  (then re-run)."
        ERRORS=$((ERRORS + 1))
      fi
    fi
  else
    log_info "Skipping volume deletion. Run later with:"
    log_info "  sudo diskutil apfs deleteVolume '${NIX_VOLUME_ID}'"
  fi
fi

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
if [[ $ERRORS -gt 0 ]]; then
  log_section "Uninstall incomplete ($ERRORS error(s))"
else
  log_section "Uninstall complete"
fi
# Report cleanup only when both the edit and its backup occurred.
printf 'Summary:\n'
if [[ $ERRORS -eq 0 ]]; then
  printf '  - Core cleanup:     completed for all attempted operations\n'
else
  printf '  - Core cleanup:     incomplete; %d operation(s) failed (see above)\n' "$ERRORS"
fi
if [[ $SYNTHETIC_CHANGED -eq 1 && $SYNTHETIC_BACKUP_CREATED -eq 1 ]]; then
  printf '  - synthetic.conf:   cleaned, backup: %s\n' "$SYNTHETIC_BACKUP"
else
  printf '  - synthetic.conf:   no nix entry found, unchanged\n'
fi
if [[ $FSTAB_CHANGED -eq 1 && $FSTAB_BACKUP_CREATED -eq 1 ]]; then
  printf '  - fstab:            cleaned, backup: %s\n' "$FSTAB_BACKUP"
else
  printf '  - fstab:            no nix entry found, unchanged\n'
fi
printf '  - APFS volume:      see step 6\n'
if [[ $ORPHAN_NIX_REMOVED -eq 1 ]]; then
  printf '  - orphan /nix:      removed\n'
fi
printf '\n'
printf 'A macOS restart is strongly recommended so /etc/synthetic.conf is\n'
printf 're-evaluated and /nix disappears for good:\n\n'
printf '  sudo shutdown -r now\n\n'
printf 'If you kept the APFS volume, it remains on disk but will not be visible\n'
printf 'at /nix after the reboot.\n'

(( ERRORS == 0 ))
