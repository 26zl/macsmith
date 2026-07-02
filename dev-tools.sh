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
if [[ -z "${HOME:-}" ]]; then
  echo "ERROR: HOME is not set; refusing to install tools into an unknown user profile" >&2
  exit 1
fi
DATA_DIR="$HOME/.local/share/macsmith"
LOCK_DIR="$DATA_DIR/devtools.lock.d"
_dt_interrupted=0
_dt_cleaned=0   # guard so the cleanup body runs once (EXIT + signal handlers may both fire)
# Temp files to remove on exit/interrupt (mirrors install.sh's TMP_FILES).
DT_TMP_FILES=()

# Share idempotent cleanup between normal exit and signal handlers.
_dt_cleanup() {
  [[ "$_dt_cleaned" == "1" ]] && return 0
  _dt_cleaned=1
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  local _f
  for _f in "${DT_TMP_FILES[@]}"; do
    [[ -n "$_f" ]] && rm -f "$_f" 2>/dev/null
  done
  if [[ "$_dt_interrupted" == "1" ]]; then
    printf '\n\033[1;33m⚠️  dev-tools interrupted.\033[0m\n'
    printf '  No persistent files are written by this script, so nothing is corrupted.\n'
    printf '  Any in-flight Homebrew/curl install may be mid-transaction but is self-recoverable.\n'
    printf '  Re-run ./dev-tools.sh when ready — it resumes where it left off.\n'
  fi
}
_dt_cleanup_on_exit() {
  local exit_code=$?
  _dt_cleanup
  exit "$exit_code"
}
_dt_on_interrupt() {
  _dt_interrupted=1
  # zsh does not run the EXIT trap after a re-raised SIGINT, so clean up
  # explicitly (mirrors _dt_on_term) — otherwise the lock + temp files leak
  # and the interrupt notice never prints.
  _dt_cleanup
  trap - INT EXIT
  kill -INT $$
}
# Re-raise termination signals after cleanup to preserve their status.
_dt_on_term() {
  _dt_cleanup
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
      echo "ERROR: Another instance of dev-tools.sh is already running (PID $lock_pid)"
      echo "  If this is a mistake, remove the lock directory: rm -rf $LOCK_DIR"
      exit 1
    fi
    # Empty PID (crashed mid-acquire) or dead PID → reclaim the stale lock.
    rm -rf "$LOCK_DIR"
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "ERROR: Could not acquire dev-tools lock at $LOCK_DIR" >&2
    exit 1
  fi
  echo $$ > "$LOCK_DIR/pid"
}
_acquire_lock
# Register traps at script scope to avoid zsh function-local EXIT traps.
trap _dt_cleanup_on_exit EXIT
trap _dt_on_interrupt INT
trap '_dt_on_term' TERM HUP

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
if [[ -n "${NO_COLOR:-}" ]]; then RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''; fi
install_warnings=0
DT_FAILURES=0   # genuine install failures (distinct from warnings); >0 makes the run exit non-zero

warn() {
  ((install_warnings++)) || true   # post-increment returns the OLD value, which is 0 (false) on the first call; don't let it trip callers
  echo "${YELLOW}⚠️  $1${NC}" >&2
}

# Record install failures without stopping the remaining optional installs.
fail() {
  ((DT_FAILURES++)) || true
  warn "$1"
}

# Extract a short Homebrew failure hint in this standalone script.
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

# Show the tail of captured source-build logs after failures.
_show_build_log() {
  local log="$1"
  [[ -n "$log" && -s "$log" ]] || return 0
  echo "  ${YELLOW}Build log: $log (last 10 lines)${NC}" >&2
  /usr/bin/tail -n 10 "$log" 2>/dev/null | /usr/bin/sed 's/^/    /' >&2
}

_env_true() {
  case "${1:l}" in
    1|true|yes|on|enable|enabled) return 0 ;;
  esac
  return 1
}

