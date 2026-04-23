#!/usr/bin/env zsh

# macsmith - Bootstrap Script
# One-command installer: curl -fsSL https://raw.githubusercontent.com/26zl/macsmith/main/bootstrap.sh | zsh
#
# Hardening notes:
#   - Pinned-ref support: set MACSMITH_REF=vYYYY.MM.DD-sha (or commit/branch)
#     to avoid running whatever is on main. Recommended for production setups.
#   - Explicit TLS via curl defaults + git's HTTPS; no plaintext fallbacks.
#   - Shallow single-branch clone minimises transferred surface.
#   - Post-clone sanity check: install.sh must be a real regular file before we run it.
#   - Interactive 5s abort window so curl|bash consumers can ctrl-c after seeing what runs.
#     Suppressed with MACSMITH_YES=1 / NONINTERACTIVE=1 / CI=1.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_URL="${MACSMITH_REPO:-https://github.com/26zl/macsmith.git}"
REF="${MACSMITH_REF:-main}"
CLONE_DIR="${TMPDIR:-/tmp}/macsmith-$$"

printf '%b🚀 macsmith%b\n' "$GREEN" "$NC"
printf '========================================\n\n'

printf '%bWhat this will do:%b\n' "$BLUE" "$NC"
printf '  1. git clone %s (ref: %s) into %s\n' "$REPO_URL" "$REF" "$CLONE_DIR"
printf '  2. Run install.sh from the cloned copy\n'
printf '  3. Offer to also run dev-tools.sh\n'
printf '  4. Remove the cloned copy on exit\n\n'

# Check macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%bERROR: This script is designed for macOS only%b\n' "$RED" "$NC" >&2
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

# Abort window: give the user a chance to Ctrl-C before we clone + run.
# The countdown does NOT need stdin (it's just timed output + signal handling),
# so it runs for the curl|zsh path too — which is exactly when you want it.
# Only suppressed when the invocation was explicitly auto-approved.
_is_autoyes() {
  [[ -n "${MACSMITH_YES:-}" ]] || [[ -n "${NONINTERACTIVE:-}" ]] || [[ -n "${CI:-}" ]]
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
  printf '  curl -fsSL https://raw.githubusercontent.com/26zl/macsmith/main/bootstrap.sh | zsh\n'
  exit 0
fi

# Cleanup on exit (including Ctrl-C). Prints a friendly interrupt message
# so the user knows the tmp clone is gone and nothing persistent was written
# by bootstrap itself (install.sh handles its own atomic writes).
_bs_interrupted=0
cleanup() {
  rm -rf "$CLONE_DIR" 2>/dev/null || true
  if [[ "$_bs_interrupted" == "1" ]]; then
    printf '\n\033[1;33m⚠️  Bootstrap interrupted.\033[0m\n'
    printf '  Cloned files removed from %s.\n' "$CLONE_DIR"
    printf '  If install.sh had started, any partial changes were rolled back by its atomic writes.\n'
    printf '  Re-run when ready:\n'
    printf '    curl -fsSL https://raw.githubusercontent.com/26zl/macsmith/main/bootstrap.sh | zsh\n'
  fi
}
_on_int() { _bs_interrupted=1; trap - INT; kill -INT $$; }
trap cleanup EXIT TERM HUP
trap _on_int INT

# Clone repository at the requested ref
printf 'Downloading setup files (ref=%s)...\n' "$REF"
if ! git -c advice.detachedHead=false clone \
      --depth=1 \
      --single-branch \
      --branch "$REF" \
      "$REPO_URL" "$CLONE_DIR" 2>/dev/null; then
  # Fall back to full clone + checkout for commit SHAs (can't be --branch'd)
  printf '%bINFO:%b Shallow clone of ref failed, trying full clone + checkout...\n' "$BLUE" "$NC"
  rm -rf "$CLONE_DIR"
  if ! git clone "$REPO_URL" "$CLONE_DIR" 2>/dev/null; then
    printf '%bERROR: Failed to clone repo. Check network or MACSMITH_REF=%s%b\n' "$RED" "$REF" "$NC" >&2
    exit 1
  fi
  if ! git -C "$CLONE_DIR" -c advice.detachedHead=false checkout "$REF" 2>/dev/null; then
    printf '%bERROR: Ref %s not found in repo%b\n' "$RED" "$REF" "$NC" >&2
    exit 1
  fi
fi

# Post-clone sanity: make sure we got the expected files and they're regular files
for required in install.sh dev-tools.sh zsh.sh macsmith.sh; do
  if [[ ! -f "$CLONE_DIR/$required" ]]; then
    printf '%bERROR: Expected file missing after clone: %s%b\n' "$RED" "$required" "$NC" >&2
    exit 1
  fi
  if [[ -L "$CLONE_DIR/$required" ]]; then
    printf '%bERROR: %s is a symlink, refusing to execute%b\n' "$RED" "$required" "$NC" >&2
    exit 1
  fi
done

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
  # Only inherit auto-yes when the bootstrap invocation itself was auto-yes'd
  # (CI / MACSMITH_YES / NONINTERACTIVE). A plain "y" to the prompt
  # above should NOT silently auto-install every optional language tool.
  if _is_autoyes; then
    NONINTERACTIVE=1 ./dev-tools.sh
  else
    ./dev-tools.sh
  fi
else
  printf '%bINFO:%b Skipped. You can run dev-tools.sh later from the repo.\n' "$BLUE" "$NC"
fi

printf '\n%b✅ Setup complete!%b\n\n' "$GREEN" "$NC"
printf 'Run: source ~/.zshrc\n\n'
