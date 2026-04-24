#!/usr/bin/env zsh

# macOS Development Tools Installation Script
# Installs language package managers, version managers, and language runtimes
#
# Usage:
#   ./dev-tools.sh          # Interactive installation
#   ./dev-tools.sh check    # Check what would be installed (dry-run)
#   ./dev-tools.sh test     # Test detection of all tools

set +e  # Allow optional components to fail

# Concurrent-run protection
LOCK_FILE="/tmp/macsmith-devtools.lock"
_dt_interrupted=0

_dt_cleanup_on_exit() {
  local exit_code=$?
  rm -f "$LOCK_FILE" 2>/dev/null || true
  if [[ "$_dt_interrupted" == "1" ]]; then
    printf '\n\033[1;33m⚠️  dev-tools interrupted.\033[0m\n'
    printf '  No persistent files are written by this script, so nothing is corrupted.\n'
    printf '  Any in-flight Homebrew/curl install may be mid-transaction but is self-recoverable.\n'
    printf '  Re-run ./dev-tools.sh when ready — it resumes where it left off.\n'
  fi
  exit "$exit_code"
}
_dt_on_interrupt() {
  _dt_interrupted=1
  trap - INT
  kill -INT $$
}

_acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local lock_pid=""
    lock_pid="$(<"$LOCK_FILE")"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "ERROR: Another instance of dev-tools.sh is already running (PID $lock_pid)"
      echo "  If this is a mistake, remove the lock file: rm $LOCK_FILE"
      exit 1
    fi
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
}
_acquire_lock
# Register traps at SCRIPT scope. In zsh `trap ... EXIT` inside a function
# fires when the function returns (LOCAL_TRAPS), which would kill the script
# immediately. Registering here makes the trap script-scoped.
trap _dt_cleanup_on_exit EXIT TERM HUP
trap _dt_on_interrupt INT

# Ensure standard Unix tools are in PATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Check for check/test mode
CHECK_MODE=false
TEST_MODE=false
if [[ "${1:-}" == "check" ]]; then
  CHECK_MODE=true
elif [[ "${1:-}" == "test" ]]; then
  TEST_MODE=true
fi

if [[ "$TEST_MODE" == false ]] && [[ "$CHECK_MODE" == false ]]; then
  echo "🛠️  macOS Development Tools Installation"
  echo "=========================================="
  echo ""
elif [[ "$TEST_MODE" == true ]]; then
  echo "🧪 Testing Tool Detection"
  echo "=========================="
  echo ""
elif [[ "$CHECK_MODE" == true ]]; then
  echo "🔍 Checking Installed Tools (Dry Run)"
  echo "======================================"
  echo ""
fi

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

