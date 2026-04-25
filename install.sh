#!/usr/bin/env zsh

# macsmith - Installation Script

set +e  # Allow optional components to fail (will be set per function)

# Concurrent-run protection + interrupt handling.
# TMP_FILES collects any tempfiles created by _atomic_* helpers so Ctrl-C
# cleans them up rather than leaving ".tmp.XXXXXX" droppings.
LOCK_FILE="/tmp/macsmith-install.lock"
typeset -ga TMP_FILES=()
_interrupted=0

_cleanup_on_exit() {
  local exit_code=$?
  # Remove any tempfiles from atomic writes that never got renamed into place
  local f
  for f in "${TMP_FILES[@]}"; do
    [[ -n "$f" ]] && rm -f "$f" 2>/dev/null || true
  done
  rm -f "$LOCK_FILE" 2>/dev/null || true
  if [[ "$_interrupted" == "1" ]]; then
    printf '\n\033[1;33m⚠️  Install interrupted.\033[0m\n'
    printf '  Any files already written are complete (atomic writes). Partial ones were rolled back.\n'
    printf '  Backups of your previous config (if any) are in: ~/.zshrc.backup.* and ~/.zprofile.backup.*\n'
    printf '  Re-run this script when ready — it is idempotent.\n'
  fi
  exit "$exit_code"
}
_on_interrupt() {
  _interrupted=1
  # Re-raise SIGINT so parent (bootstrap.sh) sees the cancel too
  trap - INT
  kill -INT $$
}

_acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local lock_pid=""
    lock_pid="$(<"$LOCK_FILE")"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "ERROR: Another instance of install.sh is already running (PID $lock_pid)"
      echo "  If this is a mistake, remove the lock file: rm $LOCK_FILE"
      exit 1
    fi
    # Stale lock file - previous run crashed
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
}
_acquire_lock
# Register traps at SCRIPT scope (not inside a function). In zsh, `trap ... EXIT`
# inside a function fires when the function returns — not when the script exits.
# Registering here ensures the cleanup only runs at real script termination.
trap _cleanup_on_exit EXIT TERM HUP
trap _on_interrupt INT

# Atomic file copy: write to tempfile in dest dir, then rename into place.
# Leaves dst untouched if interrupted mid-write. Optional third arg sets mode.
_atomic_copy() {
  local src="$1" dst="$2" mode="${3:-}"
  local dst_dir tmp
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir" 2>/dev/null || true
  tmp="$(mktemp "${dst_dir}/.macsmith.XXXXXX")" || return 1
  TMP_FILES+=("$tmp")
  if ! cp "$src" "$tmp"; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  [[ -n "$mode" ]] && chmod "$mode" "$tmp" 2>/dev/null
  mv -f "$tmp" "$dst" || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# Atomic write from stdin: content goes to tempfile, then renamed into place.
_atomic_write() {
  local dst="$1" mode="${2:-}"
  local dst_dir tmp
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir" 2>/dev/null || true
  tmp="$(mktemp "${dst_dir}/.macsmith.XXXXXX")" || return 1
  TMP_FILES+=("$tmp")
  if ! cat > "$tmp"; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  [[ -n "$mode" ]] && chmod "$mode" "$tmp" 2>/dev/null
  mv -f "$tmp" "$dst" || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# Ensure standard Unix tools are in PATH (curl, git, etc.)
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Banner — figlet "macsmith" with a claw hammer drawn next to it.
# Single-quoted heredoc prevents backticks in the figlet art from triggering
# command substitution.
printf '\033[0;32m'
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
printf '\033[0m\n'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
# Warnings are collected so we can replay them as a bullet list at the end —
# otherwise users have to scroll back through all the install output to find
# what actually went wrong.
install_warnings=()

warn() {
  install_warnings+=("$1")
  echo "${YELLOW}⚠️  $1${NC}"
}

# Extract a short, user-friendly hint from brew error output so cask/formula
# failures don't disappear into the log without explanation. Returns either
# " (reason)" or empty string. Keep it terse — full log is still discoverable
# via `brew install --cask <pkg>` when the user wants details.
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
  curl --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 "$@"
}

# Ask user for confirmation with input validation
_ask_user() {
  local prompt="$1"
  local default="${2:-N}"
  
  # Validate inputs
  [[ -z "$prompt" ]] && { echo "${RED}Error: _ask_user called without prompt${NC}" >&2; return 1; }
  [[ "$default" != "Y" && "$default" != "N" ]] && default="N"
  
  # In CI/non-interactive mode, automatically answer "yes" to all prompts
  # This simulates a user answering "yes" to everything
  # Allow FORCE_INTERACTIVE=1 to run real prompts in CI (e.g., yes-piped tests)
  # Export NONINTERACTIVE so child processes (e.g., Homebrew installer) also see it
  [[ -n "${NONINTERACTIVE:-}" ]] && export NONINTERACTIVE
  if [[ -n "${FORCE_INTERACTIVE:-}" ]]; then
    : # Proceed to prompt
  elif [[ -n "${NONINTERACTIVE:-}" ]] || [[ -n "${CI:-}" ]]; then
    echo "$prompt [Auto: yes]"
    return 0
  fi
  
  echo -n "$prompt "
  if [[ "$default" == "Y" ]]; then
    echo -n "[Y/n]: "
  else
    echo -n "[y/N]: "
  fi
  
  # Read input with validation. Prefer /dev/tty when stdin isn't a terminal —
  # e.g. when bootstrap.sh is invoked via `curl | zsh`, install.sh inherits
  # the curl pipe as stdin, and `read` would consume the remaining bootstrap
  # source bytes instead of the user's answer. FORCE_INTERACTIVE=1 keeps the
  # yes-piped CI test flow working (answers fed via stdin on purpose).
  # The 2>/dev/null on the /dev/tty read silences "device not configured"
  # when stdin lies about having a tty (e.g. nested Bash-tool invocation).
  local response=""
  if [[ -n "${FORCE_INTERACTIVE:-}" ]] || [[ -t 0 ]]; then
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
    echo "${RED}Invalid input. Please enter y/n/yes/no or press Enter for default.${NC}" >&2
    return 1
  fi
  
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

# Check available disk space (need ~15GB minimum for Xcode CLT + Homebrew + tools)
if command -v df >/dev/null 2>&1; then
  available_gb=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -n "$available_gb" ]] && [[ "$available_gb" -lt 15 ]]; then
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
  elif [[ -d /usr/local/Homebrew ]]; then
    echo /usr/local
  else
    echo ""
  fi
}

