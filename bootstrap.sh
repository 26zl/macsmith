#!/usr/bin/env zsh

# Bootstrap macsmith from a validated HTTPS Git ref.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
if [[ -n "${NO_COLOR:-}" ]]; then
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

_env_true() {
  case "${1:l}" in
    1|true|yes|on|enable|enabled) return 0 ;;
  esac
  return 1
}

REPO_URL="${MACSMITH_REPO:-https://github.com/26zl/macsmith.git}"
REF="${MACSMITH_REF:-main}"
# Accept only non-option Git ref characters before passing REF to clone or checkout.
if [[ ! "$REF" =~ ^[A-Za-z0-9._/][A-Za-z0-9._/-]*$ ]]; then
  printf 'ERROR: MACSMITH_REF contains invalid characters: %s\n' "$REF" >&2
  exit 1
fi
# Env-var prefix that preserves a pin/override across the printed re-run hints.
_rerun_prefix=""
if [[ -n "${MACSMITH_REPO:-}" ]]; then
  _rerun_prefix="MACSMITH_REPO=$REPO_URL "
fi
if [[ "$REF" != "main" ]]; then
  _rerun_prefix="${_rerun_prefix}MACSMITH_REF=$REF "
fi
# Use an unpredictable private clone directory.
CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macsmith-XXXXXX")"

# Register cleanup before any operation that can exit.
_bs_interrupted=0
_bs_cleaned=0
cleanup() {
  if [[ "$_bs_cleaned" == "1" ]]; then
    return 0
  fi
  _bs_cleaned=1
  rm -rf "$CLONE_DIR" 2>/dev/null || true
  if [[ "$_bs_interrupted" == "1" ]]; then
    printf '\n\033[1;33m⚠️  Bootstrap interrupted.\033[0m\n'
    printf '  Cloned files removed from %s.\n' "$CLONE_DIR"
    printf '  Atomic config writes were not left half-written; completed installs were not rolled back.\n'
    printf '  Re-run when ready:\n'
    printf '    %scurl -fsSL https://raw.githubusercontent.com/26zl/macsmith/main/bootstrap.sh | zsh\n' "$_rerun_prefix"
  fi
}
# Clean up before re-raising SIGINT so callers observe cancellation.
_on_int() { _bs_interrupted=1; cleanup; trap - INT EXIT; kill -INT $$; }
# Re-raise termination signals after cleanup to preserve their exit status.
_on_term() { _bs_interrupted=1; cleanup; trap - TERM HUP EXIT; kill -TERM $$; }
trap cleanup EXIT
trap _on_int INT
trap _on_term TERM HUP

# Validate the environment and repository URL before displaying them.
# Check macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%bERROR: This script is designed for macOS only%b\n' "$RED" "$NC" >&2
  exit 1
fi

# Enforce the documented minimum (macOS 13 Ventura)
os_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)" || os_major=''
if [[ "$os_major" =~ ^[0-9]+$ ]] && (( os_major < 13 )); then
  printf '%bERROR: macsmith requires macOS 13 (Ventura) or later (detected %s)%b\n' "$RED" "$(sw_vers -productVersion 2>/dev/null)" "$NC" >&2
  exit 1
fi

# Enforce HTTPS on the repo URL
case "$REPO_URL" in
  https://*) ;;
  *)
    printf '%bERROR: MACSMITH_REPO must be an https:// URL (got: %s)%b\n' "$RED" "$REPO_URL" "$NC" >&2
    exit 1
    ;;
esac

# The quoted heredoc prevents command substitution in the banner.
printf '%b' "$GREEN"
cat <<'BANNER'

                                                        \ \ \
                                                         \ \ \
                                    _ _   _              _\_\_\___
 _ __ ___   __ _  ___ ___ _ __ ___ (_) |_| |__          |         |
