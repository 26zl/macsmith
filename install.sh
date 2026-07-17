#!/usr/bin/env zsh

# macsmith - Installation Script

set +e  # Allow optional components to fail (will be set per function)

# Concurrent-run protection + interrupt handling.
# Track atomic-write temporary files for cleanup.
if [[ -z "${HOME:-}" ]]; then
  echo "ERROR: HOME is not set; refusing to install into an unknown user profile" >&2
  exit 1
fi
DATA_DIR="$HOME/.local/share/macsmith"
LOCK_DIR="$DATA_DIR/install.lock.d"
typeset -ga TMP_FILES=()
_interrupted=0
_cleanup_ran=0

# Keep cleanup idempotent across normal exits and re-raised signals.
_cleanup_on_exit() {
  if [[ "$_cleanup_ran" == "1" ]]; then return 0; fi
  _cleanup_ran=1
  # Remove any tempfiles from atomic writes that never got renamed into place
  local f
  for f in "${TMP_FILES[@]}"; do
    [[ -n "$f" ]] && rm -f "$f" 2>/dev/null || true
  done
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  if [[ "$_interrupted" == "1" ]]; then
    printf '\n\033[1;33m⚠️  Install interrupted.\033[0m\n'
    printf '  Config files were not left half-written; completed package installs were not rolled back.\n'
    printf '  Backups of your previous config (if any) are in: ~/.zshrc.backup.* and ~/.zprofile.backup.*\n'
    printf '  Re-run this script when ready — it is idempotent.\n'
  fi
}
_on_interrupt() {
  _interrupted=1
  # In zsh the EXIT trap does NOT fire after a re-raised SIGINT, so run cleanup
  # explicitly here (mirrors _on_term); otherwise the lock + atomic-write
  # tempfiles leak and the interrupt notice never prints.
  _cleanup_on_exit
  # Re-raise SIGINT so parent (bootstrap.sh) sees the cancel too
  trap - INT EXIT
  kill -INT $$
}
# Re-raise termination signals after cleanup to preserve their status.
_on_term() {
  _interrupted=1
  _cleanup_on_exit
  trap - TERM HUP EXIT
  kill -TERM $$
}

_acquire_lock() {
  mkdir -p "$DATA_DIR" 2>/dev/null || {
    echo "ERROR: Could not create $DATA_DIR" >&2
    exit 1
  }
  chmod 700 "$DATA_DIR" 2>/dev/null || true

  if [[ -d "$LOCK_DIR" ]]; then
    local lock_pid="" _tries=0
    # Give a writer that is mid-acquire a moment to publish its PID.
    while [[ -z "$lock_pid" ]] && (( _tries < 5 )); do
      lock_pid="$(<"$LOCK_DIR/pid" 2>/dev/null)"
      [[ -n "$lock_pid" ]] && break
      ((_tries++))
      sleep 0.2 2>/dev/null || sleep 1
    done
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "ERROR: Another instance of install.sh is already running (PID $lock_pid)"
      echo "  If this is a mistake, remove the lock directory: rm -rf $LOCK_DIR"
      exit 1
    fi
    # Empty PID (a run that crashed mid-acquire) or a dead PID → reclaim the
    # stale lock instead of wedging every future run.
    rm -rf "$LOCK_DIR"
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "ERROR: Could not acquire install lock at $LOCK_DIR" >&2
    exit 1
  fi
  # Write the owner PID immediately after acquiring the lock.
  echo $$ > "$LOCK_DIR/pid"
}
_acquire_lock
# Register traps at script scope to avoid zsh function-local EXIT traps.
trap _cleanup_on_exit EXIT
trap _on_interrupt INT
trap '_on_term' TERM HUP

