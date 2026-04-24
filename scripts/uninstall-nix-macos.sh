#!/usr/bin/env bash
# uninstall-nix-macos.sh — safe, interactive uninstaller for Nix on macOS.
#
# Targets the multi-user install (launch daemons, nixbld users, /etc/nix,
# /etc/synthetic.conf, /etc/fstab, APFS volume). Auto-detects the Determinate
# Systems installer at /nix/nix-installer and prefers its built-in uninstaller
# when present.
#
# Everything destructive is gated behind a confirmation prompt unless --yes
# is passed. --dry-run prints every intended action and changes nothing.
#
# Read this script before running it. It performs sudo operations and deletes
# system files.

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
              Does NOT auto-confirm the APFS volume deletion — that step
              always requires interactive confirmation typed as 'yes'.
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
    if [[ ${#ORIGINAL_ARGV[@]} -gt 0 ]]; then
      exec sudo -E bash "$0" "${ORIGINAL_ARGV[@]}"
    else
      exec sudo -E bash "$0"
    fi
  fi
fi

# --------------------------------------------------------------------------
# Shared state
# --------------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"

# Resolve the invoking user's home (under sudo, $HOME is /var/root). Use dscl
# rather than `eval ~user` to avoid shell interpretation of SUDO_USER.
USER_HOME=""
if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
  USER_HOME="$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory 2>/dev/null \
              | awk '/NFSHomeDirectory/ { print $2 }' || true)"
fi
USER_HOME="${USER_HOME:-${HOME:-}}"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Run or simulate a command. Quotes args on display so "a b" doesn't look
# like two arguments.
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

# Confirmation prompt. --yes skips. Dry-run prints the question but never
# blocks. Reads from /dev/tty so it works under pipes too.
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

# Strict confirmation — never honours --yes. Used for irreversible destructive
# steps where auto-confirm is actively dangerous (APFS volume deletion).
# README promises "never deletes the APFS volume without confirmation"; this
# function is how we keep that promise even when --yes was passed.
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
    IFS= read -r reply || return 1
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
  # strict_confirm requires the user to type 'yes' — same bar as our own APFS
  # deletion. This closes the bypass where --yes would auto-run Determinate's
  # uninstaller (which then handles APFS without a second prompt from us).
  if strict_confirm "Use 'sudo /nix/nix-installer uninstall' and exit?"; then
    run /nix/nix-installer uninstall
    log_ok "Determinate uninstall finished. A restart is still recommended."
    exit 0
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
    # bootout is the modern API; unload -w is the fallback for older macOS.
    # Both may fail harmlessly if the daemon isn't loaded — we continue.
    run launchctl bootout system "$_plist" 2>/dev/null || true
    run launchctl unload -w "$_plist" 2>/dev/null || true
    # Not safe_rm: this is a single known file, rm -f is narrow enough.
    if [[ $DRY_RUN -eq 1 ]]; then
      log_dry "rm -f $(printf '%q' "$_plist")"
    else
      rm -f "$_plist" && log_ok "removed: $_plist"
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
    run dscl . -delete "/Users/$_uid" || true
  done <<<"$_nixbld_list"
else
  log_info "no _nixbld* users to remove"
fi
unset _nixbld_list _uid

if dscl . -read /Groups/nixbld >/dev/null 2>&1; then
  run dscl . -delete /Groups/nixbld || true
else
  log_info "skip (not present): /Groups/nixbld"
fi

# --------------------------------------------------------------------------
# 3. Nix directories and per-user state
# --------------------------------------------------------------------------
log_section "3. Removing Nix config and per-user state"
safe_rm /etc/nix
safe_rm /var/root/.nix-profile
safe_rm /var/root/.nix-defexpr
safe_rm /var/root/.nix-channels
if [[ -n "$USER_HOME" ]]; then
  safe_rm "$USER_HOME/.nix-profile"
  safe_rm "$USER_HOME/.nix-defexpr"
  safe_rm "$USER_HOME/.nix-channels"
else
  log_info "invoking-user home unresolved — skipping per-user state"
fi

# --------------------------------------------------------------------------
# 4. /etc/synthetic.conf
# --------------------------------------------------------------------------
# Four tracker variables (read by the summary block at the end).
# BACKUP_CREATED flips only when the backup file actually lands on disk.
# CHANGED flips only when sed actually rewrites the file. Both stay 0 in
# dry-run, so the summary never falsely claims a cleanup that did not run.
SYNTHETIC_BACKUP=""
SYNTHETIC_BACKUP_CREATED=0
SYNTHETIC_CHANGED=0
FSTAB_BACKUP=""
FSTAB_BACKUP_CREATED=0
FSTAB_CHANGED=0

log_section "4. Cleaning /etc/synthetic.conf"
SYNTHETIC=/etc/synthetic.conf
if [[ -f "$SYNTHETIC" ]]; then
  # Match ONLY the exact canonical line "nix" (optionally followed by
  # trailing whitespace). Never touches other firmlink entries.
  if grep -qE '^nix[[:space:]]*$' "$SYNTHETIC"; then
    SYNTHETIC_BACKUP="${SYNTHETIC}.backup-before-nix-uninstall-${TS}"
    run cp -p "$SYNTHETIC" "$SYNTHETIC_BACKUP"
    # Flag only when the backup truly exists (run is a no-op under --dry-run).
    if [[ -f "$SYNTHETIC_BACKUP" ]]; then
      SYNTHETIC_BACKUP_CREATED=1
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      log_dry "sed -i '' '/^nix[[:space:]]*\$/d' $SYNTHETIC"
    else
      sed -i '' '/^nix[[:space:]]*$/d' "$SYNTHETIC"
      log_ok "stripped 'nix' entry from $SYNTHETIC"
      SYNTHETIC_CHANGED=1
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
  # Pattern matches real fstab entries where /nix is the mountpoint field:
  #   <non-comment-device> <ws> /nix <ws or EOL>
  # Never matches comments (#...) or lines where /nix is part of a longer
  # path like /nix2 or /home/nix. If nothing matches (e.g. fstab is empty
  # or pure comments) we skip the rewrite entirely, so the file is never
  # rewritten unnecessarily.
  # The `/` in `/nix` is backslash-escaped so sed's default `/` pattern
  # delimiter doesn't terminate early; grep -E is fine with the escape too.
  _fstab_pattern='^[^#[:space:]][^[:space:]]*[[:space:]]+\/nix([[:space:]]|$)'
  if grep -qE "$_fstab_pattern" "$FSTAB"; then
    FSTAB_BACKUP="${FSTAB}.backup-before-nix-uninstall-${TS}"
    run cp -p "$FSTAB" "$FSTAB_BACKUP"
    if [[ -f "$FSTAB_BACKUP" ]]; then
      FSTAB_BACKUP_CREATED=1
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      log_dry "sed -i '' -E '/$_fstab_pattern/d' $FSTAB"
    else
      sed -i '' -E "/$_fstab_pattern/d" "$FSTAB"
      log_ok "stripped /nix mount line(s) from $FSTAB"
      FSTAB_CHANGED=1
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

if [[ -z "$NIX_VOLUME_ID" ]]; then
  # `diskutil apfs list` groups volumes with identifiers like "disk3s7".
  # We track the most recent identifier line and emit it when we hit a
  # "Name: Nix Store" row inside the same block.
  NIX_VOLUME_ID="$(diskutil apfs list 2>/dev/null | awk '
    /APFS Volume Disk/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^disk[0-9]+s[0-9]+$/) { id = $i }
      }
    }
    /Name:[[:space:]]+Nix Store/ { print id; exit }
  ' || true)"