| '_ ` _ \ / _` |/ __/ __| '_ ` _ \| | __| '_ \         |         |
| | | | | | (_| | (__\__ \ | | | | | | |_| | | |      **|_________|
|_| |_| |_|\__,_|\___|___/_| |_| |_|_|\__|_| |_| * * **
                                                * **  *
                 ⚒  forge your Mac  ⚒          * *
BANNER
printf '%b\n' "$NC"

printf '%bWhat this will do:%b\n' "$BLUE" "$NC"
printf '  1. git clone %s (ref: %s) into %s\n' "$REPO_URL" "$REF" "$CLONE_DIR"
printf '  2. Run install.sh from the cloned copy\n'
printf '  3. Offer to also run dev-tools.sh\n'
printf '  4. Remove the cloned copy on exit\n\n'

# Give interactive users five seconds to cancel before cloning.
_is_autoyes() {
  _env_true "${MACSMITH_YES:-}" || _env_true "${NONINTERACTIVE:-}" || _env_true "${CI:-}"
}
if ! _is_autoyes; then
  printf '%bStarting in 5 seconds. Press Ctrl-C to abort.%b\n' "$YELLOW" "$NC"
  for i in 5 4 3 2 1; do
    printf '  %s... ' "$i"
    sleep 1
  done
  printf '\n\n'
fi

# Check for git (comes with Xcode CLT, but may not be installed yet)
if ! command -v git >/dev/null 2>&1; then
  printf '%bGit not found. Installing Xcode Command Line Tools...%b\n' "$YELLOW" "$NC"
  printf '%bINFO:%b A dialog will appear - please click "Install" and wait for completion\n' "$BLUE" "$NC"
  xcode-select --install 2>/dev/null || true
  printf '\n'
  printf '%bAfter Xcode CLT installation completes, re-run this command:%b\n' "$YELLOW" "$NC"
  printf '  %scurl -fsSL https://raw.githubusercontent.com/26zl/macsmith/main/bootstrap.sh | zsh\n' "$_rerun_prefix"
  exit 0
fi

# Clone repository at the requested ref
printf 'Downloading setup files (ref=%s)...\n' "$REF"
if ! git -c advice.detachedHead=false clone \
      -c http.lowSpeedLimit=1 \
      -c http.lowSpeedTime=30 \
      --depth=1 \
      --single-branch \
      --branch "$REF" \
      "$REPO_URL" "$CLONE_DIR" 2>/dev/null; then
  # Fall back to full clone + checkout for commit SHAs (can't be --branch'd)
  printf '%bINFO:%b Shallow clone of ref failed, trying full clone + checkout...\n' "$BLUE" "$NC"
  rm -rf "$CLONE_DIR"
  # Restore private permissions after removing the original temporary directory.
  mkdir -m 700 "$CLONE_DIR"
  if ! clone_err="$(git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 clone "$REPO_URL" "$CLONE_DIR" 2>&1)"; then
    printf '%bERROR: Failed to clone repo. Check network or MACSMITH_REF=%s%b\n' "$RED" "$REF" "$NC" >&2
    printf '%s\n' "$clone_err" >&2
    exit 1
  fi
  # Require REF to resolve to a commit before checkout.
  if ! git -C "$CLONE_DIR" rev-parse --verify --quiet "${REF}^{commit}" >/dev/null 2>&1; then
    printf '%bERROR: Ref %s not found in repo%b\n' "$RED" "$REF" "$NC" >&2
    exit 1
  fi
  if ! checkout_err="$(git -C "$CLONE_DIR" -c advice.detachedHead=false checkout "$REF" -- 2>&1)"; then
    printf '%bERROR: Failed to checkout ref %s%b\n' "$RED" "$REF" "$NC" >&2
    printf '%s\n' "$checkout_err" >&2
    exit 1
  fi
fi

# Require every installed artifact to be a regular file.
for required in install.sh dev-tools.sh zsh.sh macsmith.sh \
                scripts/nix-macos-maintenance.sh scripts/uninstall-nix-macos.sh \
                scripts/uninstall-macsmith.sh scripts/setup-github.sh \
                config/starship.toml; do
  if [[ ! -f "$CLONE_DIR/$required" ]]; then
    printf '%bERROR: Expected file missing after clone: %s%b\n' "$RED" "$required" "$NC" >&2
    exit 1
  fi
  if [[ -L "$CLONE_DIR/$required" ]]; then
    printf '%bERROR: %s is a symlink, refusing to execute%b\n' "$RED" "$required" "$NC" >&2
    exit 1
  fi
done

# Reject symlinks because install.sh copies the cloned tree into user paths.
if [[ -n "$(find "$CLONE_DIR" -type l 2>/dev/null)" ]]; then
  printf '%bERROR: Clone contains a symlink, refusing to proceed%b\n' "$RED" "$NC" >&2
  exit 1
fi

# Print what we got so the user can see what they're about to run
clone_head="$(git -C "$CLONE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
clone_desc="$(git -C "$CLONE_DIR" describe --tags --always 2>/dev/null || echo "$clone_head")"
printf '%b✅ Downloaded%b (HEAD=%s, desc=%s)\n\n' "$GREEN" "$NC" "$clone_head" "$clone_desc"

# Run install.sh
cd "$CLONE_DIR"
chmod +x install.sh
./install.sh

# Offer dev-tools
printf '\n'
printf '%bINFO:%b Core setup complete.\n\n' "$BLUE" "$NC"

_should_run_devtools() {
  if _is_autoyes; then
    return 0
  fi
  # Need a TTY for the prompt below
  if [[ ! -e /dev/tty ]]; then
    return 1
  fi
  printf 'Optional: Install development language tools (Python, Node.js, Rust, Go, etc.)?\n'
  printf '[y/N]: '
  local response=""
  read -r response </dev/tty || return 1
  case "$response" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

if _should_run_devtools; then
  chmod +x dev-tools.sh
  # Pass non-interactive mode only when the bootstrap itself was auto-approved.
  if _is_autoyes; then
    NONINTERACTIVE=1 ./dev-tools.sh
  else
    ./dev-tools.sh
  fi
else
  printf '%bINFO:%b Skipped. Run the dev-tools command later to install language tools (macsmith re-execs it from its data dir).\n' "$BLUE" "$NC"
fi

printf '\n%b✅ Setup complete!%b\n\n' "$GREEN" "$NC"
printf 'Open a new terminal (or run: exec zsh -l) to load your new environment.\n'
printf '(PATH changes live in ~/.zprofile, which only a login shell re-reads —\n'
printf ' "source ~/.zshrc" alone will not pick them up.)\n\n'