# Copy through a destination-side temporary file, with an optional mode.
_atomic_copy() {
  local src="$1" dst="$2" mode="${3:-}"
  local dst_dir tmp old_umask target_mode=""
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir" 2>/dev/null || return 1
  if [[ -z "$mode" && -e "$dst" ]]; then
    target_mode="$(stat -f '%Lp' "$dst" 2>/dev/null || true)"
  fi
  old_umask="$(umask)"
  umask 077
  if ! tmp="$(mktemp "${dst_dir}/.macsmith.XXXXXX")"; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  TMP_FILES+=("$tmp")
  if ! cp -p "$src" "$tmp"; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  [[ -n "$mode" ]] && target_mode="$mode"
  if [[ -n "$target_mode" ]] && ! chmod "$target_mode" "$tmp"; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  mv -f "$tmp" "$dst" || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# Atomic write from stdin: content goes to tempfile, then renamed into place.
_atomic_write() {
  local dst="$1" mode="${2:-}"
  local dst_dir tmp old_umask target_mode="$mode"
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir" 2>/dev/null || return 1
  if [[ -z "$target_mode" && -e "$dst" ]]; then
    target_mode="$(stat -f '%Lp' "$dst" 2>/dev/null || true)"
  fi
  old_umask="$(umask)"
  umask 077
  if ! tmp="$(mktemp "${dst_dir}/.macsmith.XXXXXX")"; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  TMP_FILES+=("$tmp")
  if ! cat > "$tmp"; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  if [[ -n "$target_mode" ]] && ! chmod "$target_mode" "$tmp"; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  mv -f "$tmp" "$dst" || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# Ensure standard Unix tools are in PATH (curl, git, etc.)
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Banner — figlet "macsmith" with a claw hammer drawn next to it.
# Single-quoted heredoc prevents backticks in the figlet art from triggering
# command substitution.
[[ -z "${NO_COLOR:-}" ]] && printf '\033[0;32m'
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
[[ -z "${NO_COLOR:-}" ]] && printf '\033[0m'
printf '\n'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
# Honor the NO_COLOR convention (https://no-color.org): blank the ANSI codes.
if [[ -n "${NO_COLOR:-}" ]]; then RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''; fi
# Collect warnings for the final summary.
install_warnings=()

warn() {
  install_warnings+=("$1")
  echo "${YELLOW}⚠️  $1${NC}"
}

# Extract a short reason from Homebrew error output.
_brew_fail_hint() {
  local err="$1"
  local first=""
  if echo "$err" | /usr/bin/grep -q "It seems there is already an App at"; then
    echo " (existing /Applications/* — use 'brew install --cask --force <pkg>' to overwrite)"
    return
  fi
  if echo "$err" | /usr/bin/grep -q "is already installed"; then
    echo " (already installed)"
    return
  fi
  first="$(echo "$err" | /usr/bin/grep -E '^Error: ' | /usr/bin/head -n1 | /usr/bin/sed 's/^Error: *//' | /usr/bin/cut -c 1-100)"
  if [[ -z "$first" ]]; then
    first="$(echo "$err" | /usr/bin/grep -v '^[[:space:]]*$' | /usr/bin/tail -n1 | /usr/bin/cut -c 1-100)"
  fi
  [[ -n "$first" ]] && echo " ($first)"
}

# Wrapper for curl with timeouts and retry
_curl_safe() {
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 "$@"
}

_download_verified_script() {
  local url="$1" expected_sha="$2" destination="$3"
  local actual_sha=""
  if ! _curl_safe -fsSL "$url" -o "$destination"; then
    return 1
  fi
  actual_sha="$(shasum -a 256 "$destination" 2>/dev/null | awk '{print $1}')"
  if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "${RED}❌ SHA-256 mismatch for installer from $url${NC}" >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   ${actual_sha:-unavailable}" >&2
    return 1
  fi
  if ! head -n1 "$destination" | grep -q '^#!'; then
    echo "${RED}❌ Downloaded installer has no shebang; refusing to execute it${NC}" >&2
    return 1
  fi
  chmod 700 "$destination" || return 1
}

_env_true() {
  case "${1:l}" in
    1|true|yes|on|enable|enabled) return 0 ;;
  esac
  return 1
}

# Ask user for confirmation with input validation
_ask_user() {
  local prompt="$1"
  local default="${2:-N}"
  
  # Validate inputs
  [[ -z "$prompt" ]] && { echo "${RED}Error: _ask_user called without prompt${NC}" >&2; return 1; }
  [[ "$default" != "Y" && "$default" != "N" ]] && default="N"
  
  # Non-interactive: MACSMITH_YES=1 → yes to all; NONINTERACTIVE/CI=1 → each prompt's
  # own default; FORCE_INTERACTIVE=1 → real prompts. Export so child processes see it.
  if _env_true "${NONINTERACTIVE:-}"; then
    export NONINTERACTIVE=1
  fi
  if _env_true "${FORCE_INTERACTIVE:-}"; then
    : # Proceed to prompt
  elif _env_true "${MACSMITH_YES:-}"; then
    echo "$prompt [Auto: yes]"
    return 0
  elif _env_true "${NONINTERACTIVE:-}" || _env_true "${CI:-}"; then
    if [[ "$default" == "Y" ]]; then
      echo "$prompt [Auto: yes (default)]"
      return 0
    else
      echo "$prompt [Auto: no (default)]"
      return 1
    fi
  fi
  
  # Retry invalid answers before falling back to the prompt default.
  local response="" attempts=0
  while true; do
    echo -n "$prompt "
    if [[ "$default" == "Y" ]]; then
      echo -n "[Y/n]: "
    else
      echo -n "[y/N]: "
    fi

    # Read from /dev/tty for piped bootstraps unless FORCE_INTERACTIVE keeps stdin.
    response=""
    if _env_true "${FORCE_INTERACTIVE:-}" || [[ -t 0 ]]; then
      IFS= read -r response || return 1
    elif [[ -e /dev/tty ]] && [[ -r /dev/tty ]]; then
      IFS= read -r response </dev/tty 2>/dev/null || return 1
    else
      return 1
    fi

    # Sanitize input: remove leading/trailing whitespace, limit length
    response=$(echo "$response" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ ${#response} -gt 10 ]] && response="${response:0:10}"  # Limit to 10 chars

    # Validate: only allow y, Y, n, N, yes, Yes, YES, no, No, NO, or empty
    if [[ -n "$response" ]] && [[ ! "$response" =~ ^[YyNn]$ ]] && [[ ! "$response" =~ ^[Yy][Ee][Ss]$ ]] && [[ ! "$response" =~ ^[Nn][Oo]$ ]]; then
      ((attempts++))
      if (( attempts >= 3 )); then
        echo "${RED}Too many invalid responses; using default ($default).${NC}" >&2
        response="$default"
      else
        echo "${RED}Invalid input. Please enter y/n/yes/no or press Enter for default.${NC}" >&2
        continue
      fi
    fi
    break
  done

  if [[ -z "$response" ]]; then
    response="$default"
  fi

  case "$response" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# Check if running on macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "${RED}❌ Error: This script is designed for macOS only${NC}"
  exit 1
fi

# Enforce the documented macOS 13 minimum.
os_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
if [[ "$os_major" =~ ^[0-9]+$ ]] && (( os_major < 13 )); then
  echo "${RED}❌ Error: macsmith requires macOS 13 (Ventura) or later (detected $(sw_vers -productVersion 2>/dev/null))${NC}"
  exit 1
fi

# Check available disk space (need ~15GB minimum for Xcode CLT + Homebrew + tools)
if command -v df >/dev/null 2>&1; then
  # -P forces single-line (POSIX) output so a long device name can't wrap the
  # row and shift the Available column; -g reports in GiB.
  available_gb=$(df -Pg / 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ "$available_gb" =~ ^[0-9]+$ ]] && [[ "$available_gb" -lt 15 ]]; then
    echo "${YELLOW}⚠️  WARNING: Low disk space detected (${available_gb}GB available)${NC}"
    echo "  ${BLUE}INFO:${NC} A full installation (Xcode CLT + Homebrew + dev tools) may need ~15-30GB"
    if ! _ask_user "Continue with limited disk space?" "N" 2>/dev/null; then
      echo "Exiting. Free up disk space and try again."
      exit 1
    fi
  fi
fi

# Detect Homebrew installation prefix
_detect_brew_prefix() {
  if [[ -d /opt/homebrew ]]; then
    echo /opt/homebrew
  elif [[ -d /usr/local/Homebrew ]] || [[ -x /usr/local/bin/brew ]]; then
    echo /usr/local
  else
    echo ""
  fi
}

HOMEBREW_PREFIX="$(_detect_brew_prefix)"

# Fresh-install vs upgrade detection
# Marker file is created at the end of a successful install.
# Presence = we've installed here before; absence = fresh machine.
INSTALL_STATE_FILE="$DATA_DIR/.install-state"

_is_fresh_install() {
  [[ ! -f "$INSTALL_STATE_FILE" ]]
}

_mark_install_state() {
  mkdir -p "$DATA_DIR"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  local version=""
  # Same precedence as setup_macsmith: shipped VERSION file (authoritative for
  # release zips, which have no .git) → git describe (local clone) → "unknown".
  if [[ -n "${REPO_ROOT:-}" ]] && [[ -f "$REPO_ROOT/VERSION" ]]; then
    version="$(head -n1 "$REPO_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"
  fi
  if [[ -z "$version" ]] && [[ -n "${REPO_ROOT:-}" ]] && [[ -d "$REPO_ROOT/.git" ]] && command -v git >/dev/null 2>&1; then
    version="$(cd "$REPO_ROOT" && git describe --tags --always 2>/dev/null || echo "")"
  fi
  [[ -z "$version" ]] && version="unknown"
  local first_install_at=""
  if [[ -f "$INSTALL_STATE_FILE" ]]; then
    first_install_at="$(grep '^first_install_at=' "$INSTALL_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
  fi
  [[ -z "$first_install_at" ]] && first_install_at="$now"

  {
    printf 'first_install_at=%s\n' "$first_install_at"
    printf 'last_install_at=%s\n' "$now"
    printf 'version=%s\n' "$version"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || echo unknown)"
  } > "$INSTALL_STATE_FILE"
}

# Detect repository root directory (where install.sh is located)
# This is saved early so it's available even after directory changes
_detect_repo_root() {
  local repo_root=""
  
  # Method 1: zsh-specific prompt-expansion trick to get the script path
  # shellcheck disable=SC2296  # ${(%):-%x} is valid zsh, not bash
  if [[ -n "${(%):-%x}" ]]; then
    # shellcheck disable=SC2296
    repo_root="$(cd "$(dirname "${(%):-%x}")" && pwd)" 2>/dev/null || repo_root=""
  fi
  
  # Method 2: Use $0 if method 1 failed
  if [[ -z "$repo_root" ]] || [[ ! -d "$repo_root" ]]; then
    if [[ -n "${0}" ]] && [[ -f "${0}" ]]; then
      repo_root="$(cd "$(dirname "${0}")" && pwd)" 2>/dev/null || repo_root=""
    fi
  fi
  
  # Method 3: Search from current directory up for macsmith.sh
  if [[ -z "$repo_root" ]] || [[ ! -f "$repo_root/macsmith.sh" ]]; then
    local search_dir="$(pwd)"
    local max_iterations=50
    local iteration=0
    while [[ "$search_dir" != "/" ]] && [[ $iteration -lt $max_iterations ]]; do
      if [[ -f "$search_dir/macsmith.sh" ]]; then
        repo_root="$search_dir"
        break
      fi
      local parent_dir="$(dirname "$search_dir")"
      # Safety check: if parent_dir is same as search_dir, we're stuck
      if [[ "$parent_dir" == "$search_dir" ]]; then
        break
      fi
      search_dir="$parent_dir"
      ((iteration++))
    done
  fi
  
  echo "$repo_root"
}

REPO_ROOT="$(_detect_repo_root)"

install_xcode_clt() {
  # Check if Xcode Command Line Tools are installed
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "${YELLOW}⚠️  IMPORTANT: Xcode Command Line Tools are required${NC}"
    echo "  ${BLUE}INFO:${NC} Xcode Command Line Tools include essential development tools"
    echo "  ${BLUE}INFO:${NC} This includes: Git, clang, make, and other build tools"
    echo ""
    echo "  Installing Xcode Command Line Tools..."
    echo "  ${BLUE}INFO:${NC} A dialog will appear - please click 'Install' and wait for completion"
    echo ""
    
    if xcode-select --install 2>/dev/null; then
      echo "${GREEN}✅ Xcode Command Line Tools installer launched${NC}"
      echo "${YELLOW}⚠️  The GUI installer has only just STARTED — it is not finished yet${NC}"
      echo "${YELLOW}⚠️  Complete the installation dialog, then re-run this script${NC}"
      echo "  ${BLUE}INFO:${NC} After installation completes, run: ./install.sh"
      # Exit 2 when CLT installation started and requires a rerun.
      exit 2
    else
      echo "${RED}❌ Failed to start Xcode Command Line Tools installation${NC}"
      echo "  ${BLUE}INFO:${NC} Please install manually: xcode-select --install"
      echo "  ${BLUE}INFO:${NC} Or download from: https://developer.apple.com/download/all/"
      exit 1
    fi
  else
    echo "${GREEN}✅ Xcode Command Line Tools already installed${NC}"
    local clt_path=$(xcode-select -p 2>/dev/null || echo "")
    if [[ -n "$clt_path" ]]; then
      echo "  ${BLUE}INFO:${NC} Installed at: $clt_path"
    fi
  fi
  
  # Verify Git is available (should be included in Xcode CLT)
  if ! command -v git >/dev/null 2>&1; then
    echo "${RED}❌ Git not found after Xcode Command Line Tools installation${NC}"
    echo "  ${BLUE}INFO:${NC} This should not happen - Git is included in Xcode CLT"
    echo "  ${BLUE}INFO:${NC} Please verify Xcode CLT installation: xcode-select -p"
    exit 1
  else
    echo "${GREEN}✅ Git found: $(git --version)${NC}"
  fi
}

install_homebrew() {
  if [[ -z "$HOMEBREW_PREFIX" ]]; then
    echo ""
    echo "${YELLOW}⚠️  IMPORTANT: Homebrew is required for this setup${NC}"
    echo "  ${BLUE}INFO:${NC} The installer may prompt you for:"
    echo "    - Your password (for sudo)"
    echo "    - Confirmation to install Xcode Command Line Tools (if not installed)"
    echo "    - Additional setup steps"
    echo ""
    echo "  ${BLUE}INFO:${NC} Please read all messages from the installer and follow instructions"
    echo "  ${BLUE}INFO:${NC} The installation process will be shown below:"
    echo ""
    echo "  Installing Homebrew..."
    local brew_commit="16be749c00897e40ecbf09e21f7f258706961b7b"
    local brew_installer_sha256="99287f194a8b3c9e6b0203a11a5fa54518be57209343e6bb954dec4635796d9d"
    local brew_installer=""
    brew_installer="$(mktemp "${TMPDIR:-/tmp}/macsmith-homebrew.XXXXXX")" || return 1
    TMP_FILES+=("$brew_installer")
    if ! _download_verified_script \
      "https://raw.githubusercontent.com/Homebrew/install/${brew_commit}/install.sh" \
      "$brew_installer_sha256" "$brew_installer"; then
      echo "${RED}❌ Failed to download and verify the pinned Homebrew installer${NC}"
      return 1
    fi
    if ! /bin/bash "$brew_installer"; then
      echo "${YELLOW}⚠️  Homebrew installer exited non-zero — verifying result below...${NC}"
    fi
    HOMEBREW_PREFIX="$(_detect_brew_prefix)"
    if [[ -n "$HOMEBREW_PREFIX" ]]; then
      echo ""
      echo "${GREEN}✅ Homebrew installed successfully${NC}"
    else
      echo ""
      echo "${RED}❌ Failed to install Homebrew${NC}"
      echo "  ${RED}ERROR:${NC} Homebrew is required for this setup."
      echo "  ${BLUE}INFO:${NC} Review the official instructions at https://brew.sh and retry."
      exit 1
    fi
  else
    echo "${GREEN}✅ Homebrew found at: $HOMEBREW_PREFIX${NC}"
  fi

  # Ensure Homebrew is in PATH for subsequent commands
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    case ":$PATH:" in
      *":$HOMEBREW_PREFIX/bin:"*) ;;
      *) export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$PATH" ;;
    esac
  fi
}