_download_verified_script() {
  local url="$1" expected_sha="$2" destination="$3"
  local actual_sha=""
  if ! /usr/bin/curl --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$url" -o "$destination"; then
    return 1
  fi
  actual_sha="$(/usr/bin/shasum -a 256 "$destination" 2>/dev/null | /usr/bin/awk '{print $1}')"
  if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "${RED}❌ SHA-256 mismatch for installer from $url${NC}" >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   ${actual_sha:-unavailable}" >&2
    return 1
  fi
  if ! /usr/bin/head -n1 "$destination" | /usr/bin/grep -q '^#!'; then
    echo "${RED}❌ Downloaded installer has no shebang; refusing to execute it${NC}" >&2
    return 1
  fi
  /bin/chmod 700 "$destination" || return 1
}

# Ask user for confirmation with input validation
_ask_user() {
  local prompt="$1"
  local default="${2:-N}"
  
  # Validate inputs
  [[ -z "$prompt" ]] && { echo "${RED}Error: _ask_user called without prompt${NC}" >&2; return 1; }
  [[ "$default" != "Y" && "$default" != "N" ]] && default="N"
  
  # Non-interactive: MACSMITH_YES=1 → yes to all; NONINTERACTIVE/CI=1 → each prompt's
  # own default; FORCE_INTERACTIVE=1 → real prompts.
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
  
  echo -n "$prompt "
  if [[ "$default" == "Y" ]]; then
    echo -n "[Y/n]: "
  else
    echo -n "[y/N]: "
  fi
  
  # Read piped bootstrap prompts from /dev/tty unless FORCE_INTERACTIVE keeps stdin.
  local response=""
  if _env_true "${FORCE_INTERACTIVE:-}" || [[ -t 0 ]]; then
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

# Filter installed packages, detach Homebrew from stdin, and show batch progress.
_brew_batch() {
  local label="$1"; shift
  local brew="$HOMEBREW_PREFIX/bin/brew"
  if [[ -z "$HOMEBREW_PREFIX" || ! -x "$brew" ]]; then warn "$label: Homebrew not available"; return 0; fi
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
    fail "$label: failed to install: ${failed[*]}"
    return ${#failed[@]}
  fi
  return 0
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
    local err=""
    if err="$( { "$brew" install "$tool" </dev/null >/dev/null; } 2>&1 )"; then
      echo "${GREEN}✅ $display installed${NC}"
    else
      fail "$display installation failed$(_brew_fail_hint "$err")"
    fi
  fi
}

# Check if running on macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "${RED}❌ Error: This script is designed for macOS only${NC}"
  exit 1
fi

# Enforce the documented minimum (macOS 13 Ventura)
os_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
if [[ "$os_major" =~ ^[0-9]+$ ]] && (( os_major < 13 )); then
  echo "${RED}❌ Error: macsmith requires macOS 13 (Ventura) or later (detected $(sw_vers -productVersion 2>/dev/null))${NC}"
  exit 1
fi

# Detect Homebrew installation prefix
_detect_brew_prefix() {
  if [[ -d /opt/homebrew ]]; then
    echo /opt/homebrew
  elif [[ -d /usr/local/Homebrew ]] || [[ -x /usr/local/bin/brew ]]; then
    # Intel/relocated Homebrew may have /usr/local/bin/brew without the
    # /usr/local/Homebrew dir; match the install.sh/zsh.sh/macsmith.sh copies.
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
        fail "Miniforge installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  Conda installation requires Homebrew${NC}"
  fi
}

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
        fail "pipx installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  pipx installation requires Homebrew${NC}"
  fi
}

install_pyenv() {
  local pyenv_installed=false
  
  # Check if pyenv is available as a command
  if command -v pyenv >/dev/null 2>&1; then
    pyenv_installed=true
  fi

  # Check if pyenv is installed via Homebrew
  if [[ "$pyenv_installed" == false ]] && [[ -n "$HOMEBREW_PREFIX" ]] && [[ -x "$HOMEBREW_PREFIX/bin/brew" ]]; then
    if "$HOMEBREW_PREFIX/bin/brew" list pyenv >/dev/null 2>&1; then
      pyenv_installed=true
      # Add pyenv to PATH if not already there
      if [[ -d "$HOMEBREW_PREFIX/opt/pyenv" ]]; then
        export PATH="$HOMEBREW_PREFIX/opt/pyenv/bin:$PATH"
        # Evaluate the shell configuration emitted by pyenv.
        eval "$(pyenv init -)" 2>/dev/null || true
      fi
    fi
  fi

  # Detect a standalone ~/.pyenv independently of Homebrew.
  if [[ "$pyenv_installed" == false ]] && [[ -d "$HOME/.pyenv" ]] && [[ -f "$HOME/.pyenv/bin/pyenv" ]]; then
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
      if [[ "$CHECK_MODE" == true ]]; then
        echo "  ${YELLOW}📦 pyenv: would install latest Python (dry-run)${NC}"
        return 0
      fi
      echo "  ${BLUE}INFO:${NC} Installing latest Python via pyenv..."
      local latest_python
      latest_python=$(pyenv install --list 2>/dev/null | /usr/bin/grep -E "^[[:space:]]+3\.[0-9]+\.[0-9]+$" | /usr/bin/sort -V | /usr/bin/tail -1 | /usr/bin/xargs)
      if [[ -n "$latest_python" ]]; then
        echo "  ${BLUE}INFO:${NC} Installing Python $latest_python (this may take a few minutes)..."
        local _py_log=""
        _py_log="$(mktemp "${TMPDIR:-/tmp}/pyenv-build.XXXXXX" 2>/dev/null)" || _py_log=""
        [[ -n "$_py_log" ]] && DT_TMP_FILES+=("$_py_log")
        if pyenv install "$latest_python" 2>"${_py_log:-/dev/null}"; then
          pyenv global "$latest_python" 2>/dev/null || true
          echo "  ${GREEN}✅ Python $latest_python installed and set as global${NC}"
        else
          echo "  ${YELLOW}⚠️  Failed to install Python via pyenv (you can install manually later with: pyenv install <version>)${NC}"
          ((DT_FAILURES++)) || true
          _show_build_log "$_py_log"
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
        local latest_python
        latest_python=$(pyenv install --list 2>/dev/null | /usr/bin/grep -E "^[[:space:]]+3\.[0-9]+\.[0-9]+$" | /usr/bin/sort -V | /usr/bin/tail -1 | /usr/bin/xargs)
        if [[ -n "$latest_python" ]]; then
          echo "  ${BLUE}INFO:${NC} Installing Python $latest_python (this may take a few minutes)..."
          local _py_log=""
          _py_log="$(mktemp "${TMPDIR:-/tmp}/pyenv-build.XXXXXX" 2>/dev/null)" || _py_log=""
          [[ -n "$_py_log" ]] && DT_TMP_FILES+=("$_py_log")
          if pyenv install "$latest_python" 2>"${_py_log:-/dev/null}"; then
            pyenv global "$latest_python" 2>/dev/null || true
            echo "  ${GREEN}✅ Python $latest_python installed and set as global${NC}"
          else
            echo "  ${YELLOW}⚠️  Failed to install Python via pyenv (you can install manually later with: pyenv install <version>)${NC}"
            ((DT_FAILURES++)) || true
            _show_build_log "$_py_log"
          fi
        else
          echo "  ${YELLOW}⚠️  Could not determine latest Python version (you can install manually later with: pyenv install <version>)${NC}"
        fi
      else
        fail "pyenv installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  pyenv installation requires Homebrew${NC}"
  fi
}

install_nvm() {
  local NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  export NVM_DIR   # the nvm install.sh we pipe to bash reads this from the env; a function-local alone is invisible to the child
  if [[ -s "$NVM_DIR/nvm.sh" ]] || type nvm >/dev/null 2>&1; then
    echo "${GREEN}✅ nvm already installed${NC}"
    # Locate nvm.sh in NVM_DIR or Homebrew before checking installed Node versions.
    local nvm_sh=""
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
      nvm_sh="$NVM_DIR/nvm.sh"
    elif [[ -n "$HOMEBREW_PREFIX" ]] && [[ -s "$HOMEBREW_PREFIX/opt/nvm/nvm.sh" ]]; then
      nvm_sh="$HOMEBREW_PREFIX/opt/nvm/nvm.sh"
    fi
    if [[ -n "$nvm_sh" ]]; then
      source "$nvm_sh" 2>/dev/null || true
    fi
    # Check if Node.js is installed via nvm (only when nvm is actually usable)
    if nvm --version >/dev/null 2>&1; then
      if nvm list 2>/dev/null | /usr/bin/grep -qE "v[0-9]+\.[0-9]+\.[0-9]+"; then
        echo "  ${BLUE}INFO:${NC} Node.js versions already installed via nvm"
      else
        if [[ "$CHECK_MODE" == true ]]; then
          echo "  ${YELLOW}📦 nvm: would install Node.js LTS (dry-run)${NC}"
          return 0
        fi
        echo "  ${BLUE}INFO:${NC} Installing Node.js LTS via nvm..."
        if nvm install --lts 2>/dev/null; then
          nvm use --lts 2>/dev/null || true
          echo "  ${GREEN}✅ Node.js LTS installed and activated${NC}"
        else
          echo "  ${YELLOW}⚠️  Failed to install Node.js via nvm (you can install manually later)${NC}"
          ((DT_FAILURES++)) || true
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
    local nvm_version="v0.40.5"
    local nvm_installer_sha256="582070e4c44452c1d8d68e16fc786c2216ecba6bc6bf18dc280a03fdba6ed1a9"
    local nvm_installer=""
    nvm_installer="$(mktemp "${TMPDIR:-/tmp}/macsmith-nvm.XXXXXX")" || {
      fail "nvm installation failed (could not create temporary file)"
      return 1
    }
    DT_TMP_FILES+=("$nvm_installer")
    echo "  ${BLUE}INFO:${NC} Installing nvm $nvm_version..."
    if _download_verified_script \
      "https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_version}/install.sh" \
      "$nvm_installer_sha256" "$nvm_installer" \
      && /bin/bash "$nvm_installer"; then
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
          ((DT_FAILURES++)) || true
        fi
      fi
    else
      fail "nvm installation failed"
    fi
  fi
}

# Function to install chruby and ruby-install
install_chruby() {
  local chruby_installed=false
  local chruby_script=""
  local path  # zsh: `path` is tied to $PATH; declare local so the loops below don't clobber it
  
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
          fail "chruby installation failed"
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
          fail "ruby-install installation failed"
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
      # Parse indented stable versions from ruby-install's Ruby section.
      local latest_ruby
      latest_ruby=$(ruby-install --list ruby 2>/dev/null | /usr/bin/awk '/^[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' | /usr/bin/sort -V | /usr/bin/tail -n1)
      
      if [[ -n "$latest_ruby" ]]; then
        echo "  ${BLUE}INFO:${NC} Installing Ruby $latest_ruby (this may take a few minutes)..."
        local _ruby_log=""
        _ruby_log="$(mktemp "${TMPDIR:-/tmp}/ruby-build.XXXXXX" 2>/dev/null)" || _ruby_log=""
        [[ -n "$_ruby_log" ]] && DT_TMP_FILES+=("$_ruby_log")
        if ruby-install ruby "$latest_ruby" 2>"${_ruby_log:-/dev/null}"; then
          echo "  ${GREEN}✅ Ruby $latest_ruby installed${NC}"
          if [[ -n "$chruby_script" ]] && [[ -f "$chruby_script" ]]; then
            source "$chruby_script" 2>/dev/null || true
            chruby "ruby-$latest_ruby" 2>/dev/null || true
          fi
        else
          echo "  ${YELLOW}⚠️  Failed to install Ruby via ruby-install (you can install manually later with: ruby-install ruby <version>)${NC}"
          ((DT_FAILURES++)) || true
          _show_build_log "$_ruby_log"
        fi
      else
        echo "  ${YELLOW}⚠️  Could not determine latest Ruby version (you can install manually later with: ruby-install ruby <version>)${NC}"
        echo "  ${BLUE}INFO:${NC} Try: ruby-install --list ruby (to see available versions)"
      fi
    fi
  fi
}

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
      if [[ "$CHECK_MODE" == true ]]; then
        echo "  ${YELLOW}📦 rustup: would install Rust stable (dry-run)${NC}"
        return 0
      fi
      echo "  ${BLUE}INFO:${NC} Installing Rust stable toolchain..."
      if rustup install stable 2>/dev/null; then
        rustup default stable 2>/dev/null || true
        echo "  ${GREEN}✅ Rust stable installed and set as default${NC}"
      else
        echo "  ${YELLOW}⚠️  Failed to install Rust via rustup (you can install manually later)${NC}"
        ((DT_FAILURES++)) || true
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
    local rustup_installer_sha256="6c30b75a75b28a96fd913a037c8581b580080b6ee9b8169a3c0feb1af7fe8caf"
    local rustup_installer=""
    rustup_installer="$(mktemp "${TMPDIR:-/tmp}/macsmith-rustup.XXXXXX")" || {
      fail "rustup installation failed (could not create temporary file)"
      return 1
    }
    DT_TMP_FILES+=("$rustup_installer")
    if _download_verified_script "https://sh.rustup.rs" "$rustup_installer_sha256" "$rustup_installer" \
      && /bin/bash "$rustup_installer" -y --no-modify-path; then
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
        ((DT_FAILURES++)) || true
      fi
      echo "  ${BLUE}INFO:${NC} Restart your terminal or run: source \$HOME/.cargo/env"
    else
      fail "rustup installation failed"
    fi
  fi
}