HOMEBREW_PREFIX="$(_detect_brew_prefix)"

# Fresh-install vs upgrade detection
# Marker file is created at the end of a successful install.
# Presence = we've installed here before; absence = fresh machine.
DATA_DIR="$HOME/.local/share/macsmith"
INSTALL_STATE_FILE="$DATA_DIR/.install-state"

_is_fresh_install() {
  [[ ! -f "$INSTALL_STATE_FILE" ]]
}

_mark_install_state() {
  mkdir -p "$DATA_DIR"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  local version=""
  if [[ -n "${REPO_ROOT:-}" ]] && [[ -d "$REPO_ROOT/.git" ]] && command -v git >/dev/null 2>&1; then
    version="$(cd "$REPO_ROOT" && git describe --tags --always 2>/dev/null || echo "")"
  fi
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

# Function to install Xcode Command Line Tools (required)
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
      echo "${GREEN}✅ Xcode Command Line Tools installation started${NC}"
      echo "${YELLOW}⚠️  Please complete the installation dialog and run this script again${NC}"
      echo "  ${BLUE}INFO:${NC} After installation completes, run: ./install.sh"
      exit 0
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

# Function to install Homebrew if not present
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
    local brew_installer
    brew_installer="$(_curl_safe -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -z "$brew_installer" ]]; then
      echo "${RED}❌ Failed to download Homebrew installer (empty response)${NC}"
      exit 1
    fi
    /bin/bash -c "$brew_installer"
    HOMEBREW_PREFIX="$(_detect_brew_prefix)"
    if [[ -n "$HOMEBREW_PREFIX" ]]; then
      echo ""
      echo "${GREEN}✅ Homebrew installed successfully${NC}"
    else
      echo ""
      echo "${RED}❌ Failed to install Homebrew${NC}"
      echo "  ${RED}ERROR:${NC} Homebrew is required for this setup. Please install it manually:"
      echo "  ${BLUE}INFO:${NC} /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
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

# Function to install Starship prompt
install_starship() {
  HOMEBREW_PREFIX="$(_detect_brew_prefix)"

  if command -v starship >/dev/null 2>&1; then
    echo "${GREEN}✅ Starship already installed${NC}"
    # Detect non-brew starship installs so users don't end up with two copies
    # (common after running curl|sh from starship.rs in addition to macsmith).
    # The macsmith flow manages Starship via brew, and `update` only touches
    # brew formulae — a stray /usr/local/bin/starship would silently rot.
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
    fi
  fi
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
      fi
    fi
  done

  # One-time notice for users upgrading from the OMZ era. The new zsh.sh no
  # longer sources ~/.oh-my-zsh, so the directory is leftover bytes.
  if [[ -d "$HOME/.oh-my-zsh" ]]; then
    echo "  ${BLUE}INFO:${NC} Old ~/.oh-my-zsh/ from a previous install is no longer used."
    echo "  ${BLUE}INFO:${NC} Safe to remove with: rm -rf ~/.oh-my-zsh"
  fi
}

# Function to install FZF
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
      fi
    else
      warn "FZF not found. Install it manually: brew install fzf"
    fi
  else
    echo "${GREEN}✅ FZF already installed${NC}"
  fi
}