install_starship() {
  HOMEBREW_PREFIX="$(_detect_brew_prefix)"

  if command -v starship >/dev/null 2>&1; then
    echo "${GREEN}✅ Starship already installed${NC}"
    # Warn when Starship is installed outside Homebrew.
    local starship_path="$(command -v starship 2>/dev/null || true)"
    if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
      if ! "$HOMEBREW_PREFIX/bin/brew" list --formula starship >/dev/null 2>&1; then
        warn "Starship at $starship_path is not brew-managed; macsmith can't update it"
        echo "  ${BLUE}INFO:${NC} Consider: sudo rm $starship_path && brew install starship"
      fi
    fi
  elif [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    echo "${YELLOW}📦 Installing Starship prompt via Homebrew...${NC}"
    if "$HOMEBREW_PREFIX/bin/brew" install starship; then
      echo "${GREEN}✅ Starship installed${NC}"
    else
      warn "Starship installation failed (try: brew install starship)"
      return 1
    fi
  else
    warn "Starship requires Homebrew. Install Homebrew first, then: brew install starship"
    return 1
  fi

  # Install default Starship config if the user doesn't already have one
  local starship_config="${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml"
  if [[ ! -f "$starship_config" ]] && [[ -n "$REPO_ROOT" ]] && [[ -f "$REPO_ROOT/config/starship.toml" ]]; then
    if _atomic_copy "$REPO_ROOT/config/starship.toml" "$starship_config"; then
      echo "  ${BLUE}INFO:${NC} Default Starship config installed at $starship_config"
    else
      warn "Failed to install default Starship config at $starship_config"
      return 1
    fi
  fi
  return 0
}

# Function to install ZSH plugins via Homebrew (sourced by zsh.sh from
# $HOMEBREW_PREFIX/share/<plugin>/<plugin>.zsh — no Oh My Zsh required).
install_zsh_plugins() {
  HOMEBREW_PREFIX="$(_detect_brew_prefix)"
  if [[ -z "$HOMEBREW_PREFIX" ]] || [[ ! -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    warn "Homebrew not available — skipping zsh plugins"
    return 1
  fi
  local brew="$HOMEBREW_PREFIX/bin/brew"
  local pkg
  local plugin_failures=0
  for pkg in zsh-syntax-highlighting zsh-autosuggestions; do
    if "$brew" list --formula "$pkg" >/dev/null 2>&1; then
      echo "${GREEN}✅ $pkg already installed${NC}"
    else
      echo "${YELLOW}📦 Installing $pkg via Homebrew...${NC}"
      local err=""
      if err="$( { "$brew" install "$pkg" </dev/null >/dev/null; } 2>&1 )"; then
        echo "${GREEN}✅ $pkg installed${NC}"
      else
        warn "$pkg installation failed$(_brew_fail_hint "$err")"
        ((plugin_failures++))
      fi
    fi
  done

  # Point out an unused Oh My Zsh directory.
  if [[ -d "$HOME/.oh-my-zsh" ]]; then
    echo "  ${BLUE}INFO:${NC} Old ~/.oh-my-zsh/ from a previous install is no longer used."
    echo "  ${BLUE}INFO:${NC} Safe to remove with: rm -rf ~/.oh-my-zsh"
  fi
  (( plugin_failures == 0 ))
}

install_fzf() {
  if ! command -v fzf >/dev/null 2>&1; then
    # Update HOMEBREW_PREFIX in case it was just installed
    HOMEBREW_PREFIX="$(_detect_brew_prefix)"
    
    if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
      echo "${YELLOW}📦 Installing FZF via Homebrew...${NC}"
      if "$HOMEBREW_PREFIX/bin/brew" install fzf; then
        echo "${GREEN}✅ FZF installed${NC}"
      else
        warn "FZF installation failed (try: brew install fzf)"
        return 1
      fi
    else
      warn "FZF not found. Install it manually: brew install fzf"
      return 1
    fi
  else
    echo "${GREEN}✅ FZF already installed${NC}"
  fi
}

install_mas() {
  if ! command -v mas >/dev/null 2>&1; then
    # Update HOMEBREW_PREFIX in case it was just installed
    HOMEBREW_PREFIX="$(_detect_brew_prefix)"

    if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
      if ! _ask_user "${YELLOW}📦 mas (Mac App Store CLI) not found. Install via Homebrew?" "N"; then
        echo "${YELLOW}⚠️  Skipping mas installation${NC}"
        return 0
      fi
      echo "${YELLOW}📦 Installing mas (Mac App Store CLI) via Homebrew...${NC}"
      if "$HOMEBREW_PREFIX/bin/brew" install mas; then
        echo "${GREEN}✅ mas installed${NC}"
        echo "  ${BLUE}INFO:${NC} Sign in to App Store to use mas: open -a 'App Store'"
      else
        warn "mas installation failed (try: brew install mas)"
        return 1
      fi
    else
      warn "mas requires Homebrew. Install Homebrew first."
      return 1
    fi
  else
    echo "${GREEN}✅ mas already installed${NC}"
  fi
}

install_macports() {
  if ! command -v port >/dev/null 2>&1; then
    if ! _ask_user "${YELLOW}📦 MacPorts not found. Install MacPorts from source?" "N"; then
      echo "${YELLOW}⚠️  Skipping MacPorts installation${NC}"
      return 0
    fi
    echo "${YELLOW}📦 Installing MacPorts from source...${NC}"
    echo "  ${BLUE}INFO:${NC} MacPorts builds from source and takes ~20-60 minutes"
    echo "  ${BLUE}INFO:${NC} Requires sudo (you will be prompted for your password)"
    echo "  ${BLUE}INFO:${NC} Integrity: HTTPS (TLS) + checksum when distfiles publishes one;"
    echo "             the source is then built and installed as root (sudo make install)."
    {
      echo ""
      echo "${YELLOW}⚠️  IMPORTANT: Please follow the MacPorts installation carefully${NC}"
      echo "  ${BLUE}INFO:${NC} This will install MacPorts from source via CLI"
      echo "  ${BLUE}INFO:${NC} The installation may prompt you for:"
      echo "    - Your password (for sudo)"
      echo "    - Confirmation to install Xcode Command Line Tools (if not installed)"
      echo "    - Agreement to Xcode license (if Xcode is installed)"
      echo ""
      echo "  ${BLUE}INFO:${NC} Please read all messages and follow instructions carefully"
      echo "  ${BLUE}INFO:${NC} The installation process will be shown below:"
      echo ""
      
      # Check for Xcode Command Line Tools (should already be installed, but verify)
      if ! xcode-select -p >/dev/null 2>&1; then
        echo "  ${RED}❌ Xcode Command Line Tools are required for MacPorts${NC}"
        echo "  ${BLUE}INFO:${NC} Xcode CLT should have been installed earlier in the installation process"
        echo "  ${BLUE}INFO:${NC} Please run: xcode-select --install"
        echo "  ${BLUE}INFO:${NC} Then run this script again to continue with MacPorts installation"
        return 1
      else
        echo "  ${GREEN}✅ Xcode Command Line Tools found${NC}"
      fi
      
      # Agree to Xcode license if needed
      if command -v xcodebuild >/dev/null 2>&1; then
        echo "  Checking Xcode license agreement..."
        if ! sudo xcodebuild -license check >/dev/null 2>&1; then
          echo "  ${YELLOW}⚠️  Xcode license agreement required${NC}"
          echo "  ${BLUE}INFO:${NC} You may be prompted to accept the license"
          sudo xcodebuild -license accept 2>/dev/null || {
            echo "  ${YELLOW}⚠️  License acceptance may require manual confirmation${NC}"
          }
        fi
      fi
      
      # Pin the MacPorts release and digest before installing as root.
      local macports_version="2.12.5"
      local macports_sha256="a63be50fc453d261752d4e82deb28c9f3bd26517385a93892fee24bc8da9d661"

      local macports_tarball="MacPorts-${macports_version}.tar.bz2"
      local macports_url="https://distfiles.macports.org/MacPorts/${macports_tarball}"
      local temp_dir=$(mktemp -d)
      local original_dir="$(pwd)"  # Save original directory safely
      
      echo "  Installing MacPorts ${macports_version} from source..."
      echo "  Downloading ${macports_tarball}..."
      
      if ! cd "$temp_dir" 2>/dev/null; then
        echo "  ${RED}❌ Failed to create temporary directory${NC}"
        rm -rf "$temp_dir" 2>/dev/null || true
        return 1
      fi
      
      if _curl_safe -fsSL -o "$macports_tarball" "$macports_url"; then
        local mp_actual=""
        mp_actual="$(shasum -a 256 "$macports_tarball" 2>/dev/null | awk '{print $1}')"
        if [[ "$mp_actual" != "$macports_sha256" ]]; then
          echo "  ${RED}❌ Checksum mismatch — refusing to build MacPorts as root${NC}"
          echo "     expected: $macports_sha256"
          echo "     actual:   ${mp_actual:-unavailable}"
          cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
          rm -rf "$temp_dir" 2>/dev/null || true
          return 1
        fi
        echo "  ${GREEN}✅ Tarball checksum verified (pinned SHA-256)${NC}"
        echo "  Extracting source code..."
        if tar xf "$macports_tarball"; then
          if ! cd "MacPorts-${macports_version}" 2>/dev/null; then
            echo "  ${RED}❌ Failed to navigate to source directory${NC}"
            cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
            rm -rf "$temp_dir" 2>/dev/null || true
            return 1
          fi
          
          echo "  Configuring MacPorts..."
          # In CI/non-interactive mode, suppress verbose output
          if _env_true "${NONINTERACTIVE:-}" || _env_true "${CI:-}"; then
            if ./configure >/dev/null 2>&1; then
              echo "  Configuration complete"
              echo "  Building MacPorts (this may take a while)..."
              if make >/dev/null 2>&1; then
                echo "  Build complete"
                echo "  Installing MacPorts (requires sudo)..."
                if sudo make install >/dev/null 2>&1; then
                  echo ""
                  echo "${GREEN}✅ MacPorts installed successfully${NC}"
                  echo "  ${BLUE}INFO:${NC} Please open a new terminal window for PATH changes to take effect"
                  echo "  ${BLUE}INFO:${NC} Then run: sudo port selfupdate"
                else
                  echo "  ${RED}❌ MacPorts installation failed (make install)${NC}"
                  cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
                  rm -rf "$temp_dir" 2>/dev/null || true
                  return 1
                fi
              else
                echo "  ${RED}❌ MacPorts build failed (make)${NC}"
                cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
                rm -rf "$temp_dir" 2>/dev/null || true
                return 1
              fi
            else
              echo "  ${RED}❌ MacPorts configuration failed (configure)${NC}"
              cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
              rm -rf "$temp_dir" 2>/dev/null || true
              return 1
            fi
          else
            if ./configure; then
              echo "  Building MacPorts (this may take a while)..."
              if make; then
                echo "  Installing MacPorts (requires sudo)..."
                if sudo make install; then
                  echo ""
                  echo "${GREEN}✅ MacPorts installed successfully${NC}"
                  echo "  ${BLUE}INFO:${NC} Please open a new terminal window for PATH changes to take effect"
                  echo "  ${BLUE}INFO:${NC} Then run: sudo port selfupdate"
                else
                  echo "  ${RED}❌ MacPorts installation failed (make install)${NC}"
                  cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
                  rm -rf "$temp_dir" 2>/dev/null || true
                  return 1
                fi
              else
                echo "  ${RED}❌ MacPorts build failed (make)${NC}"
                cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
                rm -rf "$temp_dir" 2>/dev/null || true
                return 1
              fi
            else
              echo "  ${RED}❌ MacPorts configuration failed (configure)${NC}"
              cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
              rm -rf "$temp_dir" 2>/dev/null || true
              return 1
            fi
          fi
        else
          echo "  ${RED}❌ Failed to extract MacPorts source${NC}"
          cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
          rm -rf "$temp_dir" 2>/dev/null || true
          return 1
        fi
      else
        echo "  ${RED}❌ Failed to download MacPorts source${NC}"
        echo "  ${BLUE}INFO:${NC} Visit: https://www.macports.org/install.php for manual installation"
        cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
        rm -rf "$temp_dir" 2>/dev/null || true
        return 1
      fi
      
      # Cleanup - return to original directory safely
      cd "$original_dir" 2>/dev/null || cd "$HOME" 2>/dev/null || true
      rm -rf "$temp_dir" 2>/dev/null || true
    }
  else
    echo "${GREEN}✅ MacPorts already installed${NC}"
  fi
}

install_nix() {
  # Distinguish complete Nix installs from orphan /nix directories.
  if command -v nix >/dev/null 2>&1; then
    echo "${GREEN}✅ Nix already installed${NC}"
    return 0
  fi
  if [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
    echo "${GREEN}✅ Nix detected (may need PATH setup)${NC}"
    return 0
  fi
  if [[ -d /nix ]]; then
    warn "/nix exists but no Nix binary found — looks like a partial install"
    echo "  ${BLUE}INFO:${NC} Remove /nix manually or reinstall via https://nixos.org/download.html"
    return 1
  fi
  
  echo "  ${BLUE}INFO:${NC} Nix installs system-wide as a daemon and may take 10-20 minutes"
  echo "  ${BLUE}INFO:${NC} Requires sudo (you will be prompted for your password)"
  if _ask_user "${YELLOW}📦 Nix not found. Install Nix?" "N"; then
    echo ""
    echo "${YELLOW}⚠️  IMPORTANT: Please follow the Nix installation carefully${NC}"
    echo "  ${BLUE}INFO:${NC} The installer may prompt you for:"
    echo "    - Your password (for sudo)"
    echo "    - Confirmation to create /nix directory"
    echo "    - Additional setup steps"
    echo ""
    echo "  ${BLUE}INFO:${NC} Please read all messages from the installer and follow instructions"
    echo "  ${BLUE}INFO:${NC} The installation process will be shown below:"
    echo ""
    echo "  Installing Nix..."
    echo "  ${BLUE}INFO:${NC} This will run the official Nix installer"
    echo ""
    
    # Save current directory and ensure we're in a stable location
    local original_dir="$(pwd)"
    local stable_dir="${HOME:-/tmp}"
    
    # Change to stable directory to avoid "cannot get cwd" errors
    cd "$stable_dir" || cd /tmp || {
      echo "  ${RED}❌ Failed to change to stable directory${NC}"
      return 1
    }
    
    # Download a reviewed installer revision and verify it before execution.
    local nix_installer_sha256="e9d447ce3d2ff62d7ff9cb6ef401de6fa8acb148839dd00f7271945d7b638b14"
    local nix_installer=""
    nix_installer="$(mktemp "${TMPDIR:-/tmp}/macsmith-nix.XXXXXX")" || return 1
    TMP_FILES+=("$nix_installer")
    if ! _download_verified_script "https://nixos.org/nix/install" "$nix_installer_sha256" "$nix_installer"; then
      cd "$original_dir" 2>/dev/null || true
      echo "${RED}❌ Failed to download and verify the pinned Nix installer${NC}"
      return 1
    fi

    local install_exit=0
    sh "$nix_installer" --daemon --no-modify-profile || install_exit=$?
    
    # Return to original directory
    cd "$original_dir" 2>/dev/null || true
    
    if [[ $install_exit -eq 0 ]] \
      && { command -v nix >/dev/null 2>&1 || [[ -x /nix/var/nix/profiles/default/bin/nix ]]; }; then
      echo ""
      echo "${GREEN}✅ Nix installed successfully${NC}"
      echo "  ${BLUE}INFO:${NC} Restart your terminal or run: reload"
      echo "  ${BLUE}INFO:${NC} Then run: ./scripts/nix-macos-maintenance.sh ensure-path"
      return 0
    else
      echo ""
      echo "${RED}❌ Nix installation failed or did not produce a usable binary (exit $install_exit)${NC}"
      echo "  ${BLUE}INFO:${NC} Visit: https://nixos.org/download.html for manual installation"
      echo "  ${BLUE}INFO:${NC} If installation was interrupted, you may need to clean up before retrying"
      return 1
    fi
  else
    echo "${YELLOW}⚠️  Skipping Nix installation${NC}"
    return 0
  fi
}

setup_macsmith() {
  local local_bin="$HOME/.local/bin"
  local mirror_failures=0

  echo "${YELLOW}📦 Setting up macsmith script...${NC}"
  mkdir -p "$local_bin"
  
  # Use REPO_ROOT that was detected at script start
  # If REPO_ROOT is not set or macsmith.sh not found there, try to detect again
  local script_dir="$REPO_ROOT"
  
  if [[ -z "$script_dir" ]] || [[ ! -f "$script_dir/macsmith.sh" ]]; then
    # Fallback: try to detect again (in case REPO_ROOT wasn't set correctly)
    script_dir="$(_detect_repo_root)"
  fi
  
  # Final check and installation
  if [[ -n "$script_dir" ]] && [[ -f "$script_dir/macsmith.sh" ]]; then
    # Atomic so Ctrl-C during copy leaves old binary intact (or absent, never partial)
    if ! _atomic_copy "$script_dir/macsmith.sh" "$local_bin/macsmith" 755; then
      echo "${RED}❌ Failed to install macsmith${NC}"
      exit 1
    fi
    
    # Store version and script files for self-update
    local data_dir="$HOME/.local/share/macsmith"
    mkdir -p "$data_dir"

    # Resolve version from VERSION, then Git metadata, otherwise use "unknown".
    local current_version=""
    if [[ -f "$script_dir/VERSION" ]]; then
      current_version="$(head -n1 "$script_dir/VERSION" 2>/dev/null | tr -d '[:space:]')"
    fi
    if [[ -z "$current_version" ]] && [[ -d "$script_dir/.git" ]] && command -v git >/dev/null 2>&1; then
      current_version="$(cd "$script_dir" && git describe --tags --always 2>/dev/null || echo "")"
    fi
    if [[ -z "$current_version" ]]; then
      current_version="unknown"
      echo "  ${YELLOW}⚠️  No VERSION file and no .git found.${NC} Version recorded as 'unknown'."
      echo "     'upgrade' will still work (it queries GitHub directly); notifications just won't compare."
    fi
    if ! printf '%s\n' "$current_version" | _atomic_write "$data_dir/version" 600; then
      warn "Could not write $data_dir/version"
      ((mirror_failures++))
    fi

    # Mirror scripts into the data directory unless source and destination match.
    for script_file in install.sh dev-tools.sh bootstrap.sh zsh.sh macsmith.sh; do
      if [[ -f "$script_dir/$script_file" ]] && [[ ! "$script_dir/$script_file" -ef "$data_dir/$script_file" ]]; then
        if ! _atomic_copy "$script_dir/$script_file" "$data_dir/$script_file"; then
          warn "Could not mirror $script_file into $data_dir ('upgrade'/'dev-tools' may be stale)"
          ((mirror_failures++))
        fi
      fi
    done
    # Mirror helper scripts for installed uninstall commands and upgrades.
    if [[ -d "$script_dir/scripts" ]]; then
      mkdir -p "$data_dir/scripts"
      local helper_file
      for helper_file in nix-macos-maintenance.sh uninstall-nix-macos.sh uninstall-macsmith.sh; do
        if [[ -f "$script_dir/scripts/$helper_file" ]] && [[ ! "$script_dir/scripts/$helper_file" -ef "$data_dir/scripts/$helper_file" ]]; then
          if ! _atomic_copy "$script_dir/scripts/$helper_file" "$data_dir/scripts/$helper_file"; then
            warn "Could not mirror scripts/$helper_file into $data_dir"
            ((mirror_failures++))
          fi
        fi
      done
    fi
    if [[ -d "$script_dir/config" ]]; then
      mkdir -p "$data_dir/config"
      local config_file
      for config_file in starship.toml profiles.conf; do
        if [[ -f "$script_dir/config/$config_file" ]] \
          && [[ ! "$script_dir/config/$config_file" -ef "$data_dir/config/$config_file" ]]; then
          if ! _atomic_copy "$script_dir/config/$config_file" "$data_dir/config/$config_file"; then
            warn "Could not mirror config/$config_file into $data_dir"
            ((mirror_failures++))
          fi
        fi
      done
    fi

    # Verify installation
    if [[ -x "$local_bin/macsmith" ]]; then
      # Normalize path for display (remove ../ if present)
      local display_path="$local_bin/macsmith"
      [[ "$display_path" == *"/../"* ]] && display_path="$(cd "$local_bin" && pwd)/macsmith"
      echo "${GREEN}✅ macsmith script installed to $display_path${NC}"
      if (( mirror_failures > 0 )); then
        echo "${RED}❌ macsmith data mirror is incomplete${NC}" >&2
        return 1
      fi
    else
      echo "${RED}❌ Error: macsmith was copied but is not executable${NC}"
      exit 1
    fi
  else
    echo "${RED}❌ Error: macsmith.sh not found${NC}"
    echo "  REPO_ROOT: ${REPO_ROOT:-not set}"
    echo "  Searched in: $script_dir"
    echo "  Current directory: $(pwd)"
    echo "  Attempted methods: REPO_ROOT variable, fallback detection"
    if [[ -n "$script_dir" ]] && [[ -d "$script_dir" ]]; then
      echo "  Contents of $script_dir/:"
      ls -la "$script_dir/" 2>/dev/null | head -10 || true
    fi
    echo "  Files in current directory:"
    find . -maxdepth 1 -type f \( -name '*maintain*' -o -name '*install*' \) -exec ls -la {} + 2>/dev/null || true
    exit 1
  fi
}

# Install each bundled helper persistently in ~/.local/bin/.
_install_bundled_script() {
  local script_name="$1"   # e.g., uninstall-nix-macos.sh
  local bin_name="$2"      # e.g., uninstall-nix-macos (no .sh)
  local friendly="$3"      # e.g., "Nix uninstaller"
  local alias_hint="$4"    # e.g., uninstall-nix
  local local_bin="$HOME/.local/bin"
  local data_dir="$HOME/.local/share/macsmith"
  local src=""

  # Search REPO_ROOT, a freshly detected root, then the data-directory mirror.
  if [[ -n "${REPO_ROOT:-}" ]] && [[ -f "$REPO_ROOT/scripts/$script_name" ]]; then
    src="$REPO_ROOT/scripts/$script_name"
  else
    local detected="$(_detect_repo_root 2>/dev/null || echo "")"
    if [[ -n "$detected" ]] && [[ -f "$detected/scripts/$script_name" ]]; then
      src="$detected/scripts/$script_name"
    elif [[ -f "$data_dir/scripts/$script_name" ]]; then
      src="$data_dir/scripts/$script_name"
    fi
  fi

  if [[ -z "$src" ]]; then
    warn "Bundled source missing: scripts/$script_name"
    return 1
  fi

  mkdir -p "$local_bin"
  if _atomic_copy "$src" "$local_bin/$bin_name" 755; then
    echo "${GREEN}✅ $friendly installed to $local_bin/$bin_name${NC}"
    echo "  ${BLUE}INFO:${NC} Run '$alias_hint' anytime (alias for the bundled script)"
  else
    warn "Failed to install $friendly to $local_bin"
    return 1
  fi
}

setup_uninstall_nix_script() {
  _install_bundled_script uninstall-nix-macos.sh uninstall-nix-macos "Nix uninstaller" uninstall-nix
}

setup_uninstall_macsmith_script() {
  _install_bundled_script uninstall-macsmith.sh uninstall-macsmith "macsmith uninstaller" uninstall-macsmith
}

setup_nix_path() {
  # Configure PATH only for a complete Nix installation.
  if command -v nix >/dev/null 2>&1 || [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
    echo "${YELLOW}📦 Setting up Nix PATH...${NC}"
    
    # Use REPO_ROOT that was detected at script start
    local script_dir="$REPO_ROOT"
    
    # Fallback: try to detect again if REPO_ROOT not set or file not found
    if [[ -z "$script_dir" ]] || [[ ! -f "$script_dir/scripts/nix-macos-maintenance.sh" ]]; then
      script_dir="$(_detect_repo_root)"
    fi
    
    if [[ -n "$script_dir" ]] && [[ -f "$script_dir/scripts/nix-macos-maintenance.sh" ]]; then
      local ensure_output=""
      local ensure_exit=0
      ensure_output="$("$script_dir/scripts/nix-macos-maintenance.sh" ensure-path 2>&1)" || ensure_exit=$?
      if [[ $ensure_exit -eq 0 ]]; then
        echo "${GREEN}✅ Nix PATH configured${NC}"
      else
        # Show the maintenance script's failure output directly.
        warn "Nix PATH setup failed (exit $ensure_exit):"
        printf '%s\n' "$ensure_output" | sed 's/^/    /'
        return 1
      fi
    else
      warn "Nix maintenance script not found (Nix PATH may need manual setup)"
      return 1
    fi
  else
    echo "${YELLOW}ℹ️  Nix not detected - skipping Nix PATH setup${NC}"
  fi
}

# Function to setup PATH cleanup in .zprofile
setup_zprofile_path_cleanup() {
  echo "${YELLOW}📦 Setting up PATH cleanup in .zprofile...${NC}"
  echo "  ${BLUE}INFO:${NC} .zprofile is used by login shells to set up PATH"
  echo "  ${BLUE}INFO:${NC} This ensures Homebrew and other tools are available in all shell sessions"
  
  local zprofile_file="$HOME/.zprofile"
  local zprofile_start_re='^# =+ FINAL PATH CLEANUP \(FOR \.ZPROFILE\) =+$'
  local zprofile_end_re='^# End macsmith managed block$'

  # Refresh complete blocks and repair legacy start-only blocks.
  local zprofile_has_managed=false
  local zprofile_has_legacy=false
  if [[ -f "$zprofile_file" ]] && grep -qE "$zprofile_start_re" "$zprofile_file"; then
    if grep -qE "$zprofile_end_re" "$zprofile_file"; then
      zprofile_has_managed=true
      echo "  ${BLUE}INFO:${NC} Refreshing existing macsmith .zprofile block"
    else
      zprofile_has_legacy=true
      echo "  ${YELLOW}⚠️  Found legacy macsmith .zprofile block without end marker${NC}"
      echo "  ${BLUE}INFO:${NC} Backing it up and replacing it with the current managed block"
    fi
  fi

  local zprofile_existing=""
  if [[ -f "$zprofile_file" ]]; then
    local zprofile_backup="$zprofile_file.backup.$(date +%Y%m%d_%H%M%S)-$$"
    if ! _atomic_copy "$zprofile_file" "$zprofile_backup"; then
      echo "${RED}❌ Failed to back up $zprofile_file; refusing to modify it${NC}" >&2
      return 1
    fi
    echo "  ${BLUE}INFO:${NC} Backed up existing .zprofile to $zprofile_backup"
    if [[ "$zprofile_has_managed" == true ]]; then
      # Strip the existing block, matching the full marker lines with anchored
      # regexes so a stray copy of the marker text elsewhere can't misfire.
      zprofile_existing="$(awk '
        /^# =+ FINAL PATH CLEANUP \(FOR \.ZPROFILE\) =+$/ { skip = 1; next }
        skip && /^# End macsmith managed block$/ { skip = 0; next }
        !skip { print }
      ' "$zprofile_file")"
    elif [[ "$zprofile_has_legacy" == true ]]; then
      # Preserve content before a legacy final block (anchored start marker).
      zprofile_existing="$(awk '
        /^# =+ FINAL PATH CLEANUP \(FOR \.ZPROFILE\) =+$/ { exit }
        { print }
      ' "$zprofile_file")"
      echo "  ${BLUE}INFO:${NC} Removed legacy unmanaged tail from .zprofile backup copy"
    else
      zprofile_existing="$(cat "$zprofile_file")"
    fi
  fi

  # Build the complete .zprofile content before the atomic write.
  local zprofile_block
  zprofile_block="$(cat << 'ZPROFILE_EOF'

# ================================ FINAL PATH CLEANUP (FOR .ZPROFILE) =======================
# This must be at the very end of .zprofile to fix PATH order after all tools have loaded
# Ensures Homebrew paths come before /usr/bin and ~/.local/bin is included
# Managed by macsmith
_detect_brew_prefix() {
  if [[ -d /opt/homebrew ]]; then
    echo /opt/homebrew
  elif [[ -d /usr/local/Homebrew ]] || [[ -x /usr/local/bin/brew ]]; then
    echo /usr/local
  else
    echo ""
  fi
}

# Ensure ~/.local/bin is in PATH
local_bin="$HOME/.local/bin"

HOMEBREW_PREFIX="$(_detect_brew_prefix)"
if [[ -n "$HOMEBREW_PREFIX" ]]; then
  # Remove Homebrew paths from current PATH temporarily
  # Use command grouping to avoid stray variable output
  {
    cleaned_path=$(echo "$PATH" | tr ':' '\n' | grep -v "^$HOMEBREW_PREFIX/bin$" | grep -v "^$HOMEBREW_PREFIX/sbin$" | grep -v "^$local_bin$" | tr '\n' ':' | sed 's/:$//' 2>/dev/null)
    # Rebuild PATH with Homebrew first, then ~/.local/bin, then others, then system paths
    export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$local_bin${cleaned_path:+:$cleaned_path}"
  } >/dev/null 2>&1
else
  # No Homebrew, just ensure ~/.local/bin is in PATH
  {
    case ":$PATH:" in
      *":$local_bin:"*) ;;
      *) export PATH="$local_bin:$PATH" ;;
    esac
  } >/dev/null 2>&1
fi

# Add MacPorts to PATH if installed
if [[ -d /opt/local/bin ]] && [[ -x /opt/local/bin/port ]]; then
  case ":$PATH:" in
    *":/opt/local/bin:"*) ;;
    *) export PATH="/opt/local/bin:/opt/local/sbin:$PATH" ;;
  esac
fi

# Add Nix to PATH if installed
if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
  source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
fi

# Final PATH reordering: Ensure Homebrew is ALWAYS first, even after Nix
# Nix may add paths that come before Homebrew, so we re-apply Homebrew first
HOMEBREW_PREFIX="$(_detect_brew_prefix)"
if [[ -n "$HOMEBREW_PREFIX" ]]; then
  {
    # Remove Homebrew paths from current PATH
    cleaned_path=$(echo "$PATH" | tr ':' '\n' | grep -v "^$HOMEBREW_PREFIX/bin$" | grep -v "^$HOMEBREW_PREFIX/sbin$" | tr '\n' ':' | sed 's/:$//' 2>/dev/null)
    # Rebuild PATH with Homebrew ABSOLUTELY FIRST, then others
    export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin${cleaned_path:+:$cleaned_path}"
  } >/dev/null 2>&1
fi
# End macsmith managed block
ZPROFILE_EOF
)"

  if ! printf '%s\n%s\n' "$zprofile_existing" "$zprofile_block" | _atomic_write "$zprofile_file"; then
    echo "${RED}❌ Failed to write ~/.zprofile${NC}"
    return 1
  fi

  echo "${GREEN}✅ PATH cleanup configured in .zprofile${NC}"
}