# Ask user for confirmation with input validation
_ask_user() {
  local prompt="$1"
  local default="${2:-N}"
  
  # Validate inputs
  [[ -z "$prompt" ]] && { echo "${RED}Error: _ask_user called without prompt${NC}" >&2; return 1; }
  [[ "$default" != "Y" && "$default" != "N" ]] && default="N"
  
  # In CI/non-interactive mode, automatically answer "yes" to all prompts
  # Allow FORCE_INTERACTIVE=1 to run real prompts in CI (e.g., yes-piped tests)
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
  # bootstrap.sh invokes us via `./dev-tools.sh` after the curl|zsh pipe, so
  # stdin can still be the remaining bootstrap source. Reading from /dev/tty
  # keeps interactive prompts working. FORCE_INTERACTIVE=1 keeps CI yes-piped
  # tests working by forcing reads from stdin (the intended answer stream).
  # 2>/dev/null silences "device not configured" when /dev/tty exists but
  # the controlling terminal is gone (nested tool invocations, daemons).
  local response=""
  if [[ -n "${FORCE_INTERACTIVE:-}" ]] || [[ -t 0 ]]; then
    IFS= read -r response || return 1
  elif [[ -e /dev/tty ]] && [[ -r /dev/tty ]]; then
    IFS= read -r response </dev/tty 2>/dev/null || return 1
  else
    return 1
  fi
  
  # Sanitize input: remove leading/trailing whitespace, limit length
  response=$(echo "$response" | /usr/bin/tr -d '\r\n' | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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

# Two-phase batch: filter already-installed, install the rest with [i/n] prefix.
# </dev/null isolates brew from the caller's stdin so queued answers survive.
# Progress counter reduces premature Ctrl-C on long batches (e.g. JVM extras).
_brew_batch() {
  local label="$1"; shift
  local brew="$HOMEBREW_PREFIX/bin/brew"
  [[ -z "$HOMEBREW_PREFIX" ]] || [[ ! -x "$brew" ]] && { warn "$label: Homebrew not available"; return 0; }
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
  for pkg in "${to_install[@]}"; do
    echo "  [$i/$install_count] installing $pkg..."
    if ! "$brew" install "$pkg" </dev/null >/dev/null 2>&1; then
      failed+=("$pkg")
    fi
    ((i++))
  done
  if (( ${#failed[@]} > 0 )); then
    warn "$label: failed to install: ${failed[*]}"
  fi
}

_brew_batch_cask() {
  local label="$1"; shift
  local brew="$HOMEBREW_PREFIX/bin/brew"
  [[ -z "$HOMEBREW_PREFIX" ]] || [[ ! -x "$brew" ]] && { warn "$label: Homebrew not available"; return 0; }
  local total=$#
  local skipped=0
  local to_install=()
  local pkg
  for pkg in "$@"; do
    if "$brew" list --cask "$pkg" >/dev/null 2>&1; then
      ((skipped++))
    else
      to_install+=("$pkg")
    fi
  done
  local install_count=${#to_install[@]}
  if (( install_count == 0 )); then
    echo "  all $total already installed (cask)"
    return 0
  fi
  echo "  installing $install_count new cask(s) ($skipped already present)..."
  local failed=()
  local i=1
  for pkg in "${to_install[@]}"; do
    echo "  [$i/$install_count] installing $pkg (cask)..."
    if ! "$brew" install --cask "$pkg" </dev/null >/dev/null 2>&1; then
      failed+=("$pkg")
    fi
    ((i++))
  done
  if (( ${#failed[@]} > 0 )); then
    warn "$label: failed to install: ${failed[*]}"
  fi
}

# Generic single-tool brew installer with presence check + prompt.
# Args: tool-name, display-name, default-answer (Y|N), optional tap
_install_brew_tool() {
  local tool="$1"
  local display="$2"
  local default="${3:-Y}"
  local tap="${4:-}"
  local brew="$HOMEBREW_PREFIX/bin/brew"

  if command -v "$tool" >/dev/null 2>&1; then
    echo "${GREEN}✅ $display already installed${NC}"
    return 0
  fi
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$brew" ]]; then
    if "$brew" list --formula "$tool" >/dev/null 2>&1; then
      echo "${GREEN}✅ $display already installed (via Homebrew)${NC}"
      return 0
    fi
  fi

  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 $display: Would install via Homebrew${NC}"
    return 0
  fi

  if [[ -z "$HOMEBREW_PREFIX" ]] || [[ ! -x "$brew" ]]; then
    warn "$display installation requires Homebrew"
    return 0
  fi

  if _ask_user "${YELLOW}📦 $display not found. Install via Homebrew?" "$default"; then
    if [[ -n "$tap" ]]; then
      "$brew" tap "$tap" >/dev/null 2>&1 || warn "$display: failed to tap $tap"
    fi
    if "$brew" install "$tool" </dev/null >/dev/null 2>&1; then
      echo "${GREEN}✅ $display installed${NC}"
    else
      warn "$display installation failed"
    fi
  fi
}

# Check if running on macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "${RED}❌ Error: This script is designed for macOS only${NC}"
  exit 1
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

# Cache Homebrew prefix once at script start (used throughout)
HOMEBREW_PREFIX="$(_detect_brew_prefix)"

# Ensure Homebrew is in PATH for subsequent commands and installer scripts
if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
  case ":$PATH:" in
    *":$HOMEBREW_PREFIX/bin:"*) ;;
    *) export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$PATH" ;;
  esac
fi

# Function to install Conda/Miniforge
install_conda() {
  local conda_installed=false
  
  # Check if conda is available as a command
  if command -v conda >/dev/null 2>&1; then
    conda_installed=true
  fi
  
  # Check if conda/miniforge is installed via Homebrew
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if "$HOMEBREW_PREFIX/bin/brew" list --cask miniforge >/dev/null 2>&1 || \
       "$HOMEBREW_PREFIX/bin/brew" list --cask anaconda >/dev/null 2>&1 || \
       "$HOMEBREW_PREFIX/bin/brew" list --cask miniconda >/dev/null 2>&1; then
      conda_installed=true
    fi
  fi
  
  if [[ "$conda_installed" == true ]]; then
    echo "${GREEN}✅ Conda already installed${NC}"
    return 0
  fi
  
  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 Conda/Miniforge: Would install via Homebrew${NC}"
    return 0
  fi
  
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if _ask_user "${YELLOW}📦 Conda/Miniforge not found. Install Miniforge via Homebrew?" "N"; then
      if "$HOMEBREW_PREFIX/bin/brew" install --cask miniforge </dev/null; then
        echo "${GREEN}✅ Miniforge installed${NC}"
      else
        warn "Miniforge installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  Conda installation requires Homebrew${NC}"
  fi
}

# Function to install pipx
install_pipx() {
  local pipx_installed=false
  
  # Check if pipx is available as a command
  if command -v pipx >/dev/null 2>&1; then
    pipx_installed=true
  fi
  
  # Check if pipx is installed via Homebrew
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if "$HOMEBREW_PREFIX/bin/brew" list pipx >/dev/null 2>&1; then
      pipx_installed=true
    fi
  fi
  
  if [[ "$pipx_installed" == true ]]; then
    echo "${GREEN}✅ pipx already installed${NC}"
    return 0
  fi
  
  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 pipx: Would install via Homebrew${NC}"
    return 0
  fi
  
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if _ask_user "${YELLOW}📦 pipx not found. Install pipx via Homebrew?" "Y"; then
      if "$HOMEBREW_PREFIX/bin/brew" install pipx </dev/null; then
        echo "${GREEN}✅ pipx installed${NC}"
      else
        warn "pipx installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  pipx installation requires Homebrew${NC}"
  fi
}

# Function to install pyenv
install_pyenv() {
  local pyenv_installed=false
  
  # Check if pyenv is available as a command
  if command -v pyenv >/dev/null 2>&1; then
    pyenv_installed=true
  # Check if pyenv is installed via Homebrew
  elif [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if "$HOMEBREW_PREFIX/bin/brew" list pyenv >/dev/null 2>&1; then
      pyenv_installed=true
      # Add pyenv to PATH if not already there
        if [[ -d "$HOMEBREW_PREFIX/opt/pyenv" ]]; then
          export PATH="$HOMEBREW_PREFIX/opt/pyenv/bin:$PATH"
          # Note: eval is required for pyenv initialization (standard practice)
          # pyenv init outputs shell configuration that must be evaluated
          eval "$(pyenv init -)" 2>/dev/null || true
        fi
    fi
  # Check if pyenv exists in common location
  elif [[ -d "$HOME/.pyenv" ]] && [[ -f "$HOME/.pyenv/bin/pyenv" ]]; then
    pyenv_installed=true
    export PATH="$HOME/.pyenv/bin:$PATH"
    eval "$(pyenv init -)" 2>/dev/null || true
  fi
  
  if [[ "$pyenv_installed" == true ]]; then
    echo "${GREEN}✅ pyenv already installed${NC}"
    # Check if Python is installed via pyenv
    if pyenv versions --bare 2>/dev/null | /usr/bin/grep -q .; then
      echo "  ${BLUE}INFO:${NC} Python versions already installed via pyenv"
    else
      echo "  ${BLUE}INFO:${NC} Installing latest Python via pyenv..."
      local latest_python
      latest_python=$(pyenv install --list 2>/dev/null | /usr/bin/grep -E "^\s+3\.[0-9]+\.[0-9]+$" | /usr/bin/grep -v "dev\|a\|b\|rc" | /usr/bin/tail -1 | /usr/bin/xargs)
      if [[ -n "$latest_python" ]]; then
        echo "  ${BLUE}INFO:${NC} Installing Python $latest_python (this may take a few minutes)..."
        if pyenv install "$latest_python" 2>/dev/null; then
          pyenv global "$latest_python" 2>/dev/null || true
          echo "  ${GREEN}✅ Python $latest_python installed and set as global${NC}"
        else
          echo "  ${YELLOW}⚠️  Failed to install Python via pyenv (you can install manually later with: pyenv install <version>)${NC}"
        fi
      else
        echo "  ${YELLOW}⚠️  Could not determine latest Python version (you can install manually later with: pyenv install <version>)${NC}"
      fi
    fi
    return 0
  fi
  
  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 pyenv: Would install via Homebrew${NC}"
    return 0
  fi
  
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if _ask_user "${YELLOW}📦 pyenv not found. Install pyenv via Homebrew?" "Y"; then
      if "$HOMEBREW_PREFIX/bin/brew" install pyenv </dev/null; then
        echo "${GREEN}✅ pyenv installed${NC}"
        # Install latest Python after pyenv is installed
        echo "  ${BLUE}INFO:${NC} Installing latest Python via pyenv..."
        # Source pyenv: check Homebrew location first, then ~/.pyenv
        if [[ -d "$HOMEBREW_PREFIX/opt/pyenv" ]]; then
          export PATH="$HOMEBREW_PREFIX/opt/pyenv/bin:$PATH"
          eval "$(pyenv init -)" 2>/dev/null || true
        elif [[ -f "$HOME/.pyenv/bin/pyenv" ]]; then
          export PATH="$HOME/.pyenv/bin:$PATH"
          eval "$(pyenv init -)" 2>/dev/null || true
        fi
        # Brief delay for pyenv shims to initialize after sourcing
        sleep 1
        local latest_python
        latest_python=$(pyenv install --list 2>/dev/null | /usr/bin/grep -E "^\s+3\.[0-9]+\.[0-9]+$" | /usr/bin/grep -v "dev\|a\|b\|rc" | /usr/bin/tail -1 | /usr/bin/xargs)
        if [[ -n "$latest_python" ]]; then
          echo "  ${BLUE}INFO:${NC} Installing Python $latest_python (this may take a few minutes)..."
          if pyenv install "$latest_python" 2>/dev/null; then
            pyenv global "$latest_python" 2>/dev/null || true
            echo "  ${GREEN}✅ Python $latest_python installed and set as global${NC}"
          else
            echo "  ${YELLOW}⚠️  Failed to install Python via pyenv (you can install manually later with: pyenv install <version>)${NC}"
          fi
        else
          echo "  ${YELLOW}⚠️  Could not determine latest Python version (you can install manually later with: pyenv install <version>)${NC}"
        fi
      else
        warn "pyenv installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  pyenv installation requires Homebrew${NC}"
  fi
}

# Function to install nvm
install_nvm() {
  local NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]] || type nvm >/dev/null 2>&1; then
    echo "${GREEN}✅ nvm already installed${NC}"
    # Check if Node.js is installed via nvm
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
      source "$NVM_DIR/nvm.sh" 2>/dev/null || true
      if nvm list 2>/dev/null | /usr/bin/grep -qE "v[0-9]+\.[0-9]+\.[0-9]+"; then
        echo "  ${BLUE}INFO:${NC} Node.js versions already installed via nvm"
      else
        echo "  ${BLUE}INFO:${NC} Installing Node.js LTS via nvm..."
        if nvm install --lts 2>/dev/null; then
          nvm use --lts 2>/dev/null || true
          echo "  ${GREEN}✅ Node.js LTS installed and activated${NC}"
        else
          echo "  ${YELLOW}⚠️  Failed to install Node.js via nvm (you can install manually later)${NC}"
        fi
      fi
    fi
    return 0
  fi
  
  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 nvm: Would install via curl${NC}"
    return 0
  fi
  
  if _ask_user "${YELLOW}📦 nvm not found. Install nvm?" "Y"; then
    echo "  Installing nvm..."
    # Get latest nvm version dynamically from GitHub API
    local nvm_version=""
    nvm_version="$(/usr/bin/curl -fsSL --connect-timeout 10 https://api.github.com/repos/nvm-sh/nvm/releases/latest 2>/dev/null | /usr/bin/grep '"tag_name"' | /usr/bin/sed -E 's/.*"([^"]+)".*/\1/' || echo "")"
    if [[ -z "$nvm_version" || ! "$nvm_version" =~ ^v[0-9] ]]; then
      echo "${RED}❌ Failed to determine latest nvm version from GitHub API${NC}"
      warn "nvm installation failed (could not fetch version)"
      return 1
    fi
    echo "  ${BLUE}INFO:${NC} Installing nvm $nvm_version..."
    if /usr/bin/curl --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_version}/install.sh" | /bin/bash; then
      echo "${GREEN}✅ nvm installed${NC}"
      # Install Node.js LTS after nvm is installed
      if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        source "$NVM_DIR/nvm.sh" 2>/dev/null || true
        echo "  ${BLUE}INFO:${NC} Installing Node.js LTS via nvm..."
        if nvm install --lts 2>/dev/null; then
          nvm use --lts 2>/dev/null || true
          echo "  ${GREEN}✅ Node.js LTS installed and activated${NC}"
        else
          echo "  ${YELLOW}⚠️  Failed to install Node.js via nvm (you can install manually later)${NC}"
        fi
      fi
    else
      warn "nvm installation failed"
    fi
  fi
}

# Function to install chruby and ruby-install
install_chruby() {
  local chruby_installed=false
  local chruby_script=""
  
  # Check if chruby is available as a function or command
  if type chruby >/dev/null 2>&1 || command -v chruby >/dev/null 2>&1; then
    chruby_installed=true
  fi
  
  # Check common chruby.sh locations
  local possible_paths=(
    "/usr/local/share/chruby/chruby.sh"
    "$HOME/.local/share/chruby/chruby.sh"
    "/opt/homebrew/share/chruby/chruby.sh"
    "/usr/local/opt/chruby/share/chruby/chruby.sh"
  )
  
  # Also check via Homebrew prefix
  if [[ -n "$HOMEBREW_PREFIX" ]]; then
    possible_paths+=("$HOMEBREW_PREFIX/share/chruby/chruby.sh")
    possible_paths+=("$HOMEBREW_PREFIX/opt/chruby/share/chruby/chruby.sh")
  fi
  
  # Check if chruby is installed via Homebrew (most reliable method)
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if "$HOMEBREW_PREFIX/bin/brew" list chruby >/dev/null 2>&1; then
      chruby_installed=true
      # Find the actual chruby.sh location via Homebrew
      local chruby_prefix
      chruby_prefix=$("$HOMEBREW_PREFIX/bin/brew" --prefix chruby 2>/dev/null)
      if [[ -n "$chruby_prefix" ]] && [[ -f "$chruby_prefix/share/chruby/chruby.sh" ]]; then
        chruby_script="$chruby_prefix/share/chruby/chruby.sh"
      else
        # Fallback: try common paths
        for path in "${possible_paths[@]}"; do
          if [[ -f "$path" ]]; then
            chruby_script="$path"
            break
          fi
        done
      fi
    fi
  fi
  
  # Check file locations
  for path in "${possible_paths[@]}"; do
    if [[ -f "$path" ]]; then
      chruby_installed=true
      chruby_script="$path"
      break
    fi
  done
  
  if [[ "$chruby_installed" == false ]]; then
    if [[ "$CHECK_MODE" == true ]]; then
      echo "${YELLOW}📦 chruby: Would install via Homebrew${NC}"
    elif [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
      if _ask_user "${YELLOW}📦 chruby not found. Install chruby and ruby-install via Homebrew?" "Y"; then
        if "$HOMEBREW_PREFIX/bin/brew" install chruby ruby-install </dev/null; then
          echo "${GREEN}✅ chruby and ruby-install installed${NC}"
          # Find chruby script via Homebrew prefix (works on both Intel and Apple Silicon)
          local chruby_prefix
          chruby_prefix=$("$HOMEBREW_PREFIX/bin/brew" --prefix chruby 2>/dev/null || echo "")
          if [[ -n "$chruby_prefix" ]] && [[ -f "$chruby_prefix/share/chruby/chruby.sh" ]]; then
            chruby_script="$chruby_prefix/share/chruby/chruby.sh"
          fi
        else
          warn "chruby installation failed"
        fi
      fi
    else
      echo "${YELLOW}⚠️  chruby installation requires Homebrew${NC}"
    fi
  else
    echo "${GREEN}✅ chruby already installed${NC}"
  fi
  
  # Check for ruby-install separately
  local ruby_install_installed=false
  if command -v ruby-install >/dev/null 2>&1; then
    ruby_install_installed=true
  elif [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    # Check if ruby-install is installed via Homebrew
    if "$HOMEBREW_PREFIX/bin/brew" list ruby-install >/dev/null 2>&1; then
      ruby_install_installed=true
    fi
  fi
  
  if [[ "$ruby_install_installed" == false ]]; then
    if [[ "$CHECK_MODE" == true ]]; then
      echo "${YELLOW}📦 ruby-install: Would install via Homebrew${NC}"
      return 0
    elif [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
      if _ask_user "${YELLOW}📦 ruby-install not found. Install ruby-install?" "Y"; then
        if "$HOMEBREW_PREFIX/bin/brew" install ruby-install </dev/null; then
          echo "${GREEN}✅ ruby-install installed${NC}"
        else
          warn "ruby-install installation failed"
        fi
      fi
    fi
  else
    echo "${GREEN}✅ ruby-install already installed${NC}"
  fi

  # Skip Ruby installation in check mode
  if [[ "$CHECK_MODE" == true ]]; then
    return 0
  fi

  # Install Ruby if chruby and ruby-install are available
  if command -v ruby-install >/dev/null 2>&1; then
    # Check if Ruby is already installed
    local ruby_installed=false
    if [[ -n "$chruby_script" ]] && [[ -f "$chruby_script" ]]; then
      source "$chruby_script" 2>/dev/null || true
      if chruby 2>/dev/null | /usr/bin/grep -qE "ruby-[0-9]+\.[0-9]+\.[0-9]+"; then
        ruby_installed=true
        echo "  ${BLUE}INFO:${NC} Ruby versions already installed via ruby-install"
      fi
    fi
    
    if [[ "$ruby_installed" == false ]]; then
      echo "  ${BLUE}INFO:${NC} Installing latest Ruby via ruby-install..."
      # Get latest stable Ruby version using same method as macsmith.sh
      local latest_ruby
      latest_ruby=$(ruby-install --list ruby 2>/dev/null | /usr/bin/awk '/^ruby [0-9]+\.[0-9]+\.[0-9]+$/ {print $2}' | /usr/bin/sort -V | /usr/bin/tail -n1)
      
      if [[ -n "$latest_ruby" ]]; then
        echo "  ${BLUE}INFO:${NC} Installing Ruby $latest_ruby (this may take a few minutes)..."
        if ruby-install ruby "$latest_ruby" 2>/dev/null; then
          echo "  ${GREEN}✅ Ruby $latest_ruby installed${NC}"
          if [[ -n "$chruby_script" ]] && [[ -f "$chruby_script" ]]; then
            source "$chruby_script" 2>/dev/null || true
            chruby "ruby-$latest_ruby" 2>/dev/null || true
          fi
        else
          echo "  ${YELLOW}⚠️  Failed to install Ruby via ruby-install (you can install manually later with: ruby-install ruby <version>)${NC}"
        fi
      else
        echo "  ${YELLOW}⚠️  Could not determine latest Ruby version (you can install manually later with: ruby-install ruby <version>)${NC}"
        echo "  ${BLUE}INFO:${NC} Try: ruby-install --list ruby (to see available versions)"
      fi
    fi
  fi
}

# Function to install rustup
install_rustup() {
  local rustup_installed=false
  
  # Check if rustup is available as a command
  if command -v rustup >/dev/null 2>&1; then
    rustup_installed=true
  # Check if rustup exists in common cargo location
  elif [[ -f "$HOME/.cargo/bin/rustup" ]]; then
    rustup_installed=true
    # Add cargo bin to PATH if not already there
    if [[ ":$PATH:" != *":$HOME/.cargo/bin:"* ]]; then
      export PATH="$HOME/.cargo/bin:$PATH"
    fi
  # Check if cargo directory exists (indicates rustup might be installed)
  elif [[ -d "$HOME/.cargo" ]] && [[ -f "$HOME/.cargo/env" ]]; then
    # Source cargo env to make rustup available
    if [[ -f "$HOME/.cargo/env" ]]; then
      source "$HOME/.cargo/env" 2>/dev/null || true
      if command -v rustup >/dev/null 2>&1; then
        rustup_installed=true
      fi
    fi
  fi
  
  if [[ "$rustup_installed" == true ]]; then
    echo "${GREEN}✅ rustup already installed${NC}"
    # Check if Rust is installed
    if rustup toolchain list 2>/dev/null | /usr/bin/grep -qE "stable|default"; then
      echo "  ${BLUE}INFO:${NC} Rust toolchain already installed"
    else
      echo "  ${BLUE}INFO:${NC} Installing Rust stable toolchain..."
      if rustup install stable 2>/dev/null; then
        rustup default stable 2>/dev/null || true
        echo "  ${GREEN}✅ Rust stable installed and set as default${NC}"
      else
        echo "  ${YELLOW}⚠️  Failed to install Rust via rustup (you can install manually later)${NC}"
      fi
    fi
    return 0
  fi
  
  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 rustup: Would install via curl${NC}"
    return 0
  fi
  
  if _ask_user "${YELLOW}📦 rustup not found. Install rustup (Rust toolchain manager)?" "Y"; then
    echo "  Installing rustup..."
    if /usr/bin/curl --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | /bin/bash -s -- -y; then
      echo "${GREEN}✅ rustup installed${NC}"
      # Source cargo env if available
      if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env" 2>/dev/null || true
      fi
      # Install Rust stable after rustup is installed
      echo "  ${BLUE}INFO:${NC} Installing Rust stable toolchain..."
      if rustup install stable 2>/dev/null; then
        rustup default stable 2>/dev/null || true
        echo "  ${GREEN}✅ Rust stable installed and set as default${NC}"
      else
        echo "  ${YELLOW}⚠️  Failed to install Rust via rustup (you can install manually later)${NC}"
      fi
      echo "  ${BLUE}INFO:${NC} Restart your terminal or run: source \$HOME/.cargo/env"
    else
      warn "rustup installation failed"
    fi
  fi
}

# Function to install swiftly
install_swiftly() {
  local swiftly_installed=false
  local swiftly_path=""
  
  # Check if swiftly is available as a command
  if command -v swiftly >/dev/null 2>&1; then
    swiftly_installed=true
    swiftly_path=$(command -v swiftly)
  # Check common swiftly locations (swiftly installs to $HOME/.swiftly/bin/swiftly)
  elif [[ -f "$HOME/.swiftly/bin/swiftly" ]]; then
    swiftly_installed=true
    swiftly_path="$HOME/.swiftly/bin/swiftly"
    # Add to PATH if not already there
    if [[ ":$PATH:" != *":$HOME/.swiftly/bin:"* ]]; then
      export PATH="$HOME/.swiftly/bin:$PATH"
    fi
  elif [[ -f "$HOME/.local/bin/swiftly" ]]; then
    swiftly_installed=true
    swiftly_path="$HOME/.local/bin/swiftly"
    # Add to PATH if not already there
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
      export PATH="$HOME/.local/bin:$PATH"
    fi
  # Check if .swiftly directory exists (indicates swiftly might be installed)
  elif [[ -d "$HOME/.swiftly" ]]; then
    # Try to find swiftly in common locations
    local possible_paths=(
      "$HOME/.swiftly/bin/swiftly"
      "$HOME/.local/bin/swiftly"
      "$HOME/bin/swiftly"
      "/usr/local/bin/swiftly"
    )
    for path in "${possible_paths[@]}"; do
      if [[ -f "$path" ]]; then
        swiftly_installed=true
        swiftly_path="$path"
        # Add directory to PATH if not already there
        local dir_path=$(dirname "$path")
        if [[ ":$PATH:" != *":$dir_path:"* ]]; then
          export PATH="$dir_path:$PATH"
        fi
        break
      fi
    done
  fi
  
  if [[ "$swiftly_installed" == true ]]; then
    echo "${GREEN}✅ swiftly already installed${NC}"
    # Check if Swift is installed
    if swiftly list installed 2>/dev/null | /usr/bin/grep -qE "[0-9]+\.[0-9]+"; then
      echo "  ${BLUE}INFO:${NC} Swift versions already installed via swiftly"
    else
      echo "  ${BLUE}INFO:${NC} Installing latest Swift via swiftly..."
      local latest_swift
      # swiftly list-available outputs "Swift X.Y.Z" format, extract version number (2nd field)
      latest_swift=$(swiftly list-available 2>/dev/null | /usr/bin/grep -E '^Swift [0-9]+\.[0-9]+\.[0-9]+' | /usr/bin/awk '{print $2}' | /usr/bin/sort -V | /usr/bin/tail -1)
      if [[ -n "$latest_swift" && "$latest_swift" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "  ${BLUE}INFO:${NC} Installing Swift $latest_swift (this may take a few minutes)..."
        if swiftly install --assume-yes "$latest_swift" 2>/dev/null; then
          # Run from $HOME so swiftly doesn't rewrite a project-local .swift-version
          (cd "$HOME" && swiftly use --assume-yes "$latest_swift") 2>/dev/null || true
          echo "  ${GREEN}✅ Swift $latest_swift installed and activated${NC}"
        else
          echo "  ${YELLOW}⚠️  Failed to install Swift via swiftly (you can install manually later with: swiftly install <version>)${NC}"
        fi
      else
        echo "  ${YELLOW}⚠️  Could not determine latest Swift version (you can install manually later with: swiftly install <version>)${NC}"
      fi
    fi
    return 0
  fi

  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 swiftly: Would install via curl${NC}"
    return 0
  fi

  if _ask_user "${YELLOW}📦 swiftly not found. Install swiftly (Swift toolchain manager)?" "N"; then
    echo "  Installing swiftly..."
    if /usr/bin/curl --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 -fsSL https://swiftlang.org/swiftly-install.sh | /bin/bash; then
      echo "${GREEN}✅ swiftly installed${NC}"
      # Install latest Swift after swiftly is installed
      echo "  ${BLUE}INFO:${NC} Installing latest Swift via swiftly..."
      local latest_swift
      # swiftly list-available outputs "Swift X.Y.Z" format, extract version number (2nd field)
      latest_swift=$(swiftly list-available 2>/dev/null | /usr/bin/grep -E '^Swift [0-9]+\.[0-9]+\.[0-9]+' | /usr/bin/awk '{print $2}' | /usr/bin/sort -V | /usr/bin/tail -1)
      if [[ -n "$latest_swift" && "$latest_swift" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "  ${BLUE}INFO:${NC} Installing Swift $latest_swift (this may take a few minutes)..."
        if swiftly install --assume-yes "$latest_swift" 2>/dev/null; then
          # Run from $HOME so swiftly doesn't rewrite a project-local .swift-version
          (cd "$HOME" && swiftly use --assume-yes "$latest_swift") 2>/dev/null || true
          echo "  ${GREEN}✅ Swift $latest_swift installed and activated${NC}"
        else
          echo "  ${YELLOW}⚠️  Failed to install Swift via swiftly (you can install manually later with: swiftly install <version>)${NC}"
        fi
      else
        echo "  ${YELLOW}⚠️  Could not determine latest Swift version (you can install manually later with: swiftly install <version>)${NC}"
      fi
    else
      warn "swiftly installation failed"
    fi
  fi
}

# Function to install Go
install_go() {
  local go_installed=false
  
  # Check if go is available as a command
  if command -v go >/dev/null 2>&1; then
    go_installed=true
  fi
  
  # Check if Go is installed via Homebrew
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if "$HOMEBREW_PREFIX/bin/brew" list go >/dev/null 2>&1; then
      go_installed=true
    fi
  fi
  
  if [[ "$go_installed" == true ]]; then
    echo "${GREEN}✅ Go already installed${NC}"
    return 0
  fi
  
  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 Go: Would install via Homebrew${NC}"
    return 0
  fi
  
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if _ask_user "${YELLOW}📦 Go not found. Install Go via Homebrew?" "Y"; then
      if "$HOMEBREW_PREFIX/bin/brew" install go </dev/null; then
        echo "${GREEN}✅ Go installed${NC}"
      else
        warn "Go installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  Go installation requires Homebrew, or install manually from https://go.dev/dl/${NC}"
  fi
}

# Function to install Java
install_java() {
  local java_installed=false
  
  # Check if java is available as a command
  if command -v java >/dev/null 2>&1; then
    java_installed=true
  fi
  
  # Check if Java/OpenJDK is installed via Homebrew
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if "$HOMEBREW_PREFIX/bin/brew" list openjdk >/dev/null 2>&1 || \
       "$HOMEBREW_PREFIX/bin/brew" list --cask temurin >/dev/null 2>&1 || \
       "$HOMEBREW_PREFIX/bin/brew" list --cask zulu >/dev/null 2>&1 || \
       "$HOMEBREW_PREFIX/bin/brew" list --cask java >/dev/null 2>&1; then
      java_installed=true
    fi
  fi
  
  if [[ "$java_installed" == true ]]; then
    echo "${GREEN}✅ Java already installed${NC}"
    return 0
  fi
  
  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 Java: Would install via Homebrew${NC}"
    return 0
  fi
  
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if _ask_user "${YELLOW}📦 Java not found. Install OpenJDK via Homebrew?" "N"; then
      if "$HOMEBREW_PREFIX/bin/brew" install openjdk </dev/null; then
        echo "${GREEN}✅ OpenJDK installed${NC}"
      else
        warn "OpenJDK installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  Java installation requires Homebrew, or install manually${NC}"
  fi
}

# Function to install .NET SDK
install_dotnet() {
  local dotnet_installed=false
  
  # Check if dotnet is available as a command
  if command -v dotnet >/dev/null 2>&1; then
    dotnet_installed=true
  fi
  
  # Check if .NET SDK is installed via Homebrew
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if "$HOMEBREW_PREFIX/bin/brew" list --cask dotnet-sdk >/dev/null 2>&1 || \
       "$HOMEBREW_PREFIX/bin/brew" list --cask dotnet >/dev/null 2>&1; then
      dotnet_installed=true
    fi
  fi
  
  if [[ "$dotnet_installed" == true ]]; then
    echo "${GREEN}✅ .NET SDK already installed${NC}"
    return 0
  fi
  
  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 .NET SDK: Would install via Homebrew${NC}"
    return 0
  fi
  
  if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if _ask_user "${YELLOW}📦 .NET SDK not found. Install .NET SDK via Homebrew?" "N"; then
      if "$HOMEBREW_PREFIX/bin/brew" install --cask dotnet-sdk </dev/null; then
        echo "${GREEN}✅ .NET SDK installed${NC}"
      else
        warn ".NET SDK installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  .NET SDK installation requires Homebrew, or install manually from https://dotnet.microsoft.com/download${NC}"
  fi
}

# ============================================================================
# Modern Python / JS tooling (brew-only, one-liner installs)
# ============================================================================

install_uv()   { _install_brew_tool uv   "uv (fast Python package manager)"  "Y"; }
install_bun()  { _install_brew_tool bun  "bun (JS/TS runtime + pkg manager)" "Y"; }
install_pnpm() { _install_brew_tool pnpm "pnpm (fast Node package manager)"  "Y"; }
install_deno() { _install_brew_tool deno "deno (secure JS/TS runtime)"       "N"; }

# ============================================================================
# JVM ecosystem batch (opt-in)
# ============================================================================

install_jvm_ecosystem() {
  if [[ "$CHECK_MODE" == true ]]; then
    echo "${YELLOW}📦 JVM extras: Would install kotlin, scala, clojure, gradle, maven, groovy${NC}"
    return 0
  fi
  if ! _ask_user "${YELLOW}📦 Install JVM extras (Kotlin, Scala, Clojure, Gradle, Maven, Groovy)?" "N"; then
    return 0
  fi
  _brew_batch "jvm-extras" kotlin scala clojure gradle maven groovy
  echo "${GREEN}✅ JVM extras installed${NC}"
}

# Test detection function
test_detection() {
  local all_found=0
  local all_missing=0
  
  echo "Testing detection of all tools..."
  echo ""
  
  # Test each tool
  local tools=(
    "conda:Conda/Miniforge"
    "pipx:pipx"
    "uv:uv"
    "bun:bun"
    "pnpm:pnpm"
    "deno:deno"
    "pyenv:pyenv"
    "nvm:nvm"
    "chruby:chruby"
    "ruby-install:ruby-install"
    "rustup:rustup"
    "swiftly:swiftly"
    "go:Go"
    "java:Java"
    "dotnet:.NET SDK"
  )
  
  for tool_info in "${tools[@]}"; do
    local tool="${tool_info%%:*}"
    local name="${tool_info##*:}"
    
    if command -v "$tool" >/dev/null 2>&1; then
      echo "${GREEN}✅ $name: Found via command${NC}"
      ((all_found++))
    else
      # Check via Homebrew for tools that might be installed there
          local found_via_brew=false
      
      if [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
        case "$tool" in
          conda)
            if "$HOMEBREW_PREFIX/bin/brew" list --cask miniforge >/dev/null 2>&1 || \
               "$HOMEBREW_PREFIX/bin/brew" list --cask anaconda >/dev/null 2>&1 || \
               "$HOMEBREW_PREFIX/bin/brew" list --cask miniconda >/dev/null 2>&1; then
              found_via_brew=true
            fi
            ;;
          pipx|pyenv|go|chruby|ruby-install|uv|bun|pnpm|deno)
            if "$HOMEBREW_PREFIX/bin/brew" list "$tool" >/dev/null 2>&1; then
              found_via_brew=true
            fi
            ;;
          java)
            if "$HOMEBREW_PREFIX/bin/brew" list openjdk >/dev/null 2>&1 || \
               "$HOMEBREW_PREFIX/bin/brew" list --cask temurin >/dev/null 2>&1 || \
               "$HOMEBREW_PREFIX/bin/brew" list --cask zulu >/dev/null 2>&1 || \
               "$HOMEBREW_PREFIX/bin/brew" list --cask java >/dev/null 2>&1; then
              found_via_brew=true
            fi
            ;;
          dotnet)
            if "$HOMEBREW_PREFIX/bin/brew" list --cask dotnet-sdk >/dev/null 2>&1 || \
               "$HOMEBREW_PREFIX/bin/brew" list --cask dotnet >/dev/null 2>&1; then
              found_via_brew=true
            fi
            ;;
        esac
      fi
      
      # Special checks for tools with custom locations
      case "$tool" in
        nvm)
          if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
            echo "${GREEN}✅ $name: Found at $HOME/.nvm${NC}"
            ((all_found++))
            continue
          fi
          ;;
        rustup)
          if [[ -f "$HOME/.cargo/bin/rustup" ]]; then
            echo "${GREEN}✅ $name: Found at $HOME/.cargo${NC}"
            ((all_found++))
            continue
          fi
          ;;
        swiftly)
          if [[ -f "$HOME/.swiftly/bin/swiftly" ]]; then
            echo "${GREEN}✅ $name: Found at $HOME/.swiftly${NC}"
            ((all_found++))
            continue
          fi
          ;;
        pyenv)
          if [[ -d "$HOME/.pyenv" ]] || [[ -d "$HOMEBREW_PREFIX/opt/pyenv" ]]; then
            echo "${GREEN}✅ $name: Found in custom location${NC}"
            ((all_found++))
            continue
          fi
          ;;
      esac
      
      if [[ "$found_via_brew" == true ]]; then
        echo "${GREEN}✅ $name: Found via Homebrew${NC}"
        ((all_found++))
      else
        echo "${YELLOW}❌ $name: Not found${NC}"
        ((all_missing++))
      fi
    fi
  done
  
  echo ""
  echo "Summary:"
  echo "  ${GREEN}Found: $all_found${NC}"
  echo "  ${YELLOW}Missing: $all_missing${NC}"
  echo ""
  
  if [[ $all_missing -eq 0 ]]; then
    echo "${GREEN}✅ All tools detected correctly!${NC}"
    return 0
  else
    echo "${YELLOW}⚠️  Some tools not detected. This is normal if they're not installed.${NC}"
    return 1
  fi
}

# Main installation
main() {
  if [[ "$TEST_MODE" == true ]]; then
    test_detection
    return $?
  fi
  
  if [[ "$CHECK_MODE" == false ]]; then
    echo ""
    echo "This script installs language tooling:"
    echo "  - Package managers: Conda, pipx, uv"
    echo "  - Modern JS: bun, pnpm, deno"
    echo "  - Version managers: pyenv, nvm, chruby, rustup, swiftly"
    echo "  - Runtimes: Go, Java, .NET"
    echo "  - Opt-in: JVM extras (Kotlin/Scala/Clojure/Gradle/Maven/Groovy)"
    echo ""
    echo "Note: Version managers will also install the latest/LTS version of each language."
    echo "      Some tools require Homebrew to be installed first."
    echo "      Run './install.sh' to install system package managers (Homebrew, MacPorts, Nix, mas)."
    echo ""
  fi

  # Language Package Managers
  echo "${BLUE}=== Language Package Managers ===${NC}"
  install_conda
  install_pipx
  install_uv

  echo ""
  echo "${BLUE}=== Modern JS tooling ===${NC}"
  install_bun
  install_pnpm
  install_deno

  echo ""
  echo "${BLUE}=== Language Version Managers & Runtimes ===${NC}"
  install_pyenv
  install_nvm
  install_chruby
  install_rustup
  install_swiftly
  install_go
  install_java
  install_dotnet

  echo ""
  echo "${BLUE}=== Optional ===${NC}"
  install_jvm_ecosystem
  
  if [[ "$CHECK_MODE" == true ]]; then
    echo ""
    echo "${GREEN}✅ Check complete!${NC}"
    echo ""
    echo "This was a dry-run. No tools were installed."
    echo "Run './dev-tools.sh' without arguments to actually install missing tools."
    return 0
  fi
  
  echo ""
  if [[ $install_warnings -gt 0 ]]; then
    echo "${YELLOW}⚠️  Installation completed with $install_warnings warning(s)${NC}"
  else
    echo "${GREEN}✅ Installation complete!${NC}"
  fi
  echo ""
  echo "Next steps:"
  echo "  1. Restart your terminal or run: source ~/.zshrc"
  echo "  2. Language versions have been installed automatically, but you can install additional versions:"
  echo "     - Python: pyenv install <version>"
  echo "     - Node.js: nvm install <version>"
  echo "     - Ruby: ruby-install ruby <version>, then chruby <version>"
  echo "     - Rust: rustup install <version>"
  echo "     - Swift: swiftly install <version>"
  echo "  3. Run 'update' to update all installed tools"
  echo ""
}

# Run main function
main
