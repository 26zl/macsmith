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

echo "🚀 macsmith - Installation"
echo "======================================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
install_warnings=0

warn() {
  ((install_warnings++))
  echo "${YELLOW}⚠️  $1${NC}"
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
  
  # Read input with validation
  local response=""
  IFS= read -r response || return 1
  
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

# Function to install Oh My Zsh
install_oh_my_zsh() {
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    echo "${YELLOW}📦 Installing Oh My Zsh...${NC}"
    local omz_installer
    omz_installer="$(_curl_safe -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    if [[ -z "$omz_installer" ]]; then
      warn "Oh My Zsh installer download failed (empty response)"
      return 1
    fi
    if sh -c "$omz_installer" "" --unattended --keep-zshrc; then
      echo "${GREEN}✅ Oh My Zsh installed${NC}"
    else
      warn "Oh My Zsh installation failed"
    fi
  else
    echo "${GREEN}✅ Oh My Zsh already installed${NC}"
  fi
}

# Function to install Starship prompt
install_starship() {
  HOMEBREW_PREFIX="$(_detect_brew_prefix)"

  if command -v starship >/dev/null 2>&1; then
    echo "${GREEN}✅ Starship already installed${NC}"
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

# Function to install ZSH plugins
install_zsh_plugins() {
  local plugins_dir="$HOME/.oh-my-zsh/custom/plugins"
  
  # zsh-syntax-highlighting
  if [[ ! -d "$plugins_dir/zsh-syntax-highlighting" ]]; then
    echo "${YELLOW}📦 Installing zsh-syntax-highlighting...${NC}"
    if git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$plugins_dir/zsh-syntax-highlighting"; then
      echo "${GREEN}✅ zsh-syntax-highlighting installed${NC}"
    else
      warn "zsh-syntax-highlighting installation failed"
    fi
  else
    echo "${GREEN}✅ zsh-syntax-highlighting already installed${NC}"
  fi
  
  # zsh-autosuggestions
  if [[ ! -d "$plugins_dir/zsh-autosuggestions" ]]; then
    echo "${YELLOW}📦 Installing zsh-autosuggestions...${NC}"
    if git clone https://github.com/zsh-users/zsh-autosuggestions.git "$plugins_dir/zsh-autosuggestions"; then
      echo "${GREEN}✅ zsh-autosuggestions installed${NC}"
    else
      warn "zsh-autosuggestions installation failed"
    fi
  else
    echo "${GREEN}✅ zsh-autosuggestions already installed${NC}"
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
  # Check if Nix is already installed (multiple ways to detect)
  if command -v nix >/dev/null 2>&1 || [[ -d /nix ]] || [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
    if [[ -d /nix ]] || [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
      echo "${GREEN}✅ Nix detected (may need PATH setup)${NC}"
    else
      echo "${GREEN}✅ Nix already installed${NC}"
    fi
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

    # Copy scripts to data dir for reference
    for script_file in install.sh dev-tools.sh bootstrap.sh zsh.sh macsmith.sh; do
      [[ -f "$script_dir/$script_file" ]] && cp "$script_dir/$script_file" "$data_dir/$script_file"
    done

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

# Function to setup Nix PATH
setup_nix_path() {
  # Check if Nix is installed (same conditions as install_nix)
  if command -v nix >/dev/null 2>&1 || [[ -d /nix ]] || [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
    echo "${YELLOW}📦 Setting up Nix PATH...${NC}"
    
    # Use REPO_ROOT that was detected at script start
    local script_dir="$REPO_ROOT"
    
    # Fallback: try to detect again if REPO_ROOT not set or file not found
    if [[ -z "$script_dir" ]] || [[ ! -f "$script_dir/scripts/nix-macos-maintenance.sh" ]]; then
      script_dir="$(_detect_repo_root)"
    fi
    
    if [[ -n "$script_dir" ]] && [[ -f "$script_dir/scripts/nix-macos-maintenance.sh" ]]; then
      if "$script_dir/scripts/nix-macos-maintenance.sh" ensure-path >/dev/null 2>&1; then
        echo "${GREEN}✅ Nix PATH configured${NC}"
      else
        warn "Nix PATH setup had issues (run manually: ./scripts/nix-macos-maintenance.sh ensure-path)"
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
  
  # Check if PATH cleanup already exists
  if [[ -f "$HOME/.zprofile" ]] && grep -q "FINAL PATH CLEANUP (FOR .ZPROFILE)" "$HOME/.zprofile"; then
    echo "${GREEN}✅ PATH cleanup already configured in .zprofile${NC}"
    return 0
  fi
  
  # Backup .zprofile if it exists (timestamped; non-atomic but harmless — if
  # the backup itself is interrupted we simply won't overwrite the original)
  local zprofile_existing=""
  if [[ -f "$HOME/.zprofile" ]]; then
    local zprofile_backup="$HOME/.zprofile.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$HOME/.zprofile" "$zprofile_backup"
    echo "  ${BLUE}INFO:${NC} Backed up existing .zprofile to $zprofile_backup"
    zprofile_existing="$(cat "$HOME/.zprofile")"
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
ZPROFILE_EOF
)"

  if ! printf '%s\n%s\n' "$zprofile_existing" "$zprofile_block" | _atomic_write "$HOME/.zprofile"; then
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
  local poweruser=(
    btop ncdu dust duf
    ripgrep bat eza fd zoxide
    jq yq tree tldr watch
    gh lazygit
    mtr bandwhich
    direnv shellcheck shfmt pre-commit
    tmux neovim
    chezmoi
  )

  # Crypto & secrets tooling.
  local crypto_formulae=(age sops gnupg pinentry-mac)
  local crypto_casks=(1password-cli)

  # Network & security tooling. Core items only; password crackers and
  # wireless attack tools deliberately omitted (very specialised).
  local netsec_formulae=(nmap masscan iperf3 nikto sqlmap)
  local netsec_casks=(wireshark)

  # DevOps / SRE tooling. Free container runtime via colima; OrbStack cask
  # as a fast proprietary alternative to Docker Desktop.
  local devops_formulae=(
    # k8s
    kubernetes-cli helm k9s kubectx kustomize stern
    # IaC
    terraform terragrunt tflint ansible
    # Cloud CLIs
    awscli azure-cli doctl
    # GitOps / CI
    argocd skaffold
    # Container runtime (colima) + docker CLI
    colima docker docker-compose
  )
  local devops_casks=(google-cloud-sdk orbstack multipass)

  # Helpers: install each package individually so one failure doesn't abort the batch
  _brew_batch() {
    local label="$1"; shift
    local failed=()
    local pkg
    for pkg in "$@"; do
      if "$brew" list --formula "$pkg" >/dev/null 2>&1; then
        continue
      fi
      echo "  installing $pkg..."
      if ! "$brew" install "$pkg" >/dev/null 2>&1; then
        failed+=("$pkg")
      fi
    done
    if (( ${#failed[@]} > 0 )); then
      warn "$label: failed to install: ${failed[*]}"
    fi
  }

  _brew_batch_cask() {
    local label="$1"; shift
    local failed=()
    local pkg
    for pkg in "$@"; do
      if "$brew" list --cask "$pkg" >/dev/null 2>&1; then
        continue
      fi
      echo "  installing $pkg (cask)..."
      if ! "$brew" install --cask "$pkg" >/dev/null 2>&1; then
        failed+=("$pkg")
      fi
    done
    if (( ${#failed[@]} > 0 )); then
      warn "$label: failed to install: ${failed[*]}"
    fi
  }

  echo ""
  echo "${BLUE}=== Extra tooling (profiles) ===${NC}"

  if _ask_user "${YELLOW}📦 Install power-user CLI (btop, gh, lazygit, ripgrep, bat, jq, chezmoi, neovim, ...)?" "Y"; then
    _brew_batch "power-user" "${poweruser[@]}"
    echo "${GREEN}✅ Power-user tools installed${NC}"
  fi

  if _ask_user "${YELLOW}📦 Install crypto/secrets tools (age, sops, gnupg, 1password-cli)?" "Y"; then
    _brew_batch "crypto" "${crypto_formulae[@]}"
    _brew_batch_cask "crypto-casks" "${crypto_casks[@]}"
    echo "${GREEN}✅ Crypto/secrets tools installed${NC}"
  fi

  if _ask_user "${YELLOW}📦 Install network/security tools (nmap, wireshark, masscan, hashcat, sqlmap, ...)?" "N"; then
    _brew_batch "netsec" "${netsec_formulae[@]}"
    _brew_batch_cask "netsec-casks" "${netsec_casks[@]}"
    echo "${GREEN}✅ Network/security tools installed${NC}"
  fi

  if _ask_user "${YELLOW}📦 Install DevOps/SRE tools (kubectl, terraform, ansible, awscli, gcloud, k9s, ...)?" "N"; then
    _brew_batch "devops" "${devops_formulae[@]}"
    _brew_batch_cask "devops-casks" "${devops_casks[@]}"
    echo "${GREEN}✅ DevOps/SRE tools installed${NC}"
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

    # Alias/export harvest: on fresh installs, pull user-defined aliases and
    # exports from the old .zshrc into ~/.zshrc.local so they survive the
    # overwrite. Managed config lines (starting with our marker or obvious
    # OMZ boilerplate) are skipped. Only runs if no marker existed AND
    # ~/.zshrc.local has never been harvested, to avoid appending duplicates
    # on a crashed-then-rerun install.
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
  if ! setup_zprofile_path_cleanup; then echo "${RED}❌ Critical: PATH cleanup setup failed${NC}"; exit 1; fi
  if ! install_zsh_config; then echo "${RED}❌ Critical: zsh configuration installation failed${NC}"; exit 1; fi
  if ! refresh_environment; then echo "${RED}❌ Critical: Environment refresh failed${NC}"; exit 1; fi

  # Optional installations (can fail)
  install_oh_my_zsh || warn "Oh My Zsh installation failed"
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
  if [[ $install_warnings -gt 0 ]]; then
    echo "${YELLOW}⚠️  Installation completed with $install_warnings warning(s)${NC}"
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