# Function to install sysadmin/power-user/netsec/devops tools via Homebrew.
# Split into profile-based batches so the user can opt in/out per profile.
# Non-interactive runs use each profile's default unless MACSMITH_YES is set.
install_sysadmin_tools() {
  # Skip all sysadmin profiles (core-only install).
  if _env_true "${MACSMITH_SKIP_PROFILES:-}"; then
    echo "  ${BLUE}INFO:${NC} MACSMITH_SKIP_PROFILES=1 — skipping sysadmin profiles"
    return 0
  fi
  HOMEBREW_PREFIX="$(_detect_brew_prefix)"
  if [[ -z "$HOMEBREW_PREFIX" ]] || [[ ! -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    warn "Sysadmin tools require Homebrew (skipping)"
    return 0
  fi
  local brew="$HOMEBREW_PREFIX/bin/brew"

  # Reset the failure tally for each profile summary.
  local profile_failures=0
  local sysadmin_failures=0

  local profile_manifest="$REPO_ROOT/config/profiles.conf"
  if [[ ! -f "$profile_manifest" ]]; then
    warn "Profile manifest missing: $profile_manifest"
    return 1
  fi
  _profile_packages() {
    local profile="$1" kind="$2"
    awk -F'|' -v profile="$profile" -v kind="$kind" \
      '$1 == profile && $2 == kind { print $3 }' "$profile_manifest"
  }
  # shellcheck disable=SC2296  # ${(f)...} is zsh newline splitting
  local poweruser=("${(@f)$(_profile_packages power-user formula)}")
  # shellcheck disable=SC2296
  local poweruser_casks=("${(@f)$(_profile_packages power-user cask)}")
  # shellcheck disable=SC2296
  local crypto_formulae=("${(@f)$(_profile_packages crypto formula)}")
  # shellcheck disable=SC2296
  local netsec_formulae=("${(@f)$(_profile_packages netsec formula)}")
  # shellcheck disable=SC2296
  local netsec_casks=("${(@f)$(_profile_packages netsec cask)}")
  # shellcheck disable=SC2296
  local devops_formulae=("${(@f)$(_profile_packages devops formula)}")
  # shellcheck disable=SC2296
  local devops_casks=("${(@f)$(_profile_packages devops cask)}")
  # shellcheck disable=SC2296
  local databases_formulae=("${(@f)$(_profile_packages databases formula)}")

  # Filter installed packages, show progress, and detach Homebrew from prompt input.
  _brew_batch() {
    local label="$1"; shift
    local total=$#
    local skipped=0
    local to_install=()
    local pkg
    for pkg in "$@"; do
      if "$brew" list --formula "$pkg" >/dev/null 2>&1; then
        ((skipped++))
      else
        to_install+=("$pkg")
      fi
    done
    local install_count=${#to_install[@]}
    if (( install_count == 0 )); then
      echo "  all $total already installed"
      return 0
    fi
    echo "  installing $install_count new ($skipped already present)..."
    local failed=()
    local i=1
    local err=""
    local hint=""
    for pkg in "${to_install[@]}"; do
      echo "  [$i/$install_count] installing $pkg..."
      if ! err="$( { "$brew" install "$pkg" </dev/null >/dev/null; } 2>&1 )"; then
        failed+=("$pkg")
        hint="$(_brew_fail_hint "$err")"
        echo "    ${YELLOW}⚠️  $pkg failed${hint}${NC}"
      fi
      ((i++))
    done
    if (( ${#failed[@]} > 0 )); then
      warn "$label: failed to install: ${failed[*]}"
      (( profile_failures += ${#failed[@]} ))
      (( sysadmin_failures += ${#failed[@]} ))
      return 1
    fi
    return 0
  }

  # Map casks to app bundles so manually installed apps can be skipped.
  _cask_app_for() {
    case "$1" in
      orbstack)       echo "OrbStack.app" ;;
      wireshark-app)  echo "Wireshark.app" ;;
      multipass)      echo "Multipass.app" ;;
      ghostty)        echo "Ghostty.app" ;;
      *)              echo "" ;;
    esac
  }

  _brew_batch_cask() {
    local label="$1"; shift
    local total=$#
    local skipped=0
    local skipped_manual=()
    local to_install=()
    local pkg
    local app=""
    for pkg in "$@"; do
      if "$brew" list --cask "$pkg" >/dev/null 2>&1; then
        ((skipped++))
        continue
      fi
      app="$(_cask_app_for "$pkg")"
      if [[ -n "$app" ]] && { [[ -d "/Applications/$app" ]] || [[ -d "$HOME/Applications/$app" ]]; }; then
        skipped_manual+=("$pkg")
        ((skipped++))
        continue
      fi
      to_install+=("$pkg")
    done
    if (( ${#skipped_manual[@]} > 0 )); then
      echo "  skipping (already installed outside brew): ${skipped_manual[*]}"
    fi
    local install_count=${#to_install[@]}
    if (( install_count == 0 )); then
      echo "  all $total already installed (cask)"
      return 0
    fi
    echo "  installing $install_count new cask(s) ($skipped already present)..."
    local failed=()
    local i=1
    local err=""
    local hint=""
    for pkg in "${to_install[@]}"; do
      echo "  [$i/$install_count] installing $pkg (cask)..."
      if ! err="$( { "$brew" install --cask "$pkg" </dev/null >/dev/null; } 2>&1 )"; then
        failed+=("$pkg")
        hint="$(_brew_fail_hint "$err")"
        echo "    ${YELLOW}⚠️  $pkg failed${hint}${NC}"
      fi
      ((i++))
    done
    if (( ${#failed[@]} > 0 )); then
      warn "$label: failed to install: ${failed[*]}"
      (( profile_failures += ${#failed[@]} ))
      (( sysadmin_failures += ${#failed[@]} ))
      return 1
    fi
    return 0
  }

  # Return success when every formula and cask argument is already installed.
  _profile_complete() {
    local mode="formula"
    local pkg app
    for pkg in "$@"; do
      case "$pkg" in
        --formula) mode="formula"; continue ;;
        --cask)    mode="cask";    continue ;;
      esac
      if [[ "$mode" == "formula" ]]; then
        "$brew" list --formula "$pkg" >/dev/null 2>&1 || return 1
      else
        "$brew" list --cask "$pkg" >/dev/null 2>&1 && continue
        # Cask not installed via brew — accept a manually-installed .app at the
        # standard location (matches _brew_batch_cask's "skipping outside brew").
        app="$(_cask_app_for "$pkg")"
        if [[ -n "$app" ]] && { [[ -d "/Applications/$app" ]] || [[ -d "$HOME/Applications/$app" ]]; }; then
          continue
        fi
        return 1
      fi
    done
    return 0
  }

  # Report profile completion based on its package failures.
  _profile_done() {
    local label="$1"
    if (( profile_failures == 0 )); then
      echo "${GREEN}✅ ${label} installed${NC}"
    else
      echo "${YELLOW}⚠️  ${label} installed with ${profile_failures} failure(s) (see warnings)${NC}"
    fi
  }

  echo ""
  echo "${BLUE}=== Extra tooling (profiles) ===${NC}"

  if _profile_complete --formula "${poweruser[@]}" --cask "${poweruser_casks[@]}"; then
    echo "${GREEN}✅ Power-user tools already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install power-user CLI (btop, gh, lazygit, ripgrep, bat, jq, chezmoi, neovim, mole, wget, just, gcc, cmake, coreutils, ghostty, ...)?" "Y"; then
    echo "  ${BLUE}INFO:${NC} mole is provided by the tw93/tap Homebrew tap"
    profile_failures=0
    _brew_batch "power-user" "${poweruser[@]}"
    _brew_batch_cask "power-user-casks" "${poweruser_casks[@]}"
    _profile_done "Power-user tools"
  fi

  if _profile_complete --formula "${crypto_formulae[@]}"; then
    echo "${GREEN}✅ Crypto/secrets tools already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install crypto/secrets tools (age, sops, gnupg, pinentry-mac)?" "Y"; then
    profile_failures=0
    _brew_batch "crypto" "${crypto_formulae[@]}"
    _profile_done "Crypto/secrets tools"
  fi

  if _profile_complete --formula "${netsec_formulae[@]}" --cask "${netsec_casks[@]}"; then
    echo "${GREEN}✅ Network/security tools already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install network tools (nmap, masscan, iperf3, Wireshark)?" "N"; then
    profile_failures=0
    _brew_batch "netsec" "${netsec_formulae[@]}"
    _brew_batch_cask "netsec-casks" "${netsec_casks[@]}"
    _profile_done "Network/security tools"
  fi

  if _profile_complete --formula "${devops_formulae[@]}" --cask "${devops_casks[@]}"; then
    echo "${GREEN}✅ DevOps/SRE tools already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install DevOps/SRE tools (kubectl, Terraform, ansible, awscli, gcloud, k9s, powershell, ...)?" "N"; then
    echo "  ${BLUE}INFO:${NC} Terraform is provided by HashiCorp's Homebrew tap"
    profile_failures=0
    if ! "$brew" tap hashicorp/tap </dev/null >/dev/null 2>&1; then
      warn "devops: failed to tap hashicorp/tap (terraform may fail)"
      ((profile_failures++))
      ((sysadmin_failures++))
    fi
    _brew_batch "devops" "${devops_formulae[@]}"
    _brew_batch_cask "devops-casks" "${devops_casks[@]}"
    _profile_done "DevOps/SRE tools"
  fi

  if _profile_complete --formula "${databases_formulae[@]}"; then
    echo "${GREEN}✅ Databases already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install databases (mysql, postgresql@17)?" "N"; then
    profile_failures=0
    _brew_batch "databases" "${databases_formulae[@]}"
    _profile_done "Databases"
    echo "  ${BLUE}INFO:${NC} MongoDB is out-of-core; install via: brew tap mongodb/brew && brew install mongodb-community"
  fi
  (( sysadmin_failures == 0 ))
}

# Keep recent .zshrc backups plus the oldest non-macsmith backup.
_rotate_zshrc_backups() {
  local keep_recent=5
  # shellcheck disable=SC2012   # backup filenames are timestamp-only; ls+sort is safe
  local all
  all="$(ls -1 "$HOME"/.zshrc.backup.* 2>/dev/null | sort)"
  [[ -z "$all" ]] && return 0

  # Oldest non-macsmith-managed backup — detect by absence of macsmith_bin= signature
  local oldest_nonmanaged=""
  local _line
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    if ! grep -q '^macsmith_bin=' "$_line" 2>/dev/null; then
      oldest_nonmanaged="$_line"
      break
    fi
  done <<<"$all"

  # The N newest (last N lines of ascending sort)
  local newest_n
  newest_n="$(printf '%s\n' "$all" | tail -n "$keep_recent")"

  # Remove everything not in the keep-set
  local removed=0
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    [[ "$_line" == "$oldest_nonmanaged" ]] && continue
    if printf '%s\n' "$newest_n" | grep -Fxq "$_line"; then
      continue
    fi
    if rm -f "$_line" 2>/dev/null; then
      removed=$((removed + 1))
    fi
  done <<<"$all"

  if (( removed > 0 )); then
    echo "  ${BLUE}INFO:${NC} Rotated $removed old .zshrc backup(s); kept newest $keep_recent + oldest pre-macsmith"
  fi
}

# Function to backup and install zsh config
install_zsh_config() {
  local zshrc_backup="$HOME/.zshrc.backup.$(date +%Y%m%d_%H%M%S)-$$"
  local user_customizations=""

  # Use REPO_ROOT that was detected at script start
  local script_dir="$REPO_ROOT"

  # Fallback: try to detect again if REPO_ROOT not set or file not found
  if [[ -z "$script_dir" ]] || [[ ! -f "$script_dir/zsh.sh" ]]; then
    script_dir="$(_detect_repo_root)"
  fi

  if [[ -z "$script_dir" ]] || [[ ! -f "$script_dir/zsh.sh" ]]; then
    echo "${RED}❌ Error: zsh.sh not found in $script_dir${NC}"
    echo "  REPO_ROOT: ${REPO_ROOT:-not set}"
    exit 1
  fi

  if [[ -f "$HOME/.zshrc" ]]; then
    # Extract user customizations added after our managed config
    if grep -q "# USER CUSTOMIZATIONS" "$HOME/.zshrc" 2>/dev/null; then
      user_customizations="$(sed -n '/^# USER CUSTOMIZATIONS/,$ p' "$HOME/.zshrc")"
    fi

    echo "${YELLOW}📦 Backing up existing .zshrc to $zshrc_backup...${NC}"
    if _atomic_copy "$HOME/.zshrc" "$zshrc_backup"; then
      echo "${GREEN}✅ Backup created${NC}"
      _rotate_zshrc_backups
    else
      echo "${RED}❌ Failed to back up existing .zshrc; refusing to replace it${NC}" >&2
      return 1
    fi

    # Harvest unmanaged aliases and exports once on fresh installs.
    local _already_harvested=false
    if [[ -f "$HOME/.zshrc.local" ]] && grep -q '^# Harvested from ' "$HOME/.zshrc.local" 2>/dev/null; then
      _already_harvested=true
    fi
    if _is_fresh_install && [[ -z "$user_customizations" ]] && [[ "$_already_harvested" == false ]]; then
      # Use private permissions while handling shell exports.
      local _harvest_old_umask; _harvest_old_umask="$(umask)"
      umask 077
      local harvest_tmp_dir="$DATA_DIR/tmp"
      mkdir -p "$harvest_tmp_dir" 2>/dev/null || true
      chmod 700 "$DATA_DIR" "$harvest_tmp_dir" 2>/dev/null || true
      local harvest_tmp harvest_sensitive
      harvest_tmp="$(mktemp)" 2>/dev/null || harvest_tmp="$harvest_tmp_dir/zshrc-harvest-$$"
      harvest_sensitive="$(mktemp)" 2>/dev/null || harvest_sensitive="$harvest_tmp_dir/zshrc-harvest-sensitive-$$"
      TMP_FILES+=("$harvest_tmp" "$harvest_sensitive")

      # Collect user aliases and exports while excluding managed lines.
      # shellcheck disable=SC2016
      local harvest_all
      harvest_all="$(mktemp)" 2>/dev/null || harvest_all="$harvest_tmp_dir/zshrc-harvest-all-$$"
      TMP_FILES+=("$harvest_all")
      grep -E '^[[:space:]]*(alias |export )' "$HOME/.zshrc" 2>/dev/null \
        | grep -vE '^[[:space:]]*export (ZSH|ZSH_THEME|plugins|PATH|NVM_DIR|PYENV_ROOT|GEM_HOME|GEM_PATH|PIPX_DEFAULT_PYTHON|HOMEBREW_PREFIX)=' \
        | grep -vE "alias (ls|myip|flushdns|reloadzsh|reload|change|mysqlstart|mysqlstop|mysqlstatus|mysqlrestart|mysqlconnect|update|verify|versions|upgrade|sys-install|dev-tools|doctor|uninstall-profile|uninstall-nix|uninstall-macsmith|gst|gd|gds|gp|gpl|gf|gb|gco|gcb|gcm|gca|glog)=" \
        > "$harvest_all" 2>/dev/null || true

      # Separate secret-shaped exports so they remain only in the backup.
      if [[ -s "$harvest_all" ]]; then
        # Match secret assignments anywhere on a line with BSD-compatible character classes.
        local sensitive_re='(^|[[:space:]])[A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API[_-]?KEY|APIKEY|PRIVATE[_-]?KEY|PRIVATE[_-]?TOKEN|ACCESS[_-]?KEY|SECRET[_-]?KEY|SSH[_-]?KEY|GPG[_-]?KEY|SIGNING[_-]?KEY|ENCRYPTION[_-]?KEY|SESSION[_-]?KEY|BEARER|CREDENTIAL)[A-Za-z0-9_]*='
        # Treat KEY-suffixed names as sensitive except for the explicit benign list.
        local key_re='(^|[[:space:]])[A-Za-z0-9_]*KEY='
        local benign_key_re='(^|[[:space:]])(HOTKEY|HOT_KEY|PATH_KEY|MONKEY|DONKEY|TURKEY|JOCKEY|LACKEY|WHISKEY|LOWKEY|LOW_KEY)='
        # Sensitive bucket = explicit patterns ∪ (KEY-suffixed names − benign).
        {
          grep -iE "$sensitive_re" "$harvest_all" 2>/dev/null
          grep -iE "$key_re" "$harvest_all" 2>/dev/null | grep -ivE "$benign_key_re" 2>/dev/null
        } | sort -u > "$harvest_sensitive" || true
        # Harvestable = everything not in the sensitive bucket (whole-line match).
        if [[ -s "$harvest_sensitive" ]]; then
          grep -vxF -f "$harvest_sensitive" "$harvest_all" > "$harvest_tmp" 2>/dev/null || true
        else
          cp "$harvest_all" "$harvest_tmp" 2>/dev/null || true
        fi
      fi

      if [[ -s "$harvest_tmp" ]]; then
        local zshrc_local="$HOME/.zshrc.local"
        {
          printf '# Harvested from %s on %s\n' "$zshrc_backup" "$(date)"
          printf '# These are aliases/exports from your previous .zshrc that were not\n'
          printf '# recognised as managed by macsmith. Review and edit freely.\n'
          printf '# (Secret-shaped exports were intentionally excluded — see %s\n' "$zshrc_backup"
          printf '#  if you need to manually move any token/key/password exports.)\n\n'
          cat "$harvest_tmp"
        } >> "$zshrc_local"
        echo "  ${BLUE}INFO:${NC} Harvested custom aliases/exports into $zshrc_local"
        echo "  ${BLUE}INFO:${NC} This file is sourced automatically at the end of .zshrc"
        echo "  ${BLUE}INFO:${NC} ONLY aliases and exports were migrated; functions and any other"
        echo "       custom .zshrc content remain in the backup ($zshrc_backup) for manual review."
      fi

      if [[ -s "$harvest_sensitive" ]]; then
        local skipped_count
        skipped_count="$(wc -l < "$harvest_sensitive" | tr -d ' ')"
        echo "  ${YELLOW}⚠️  $skipped_count secret-shaped export line(s) were NOT harvested${NC}"
        echo "     (names matched TOKEN/SECRET/KEY/PASSWORD/CREDENTIAL/etc.)"
        echo "     They remain only in the backup: $zshrc_backup"
        echo "     Review and manually move them into a password manager or ~/.zshrc.local if needed."
      fi

      rm -f "$harvest_tmp" "$harvest_sensitive" "$harvest_all" 2>/dev/null || true
      umask "$_harvest_old_umask"
    fi
  fi

  echo "${YELLOW}📦 Installing zsh configuration...${NC}"
  # Build the complete .zshrc content before the atomic write.
  local zshrc_content
  zshrc_content="$(cat "$script_dir/zsh.sh")"
  if [[ -n "$user_customizations" ]]; then
    zshrc_content+="
"
    zshrc_content+="$user_customizations"
  else
    zshrc_content+="

# USER CUSTOMIZATIONS
# Add your personal shell customizations below this line.
# This section is preserved when install.sh re-runs."
  fi
  if ! printf '%s\n' "$zshrc_content" | _atomic_write "$HOME/.zshrc"; then
    echo "${RED}❌ Failed to write ~/.zshrc${NC}"
    return 1
  fi
  if [[ -n "$user_customizations" ]]; then
    echo "${GREEN}✅ zsh configuration installed (user customizations preserved)${NC}"
    echo "  ${BLUE}INFO:${NC} Your custom additions in the '# USER CUSTOMIZATIONS' section were kept"
  else
    echo "${GREEN}✅ zsh configuration installed${NC}"
    echo "  ${BLUE}INFO:${NC} Add personal customizations below '# USER CUSTOMIZATIONS' in ~/.zshrc"
    echo "  ${BLUE}INFO:${NC} That section is preserved if you re-run install.sh"
  fi
}

# Refresh PATH in the current shell after installation.
refresh_environment() {
  echo "${YELLOW}📦 Refreshing environment...${NC}"
  
  # Update HOMEBREW_PREFIX detection
  HOMEBREW_PREFIX="$(_detect_brew_prefix)"
  
  # Apply .zprofile's PATH logic without sourcing arbitrary shell commands.
  
  # Update PATH immediately based on what should be in .zprofile
  local local_bin="$HOME/.local/bin"
  
  if [[ -n "$HOMEBREW_PREFIX" ]]; then
    # Remove Homebrew paths from current PATH temporarily
    local cleaned_path=$(echo "$PATH" | tr ':' '\n' | grep -v "^$HOMEBREW_PREFIX/bin$" | grep -v "^$HOMEBREW_PREFIX/sbin$" | grep -v "^$local_bin$" | tr '\n' ':' | sed 's/:$//' 2>/dev/null)
    # Rebuild PATH with Homebrew first, then ~/.local/bin, then others
    export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$local_bin${cleaned_path:+:$cleaned_path}"
  else
    # No Homebrew, just ensure ~/.local/bin is in PATH
    case ":$PATH:" in
      *":$local_bin:"*) ;;
      *) export PATH="$local_bin:$PATH" ;;
    esac
  fi
  
  # Add MacPorts to PATH if installed
  if [[ -d /opt/local/bin ]] && [[ -x /opt/local/bin/port ]]; then
    case ":$PATH:" in
      *":/opt/local/bin:"*) ;;
      *) export PATH="/opt/local/bin:/opt/local/sbin:$PATH" ;;
    esac
  fi
  
  # Add Nix to PATH if installed
  if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
  fi

  # Final PATH reordering: ensure Homebrew is ALWAYS first, even after MacPorts
  # and Nix prepended their own paths above (mirrors the .zprofile heredoc).
  HOMEBREW_PREFIX="$(_detect_brew_prefix)"
  if [[ -n "$HOMEBREW_PREFIX" ]]; then
    local reordered_path=$(echo "$PATH" | tr ':' '\n' | grep -v "^$HOMEBREW_PREFIX/bin$" | grep -v "^$HOMEBREW_PREFIX/sbin$" | tr '\n' ':' | sed 's/:$//' 2>/dev/null)
    export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin${reordered_path:+:$reordered_path}"
  fi

  # Verify critical commands are now available
  if [[ -n "$HOMEBREW_PREFIX" ]] && ! command -v brew >/dev/null 2>&1; then
    # Try to add brew to PATH if it exists but isn't found
    if [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
      export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$PATH"
    fi
  fi
  
  echo "${GREEN}✅ Environment refreshed${NC}"
  
  # In CI/non-interactive mode, verify critical commands are available
  if _env_true "${NONINTERACTIVE:-}" || _env_true "${CI:-}"; then
    local verified=0
    if command -v brew >/dev/null 2>&1; then
      ((verified++))
    fi
    if command -v macsmith >/dev/null 2>&1 || [[ -x "$local_bin/macsmith" ]]; then
      ((verified++))
    fi
    if [[ $verified -gt 0 ]]; then
      echo "  ${BLUE}INFO:${NC} Critical commands verified in current shell session"
    fi
  fi
}

# Main installation
main() {
  local install_failures=0
  echo ""
  if _is_fresh_install; then
    echo "${BLUE}Mode: fresh install${NC} (no prior state marker found at $INSTALL_STATE_FILE)"
  else
    echo "${BLUE}Mode: upgrade${NC} (existing install detected)"
    if [[ -f "$INSTALL_STATE_FILE" ]]; then
      local last_install
      last_install="$(grep '^last_install_at=' "$INSTALL_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
      [[ -n "$last_install" ]] && echo "  ${BLUE}INFO:${NC} Last install: $last_install"
    fi
  fi
  echo ""
  echo "Starting installation..."
  echo ""

  # Critical installations (must succeed)
  if ! install_xcode_clt; then echo "${RED}❌ Critical: Xcode Command Line Tools installation failed${NC}"; exit 1; fi
  if ! install_homebrew; then echo "${RED}❌ Critical: Homebrew installation failed${NC}"; exit 1; fi
  if ! setup_macsmith; then echo "${RED}❌ Critical: macsmith script installation failed${NC}"; exit 1; fi
  setup_uninstall_nix_script || { warn "Nix uninstaller install failed"; ((install_failures++)); }
  setup_uninstall_macsmith_script || { warn "macsmith uninstaller install failed"; ((install_failures++)); }
  if ! setup_zprofile_path_cleanup; then echo "${RED}❌ Critical: PATH cleanup setup failed${NC}"; exit 1; fi
  if ! install_zsh_config; then echo "${RED}❌ Critical: zsh configuration installation failed${NC}"; exit 1; fi
  if ! refresh_environment; then echo "${RED}❌ Critical: Environment refresh failed${NC}"; exit 1; fi

  # Continue through selected components, but remember every real failure.
  install_starship || ((install_failures++))
  install_zsh_plugins || ((install_failures++))
  install_fzf || ((install_failures++))
  install_mas || ((install_failures++))
  install_macports || { warn "MacPorts installation failed"; ((install_failures++)); }
  install_nix || { warn "Nix installation failed"; ((install_failures++)); }
  setup_nix_path || { warn "Nix PATH setup failed"; ((install_failures++)); }
  install_sysadmin_tools || ((install_failures++))

  # Critical path already exited on failure above, so record the marker regardless of
  # optional failures — else one failed optional package flags the machine "fresh" forever.
  _mark_install_state || { warn "Failed to write install state marker"; ((install_failures++)); }
  if (( install_failures > 0 )); then
    warn "Marked install state, but $install_failures optional component(s) failed"
  fi

  echo ""
  if (( ${#install_warnings[@]} > 0 )); then
    echo "${YELLOW}⚠️  Installation completed with ${#install_warnings[@]} warning(s):${NC}"
    # Iterate values + counter; avoids ${!arr[@]} which isn't portable zsh↔bash
    local _i=0
    local _msg
    for _msg in "${install_warnings[@]}"; do
      _i=$((_i + 1))
      printf '  %d. %s\n' "$_i" "$_msg"
    done
  else
    echo "${GREEN}✅ Installation complete!${NC}"
  fi
  echo ""
  if (( install_failures > 0 )); then
    echo "${RED}❌ Installation incomplete: $install_failures component(s) failed.${NC}"
  fi
  echo "Next steps:"
  echo "  1. Open a new terminal (or run: exec zsh -l)"
  echo "     PATH changes live in ~/.zprofile, which only a login shell re-reads —"
  echo "     'source ~/.zshrc' alone won't pick up Homebrew or ~/.local/bin."
  echo "  2. (Optional) Install language tools:"
  echo "     - Run './dev-tools.sh' for Python/Node/Rust/Ruby/Swift/Go/Java/.NET toolchains"
  echo "  3. Useful commands now available:"
  echo "     - reload     : Reload both .zprofile and .zshrc"
  echo "     - reloadzsh  : Reload only .zshrc"
  echo "  4. Customize the Starship prompt (optional): edit ~/.config/starship.toml"
  echo "  5. Run 'update' to update all your tools"
  echo ""
  echo "Available commands:"
  echo "  - reload     : Reload both .zprofile and .zshrc (updates PATH and shell config)"
  echo "  - reloadzsh  : Reload only .zshrc (updates shell config, faster)"
  echo "  - update     : Update all tools, package managers, and language runtimes"
  echo "  - verify     : Check status of all installed tools"
  echo "  - versions   : Display versions of all tools"
  echo ""
  
  # In CI/non-interactive mode, verify that commands are immediately available
  if _env_true "${NONINTERACTIVE:-}" || _env_true "${CI:-}"; then
    echo ""
    echo "${BLUE}INFO:${NC} Environment has been refreshed - commands should be available immediately"
    echo "${BLUE}INFO:${NC} Testing critical commands..."
    
    if command -v brew >/dev/null 2>&1; then
      echo "  ✅ brew is available"
    else
      echo "  ⚠️  brew not found in PATH (may need shell restart)"
    fi
    
    local local_bin="$HOME/.local/bin"
    
    if command -v macsmith >/dev/null 2>&1 || [[ -x "$local_bin/macsmith" ]]; then
      echo "  ✅ macsmith is available"
    else
      echo "  ⚠️  macsmith not found (may need shell restart)"
    fi
    
    if command -v port >/dev/null 2>&1; then
      echo "  ✅ port (MacPorts) is available"
    fi
    
    if command -v nix >/dev/null 2>&1 || [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
      echo "  ✅ nix is available"
    fi
  fi
  echo ""
  (( install_failures == 0 ))
}

# Run main function
main