fi

if [[ -z "$NIX_VOLUME_ID" ]]; then
  # Last resort — any volume literally named "Nix Store" in `diskutil list`
  NIX_VOLUME_ID="$(diskutil list 2>/dev/null \
                   | awk '/Nix Store/ { print $NF; exit }' || true)"
fi

if [[ -z "$NIX_VOLUME_ID" ]]; then
  log_info "No Nix APFS volume found."
  if [[ -e /nix || -L /nix ]]; then
    log_warn "Found orphan /nix path but no Nix APFS volume."
    log_warn "This is usually a leftover mountpoint from a partial/old install."
    if confirm "Remove orphan /nix directory/symlink?"; then
      safe_rm /nix
      if [[ ! -e /nix && ! -L /nix ]]; then
        ORPHAN_NIX_REMOVED=1
      fi
    else
      log_info "Keeping /nix. install.sh/doctor may report a partial Nix install."
    fi
  fi
else
  log_warn "Found Nix APFS volume: ${NIX_VOLUME_ID}"
  log_warn "Deleting this volume is irreversible and frees the disk space."
  # Uses strict_confirm so --yes cannot auto-delete the volume; README promises
  # "never deletes the APFS volume without confirmation" and we enforce that.
  if strict_confirm "Delete APFS volume '${NIX_VOLUME_ID}'?"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_dry "diskutil apfs deleteVolume $(printf '%q' "$NIX_VOLUME_ID")"
    else
      if diskutil apfs deleteVolume "$NIX_VOLUME_ID"; then
        log_ok "deleted APFS volume: $NIX_VOLUME_ID"
      else
        log_warn "deleteVolume failed. If the volume is FileVault-locked or"
        log_warn "busy, try: diskutil unmount force /nix  (then re-run)."
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
log_section "Uninstall complete"
# Summary reflects what actually happened. Claims of "cleaned" + backup are
# gated on both CHANGED and BACKUP_CREATED being 1 so dry-run can never
# print a path that does not exist on disk.
printf 'Summary:\n'
printf '  - Launch daemons:   unloaded + removed (if present)\n'
printf '  - nixbld accounts:  removed (if present)\n'
printf '  - Nix state:        /etc/nix + per-user .nix-* removed (if present)\n'
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