# Function to install mas (Mac App Store CLI)
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
      fi
    else
      warn "mas requires Homebrew. Install Homebrew first."
    fi
  else
    echo "${GREEN}✅ mas already installed${NC}"
  fi
}

# Function to install MacPorts
install_macports() {
  if ! command -v port >/dev/null 2>&1; then
    if ! _ask_user "${YELLOW}📦 MacPorts not found. Install MacPorts from source?" "N"; then
      echo "${YELLOW}⚠️  Skipping MacPorts installation${NC}"
      return 0
    fi
    echo "${YELLOW}📦 Installing MacPorts from source...${NC}"
    echo "  ${BLUE}INFO:${NC} MacPorts builds from source and takes ~20-60 minutes"
    echo "  ${BLUE}INFO:${NC} Requires sudo (you will be prompted for your password)"
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
      
      # Get latest MacPorts version dynamically (no hardcoded fallback)
      echo "  Fetching latest MacPorts version..."
      local macports_version=""
      local latest_url
      latest_url=$(_curl_safe -s https://distfiles.macports.org/MacPorts/ | grep -oE 'MacPorts-[0-9]+\.[0-9]+\.[0-9]+\.tar\.bz2' | sort -V | tail -1 || echo "")
      if [[ -n "$latest_url" ]]; then
        macports_version=$(echo "$latest_url" | sed 's/MacPorts-\(.*\)\.tar\.bz2/\1/')
      fi
      if [[ -z "$macports_version" ]]; then
        echo "  ${RED}❌ Failed to determine latest MacPorts version${NC}"
        echo "  ${BLUE}INFO:${NC} This may be a network issue. Check your connection and try again."
        echo "  ${BLUE}INFO:${NC} Or install manually: https://www.macports.org/install.php"
        return 1
      fi
      
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
          if [[ -n "${NONINTERACTIVE:-}" ]] || [[ -n "${CI:-}" ]]; then
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

# Function to install Nix
install_nix() {
  # Three-way detection: on PATH, installed but not wired to PATH, or partial
  # (orphan /nix dir with no binary). The last case is common after a failed
  # or abandoned install — we must NOT claim Nix is "detected" there, because
  # setup_nix_path would then call ensure-path, which rejects the partial state.
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
    return 0
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
    
    # Run Nix installer and capture exit code
    local install_exit=0
    sh <(_curl_safe --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon --no-modify-profile || install_exit=$?
    
    # Return to original directory
    cd "$original_dir" 2>/dev/null || true
    
    # Check if Nix was actually installed, even if installer reported failure
    # (Sometimes the installer fails at the end but Nix is still installed)
    if command -v nix >/dev/null 2>&1 || [[ -d /nix ]] || [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
      echo ""
      echo "${GREEN}✅ Nix installed successfully${NC}"
      echo "  ${BLUE}INFO:${NC} Restart your terminal or run: reload"
      echo "  ${BLUE}INFO:${NC} Then run: ./scripts/nix-macos-maintenance.sh ensure-path"
      return 0
    elif [[ $install_exit -eq 0 ]]; then
      # Installer reported success but Nix not found - might need PATH setup
      echo ""
      echo "${YELLOW}⚠️  Nix installer completed, but Nix not found in PATH${NC}"
      echo "  ${BLUE}INFO:${NC} This may be normal - try restarting your terminal"
      echo "  ${BLUE}INFO:${NC} Or run: reload"
      return 0
    else
      echo ""
      echo "${RED}❌ Nix installation failed${NC}"
      echo "  ${BLUE}INFO:${NC} Visit: https://nixos.org/download.html for manual installation"
      echo "  ${BLUE}INFO:${NC} If installation was interrupted, you may need to clean up before retrying"
      return 1
    fi
  else
    echo "${YELLOW}⚠️  Skipping Nix installation${NC}"
    return 0
  fi
}

# Function to setup macsmith script
setup_macsmith() {
  local local_bin="$HOME/.local/bin"

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

    # Detect current version. Order:
    #   1. Shipped VERSION file (release pipeline writes resolved tag here —
    #      authoritative for release zips).
    #   2. git describe (local clone of the repo).
    #   3. Nothing. We refuse to guess from GitHub "latest" because if the
    #      user is installing an OLDER release zip or an unknown copy, writing
    #      "latest" here makes `upgrade`/update notifications lie. Instead
    #      write a literal "unknown" marker so behaviour is transparent.
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
    echo "$current_version" > "$data_dir/version"

    # Mirror the repo into the data dir so `upgrade` + the bundled-script
    # installer can re-source helpers after the temp bootstrap clone is wiped.
    # -ef guard avoids macOS cp "are identical" noise when sys-install re-execs
    # this script from $DATA_DIR (then $script_dir == $data_dir).
    for script_file in install.sh dev-tools.sh bootstrap.sh zsh.sh macsmith.sh; do
      if [[ -f "$script_dir/$script_file" ]] && [[ ! "$script_dir/$script_file" -ef "$data_dir/$script_file" ]]; then
        cp "$script_dir/$script_file" "$data_dir/$script_file"
      fi
    done
    # Helper scripts live in scripts/; copy the whole dir so uninstall-nix and
    # uninstall-macsmith survive bootstrap cleanup AND get refreshed by upgrade.
    if [[ -d "$script_dir/scripts" ]]; then
      mkdir -p "$data_dir/scripts"
      local helper_file
      for helper_file in nix-macos-maintenance.sh uninstall-nix-macos.sh uninstall-macsmith.sh; do
        if [[ -f "$script_dir/scripts/$helper_file" ]] && [[ ! "$script_dir/scripts/$helper_file" -ef "$data_dir/scripts/$helper_file" ]]; then
          cp "$script_dir/scripts/$helper_file" "$data_dir/scripts/$helper_file"
        fi
      done
    fi

    # Verify installation
    if [[ -x "$local_bin/macsmith" ]]; then
      # Normalize path for display (remove ../ if present)
      local display_path="$local_bin/macsmith"
      [[ "$display_path" == *"/../"* ]] && display_path="$(cd "$local_bin" && pwd)/macsmith"
      echo "${GREEN}✅ macsmith script installed to $display_path${NC}"
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

# Install a bundled helper script as a first-class binary in ~/.local/bin/.
# Same reason for both uninstallers: users who arrived via `curl | zsh` lose
# the temp clone after bootstrap exits, so these need to live somewhere
# persistent. A missing source is a no-op (non-fatal).
_install_bundled_script() {
  local script_name="$1"   # e.g., uninstall-nix-macos.sh
  local bin_name="$2"      # e.g., uninstall-nix-macos (no .sh)
  local friendly="$3"      # e.g., "Nix uninstaller"
  local alias_hint="$4"    # e.g., uninstall-nix
  local local_bin="$HOME/.local/bin"
  local data_dir="$HOME/.local/share/macsmith"
  local src=""

  # Try three sources in order: live REPO_ROOT (fresh install / clone),
  # re-detection (edge cases), and the data-dir mirror (lets `upgrade`
  # refresh helpers even when REPO_ROOT no longer exists).
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
    return 0
  fi

  mkdir -p "$local_bin"
  if _atomic_copy "$src" "$local_bin/$bin_name" 755; then
    echo "${GREEN}✅ $friendly installed to $local_bin/$bin_name${NC}"
    echo "  ${BLUE}INFO:${NC} Run '$alias_hint' anytime (alias for the bundled script)"
  else
    warn "Failed to install $friendly to $local_bin (non-fatal)"
  fi
}

setup_uninstall_nix_script() {
  _install_bundled_script uninstall-nix-macos.sh uninstall-nix-macos "Nix uninstaller" uninstall-nix
}

setup_uninstall_macsmith_script() {
  _install_bundled_script uninstall-macsmith.sh uninstall-macsmith "macsmith uninstaller" uninstall-macsmith
}

# Function to setup Nix PATH
setup_nix_path() {
  # Only wire up PATH if there's a real Nix binary to point at. Orphan /nix
  # directories (partial installs) were previously triggering a misleading
  # "Nix PATH setup had issues" warning because ensure-path correctly refuses
  # to run against an incomplete install. install_nix already reported the
  # partial state; nothing more to do here.
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
        # Surface the real failure reason so the user can act on it, rather
        # than pointing them back at a script that will print the same error.
        warn "Nix PATH setup failed (exit $ensure_exit):"
        printf '%s\n' "$ensure_output" | sed 's/^/    /'
      fi
    else
      warn "Nix maintenance script not found (Nix PATH may need manual setup)"
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

  # Check if a complete managed block already exists. Older macsmith installs
  # had the start header but no end marker, which made uninstall-macsmith unable
  # to cleanly remove the block. Treat that legacy format as repairable instead
  # of "already configured".
  if [[ -f "$zprofile_file" ]] && grep -qE "$zprofile_start_re" "$zprofile_file"; then
    if grep -qE "$zprofile_end_re" "$zprofile_file"; then
      echo "${GREEN}✅ PATH cleanup already configured in .zprofile${NC}"
      return 0
    fi
    echo "  ${YELLOW}⚠️  Found legacy macsmith .zprofile block without end marker${NC}"
    echo "  ${BLUE}INFO:${NC} Backing it up and replacing it with the current managed block"
  fi
  
  # Backup .zprofile if it exists (timestamped; non-atomic but harmless — if
  # the backup itself is interrupted we simply won't overwrite the original)
  local zprofile_existing=""
  if [[ -f "$zprofile_file" ]]; then
    local zprofile_backup="$zprofile_file.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$zprofile_file" "$zprofile_backup"
    echo "  ${BLUE}INFO:${NC} Backed up existing .zprofile to $zprofile_backup"
    if grep -qE "$zprofile_start_re" "$zprofile_file" && ! grep -qE "$zprofile_end_re" "$zprofile_file"; then
      # Legacy block was intended to be the final section. Keep everything
      # before it, then append the modern bounded block below.
      zprofile_existing="$(awk -v start_re="$zprofile_start_re" '
        $0 ~ start_re { exit }
        { print }
      ' "$zprofile_file")"
      echo "  ${BLUE}INFO:${NC} Removed legacy unmanaged tail from .zprofile backup copy"
    else
      zprofile_existing="$(cat "$zprofile_file")"
    fi
  fi

  # Build new .zprofile content in memory (existing + appended block) so the
  # write itself is atomic. Ctrl-C mid-heredoc won't corrupt .zprofile.
  local zprofile_block
  zprofile_block="$(cat << 'ZPROFILE_EOF'

# ================================ FINAL PATH CLEANUP (FOR .ZPROFILE) =======================
# This must be at the very end of .zprofile to fix PATH order after all tools have loaded
# Ensures Homebrew paths come before /usr/bin and ~/.local/bin is included
# Managed by macsmith
_detect_brew_prefix() {
  if [[ -d /opt/homebrew ]]; then
    echo /opt/homebrew
  elif [[ -d /usr/local/Homebrew ]]; then
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
    export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$local_bin:$cleaned_path"
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
    export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$cleaned_path"
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
# In CI/non-interactive mode, all profiles are installed (answers "yes").
install_sysadmin_tools() {
  HOMEBREW_PREFIX="$(_detect_brew_prefix)"
  if [[ -z "$HOMEBREW_PREFIX" ]] || [[ ! -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    warn "Sysadmin tools require Homebrew (skipping)"
    return 0
  fi
  local brew="$HOMEBREW_PREFIX/bin/brew"

  # Power-user CLI utilities. Small, fast, useful for everyone.
  # mole is a macOS cleaner CLI (AppCleaner-style leftover detection) from
  # the tw93/tap tap — handy for everyone, hence in this profile.
  local poweruser=(
    btop dust
    ripgrep bat eza fd zoxide
    jq yq tree tlrc watch
    gh lazygit
    mtr bandwhich
    direnv shellcheck shfmt pre-commit
    tmux neovim
    chezmoi
    tw93/tap/mole
  )

  # Crypto & secrets tooling.
  local crypto_formulae=(age sops gnupg pinentry-mac)

  # Network tooling — strictly network-layer (L2-L4) and packet analysis.
  # Web-app / DB-exploit scanners (nikto, sqlmap) are NOT included here; they
  # belong to a separate "appsec" profile if ever added. Keeps this profile
  # honest to its name for users who just want network visibility.
  local netsec_formulae=(nmap masscan iperf3)
  local netsec_casks=(wireshark-app)

  # DevOps / SRE tooling. OrbStack (cask) is the container runtime; we
  # keep the docker / docker-compose formulae as the CLI clients in case
  # OrbStack isn't running.
  local devops_formulae=(
    # k8s
    kubernetes-cli helm k9s kubectx kustomize stern
    # IaC
    hashicorp/tap/terraform terragrunt tflint ansible
    # Cloud CLIs
    awscli azure-cli doctl
    # GitOps / CI
    argocd skaffold
    # docker CLI (daemon comes from OrbStack)
    docker docker-compose
  )
  local devops_casks=(google-cloud-sdk orbstack multipass)

  # Databases. MySQL + PostgreSQL cover most dev cases and live in brew core.
  # MongoDB requires the mongodb/brew tap (not in core since 2020) — deliberately
  # omitted here to keep this profile tap-free. Users who want MongoDB can run:
  #   brew tap mongodb/brew && brew install mongodb-community
  local databases_formulae=(mysql postgresql@17)

  # Two-phase batch: filter already-installed, then install the rest with a
  # [current/total] progress prefix. </dev/null isolates brew from the caller's
  # stdin so piped answers to _ask_user survive across brew invocations.
  # The visible progress counter reduces premature Ctrl-C on long batches
  # (power-user is 24 formulae) — users can see something is still happening.
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
    fi
  }

  # Map cask name → the .app it ships, for casks we install. Lets us detect
  # when a user has already installed the app manually (e.g. dragged
  # OrbStack.app to /Applications from orbstack.com) so brew doesn't try and
  # fail every run with "It seems there is already an App at...".
  _cask_app_for() {
    case "$1" in
      orbstack)       echo "OrbStack.app" ;;
      wireshark-app)  echo "Wireshark.app" ;;
      multipass)      echo "Multipass.app" ;;
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
    fi
  }

  # Returns 0 when every package passed in is already installed via brew.
  # Args alternate by section:
  #   _profile_complete --formula pkg1 pkg2 ... [--cask pkg1 pkg2 ...]
  # Used to skip the per-profile install prompt on upgrade re-runs when there
  # is nothing left to do.
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

  echo ""
  echo "${BLUE}=== Extra tooling (profiles) ===${NC}"

  if _profile_complete --formula "${poweruser[@]}"; then
    echo "${GREEN}✅ Power-user tools already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install power-user CLI (btop, gh, lazygit, ripgrep, bat, jq, chezmoi, neovim, mole, ...)?" "Y"; then
    echo "  ${BLUE}INFO:${NC} mole is provided by the tw93/tap Homebrew tap"
    _brew_batch "power-user" "${poweruser[@]}"
    echo "${GREEN}✅ Power-user tools installed${NC}"
  fi

  if _profile_complete --formula "${crypto_formulae[@]}"; then
    echo "${GREEN}✅ Crypto/secrets tools already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install crypto/secrets tools (age, sops, gnupg, pinentry-mac)?" "Y"; then
    _brew_batch "crypto" "${crypto_formulae[@]}"
    echo "${GREEN}✅ Crypto/secrets tools installed${NC}"
  fi

  if _profile_complete --formula "${netsec_formulae[@]}" --cask "${netsec_casks[@]}"; then
    echo "${GREEN}✅ Network/security tools already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install network tools (nmap, masscan, iperf3, Wireshark)?" "N"; then
    _brew_batch "netsec" "${netsec_formulae[@]}"
    _brew_batch_cask "netsec-casks" "${netsec_casks[@]}"
    echo "${GREEN}✅ Network/security tools installed${NC}"
  fi

  if _profile_complete --formula "${devops_formulae[@]}" --cask "${devops_casks[@]}"; then
    echo "${GREEN}✅ DevOps/SRE tools already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install DevOps/SRE tools (kubectl, Terraform, ansible, awscli, gcloud, k9s, ...)?" "N"; then
    echo "  ${BLUE}INFO:${NC} Terraform is provided by HashiCorp's Homebrew tap"
    "$brew" tap hashicorp/tap </dev/null >/dev/null 2>&1 || warn "devops: failed to tap hashicorp/tap (terraform may fail)"
    _brew_batch "devops" "${devops_formulae[@]}"
    _brew_batch_cask "devops-casks" "${devops_casks[@]}"
    echo "${GREEN}✅ DevOps/SRE tools installed${NC}"
  fi

  if _profile_complete --formula "${databases_formulae[@]}"; then
    echo "${GREEN}✅ Databases already installed (skipping prompt)${NC}"
  elif _ask_user "${YELLOW}📦 Install databases (mysql, postgresql@17)?" "N"; then
    _brew_batch "databases" "${databases_formulae[@]}"
    echo "${GREEN}✅ Databases installed${NC}"
    echo "  ${BLUE}INFO:${NC} MongoDB is out-of-core; install via: brew tap mongodb/brew && brew install mongodb-community"
  fi
}

# Rotate ~/.zshrc.backup.* files: keep the N most recent AND always keep the
# oldest non-macsmith-managed backup (the user's original pre-macsmith shell
# config — critical for uninstall-macsmith to restore). Without this, a new
# backup accumulates on every install.sh run.
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
  local zshrc_backup="$HOME/.zshrc.backup.$(date +%Y%m%d_%H%M%S)"
  local user_customizations=""
  local MANAGED_MARKER="# Managed by macsmith"

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
    cp "$HOME/.zshrc" "$zshrc_backup"
    echo "${GREEN}✅ Backup created${NC}"
    _rotate_zshrc_backups

    # Alias/export harvest: on fresh installs, pull user-defined aliases and
    # exports from the old .zshrc into ~/.zshrc.local so they survive the
    # overwrite. Managed config lines (starting with our marker) are skipped.
    # Only runs if no marker existed AND ~/.zshrc.local has never been
    # harvested, to avoid appending duplicates on a crashed-then-rerun install.
    local _already_harvested=false
    if [[ -f "$HOME/.zshrc.local" ]] && grep -q '^# Harvested from ' "$HOME/.zshrc.local" 2>/dev/null; then
      _already_harvested=true
    fi
    if _is_fresh_install && [[ -z "$user_customizations" ]] && [[ "$_already_harvested" == false ]]; then
      local harvest_tmp harvest_sensitive
      harvest_tmp="$(mktemp)" 2>/dev/null || harvest_tmp="/tmp/zshrc-harvest-$$"
      harvest_sensitive="$(mktemp)" 2>/dev/null || harvest_sensitive="/tmp/zshrc-harvest-sensitive-$$"

      # Start by collecting user-defined alias/export lines and dropping
      # ones that match the config we're about to install (avoid duplicates).
      # shellcheck disable=SC2016
      local harvest_all
      harvest_all="$(mktemp)" 2>/dev/null || harvest_all="/tmp/zshrc-harvest-all-$$"
      grep -E '^\s*(alias |export )' "$HOME/.zshrc" 2>/dev/null \
        | grep -vE '^\s*export (ZSH|ZSH_THEME|plugins|PATH|NVM_DIR|PYENV_ROOT|GEM_HOME|GEM_PATH|PIPX_DEFAULT_PYTHON|HOMEBREW_PREFIX)=' \
        | grep -vE "alias (ls|myip|flushdns|reloadzsh|reload|change|mysqlstart|mysqlstop|mysqlstatus|mysqlrestart|mysqlconnect|update|verify|versions|upgrade|sys-install|dev-tools)=" \
        > "$harvest_all" 2>/dev/null || true

      # Split: anything that looks secret-shaped (TOKEN / SECRET / PASSWORD /
      # API*KEY / PRIVATE / CREDENTIAL / SESSION / _KEY=) goes to a separate
      # bucket so we never silently duplicate credentials into .zshrc.local.
      # The user can still recover them from the timestamped backup if needed.
      if [[ -s "$harvest_all" ]]; then
        # Specific compound patterns only. Bare `_KEY` would false-positive on
        # PATH_KEY / HOTKEY / HOMEBREW_KEY-style benign names.
        local sensitive_re='export\s+[A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|APIKEY|PRIVATE[_-]?KEY|PRIVATE[_-]?TOKEN|ACCESS[_-]?KEY|SECRET[_-]?KEY|SSH[_-]?KEY|GPG[_-]?KEY|SIGNING[_-]?KEY|ENCRYPTION[_-]?KEY|SESSION[_-]?KEY|BEARER|CREDENTIAL)[A-Za-z0-9_]*='
        grep -iE "$sensitive_re" "$harvest_all" > "$harvest_sensitive" 2>/dev/null || true
        grep -ivE "$sensitive_re" "$harvest_all" > "$harvest_tmp" 2>/dev/null || true
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
    fi
  fi

  echo "${YELLOW}📦 Installing zsh configuration...${NC}"
  # Build the full .zshrc content in memory, then write atomically so Ctrl-C
  # can't leave a half-written shell config.
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

# Function to refresh environment immediately after installation
# This ensures PATH and other variables are updated in the current shell session
# Critical for CI/non-interactive mode where commands are run immediately after installation
refresh_environment() {
  echo "${YELLOW}📦 Refreshing environment...${NC}"
  
  # Update HOMEBREW_PREFIX detection
  HOMEBREW_PREFIX="$(_detect_brew_prefix)"
  
  # Update PATH based on .zprofile configuration without sourcing the entire file
  # This avoids executing potentially problematic commands in non-interactive mode
  # We manually apply the PATH cleanup logic instead of sourcing .zprofile
  
  # Update PATH immediately based on what should be in .zprofile
  local local_bin="$HOME/.local/bin"
  
  if [[ -n "$HOMEBREW_PREFIX" ]]; then
    # Remove Homebrew paths from current PATH temporarily
    local cleaned_path=$(echo "$PATH" | tr ':' '\n' | grep -v "^$HOMEBREW_PREFIX/bin$" | grep -v "^$HOMEBREW_PREFIX/sbin$" | grep -v "^$local_bin$" | tr '\n' ':' | sed 's/:$//' 2>/dev/null)
    # Rebuild PATH with Homebrew first, then ~/.local/bin, then others
    export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$local_bin:$cleaned_path"
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
  
  # Verify critical commands are now available
  local missing_commands=()
  if [[ -n "$HOMEBREW_PREFIX" ]] && ! command -v brew >/dev/null 2>&1; then
    # Try to add brew to PATH if it exists but isn't found
    if [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
      export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$PATH"
    fi
  fi
  
  # Check macsmith
  if ! command -v macsmith >/dev/null 2>&1; then
    local macsmith_path="$local_bin/macsmith"
    if [[ -x "$macsmith_path" ]]; then
      # It exists but isn't in PATH yet - PATH should have been updated above
      # Just verify it's accessible
      if [[ -x "$macsmith_path" ]]; then
        : # Command exists, PATH should work now
      fi
    fi
  fi
  
  echo "${GREEN}✅ Environment refreshed${NC}"
  
  # In CI/non-interactive mode, verify critical commands are available
  if [[ -n "${NONINTERACTIVE:-}" ]] || [[ -n "${CI:-}" ]]; then
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
  setup_uninstall_nix_script || warn "Nix uninstaller install had issues (non-fatal)"
  setup_uninstall_macsmith_script || warn "macsmith uninstaller install had issues (non-fatal)"
  if ! setup_zprofile_path_cleanup; then echo "${RED}❌ Critical: PATH cleanup setup failed${NC}"; exit 1; fi
  if ! install_zsh_config; then echo "${RED}❌ Critical: zsh configuration installation failed${NC}"; exit 1; fi
  if ! refresh_environment; then echo "${RED}❌ Critical: Environment refresh failed${NC}"; exit 1; fi

  # Optional installations (can fail)
  install_starship || warn "Starship prompt installation failed"
  install_zsh_plugins || warn "ZSH plugins installation failed"
  install_fzf || warn "FZF installation failed"
  install_mas || warn "mas installation failed"
  install_macports || warn "MacPorts installation failed or was skipped"
  install_nix || warn "Nix installation failed or was skipped"
  setup_nix_path || warn "Nix PATH setup failed"
  install_sysadmin_tools || warn "Sysadmin tools install had issues"

  # Record that we've completed an install on this machine
  _mark_install_state || warn "Failed to write install state marker"

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
  echo "Next steps:"
  echo "  1. Run: source ~/.zshrc"
  echo "     (Loads 'reload'/'reloadzsh' aliases and all shell configuration)"
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
  if [[ -n "${NONINTERACTIVE:-}" ]] || [[ -n "${CI:-}" ]]; then
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
}

# Run main function
main