install_swiftly() {
  local swiftly_installed=false
  local path  # zsh: `path` is tied to $PATH; declare local so the loop below doesn't clobber it

  # Check if swiftly is available as a command
  if command -v swiftly >/dev/null 2>&1; then
    swiftly_installed=true
  # Check common swiftly locations (swiftly installs to $HOME/.swiftly/bin/swiftly)
  elif [[ -f "$HOME/.swiftly/bin/swiftly" ]]; then
    swiftly_installed=true
    # Add to PATH if not already there
    if [[ ":$PATH:" != *":$HOME/.swiftly/bin:"* ]]; then
      export PATH="$HOME/.swiftly/bin:$PATH"
    fi
  elif [[ -f "$HOME/.local/bin/swiftly" ]]; then
    swiftly_installed=true
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
    # Check the toolchain directory before parsing version-dependent swiftly output.
    local _swift_installed=false
    if [[ -d "$HOME/.swiftly/toolchains" ]] && /usr/bin/find "$HOME/.swiftly/toolchains" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | /usr/bin/grep -q .; then
      _swift_installed=true
    # Use `swiftly list`, which works with current swiftly releases.
    elif swiftly list 2>/dev/null | /usr/bin/grep -qE "Swift [0-9]+\.[0-9]+"; then
      _swift_installed=true
    # Fallback: if a Swift compiler is on PATH and reports a version, the
    # toolchain is functional regardless of where swiftly hides its files.
    elif command -v swift >/dev/null 2>&1 && swift --version 2>/dev/null | /usr/bin/grep -qE "[0-9]+\.[0-9]+\.[0-9]+"; then
      _swift_installed=true
    fi
    if [[ "$_swift_installed" == true ]]; then
      echo "  ${BLUE}INFO:${NC} Swift versions already installed via swiftly"
    else
      if [[ "$CHECK_MODE" == true ]]; then
        echo "  ${YELLOW}📦 swiftly: would install latest Swift (dry-run)${NC}"
        return 0
      fi
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
          ((DT_FAILURES++)) || true
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
    # Install swiftly's signed package into the current user's home.
    local _swiftly_pkg
    _swiftly_pkg="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/swiftly.XXXXXX")" || {
      fail "swiftly installation failed (could not create temporary package file)"
      return 1
    }
    DT_TMP_FILES+=("$_swiftly_pkg")  # ensure removal on Ctrl-C/EXIT, not just success/fail branches
    if /usr/bin/curl --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL https://download.swift.org/swiftly/darwin/swiftly.pkg -o "$_swiftly_pkg"; then
      # Verify the downloaded package signature before installation.
      local _swiftly_signature=""
      local _swiftly_signature_rc=0
      _swiftly_signature="$(/usr/sbin/pkgutil --check-signature "$_swiftly_pkg" 2>&1)" \
        || _swiftly_signature_rc=$?
      if [[ $_swiftly_signature_rc -ne 0 ]] || ! printf '%s\n' "$_swiftly_signature" \
        | /usr/bin/grep -Fq 'Developer ID Installer: Swift Open Source (V9AUD2URP3)'; then
        fail "swiftly package signature verification failed — refusing to install"
        /bin/rm -f "$_swiftly_pkg" 2>/dev/null || true
        return 1
      fi
      if /usr/sbin/installer -pkg "$_swiftly_pkg" -target CurrentUserHomeDirectory; then
        /bin/rm -f "$_swiftly_pkg" 2>/dev/null || true
        # init writes ~/.swiftly/env.sh that the PATH wiring below sources.
        "$HOME/.swiftly/bin/swiftly" init --quiet-shell-followup --assume-yes 2>/dev/null || true
        echo "${GREEN}✅ swiftly installed${NC}"
        # Load swiftly into the current shell before installing Swift.
        [[ -s "$HOME/.swiftly/env.sh" ]] && source "$HOME/.swiftly/env.sh" 2>/dev/null
        export PATH="$HOME/.swiftly/bin:$PATH"
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
            ((DT_FAILURES++)) || true
          fi
        else
          echo "  ${YELLOW}⚠️  Could not determine latest Swift version (you can install manually later with: swiftly install <version>)${NC}"
        fi
      else
        /bin/rm -f "$_swiftly_pkg" 2>/dev/null || true
        fail "swiftly installation failed"
      fi
    else
      /bin/rm -f "$_swiftly_pkg" 2>/dev/null || true
      fail "swiftly installation failed"
    fi
  fi
}

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
        fail "Go installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  Go installation requires Homebrew, or install manually from https://go.dev/dl/${NC}"
  fi
}

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
        fail "OpenJDK installation failed"
      fi
    fi
  else
    echo "${YELLOW}⚠️  Java installation requires Homebrew, or install manually${NC}"
  fi
}

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
        fail ".NET SDK installation failed"
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
install_bun()  { _install_brew_tool bun  "bun (JS/TS runtime + pkg manager)" "Y"; }  # bun is in homebrew-core; the oven-sh/bun tap is redundant
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
  local rc=$?
  if (( rc == 0 )); then
    echo "${GREEN}✅ JVM extras installed${NC}"
  else
    echo "${YELLOW}⚠️  JVM extras installed with $rc failure(s) (see warnings above)${NC}"
  fi
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
  if (( install_warnings > 0 || DT_FAILURES > 0 )); then
    echo "${YELLOW}⚠️  Installation completed with ${install_warnings} warning(s), ${DT_FAILURES} failure(s)${NC}"
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

  # Exit-status contract: 0 = all installs OK, 1 = one or more installs failed.
  if (( DT_FAILURES > 0 )); then
    return 1
  fi
  return 0
}

# Run main function
main
