#!/usr/bin/env zsh

# macsmith - Standalone system and dev environment maintenance script
# Usage: macsmith [update|verify|versions|upgrade]

# Wrap entire script in a block so zsh reads the full file into memory
# before execution. This prevents parse errors when self-upgrade replaces
# this file while it's running.
{

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# ================================ SYSTEM COMPATIBILITY ====================

_check_macos_compatibility() {
  # Verify we're running on macOS
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: This script is designed for macOS only"
    return 1
  fi
  
  # Detect architecture
  local arch=""
  case "$(uname -m)" in
    x86_64) arch="Intel" ;;
    arm64) arch="Apple Silicon" ;;
    *) arch="Unknown" ;;
  esac
  
  echo "${GREEN}[macOS]${NC} Detected: macOS ($arch)"
  
  # Check for Homebrew
  local HOMEBREW_PREFIX="$(_detect_brew_prefix)"
  if [[ -z "$HOMEBREW_PREFIX" ]]; then
    echo "  ${RED}WARNING:${NC} Homebrew not detected - some features may not work"
  else
    echo "  Homebrew found at: $HOMEBREW_PREFIX"
  fi
  
  # Check available disk space
  if command -v df >/dev/null 2>&1; then
    local available_space=$(df -g . 2>/dev/null | awk 'NR==2 {print $4}' || echo "")
    if [[ -n "$available_space" ]] && [[ "$available_space" =~ ^[0-9]+$ ]] && [[ "$available_space" -lt 1 ]]; then
      echo "  ${RED}WARNING:${NC} Low disk space detected ($available_space GB available)"
    fi
  fi
}

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

_ensure_system_path() {
  local required_paths=(/usr/bin /bin /usr/sbin /sbin)
  local path_entry=""
  for path_entry in "${required_paths[@]}"; do
    case ":$PATH:" in
      *":$path_entry:"*) ;;
      *) PATH="$path_entry:$PATH" ;;
    esac
  done
  export PATH
}

_is_disabled() {
  local value="${1:-}"
  case "${value:l}" in
    0|false|no|off|disable|disabled)
      return 0
      ;;
  esac
  return 1
}

# Check if we're in a project directory (not home directory)
# Returns 0 if in project directory, 1 if in home directory or other location
_is_project_directory() {
  local current_dir="${PWD:-$(pwd)}"
  local home_dir="${HOME:-}"
  
  # If we're in home directory, it's not a project (global packages are OK to update)
  if [[ "$current_dir" == "$home_dir" ]]; then
    return 1  # Not a project directory
  fi
  
  # Check for project indicators (but not in home directory)
  # If we have project files, we're in a project directory
  if [[ -f "package.json" ]] || [[ -f "Gemfile" ]] || [[ -f "go.mod" ]] || [[ -f "requirements.txt" ]] || [[ -f "Cargo.toml" ]]; then
    # Additional check: if we're in a subdirectory of home that looks like a project
    # (e.g., ~/projects/myapp), treat it as a project
    if [[ "$current_dir" == "$home_dir"/* ]]; then
      # Check if it's a common project location (projects, dev, code, etc.)
      local relative_path="${current_dir#"$home_dir"/}"
      local first_dir="${relative_path%%/*}"
      case "$first_dir" in
        projects|dev|code|workspace|workspaces|src|sources|repos|repositories|git|github|gitlab|bitbucket)
          return 0  # Likely a project directory
          ;;
        *)
          # If it has project files, it's a project
          return 0
          ;;
      esac
    else
      # Not in home directory and has project files - definitely a project
      return 0
    fi
  fi
  
  return 1  # Not a project directory
}

# Check if Python is system Python (should not be modified)
_is_system_python() {
  local python_path="$1"
  [[ -z "$python_path" ]] && return 1
  
  # Check if it's in system directories
  case "$python_path" in
    /usr/bin/python*|/System/Library/Frameworks/Python.framework/*)
      return 0
      ;;
  esac
  
  # Check if it's a symlink pointing to system Python
  if [[ -L "$python_path" ]]; then
    local resolved=$(readlink -f "$python_path" 2>/dev/null || readlink "$python_path" 2>/dev/null || echo "")
    case "$resolved" in
      /usr/bin/python*|/System/Library/Frameworks/Python.framework/*)
        return 0
        ;;
    esac
  fi
  
  return 1
}

_is_homebrew_python() {
  local python_path="$1"
  [[ -z "$python_path" ]] && return 1

  local brew_prefix="$(_detect_brew_prefix)"
  [[ -z "$brew_prefix" ]] && return 1

  case "$python_path" in
    "$brew_prefix"/*)
      return 0
      ;;
  esac

  if [[ -L "$python_path" ]]; then
    local resolved=$(readlink -f "$python_path" 2>/dev/null || readlink "$python_path" 2>/dev/null || echo "")
    case "$resolved" in
      "$brew_prefix"/*)
        return 0
        ;;
    esac
  fi

  return 1
}

# Check if Ruby is system Ruby (should not be modified)
_is_system_ruby() {
  local ruby_path="$1"
  [[ -z "$ruby_path" ]] && return 1
  
  # Check if it's in system directories
  case "$ruby_path" in
    /usr/bin/ruby|/System/Library/Frameworks/Ruby.framework/*)
      return 0
      ;;
  esac
  
  # Check if it's a symlink pointing to system Ruby
  if [[ -L "$ruby_path" ]]; then
    local resolved=$(readlink -f "$ruby_path" 2>/dev/null || readlink "$ruby_path" 2>/dev/null || echo "")
    case "$resolved" in
      /usr/bin/ruby|/System/Library/Frameworks/Ruby.framework/*)
        return 0
        ;;
    esac
  fi
  
  return 1
}

# ================================ RUBY GEM COMPATIBILITY ===================

_fix_all_ruby_gems() {
  echo "${GREEN}[Ruby]${NC} Auto-fixing Ruby gems for compatibility..."
  
  if ! command -v ruby >/dev/null 2>&1; then
    echo "  ERROR: Ruby not found, skipping gem fix"
    return 1
  fi
  
  local current_ruby="$(ruby -v | cut -d' ' -f2)"
  echo "  Current Ruby version: $current_ruby"
  
  # Get all installed gems
  local installed_gems=($(gem list --no-versions 2>/dev/null || true))
  
  if [[ ${#installed_gems[@]} -eq 0 ]]; then
    echo "  No gems found to check"
    return 0
  fi
  
  echo "  Checking ${#installed_gems[@]} installed gems..."
  
  local fixed_count=0
  local problematic_gems=()
  local working_gems=0
  
  
  # Check each gem for issues
  for gem in "${installed_gems[@]}"; do
    # Skip default gems that can't be uninstalled
    if gem list "$gem" | grep -q "default"; then
      ((working_gems++))
      continue
    fi
    
    # Check if gem executable exists and works
    local gem_executable=""
    local executable_path=""
    if executable_path="$(gem contents "$gem" 2>/dev/null | grep -E "(bin/|exe/)" | head -n1)"; then
      gem_executable="$(basename "$executable_path")"
    fi
    
    # Check if gem is problematic
    local is_problematic=false
    
    # Check if gem has executables and test them
    if [[ -n "$gem_executable" ]]; then
      # Check if executable is in PATH
      if command -v "$gem_executable" >/dev/null 2>&1; then
        # Test if the executable actually works
        if ! "$gem_executable" --version >/dev/null 2>&1 && ! "$gem_executable" -v >/dev/null 2>&1 && ! "$gem_executable" --help >/dev/null 2>&1; then
          is_problematic=true
          echo "  DETECTED: $gem executable is broken"
        else
          ((working_gems++))
        fi
      else
        # Executable not in PATH - might be problematic
        is_problematic=true
        echo "  DETECTED: $gem executable not found in PATH"
      fi
    else
      # Gems without executables are considered working
      ((working_gems++))
    fi
    
    if [[ "$is_problematic" == true ]]; then
      # Check if gem is already in problematic_gems array
      local already_listed=false
      for existing_gem in "${problematic_gems[@]}"; do
        if [[ "$existing_gem" == "$gem" ]]; then
          already_listed=true
          break
        fi
      done
      
      if [[ "$already_listed" == false ]]; then
        problematic_gems+=("$gem")
      fi
      
      echo "  FIXING: $gem..."
      
      # Uninstall and reinstall (non-interactive)
      gem uninstall "$gem" --ignore-dependencies --force --no-user-install 2>/dev/null || true
      if gem install "$gem" --no-user-install --no-document 2>/dev/null; then
        ((fixed_count++))
        echo "    SUCCESS: Fixed $gem"
      else
        echo "    ${RED}WARNING:${NC} Failed to fix $gem"
      fi
    fi
  done
  
  # Reinstall gems from Gemfile if it exists
  # BUT: Only if we're NOT in a project directory (to avoid modifying project files)
  # If Gemfile is in home directory, it's for global gems (OK to update)
  if [[ -f "Gemfile" ]]; then
    if _is_project_directory; then
      echo "  ${BLUE}INFO:${NC} Gemfile found in project directory - skipping bundle install"
      echo "  ${BLUE}INFO:${NC} This script maintains system tools, not project dependencies"
      echo "  ${BLUE}INFO:${NC} Run 'bundle install' manually in your project directory if needed"
    else
      # Gemfile in home directory or other non-project location - OK to update (global gems)
      echo "  BUNDLE: Reinstalling gems from Gemfile (global installation)..."
      bundle install 2>/dev/null || echo "    ${RED}WARNING:${NC} Bundle install failed"
    fi
  fi
  
  # Clear gem cache
  echo "  CLEANUP: Clearing gem cache..."
  gem cleanup 2>/dev/null || true
  
  if [[ $fixed_count -gt 0 ]]; then
    echo "  SUCCESS: Fixed $fixed_count problematic gems ($working_gems working properly)"
  else
    echo "  SUCCESS: All $working_gems gems are working properly"
  fi
  
  # Refresh command hash table after gem changes
  hash -r 2>/dev/null || true
}

# ================================ PYTHON COMPATIBILITY =====================

_check_python_package_compatibility() {
  local current_python="$1"
  local target_python="$2"
  local package_name="$3"
  
  # Check if package has Python version requirements
  local requirements=""
  if command -v pip >/dev/null 2>&1; then
    requirements="$(pip show "$package_name" 2>/dev/null | grep -i "requires-python" | cut -d: -f2 | tr -d ' ' || true)"
  fi
  
  if [[ -n "$requirements" ]]; then
    # Simple check for Python version requirements (can be extended for more complex parsing)
    if [[ "$requirements" == *"<"* ]] || [[ "$requirements" == *">"* ]] || [[ "$requirements" == *"!="* ]]; then
      echo "  ${RED}WARNING:${NC} $package_name has Python version requirements: $requirements"
      return 1
    fi
  fi
  
  return 0
}

_check_python_upgrade_compatibility() {
  local current_python="$1"
  local target_python="$2"
  
  echo "${GREEN}[Python]${NC} Checking package compatibility before upgrade..."
  local incompatible_packages=()
  
  # Check regular pip packages
  if command -v pip >/dev/null 2>&1; then
    local installed_packages="$(pip list --format=freeze 2>/dev/null | cut -d= -f1 || true)"
    if [[ -n "$installed_packages" ]]; then
      echo "  Checking pip packages..."
      while IFS= read -r package; do
        [[ -z "$package" ]] && continue
        if ! _check_python_package_compatibility "$current_python" "$target_python" "$package"; then
          incompatible_packages+=("$package")
        fi
      done <<< "$installed_packages"
    fi
  fi
  
  # Check pipx packages (isolated in their own venvs, generally safe)
  if command -v pipx >/dev/null 2>&1; then
    local pipx_packages="$(pipx list --short 2>/dev/null | grep -v '^$' || true)"
    if [[ -n "$pipx_packages" ]]; then
      local pipx_count=$(echo "$pipx_packages" | wc -l | tr -d ' ')
      echo "  Checking pipx packages... ($pipx_count packages found)"
      # pipx packages are isolated, safe to upgrade Python
      echo "  ${BLUE}INFO:${NC} pipx packages are isolated and should be safe to upgrade Python"
    fi
  fi
  
  # Report results
  if [[ ${#incompatible_packages[@]} -gt 0 ]]; then
    echo "  ERROR: Incompatible packages found:"
    for package in "${incompatible_packages[@]}"; do
      echo "    - pip: $package"
    done
    echo "  ${RED}WARNING:${NC} Python upgrade skipped to avoid breaking packages"
    return 1
  else
    echo "  SUCCESS: All packages are compatible with new Python version"
    return 0
  fi
}

# ================================ GO HELPERS =============================

# Setup permanent Go configuration in .zprofile
_setup_go_permanent() {
  local goroot="$1"
  [[ -z "$goroot" || ! -d "$goroot" ]] && return 1
  
  local zprofile="$HOME/.zprofile"
  local marker="# Managed by macsmith - Go configuration"
  local go_config_block="export GOROOT=\"$goroot\"
export PATH=\"\$GOROOT/bin:\$PATH\""

  # Check if Go config already exists
  if [[ -f "$zprofile" ]] && grep -q "$marker" "$zprofile" 2>/dev/null; then
    # Update existing Go config - use sed to replace the GOROOT line
    local temp_file=$(mktemp)
    local in_go_block=false
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == *"$marker"* ]]; then
        in_go_block=true
        echo "$line"
        echo "$go_config_block"
        continue
      fi
      if [[ "$in_go_block" == true ]]; then
        # Skip old Go config lines (export GOROOT or export PATH with GOROOT)
        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+GOROOT ]] || [[ "$line" =~ ^[[:space:]]*export[[:space:]]+PATH.*GOROOT ]]; then
          continue
        fi
        # Hit end of Go block, stop skipping
        in_go_block=false
      fi
      echo "$line"
    done < "$zprofile" > "$temp_file"
    mv "$temp_file" "$zprofile"
  else
    # Append new Go config
    {
      echo ""
      echo "$marker"
      echo "$go_config_block"
    } >> "$zprofile"
  fi
  
  return 0
}

# ================================ PYENV HELPERS =============================

_pyenv_latest_available() {
  # Cache the result to avoid slow network calls
  local cache_file="${PYENV_ROOT:=$HOME/.pyenv}/.latest_available_cache"
  local cache_age="${PYENV_CACHE_AGE:-86400}"  # Default 24 hours, configurable via PYENV_CACHE_AGE env var
  
  # Check if cache exists and is recent
  if [[ -f "$cache_file" ]]; then
    local cache_time=$(stat -f "%m" "$cache_file" 2>/dev/null || stat -c "%Y" "$cache_file" 2>/dev/null || echo "0")
    local current_time=$(date +%s)
    local age=$((current_time - cache_time))
    
    if [[ $age -lt $cache_age ]]; then
      cat "$cache_file" 2>/dev/null && return 0
    fi
  fi
  
  # Fetch latest available (slow operation)
  local latest=$(pyenv install --list 2>/dev/null | sed 's/^[[:space:]]*//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
  
  # Cache the result
  [[ -n "$latest" ]] && echo "$latest" > "$cache_file" 2>/dev/null || true
  
  echo "$latest"
}

_pyenv_latest_installed() {
  local PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
  pyenv versions --bare 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1
}

_pyenv_activate_latest() {
  local PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
  local HOMEBREW_PREFIX="$(_detect_brew_prefix)"
  
  command -v pyenv >/dev/null 2>&1 || return 1
  local target="${1:-$(_pyenv_latest_available)}"
  [[ -n "$target" ]] || return 1
  
  # Check if version is already installed (multiple methods for robustness)
  local is_installed=false
  
  # Method 1: Check via pyenv versions command
  if pyenv versions --bare 2>/dev/null | grep -qE "^[[:space:]]*${target}[[:space:]]*$"; then
    is_installed=true
  fi
  
  # Method 2: Check if version directory exists (more reliable)
  if [[ -d "$PYENV_ROOT/versions/$target" ]]; then
    is_installed=true
  fi
  
  if [[ "$is_installed" == false ]]; then
    # Try to install via Homebrew first (much faster - uses pre-built binaries)
    local major_version=$(echo "$target" | cut -d. -f1)
    local minor_version=$(echo "$target" | cut -d. -f2)
    local brew_python_formula=""
    local brew_installed=false
    
    # Check if Homebrew is available
    if [[ -n "$HOMEBREW_PREFIX" ]] && command -v brew >/dev/null 2>&1; then
      # Try different Homebrew Python formula names (most specific first)
      for formula in "python@${major_version}.${minor_version}" "python@${major_version}" "python"; do
        # Check if formula exists and is installable
        if brew info "$formula" >/dev/null 2>&1 && ! brew info "$formula" 2>/dev/null | grep -q "Not installed"; then
          brew_python_formula="$formula"
          # Check if it's already installed
          if brew list "$formula" >/dev/null 2>&1; then
            brew_installed=true
          fi
          break
        elif brew list "$formula" >/dev/null 2>&1; then
          # Formula is installed even if info check failed
          brew_python_formula="$formula"
          brew_installed=true
          break
        fi
      done
      
      if [[ -n "$brew_python_formula" ]]; then
        if [[ "$brew_installed" == false ]]; then
          echo "  Installing Python $target via Homebrew (fast - pre-built binaries)..." >&2
          if brew install "$brew_python_formula" 2>/dev/null; then
            brew_installed=true
          else
            echo "  ${RED}WARNING:${NC} Homebrew installation failed, will try pyenv install instead" >&2
            brew_installed=false
          fi
        else
          echo "  Found existing Homebrew Python installation: $brew_python_formula" >&2
        fi
        
        if [[ "$brew_installed" == true ]] || brew list "$brew_python_formula" >/dev/null 2>&1; then
          # Link Homebrew Python to pyenv (with safety checks)
          local brew_python_path=""
          
          # Try multiple paths to find Homebrew Python
          if [[ -d "$HOMEBREW_PREFIX/opt/$brew_python_formula/bin" ]]; then
            brew_python_path="$HOMEBREW_PREFIX/opt/$brew_python_formula"
          elif [[ -L "$HOMEBREW_PREFIX/opt/$brew_python_formula" ]]; then
            # Follow symlink if opt is a symlink (macOS readlink doesn't support -f, use cd -P instead)
            brew_python_path=$(cd -P "$HOMEBREW_PREFIX/opt/$brew_python_formula" 2>/dev/null && pwd || echo "")
            [[ -z "$brew_python_path" ]] && brew_python_path="$HOMEBREW_PREFIX/opt/$brew_python_formula"
          elif [[ -d "$HOMEBREW_PREFIX/Cellar/$brew_python_formula" ]]; then
            # Find the latest version in Cellar
            brew_python_path=$(ls -td "$HOMEBREW_PREFIX/Cellar/$brew_python_formula"/*/bin 2>/dev/null | head -1 | sed 's|/bin$||')
          fi
          
          # Verify python3 exists 
          if [[ -n "$brew_python_path" && -e "$brew_python_path/bin/python3" ]]; then
            # Verify the version matches 
            local brew_version=$("$brew_python_path/bin/python3" --version 2>/dev/null | cut -d' ' -f2 || echo "")
            if [[ -n "$brew_version" ]]; then
              # Extract major.minor from both versions for comparison
              local target_major_minor="${target%.*}"
              local brew_major_minor="${brew_version%.*}"
              
              # Accept if major.minor matches (e.g., 3.14.x matches 3.14.2)
              if [[ "$brew_major_minor" == "$target_major_minor" ]]; then
                local symlink_path="$PYENV_ROOT/versions/$target"
                if [[ -L "$symlink_path" ]]; then
                  # Check if symlink is broken
                  if [[ ! -e "$symlink_path" ]]; then
                    echo "  ${RED}WARNING:${NC} Broken symlink detected, removing..." >&2
                    rm -f "$symlink_path" 2>/dev/null || true
                  elif [[ "$(readlink "$symlink_path")" != "$brew_python_path" ]]; then
                    # Symlink points to wrong location, update it
                    echo "  Updating symlink to point to current Homebrew Python ($brew_version)..." >&2
                    rm -f "$symlink_path" 2>/dev/null || true
                    mkdir -p "$PYENV_ROOT/versions" 2>/dev/null || true
                    ln -sf "$brew_python_path" "$symlink_path" 2>/dev/null || true
                  else
                    # Symlink is valid and points to correct location
                    is_installed=true
                  fi
                else
                  # Create new symlink
                  echo "  Linking Homebrew Python $brew_version as pyenv $target..." >&2
                  mkdir -p "$PYENV_ROOT/versions" 2>/dev/null || true
                  ln -sf "$brew_python_path" "$symlink_path" 2>/dev/null || true
                fi
                
                if [[ "$is_installed" == false ]]; then
                  # Verify symlink was created successfully
                  if [[ -L "$symlink_path" && -e "$symlink_path" ]]; then
                    pyenv rehash 2>/dev/null || true
                    is_installed=true
                    echo "  SUCCESS: Using Homebrew Python $brew_version (close match to $target)" >&2
                  fi
                else
                  pyenv rehash 2>/dev/null || true
                fi
              else
                echo "  ${BLUE}INFO:${NC} Homebrew Python version $brew_version doesn't match $target (need $target_major_minor.x)" >&2
              fi
            fi
          fi
        fi
      fi
    fi
    
    # If Homebrew installation didn't work, fall back to pyenv install (slower - compiles from source)
    if [[ "$is_installed" == false ]]; then
      echo "  Installing Python $target via pyenv (this may take several minutes - compiling from source)..." >&2
      pyenv install "$target" || return 1
      pyenv rehash 2>/dev/null || true
    fi
  fi
  
  # Activate the version
  pyenv global "$target" || return 1
  pyenv rehash >/dev/null 2>&1 || true
  
  # Ensure 'python' symlink exists in pyenv version (needed for pipx and other tools)
  local pyenv_bin_dir="$PYENV_ROOT/versions/$target/bin"
  if [[ -d "$pyenv_bin_dir" ]]; then
    # If python doesn't exist but python3 does, create a symlink
    if [[ ! -f "$pyenv_bin_dir/python" ]] && [[ -f "$pyenv_bin_dir/python3" ]]; then
      # For symlinked Homebrew Python, we need to create python symlink pointing to python3
      if [[ -L "$pyenv_bin_dir" ]] || [[ -L "$PYENV_ROOT/versions/$target" ]]; then
        # Follow symlink to find actual bin directory
        local actual_bin_dir=$(cd -P "$pyenv_bin_dir" 2>/dev/null && pwd)
        if [[ -n "$actual_bin_dir" && -f "$actual_bin_dir/python3" && ! -f "$actual_bin_dir/python" ]]; then
          ln -sf python3 "$actual_bin_dir/python" 2>/dev/null || true
        fi
      else
        # Regular pyenv installation
        ln -sf python3 "$pyenv_bin_dir/python" 2>/dev/null || true
      fi
    fi
  fi
  
  printf "%s" "$target"
}

# ================================ CHRUBY HELPERS =============================

_chruby_latest_available() {
  # Cache the result to avoid slow network calls
  local rubies_root="${RUBIES_ROOT:-$HOME/.rubies}"
  local cache_file="$rubies_root/.latest_available_cache"
  local cache_age="${RUBY_CACHE_AGE:-86400}"  # Default 24 hours, configurable via RUBY_CACHE_AGE env var
  
  # Check if cache exists and is recent
  if [[ -f "$cache_file" ]]; then
    local cache_time=$(stat -f "%m" "$cache_file" 2>/dev/null || stat -c "%Y" "$cache_file" 2>/dev/null || echo "0")
    local current_time=$(date +%s)
    local age=$((current_time - cache_time))
    
    if [[ $age -lt $cache_age ]]; then
      cat "$cache_file" 2>/dev/null && return 0
    fi
  fi
  
  # Fetch latest available (slow operation)
  local latest=""
  if command -v ruby-install >/dev/null 2>&1; then
    latest="$(ruby-install --list ruby 2>/dev/null | awk '/^ruby [0-9]+\.[0-9]+\.[0-9]+$/ {print $2}' | sort -V | tail -n1)"
  fi
  
  # Cache the result
  [[ -n "$latest" ]] && echo "$latest" > "$cache_file" 2>/dev/null || true
  
  echo "$latest"
}

_chruby_latest_installed() {
  # chruby is a shell function, check with type
  type chruby >/dev/null 2>&1 || return 1
  chruby 2>/dev/null | sed -E 's/^[* ]+//' | grep -E '^ruby-[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1
}

_chruby_install_latest() {
  # chruby is a shell function, check with type
  type chruby >/dev/null 2>&1 || return 1
  command -v ruby-install >/dev/null 2>&1 || return 1
  local latest
  latest="$(_chruby_latest_available)"
  [[ -n "$latest" ]] || return 1
  if ! chruby 2>/dev/null | sed -E 's/^[* ]+//' | grep -qx "ruby-$latest"; then
    ruby-install ruby "$latest" || return 1
  fi
  # Activate the installed version
  chruby "ruby-$latest" 2>/dev/null || true
  echo "ruby-$latest"
}

# ================================ GO HELPERS ==================================

_go_update_toolchain() {
  command -v go >/dev/null 2>&1 || return 1
  
  echo "${GREEN}[Go]${NC} Updating Go toolchain and packages..."
  
  # Get current version
  local current_version=$(go version | awk '{print $3}' | sed 's/go//')
  echo "  Current: Go $current_version"
  
  local go_errors=()

  # Note: go clean -modcache removed - it deletes the entire module download cache
  # which forces all Go projects to re-download dependencies. Too aggressive for routine updates.
  
  # Update Go itself - Homebrew only (no auto-install via go tool)
  local brew_go=false
  local go_updated=false
  local go_update_available=false
  if command -v brew >/dev/null 2>&1 && brew list go >/dev/null 2>&1; then
    brew_go=true
    echo "  Updating Go via Homebrew..."
    local old_version="$current_version"
    if brew upgrade go 2>/dev/null; then
      local new_version=$(go version | awk '{print $3}' | sed 's/go//')
      # Check if version actually changed
      if [[ "$new_version" != "$old_version" ]]; then
        go_updated=true
        # Get GOROOT from updated Go
        local new_goroot=$(go env GOROOT 2>/dev/null || echo "")
        if [[ -n "$new_goroot" && -d "$new_goroot" ]]; then
          # Make it permanent
          _setup_go_permanent "$new_goroot"
        fi
        current_version="$new_version"
        echo "  SUCCESS: Updated to Go $new_version (permanent configuration added to .zprofile)"
      else
        echo "  ${BLUE}INFO:${NC} Go is already up to date ($current_version)"
      fi
    else
      go_errors+=("homebrew_upgrade")
      echo "  ${RED}WARNING:${NC} Homebrew upgrade failed"
    fi
  else
    echo "  ${BLUE}INFO:${NC} Go is not installed via Homebrew"
  fi

  # Check latest Go release (info only)
  echo "  Checking latest Go release..."
  local latest_version=""
  if command -v curl >/dev/null 2>&1; then
    local json_response=""
    json_response="$(curl -s --connect-timeout 15 --max-time 30 --retry 3 'https://go.dev/dl/?mode=json' 2>/dev/null || echo "")"
    if [[ -n "$json_response" && "$json_response" != "FAILED" ]]; then
      # Parse JSON to find latest stable version
      # The JSON format is: [{"version":"go1.24.5","stable":true,...},...]
      # Use jq if available (most reliable), otherwise use python3, then grep as last resort
      if command -v jq >/dev/null 2>&1; then
        latest_version="$(echo "$json_response" | jq -r '.[] | select(.stable == true) | .version' 2>/dev/null | head -1 | sed 's/go//' || echo "")"
      elif command -v python3 >/dev/null 2>&1; then
        latest_version="$(echo "$json_response" | python3 -c "import sys, json; data = json.load(sys.stdin); stable = [x for x in data if x.get('stable')]; print(stable[0]['version'].replace('go', '') if stable else '')" 2>/dev/null || echo "")"
      else
        # Fallback: grep for first stable version (less reliable but works without dependencies)
        latest_version="$(echo "$json_response" | grep -oE '"version":"go[0-9]+\.[0-9]+(\.[0-9]+)?".*"stable":true' | head -1 | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/go//' || echo "")"
      fi
      
      if [[ -n "$latest_version" && "$latest_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        if [[ "$latest_version" != "$current_version" ]]; then
          go_update_available=true
          echo "  ${BLUE}INFO:${NC} Latest Go release: $latest_version (current: $current_version)"
        else
          echo "  ${BLUE}INFO:${NC} Go is up to date ($current_version)"
        fi
      else
        echo "  ${BLUE}INFO:${NC} Could not determine latest Go version from go.dev (parsing failed)"
      fi
    else
      echo "  ${BLUE}INFO:${NC} Could not check for updates (network issue or invalid response)"
    fi
  else
    echo "  ${BLUE}INFO:${NC} curl not available; skipping go.dev version check"
  fi

  if [[ "$brew_go" == "true" ]]; then
    if [[ "$go_updated" == "true" ]]; then
      if [[ "$go_update_available" == "true" && -n "$latest_version" && "$latest_version" != "$current_version" ]]; then
        echo "  ${BLUE}INFO:${NC} Homebrew updated Go to $current_version; upstream $latest_version is available (manual install or wait for Homebrew)"
      else
        echo "  ${BLUE}INFO:${NC} Homebrew manages Go and will handle updates automatically"
      fi
    else
      if [[ "$go_update_available" == "true" && -n "$latest_version" ]]; then
        echo "  ${BLUE}INFO:${NC} New Go release available upstream: $latest_version (Homebrew currently provides $current_version)"
        echo "  ${BLUE}INFO:${NC} Options: wait for Homebrew to update, or install manually: https://go.dev/dl/"
      else
        echo "  ${BLUE}INFO:${NC} Go is up to date via Homebrew ($current_version)"
      fi
    fi
  else
    if [[ -n "$latest_version" && "$latest_version" != "$current_version" ]]; then
      go_update_available=true
      echo "  ${BLUE}INFO:${NC} Update available: $latest_version (current: $current_version)"
    fi
    echo "  ${BLUE}INFO:${NC} Recommended: Install Go via Homebrew for automatic updates: brew install go"
    echo "  ${BLUE}INFO:${NC} Manual download: https://go.dev/dl/"
  fi
  
  # Go modules are project-specific and should be updated in project directories
  echo "  Updating Go modules and dependencies..."
  echo "    ${BLUE}INFO:${NC} Go modules are project-specific - run 'update' in your Go project directories"
  
  # Update all globally installed Go tools
  echo "  Checking for globally installed Go tools..."
  
  # Find Go binary directories
  local go_bin_dirs=()
  local gobin=$(go env GOBIN 2>/dev/null || echo "")
  local gopath=$(go env GOPATH 2>/dev/null || echo "")
  local home_go_bin="$HOME/go/bin"
  
  # Collect all possible Go binary directories
  [[ -n "$gobin" && -d "$gobin" ]] && go_bin_dirs+=("$gobin")
  [[ -n "$gopath" && -d "$gopath/bin" ]] && go_bin_dirs+=("$gopath/bin")
  [[ -d "$home_go_bin" ]] && go_bin_dirs+=("$home_go_bin")
  
  if [[ ${#go_bin_dirs[@]} -eq 0 ]]; then
    echo "    ${BLUE}INFO:${NC} No Go binary directories found"
  else
    local tools_found=0
    local tools_updated=0
    local tools_failed=0
    local tools_skipped=0
    
    # Find all binaries in Go bin directories
    for bin_dir in "${go_bin_dirs[@]}"; do
      if [[ -d "$bin_dir" ]]; then
        while IFS= read -r binary; do
          [[ -z "$binary" ]] && continue
          [[ ! -f "$binary" ]] && continue
          [[ ! -x "$binary" ]] && continue
          
          local tool_name=$(basename "$binary")
          
          # Skip if it's the go binary itself
          [[ "$tool_name" == "go" ]] && continue
          
          # Try to get module path from binary using go version -m
          local module_path=""
          local module_info=$(go version -m "$binary" 2>/dev/null | grep -E "^[[:space:]]*mod[[:space:]]+" | head -1 || echo "")
          
          if [[ -n "$module_info" ]]; then
            # Extract module path (format: "mod    path/to/module    version")
            module_path=$(echo "$module_info" | awk '{print $2}')
          fi
          
          # If we couldn't get module path, skip this tool
          if [[ -z "$module_path" ]]; then
            ((tools_skipped++))
            continue
          fi
          
          # Skip standard library modules
          if [[ "$module_path" == std* ]] || [[ "$module_path" == cmd/* ]] || [[ "$module_path" == "main" ]]; then
            ((tools_skipped++))
            continue
          fi
          
          ((tools_found++))
          echo "    Checking $tool_name ($module_path)..."
          
          # Try to update the tool by trying different common paths
          local updated=false
          
          # Try 1: Direct module path (if it's already a command path)
          if go install "${module_path}@latest" 2>/dev/null; then
            updated=true
          else
            # Try 2: Module path + /cmd/toolname
            if go install "${module_path}/cmd/${tool_name}@latest" 2>/dev/null; then
              updated=true
            else
              # Try 3: Module path + /toolname
              if go install "${module_path}/${tool_name}@latest" 2>/dev/null; then
                updated=true
              fi
            fi
          fi
          
          if [[ "$updated" == true ]]; then
            ((tools_updated++))
            echo "      SUCCESS: Updated $tool_name"
          else
            ((tools_failed++))
            echo "      ${RED}WARNING:${NC} Could not determine install path for $tool_name"
          fi
        done < <(find "$bin_dir" -maxdepth 1 -type f -perm +111 2>/dev/null)
      fi
    done
    
    if [[ $tools_found -eq 0 ]]; then
      echo "    ${BLUE}INFO:${NC} No Go tools found in Go binary directories"
    else
      echo "    Found $tools_found Go tools, updated $tools_updated, failed $tools_failed, skipped $tools_skipped"
    fi
  fi
  
  # Report summary
  local go_summary_parts=()
  if [[ "$go_updated" == "true" ]]; then
    go_summary_parts+=("Go toolchain updated")
  fi
  if [[ -n "${tools_updated:-}" ]] && [[ $tools_updated -gt 0 ]]; then
    go_summary_parts+=("$tools_updated Go tool(s) updated")
  fi
  if [[ ${#go_summary_parts[@]} -gt 0 ]]; then
    echo "  SUCCESS: ${go_summary_parts[*]}"
  elif [[ "$go_update_available" == "true" ]]; then
    echo "  ${BLUE}INFO:${NC} Go update available (manual install required)"
  elif [[ -n "${tools_found:-}" ]] && [[ $tools_found -gt 0 ]] && [[ -n "${tools_updated:-}" ]] && [[ $tools_updated -eq 0 ]]; then
    echo "  ${BLUE}INFO:${NC} Go toolchain and tools are up to date"
  else
    echo "  ${BLUE}INFO:${NC} Go toolchain checked (no updates needed)"
  fi
  
  if [[ ${#go_errors[@]} -gt 0 ]]; then
    echo "  Go issues: ${go_errors[*]}"
    return 1
  else
    return 0
  fi
}

_cargo_update_packages() {
  command -v cargo >/dev/null 2>&1 || return 1
  
  echo "${GREEN}[Cargo]${NC} Upgrading globally installed packages..."
  
  # Get list of installed packages
  local installed_packages=$(cargo install --list 2>/dev/null | grep -E '^[a-z]' | awk '{print $1}')
  
  if [[ -z "$installed_packages" ]]; then
    echo "  ${BLUE}INFO:${NC} No globally installed cargo packages found"
    return 0
  fi
  
  local total=$(echo "$installed_packages" | wc -l)
  local updated=0
  local failed=0
  
  echo "  Found $total globally installed packages"
  
  # Update each package
  while IFS= read -r package; do
    [[ -z "$package" ]] && continue
    echo "  Upgrading $package..."
    if cargo install "$package" 2>/dev/null >/dev/null; then
      ((updated++))
    else
      ((failed++))
      echo "    ${RED}WARNING:${NC} Failed to upgrade $package"
    fi
  done <<< "$installed_packages"
  
  if [[ $failed -eq 0 ]]; then
    echo "  SUCCESS: Updated $updated packages"
    return 0
  else
    echo "  PARTIAL: Updated $updated packages, $failed failed"
    return 1
  fi
}

# ================================ UPDATE ===================================

update() {
  _ensure_system_path
  echo "${GREEN}==> Update started $(date)${NC}"
  if [[ -f "$DATA_DIR/version" ]]; then
    echo "  Version: ${BLUE}$(<"$DATA_DIR/version")${NC}"
  fi

  # Check if we're in a project directory and warn user
  if _is_project_directory; then
    echo "  ${BLUE}INFO:${NC} Project directory detected - project files will NOT be modified"
    echo "  ${BLUE}INFO:${NC} Only global/system packages will be updated"
    echo "  ${BLUE}INFO:${NC} To update project dependencies, run package manager commands manually in this directory"
  fi
  
  # Check macOS compatibility
  if ! _check_macos_compatibility; then
    echo "ERROR: This script requires macOS"
    return 1
  fi

  # Check for Homebrew - skip if missing (install via install.sh)
  if ! command -v brew >/dev/null 2>&1; then
    echo "${GREEN}[Homebrew]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install Homebrew, run: 'sys-install'"
  fi
  
  if command -v brew >/dev/null 2>&1; then
    echo "${GREEN}[Homebrew]${NC} update/upgrade/cleanup..."
    local brew_errors=()
    
    local brew_update_output=""
    local brew_update_exit_code=0
    brew_update_output="$(brew update 2>&1)" || brew_update_exit_code=$?

    if [[ $brew_update_exit_code -eq 0 ]]; then
      # Check if output indicates an actual update occurred
      # brew update shows "Updated X tap(s)" or "==> Updated Formulae" when something changed
      # "Already up-to-date." means no update occurred
      if echo "$brew_update_output" | grep -qiE "(Already up-to-date|Already updated|No changes)"; then
        echo "  ${BLUE}INFO:${NC} Homebrew is already up to date"
      elif echo "$brew_update_output" | grep -qiE "(Updated [0-9]+ tap|==> Updated Formulae|==> Updating)"; then
        echo "  Homebrew updated successfully"
      else
        # Default to "already up to date" if output is minimal (indicates no changes)
        echo "  ${BLUE}INFO:${NC} Homebrew is already up to date"
      fi
      # Always show what Homebrew reported so users can see tap changes
      echo "$brew_update_output" | sed 's/^/    /'
      
      # Show what is queued for upgrade (formulae and casks)
      local brew_outdated_formula brew_outdated_cask
      brew_outdated_formula="$(brew outdated --verbose 2>/dev/null || true)"
      brew_outdated_cask="$(brew outdated --cask --greedy --verbose 2>/dev/null || true)"
      local brew_outdated_formula_count=0
      local brew_outdated_cask_count=0
      [[ -n "$brew_outdated_formula" ]] && brew_outdated_formula_count=$(echo "$brew_outdated_formula" | grep -E '^[[:alnum:]]' | wc -l | tr -d ' ' || echo 0)
      [[ -n "$brew_outdated_cask" ]] && brew_outdated_cask_count=$(echo "$brew_outdated_cask" | grep -E '^[[:alnum:]]' | wc -l | tr -d ' ' || echo 0)
      local brew_outdated_total=$((brew_outdated_formula_count + brew_outdated_cask_count))
      if [[ -n "$brew_outdated_formula" || -n "$brew_outdated_cask" ]]; then
        echo "  Pending Homebrew updates:"
        if [[ -n "$brew_outdated_formula" ]]; then
          echo "    Formulae:"
          echo "$brew_outdated_formula" | sed 's/^/      /'
        fi
        if [[ -n "$brew_outdated_cask" ]]; then
          echo "    Casks:"
          echo "$brew_outdated_cask" | sed 's/^/      /'
        fi
      else
        echo "  ${BLUE}INFO:${NC} No pending Homebrew updates before upgrade"
      fi
    else
      brew_errors+=("update")
      echo "  ${RED}WARNING:${NC} Homebrew update failed"
      # Initialize variables that would have been set in the success path
      local brew_outdated_formula="" brew_outdated_cask=""
      local brew_outdated_formula_count=0 brew_outdated_cask_count=0
      local brew_outdated_total=0
    fi

    local brew_formula_upgraded=false
    local brew_cask_upgraded=false
    local brew_upgrade_formula_output=""
    local brew_upgrade_formula_exit_code=0

    if [[ "$brew_outdated_total" -gt 0 ]]; then
      echo "  Installing $brew_outdated_total package update(s), this may take a while..."
    fi

    brew_upgrade_formula_output="$(brew upgrade 2>&1)" || brew_upgrade_formula_exit_code=$?

    if [[ $brew_upgrade_formula_exit_code -eq 0 ]]; then
      # Check if output indicates packages were actually upgraded
      if echo "$brew_upgrade_formula_output" | grep -qiE "(Already up-to-date|Nothing to upgrade|All formulae are up to date|No outdated packages|0 outdated packages)"; then
        echo "  ${BLUE}INFO:${NC} Homebrew formulae are already up to date"
      else
        # Extract what was upgraded (handles both "==> Upgrading foo" and "==> Upgrading 1 outdated package: foo")
        local upgraded_list=""
        upgraded_list="$(echo "$brew_upgrade_formula_output" | grep -E '^==> Upgrading' | sed -E 's/^==> Upgrading ([0-9]+ outdated packages?: )?//' || true)"
        if [[ -n "$upgraded_list" ]]; then
          brew_formula_upgraded=true
          local upgraded_count
          upgraded_count="$(echo "$upgraded_list" | wc -l | tr -d ' ')"
          echo "  Upgraded $upgraded_count formula(e): $(echo "$upgraded_list" | tr '\n' ', ' | sed 's/, $//')"
        else
          echo "  ${BLUE}INFO:${NC} Homebrew formulae checked (no changes detected)"
        fi
      fi
    else
      brew_errors+=("upgrade_formula")
      echo "  ${RED}WARNING:${NC} Homebrew formula upgrade failed (exit code: $brew_upgrade_formula_exit_code)"
    fi

    # Upgrade casks greedily so GUI apps are updated automatically
    local brew_upgrade_cask_output=""
    local brew_upgrade_cask_exit_code=0

    brew_upgrade_cask_output="$(brew upgrade --cask --greedy 2>&1)" || brew_upgrade_cask_exit_code=$?

    if [[ $brew_upgrade_cask_exit_code -eq 0 ]]; then
      if echo "$brew_upgrade_cask_output" | grep -qiE "(Already up-to-date|Nothing to upgrade|All casks are up to date|No outdated casks|0 outdated casks)"; then
        echo "  ${BLUE}INFO:${NC} Homebrew casks are already up to date"
      else
        # Extract what was upgraded (handles both "==> Upgrading foo" and "==> Upgrading 1 outdated package: foo")
        local upgraded_cask_list=""
        upgraded_cask_list="$(echo "$brew_upgrade_cask_output" | grep -E '^==> Upgrading' | sed -E 's/^==> Upgrading ([0-9]+ outdated packages?: )?//' || true)"
        if [[ -n "$upgraded_cask_list" ]]; then
          brew_cask_upgraded=true
          local upgraded_cask_count
          upgraded_cask_count="$(echo "$upgraded_cask_list" | wc -l | tr -d ' ')"
          echo "  Upgraded $upgraded_cask_count cask(s): $(echo "$upgraded_cask_list" | tr '\n' ', ' | sed 's/, $//')"
        else
          echo "  ${BLUE}INFO:${NC} Homebrew casks checked (no changes detected)"
        fi
      fi
    else
      brew_errors+=("upgrade_cask")
      echo "  ${RED}WARNING:${NC} Homebrew cask upgrade failed (exit code: $brew_upgrade_cask_exit_code)"
    fi

    # If we started with pending items, re-check to confirm everything is updated
    if [[ "${brew_outdated_total:-0}" -gt 0 ]]; then
      local brew_outdated_formula_after brew_outdated_cask_after
      brew_outdated_formula_after="$(brew outdated --verbose 2>/dev/null || true)"
      brew_outdated_cask_after="$(brew outdated --cask --greedy --verbose 2>/dev/null || true)"
      local brew_outdated_after_count=0
      [[ -n "$brew_outdated_formula_after" ]] && brew_outdated_after_count=$((brew_outdated_after_count + $(echo "$brew_outdated_formula_after" | grep -E '^[[:alnum:]]' | wc -l | tr -d ' ' || echo 0)))
      [[ -n "$brew_outdated_cask_after" ]] && brew_outdated_after_count=$((brew_outdated_after_count + $(echo "$brew_outdated_cask_after" | grep -E '^[[:alnum:]]' | wc -l | tr -d ' ' || echo 0)))
      if [[ $brew_outdated_after_count -gt 0 ]]; then
        echo "  ${BLUE}INFO:${NC} Some Homebrew items remain pending after upgrade (check pinned/held packages):"
        if [[ -n "$brew_outdated_formula_after" ]]; then
          echo "    Formulae:"
          echo "$brew_outdated_formula_after" | sed 's/^/      /'
        fi
        if [[ -n "$brew_outdated_cask_after" ]]; then
          echo "    Casks:"
          echo "$brew_outdated_cask_after" | sed 's/^/      /'
        fi
      elif [[ "$brew_formula_upgraded" == true || "$brew_cask_upgraded" == true ]]; then
        echo "  Homebrew packages upgraded successfully"
      fi
    elif [[ "$brew_formula_upgraded" == true || "$brew_cask_upgraded" == true ]]; then
      echo "  Homebrew packages upgraded successfully"
    fi
    
    brew cleanup 2>/dev/null || brew_errors+=("cleanup")
    brew cleanup -s 2>/dev/null || true
    
    if brew doctor 2>/dev/null; then
      echo "  Homebrew doctor check passed"
    else
      if [[ -n "${CI:-}" ]]; then
        echo "  ${BLUE}INFO:${NC} brew doctor reported issues (CI mode)"
      else
        brew_errors+=("doctor")
        echo "  ${RED}WARNING:${NC} brew doctor reported issues"
      fi
    fi
    
    # Report summary of Homebrew issues
    if [[ ${#brew_errors[@]} -gt 0 ]]; then
      echo "  Homebrew issues: ${brew_errors[*]}"
      echo "  Consider running: brew doctor for detailed diagnostics"
    fi
  fi

  # Check for MacPorts - skip if missing (install via install.sh)
  if ! command -v port >/dev/null 2>&1; then
    echo "${GREEN}[MacPorts]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install MacPorts, run: 'sys-install'"
  fi
  
  if command -v port >/dev/null 2>&1; then
    # Skip MacPorts in CI/CD environments (requires sudo)
    if [[ -n "${CI:-}" ]] || [[ -n "${NONINTERACTIVE:-}" ]]; then
      echo "${GREEN}[MacPorts]${NC} Skipped in CI/non-interactive mode (requires sudo)"
      # Continue with rest of update function, just skip MacPorts block
    else
      echo "${GREEN}[MacPorts]${NC} sudo required; you may be prompted..."
      local port_errors=()
    
    local port_output=""
    local port_exit_code=0
    port_output="$(sudo port -v selfupdate 2>&1)" || port_exit_code=$?

    if [[ $port_exit_code -eq 0 ]]; then
      # Check if output indicates an actual update occurred
      # MacPorts shows "Adding port" when new ports are added
      # "Ports successfully parsed: X" where X > 0 means new ports were added
      # "Up-to-date ports skipped" means no new ports
      # Note: "Ports successfully parsed: 1" can be just re-parsing, not a real update
      if echo "$port_output" | grep -qiE "Adding port"; then
        echo "  MacPorts updated successfully"
      elif echo "$port_output" | grep -qiE "(Ports successfully parsed:[[:space:]]+[2-9]|Ports successfully parsed:[[:space:]]+[0-9]{2,})"; then
        # Only consider it an update if 2+ ports were parsed (1 is often just re-parsing)
        # Grouped alternation to avoid false matches
        echo "  MacPorts updated successfully"
      elif echo "$port_output" | grep -qiE "(already|up to date|latest version|Up-to-date ports skipped|Ports successfully parsed:[[:space:]]+0|Ports successfully parsed:[[:space:]]+1)"; then
        echo "  ${BLUE}INFO:${NC} MacPorts is already up to date"
      else
        # Default to "already up to date" if we can't determine
        echo "  ${BLUE}INFO:${NC} MacPorts is already up to date"
      fi
    else
      port_errors+=("selfupdate")
      echo "  ${RED}WARNING:${NC} MacPorts selfupdate failed (exit code: $port_exit_code)"
    fi

    local port_upgrade_output=""
    local port_upgrade_exit_code=0
    port_upgrade_output="$(sudo port -N upgrade outdated 2>&1)" || port_upgrade_exit_code=$?

    if [[ $port_upgrade_exit_code -eq 0 ]]; then
      # Check if output indicates packages were actually upgraded
      # "Nothing to upgrade" means no packages were upgraded
      if echo "$port_upgrade_output" | grep -qiE "(Nothing to upgrade|All ports are up to date|No packages to upgrade)"; then
        echo "  ${BLUE}INFO:${NC} MacPorts packages are already up to date"
      elif echo "$port_upgrade_output" | grep -qiE "(Upgrading|Installing|Building|Activating)"; then
        echo "  MacPorts packages upgraded successfully"
      else
        echo "  ${BLUE}INFO:${NC} MacPorts packages are already up to date"
      fi
    else
      port_errors+=("upgrade")
      echo "  ${RED}WARNING:${NC} Some MacPorts packages failed to upgrade (exit code: $port_upgrade_exit_code)"
    fi
    
    sudo port reclaim -f --disable-reminders 2>/dev/null || port_errors+=("reclaim")
    (cd /tmp && sudo port clean --all installed) 2>/dev/null || port_errors+=("clean")
    
    # Report summary of MacPorts issues
    if [[ ${#port_errors[@]} -gt 0 ]]; then
      echo "  MacPorts issues: ${port_errors[*]}"
    fi
    fi  # End of else block for non-CI MacPorts update
  fi

  local pybin=""
  local pyenv_target=""
  local current_python=""
  local PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
  
  # Get current Python version before upgrade
  if command -v pyenv >/dev/null 2>&1; then
    current_python="$(pyenv version-name 2>/dev/null || true)"
  else
    current_python="$(python3 -V 2>/dev/null | cut -d' ' -f2 || python -V 2>/dev/null | cut -d' ' -f2 || true)"
  fi
  
  if command -v pyenv >/dev/null 2>&1; then
    # First check installed versions (fast) before checking available (slow)
    local latest_installed="$(_pyenv_latest_installed)"
    local latest_available=""
    
    # Normalize current_python (handle empty or "system")
    [[ -z "$current_python" || "$current_python" == "system" ]] && current_python=""
    
    # If we have a latest installed version, use it as baseline
    if [[ -n "$latest_installed" ]]; then
      # Check if we need to activate the latest installed version
      if [[ -z "$current_python" || "$current_python" != "$latest_installed" ]]; then
        echo "${GREEN}[pyenv]${NC} Current: ${current_python:-system}, Latest installed: $latest_installed"
        # Activate latest installed immediately (fast)
        if pyenv_target="$(_pyenv_activate_latest "$latest_installed" 2>/dev/null)"; then
          echo "${GREEN}[pyenv]${NC} Activated: $pyenv_target"
          pybin="$(pyenv which python 2>/dev/null || true)"
          current_python="$pyenv_target"
        fi
      fi
      
      # Now check if there's a newer version available (may be slow, but cached)
      # Only check cache first to avoid unnecessary network calls
      local cache_file="$PYENV_ROOT/.latest_available_cache"
      if [[ -f "$cache_file" ]]; then
        local cached_latest=$(cat "$cache_file" 2>/dev/null)
        # If cache shows a newer version than installed, fetch fresh to confirm
        if [[ -n "$cached_latest" && "$cached_latest" != "$latest_installed" ]]; then
          latest_available="$(_pyenv_latest_available)"
        else
          # Cache suggests we're up to date, use installed version
          latest_available="$latest_installed"
        fi
      else
        # No cache yet - check available versions (will create cache)
        latest_available="$(_pyenv_latest_available)"
      fi
    else
      # No installed versions - check what's available (may be slow, but cached)
      latest_available="$(_pyenv_latest_available)"
    fi
    
    if [[ -n "$latest_available" && "$current_python" != "$latest_available" ]]; then
      echo "${GREEN}[pyenv]${NC} Current: ${current_python:-system}, Latest available: $latest_available"
      
      # Check compatibility before upgrade
      if ! _check_python_upgrade_compatibility "$current_python" "$latest_available"; then
        echo ""
        echo "WARNING: Some packages may be broken by Python upgrade!"
        echo "   This may affect global pip packages and pipx packages."
        echo ""
        # Skip prompt in non-interactive mode
        local should_upgrade=false
        if [[ -n "${NONINTERACTIVE:-}" ]] || [[ -n "${CI:-}" ]]; then
          echo "  ${BLUE}INFO:${NC} Non-interactive mode: skipping Python upgrade (incompatible packages detected)"
          should_upgrade=false
        else
          echo -n "Do you want to continue with Python upgrade? (y/N): "
          local upgrade_reply=""
          IFS= read -r upgrade_reply || true
          if [[ "$upgrade_reply" =~ ^[Yy]$ ]]; then
            should_upgrade=true
          fi
        fi
        
        if [[ "$should_upgrade" == "true" ]]; then
          echo "${GREEN}[pyenv]${NC} Continuing with Python upgrade..."
          if pyenv_target="$(_pyenv_activate_latest "$latest_available")"; then
            echo "${GREEN}[pyenv]${NC} Using $pyenv_target"
            pybin="$(pyenv which python 2>/dev/null || true)"
          else
            echo "${GREEN}[pyenv]${NC} Could not activate latest Python (continuing)."
            pybin="$(pyenv which python 2>/dev/null || true)"
          fi
        else
          echo "${GREEN}[pyenv]${NC} Python upgrade cancelled by user"
          pyenv_target="$current_python"
          pybin="$(pyenv which python 2>/dev/null || true)"
        fi
      else
        echo "${GREEN}[pyenv]${NC} Activating latest Python..."
        if pyenv_target="$(_pyenv_activate_latest "$latest_available")"; then
          echo "${GREEN}[pyenv]${NC} Using $pyenv_target"
          pybin="$(pyenv which python 2>/dev/null || true)"
        else
          echo "${GREEN}[pyenv]${NC} Could not activate latest Python (continuing)."
          pybin="$(pyenv which python 2>/dev/null || true)"
        fi
      fi
    else
      echo "${GREEN}[pyenv]${NC} Already using latest Python: $current_python"
      pyenv_target="$current_python"
      pybin="$(pyenv which python 2>/dev/null || true)"
    fi
  fi
  [[ -z "$pybin" ]] && pybin="$(command -v python3 || command -v python || true)"
  if [[ -n "$pybin" ]]; then
    local python_errors=()
    local pyenv_version_dir=""
    local is_system_python=false
    local is_homebrew_python=false

    if _is_system_python "$pybin"; then
      is_system_python=true
    fi
    if _is_homebrew_python "$pybin"; then
      is_homebrew_python=true
    fi

    if [[ "$is_system_python" == true ]]; then
      echo "${GREEN}[Python]${NC} Detected system Python ($pybin) - skipping pip/setuptools/wheel upgrade"
      echo "  ${BLUE}INFO:${NC} System Python should not be modified - use pyenv or Homebrew Python for development"
      echo "  ${BLUE}INFO:${NC} To upgrade system Python packages, use: sudo pip3 install --upgrade <package> (not recommended)"
    else
      echo "${GREEN}[Python]${NC} Upgrading pip/setuptools/wheel and global packages..."
      if [[ "$is_homebrew_python" == true ]]; then
        echo "  ${BLUE}INFO:${NC} Homebrew Python detected - skipping pip/setuptools/wheel upgrades"
        echo "  ${BLUE}INFO:${NC} Homebrew manages pip/setuptools/wheel - use 'brew upgrade python@X' to update"
        echo "  ${BLUE}INFO:${NC} User-installed pip packages will still be upgraded below"
      else
        # Check if Python is a symlink to Homebrew (read-only, skip pip upgrades)
        if command -v pyenv >/dev/null 2>&1; then
          local current_pyenv_version=$(pyenv version-name 2>/dev/null || echo "")
          if [[ -n "$current_pyenv_version" && "$current_pyenv_version" != "system" ]]; then
            pyenv_version_dir="${PYENV_ROOT:-$HOME/.pyenv}/versions/$current_pyenv_version"
            if [[ -L "$pyenv_version_dir" ]]; then
              echo "  ${BLUE}INFO:${NC} Python is symlinked to Homebrew (read-only), skipping pip/setuptools/wheel upgrade"
              echo "  ${BLUE}INFO:${NC} Homebrew manages these packages - use 'brew upgrade python@X' to update"
            else
              # Regular pyenv installation - can upgrade pip
              if "$pybin" -m ensurepip --upgrade 2>/dev/null; then
                echo "  ensurepip upgraded successfully"
              else
                python_errors+=("ensurepip")
                echo "  ${RED}WARNING:${NC} ensurepip upgrade failed"
              fi
              
              if "$pybin" -m pip install --upgrade pip setuptools wheel 2>/dev/null; then
                echo "  pip/setuptools/wheel upgraded successfully"
              else
                python_errors+=("pip_upgrade")
                echo "  ${RED}WARNING:${NC} pip/setuptools/wheel upgrade failed"
              fi
            fi
          else
            # pyenv set to "system" - not system Python (already checked above), might be Homebrew or other
            if "$pybin" -m ensurepip --upgrade 2>/dev/null; then
              echo "  ensurepip upgraded successfully"
            else
              python_errors+=("ensurepip")
              echo "  ${RED}WARNING:${NC} ensurepip upgrade failed"
            fi
            
            if "$pybin" -m pip install --upgrade pip setuptools wheel 2>/dev/null; then
              echo "  pip/setuptools/wheel upgraded successfully"
            else
              python_errors+=("pip_upgrade")
              echo "  ${RED}WARNING:${NC} pip/setuptools/wheel upgrade failed"
            fi
          fi
        else
          # No pyenv - not system Python (already checked above), might be Homebrew or other
          if "$pybin" -m ensurepip --upgrade 2>/dev/null; then
            echo "  ensurepip upgraded successfully"
          else
            python_errors+=("ensurepip")
            echo "  ${RED}WARNING:${NC} ensurepip upgrade failed"
          fi
          
          if "$pybin" -m pip install --upgrade pip setuptools wheel 2>/dev/null; then
            echo "  pip/setuptools/wheel upgraded successfully"
          else
            python_errors+=("pip_upgrade")
            echo "  ${RED}WARNING:${NC} pip/setuptools/wheel upgrade failed"
          fi
        fi
      fi
    fi
    
    if command -v pipx >/dev/null 2>&1; then
      echo "${GREEN}[pipx]${NC} Upgrading all packages..."
      
      # Set the default Python for pipx if needed
      # For symlinked pyenv versions, we need to use the actual Python binary, not the symlink
      if [[ -n "$pybin" ]]; then
        local actual_python="$pybin"
        
        # If pybin is a symlink (pyenv shim), resolve it to the actual binary
        if [[ -L "$pybin" ]] || [[ "$pybin" == *"/.pyenv/shims/"* ]]; then
          # Get the actual Python path by following symlinks
          actual_python=$(cd -P "$(dirname "$pybin")" 2>/dev/null && pwd)/$(basename "$pybin")
          # If that didn't work, try using python3 directly
          if [[ ! -f "$actual_python" ]]; then
            actual_python=$(command -v python3 2>/dev/null || echo "$pybin")
          fi
        fi
        
        # For Homebrew Python symlinks, find the actual binary
        if [[ -L "$actual_python" ]]; then
          local resolved_python=$(cd -P "$(dirname "$actual_python")" 2>/dev/null && pwd)/$(basename "$actual_python")
          if [[ -f "$resolved_python" ]]; then
            actual_python="$resolved_python"
          fi
        fi
        
        # Ensure we have a valid Python binary (try python3.x versions dynamically, python3, or python)
        if [[ ! -f "$actual_python" ]]; then
          local python_dir=$(dirname "$actual_python")
          local found_python=""
          # First try python3 (most common)
          if [[ -f "$python_dir/python3" ]]; then
            found_python="$python_dir/python3"
          # Then try to find highest python3.x version dynamically
          else
            # Use globbing 
            local python_versions=()
            for f in "$python_dir"/python3.[0-9]*; do
              [[ -f "$f" && "$f" =~ python3\.[0-9]+$ ]] && python_versions+=("$f")
            done
            if [[ ${#python_versions[@]} -gt 0 ]]; then
              # Sort versions and get the highest
              IFS=$'\n' sorted=($(sort -V <<<"${python_versions[*]}"))
              found_python="${sorted[-1]}"
            fi
          fi
          # Fallback to python if nothing else found
          if [[ -z "$found_python" && -f "$python_dir/python" ]]; then
            found_python="$python_dir/python"
          fi
          if [[ -n "$found_python" && -f "$found_python" ]]; then
            actual_python="$found_python"
          fi
        fi
        
        export PIPX_DEFAULT_PYTHON="$actual_python"
        echo "  Using Python: $actual_python"
      fi
      
      # Try to upgrade all pipx packages
      local pipx_output
      pipx_output="$(pipx upgrade-all --verbose 2>&1)"
      local pipx_exit_code=$?
      
      if [[ $pipx_exit_code -eq 0 ]]; then
        # Check if output indicates packages were actually upgraded
        # pipx upgrade-all shows "No packages upgraded" when nothing changed
        # or shows package names when upgrading
        if echo "$pipx_output" | grep -qiE "(No packages upgraded|No packages to upgrade|already|up to date|nothing to do|all packages are)"; then
          echo "  ${BLUE}INFO:${NC} pipx packages are already up to date"
        elif echo "$pipx_output" | grep -qiE "(upgraded [a-z]|installed [a-z]|upgrading [a-z]|package.*upgraded|package.*installed|upgraded successfully)"; then
          echo "  pipx packages upgraded successfully"
        elif [[ -z "$pipx_output" ]] || [[ ${#pipx_output} -lt 20 ]]; then
          # Empty or very short output usually means nothing to upgrade
          echo "  ${BLUE}INFO:${NC} pipx packages are already up to date"
        else
          echo "  ${BLUE}INFO:${NC} pipx packages checked (may already be up to date)"
        fi
      else
        python_errors+=("pipx")
        echo "  ${RED}WARNING:${NC} pipx upgrade failed (exit code: $pipx_exit_code)"
        
        # Try to identify specific issues
        if [[ "$pipx_output" == *"No packages to upgrade"* ]]; then
          echo "  ${BLUE}INFO:${NC} No pipx packages need upgrading"
        elif [[ "$pipx_output" == *"error"* ]] || [[ "$pipx_output" == *"Error"* ]]; then
          echo "  ERROR: pipx encountered errors during upgrade"
          echo "  Consider running: pipx upgrade-all --force"
        else
          echo "  ${BLUE}INFO:${NC} pipx upgrade completed with warnings"
        fi
        
        # Try force upgrade as fallback
        echo "  ATTEMPTING: Force upgrade as fallback..."
        local pipx_force_output
        pipx_force_output="$(pipx upgrade-all --force 2>&1)"
        if [[ $? -eq 0 ]]; then
          # Check if force upgrade actually updated anything
          if echo "$pipx_force_output" | grep -qiE "(upgraded|installed|updating|changed|new version)"; then
            echo "  SUCCESS: pipx packages upgraded with force"
            # Remove pipx from errors if force upgrade succeeded
            local new_errors=()
            for err in "${python_errors[@]}"; do
              [[ "$err" != "pipx" ]] && new_errors+=("$err")
            done
            python_errors=("${new_errors[@]}")
          elif echo "$pipx_force_output" | grep -qiE "(No packages to upgrade|already|up to date|nothing to do)"; then
            echo "  ${BLUE}INFO:${NC} pipx packages are already up to date (force check)"
          else
            echo "  ${BLUE}INFO:${NC} pipx packages checked with force (may already be up to date)"
          fi
        else
          echo "  ${RED}WARNING:${NC} Force upgrade also failed"
        fi
      fi
    else
      echo "${GREEN}[pipx]${NC} Not found - skipping"
      echo "  ${BLUE}INFO:${NC} To install pipx, run: 'dev-tools'"
    fi

    # Update miniforge/conda packages
    if command -v conda >/dev/null 2>&1; then
      echo "${GREEN}[conda/miniforge]${NC} Updating conda and packages..."
      local conda_errors=()
      
      # Update conda itself first
      local conda_update_output=""
      local conda_update_exit_code=0

      # Try updating conda (use defaults channel for Anaconda, skip for miniforge)
      if conda info | grep -qi "channel.*defaults"; then
        conda_update_output="$(conda update -n base -c defaults conda -y 2>&1)" || conda_update_exit_code=$?
      else
        # For miniforge, update without specifying defaults channel
        conda_update_output="$(conda update -n base conda -y 2>&1)" || conda_update_exit_code=$?
      fi

      if [[ $conda_update_exit_code -eq 0 ]]; then
        # Check if output indicates an actual update occurred
        if echo "$conda_update_output" | grep -qiE "(downloading|installing|updating|changed|upgraded)"; then
          echo "  conda updated successfully"
        elif echo "$conda_update_output" | grep -qiE "(already|up to date|All requested packages already installed)"; then
          echo "  ${BLUE}INFO:${NC} conda is already up to date"
        else
          echo "  ${BLUE}INFO:${NC} conda checked (may already be up to date)"
        fi
      else
        conda_errors+=("conda_update")
        echo "  ${RED}WARNING:${NC} conda update failed (exit code: $conda_update_exit_code)"
      fi
      
      # Update all packages in base environment
      local conda_packages_output=""
      local conda_packages_exit_code=0
      conda_packages_output="$(conda update --all -y 2>&1)" || conda_packages_exit_code=$?

      if [[ $conda_packages_exit_code -eq 0 ]]; then
        # Check if output indicates packages were actually updated
        if echo "$conda_packages_output" | grep -qiE "(downloading|installing|updating|changed|upgraded|will be)"; then
          echo "  conda packages updated successfully"
        elif echo "$conda_packages_output" | grep -qiE "(already|up to date|All requested packages already installed)"; then
          echo "  ${BLUE}INFO:${NC} conda packages are already up to date"
        else
          echo "  ${BLUE}INFO:${NC} conda packages checked (may already be up to date)"
        fi
      else
        conda_errors+=("conda_packages")
        echo "  ${RED}WARNING:${NC} Some conda packages failed to update (exit code: $conda_packages_exit_code)"
      fi
      
      # Clean conda cache
      conda clean --all -y 2>/dev/null || conda_errors+=("conda_clean")
      
      # Report summary of conda issues
      if [[ ${#conda_errors[@]} -gt 0 ]]; then
        echo "  conda issues: ${conda_errors[*]}"
      fi
    else
      # Miniforge installed but not initialized in PATH - detect dynamically
      local miniforge_path=""
      local HOMEBREW_PREFIX="$(_detect_brew_prefix)"
      local conda_paths=(
        "$HOME/miniforge3/bin/conda"
        "$HOME/miniforge/bin/conda"
        "$HOME/anaconda3/bin/conda"
        "$HOME/anaconda/bin/conda"
        "$HOMEBREW_PREFIX/Caskroom/miniforge/base/bin/conda"
        "$HOMEBREW_PREFIX/Caskroom/anaconda/base/bin/conda"
        "/usr/local/miniforge3/bin/conda"
        "/usr/local/anaconda3/bin/conda"
      )
      
      for path in "${conda_paths[@]}"; do
        if [[ -f "$path" ]]; then
          # Use zsh parameter expansion instead of dirname command
          miniforge_path="${path%/*}"
          break
        fi
      done
      
      if [[ -n "$miniforge_path" ]]; then
        echo "${GREEN}[miniforge]${NC} Initializing and updating miniforge..."
        # Initialize conda for this shell
        eval "$("$miniforge_path/conda" shell.zsh hook 2>/dev/null)" || true
        
        if command -v conda >/dev/null 2>&1; then
          local conda_errors=()
          
          # Update conda itself first
          local conda_update_output=""
          local conda_update_exit_code=0

          # Try updating conda (use defaults channel for Anaconda, skip for miniforge)
          if conda info | grep -qi "channel.*defaults"; then
            conda_update_output="$(conda update -n base -c defaults conda -y 2>&1)" || conda_update_exit_code=$?
          else
            # For miniforge, update without specifying defaults channel
            conda_update_output="$(conda update -n base conda -y 2>&1)" || conda_update_exit_code=$?
          fi

          if [[ $conda_update_exit_code -eq 0 ]]; then
            # Check if output indicates an actual update occurred
            if echo "$conda_update_output" | grep -qiE "(downloading|installing|updating|changed|upgraded)"; then
              echo "  conda updated successfully"
            elif echo "$conda_update_output" | grep -qiE "(already|up to date|All requested packages already installed)"; then
              echo "  ${BLUE}INFO:${NC} conda is already up to date"
            else
              echo "  ${BLUE}INFO:${NC} conda checked (may already be up to date)"
            fi
          else
            conda_errors+=("conda_update")
            echo "  ${RED}WARNING:${NC} conda update failed (exit code: $conda_update_exit_code)"
          fi

          # Update all packages in base environment
          local conda_packages_output=""
          local conda_packages_exit_code=0
          conda_packages_output="$(conda update --all -y 2>&1)" || conda_packages_exit_code=$?

          if [[ $conda_packages_exit_code -eq 0 ]]; then
            # Check if output indicates packages were actually updated
            if echo "$conda_packages_output" | grep -qiE "(downloading|installing|updating|changed|upgraded|will be)"; then
              echo "  conda packages updated successfully"
            elif echo "$conda_packages_output" | grep -qiE "(already|up to date|All requested packages already installed)"; then
              echo "  ${BLUE}INFO:${NC} conda packages are already up to date"
            else
              echo "  ${BLUE}INFO:${NC} conda packages checked (may already be up to date)"
            fi
          else
            conda_errors+=("conda_packages")
            echo "  ${RED}WARNING:${NC} Some conda packages failed to update (exit code: $conda_packages_exit_code)"
          fi
          
          # Clean conda cache
          conda clean --all -y 2>/dev/null || conda_errors+=("conda_clean")
          
          # Report summary of conda issues
          if [[ ${#conda_errors[@]} -gt 0 ]]; then
            echo "  conda issues: ${conda_errors[*]}"
          fi
        fi
      else
        echo "${GREEN}[conda]${NC} Not found - skipping"
        echo "  ${BLUE}INFO:${NC} To install conda, run: 'dev-tools'"
      fi
    fi
    
    # Upgrade global packages with better error handling (skip if system Python only)
    # Homebrew Python: Skip pip/setuptools/wheel (Homebrew manages), but upgrade user-installed packages
    if [[ "$is_system_python" == true ]]; then
      echo "  ${BLUE}INFO:${NC} Skipping global packages upgrade (system Python)"
    else
      # Upgrade user-installed packages for both pyenv and Homebrew Python
      _ensure_system_path
      local outdated_packages
      outdated_packages="$("$pybin" -m pip list --outdated --format=freeze 2>/dev/null | cut -d= -f1 || true)"
      if [[ -n "$outdated_packages" ]]; then
        echo "  Upgrading global packages..."
        local failed_packages=()
        while IFS= read -r package; do
          [[ -z "$package" ]] && continue
          # Skip pip, setuptools, wheel if Homebrew Python (Homebrew manages these)
          if [[ "$is_homebrew_python" == true ]] && [[ "$package" == "pip" || "$package" == "setuptools" || "$package" == "wheel" ]]; then
            continue
          fi
          if ! "$pybin" -m pip install -U "$package" 2>/dev/null; then
            failed_packages+=("$package")
          fi
        done <<< "$outdated_packages"
        
        if [[ ${#failed_packages[@]} -gt 0 ]]; then
          python_errors+=("global_packages")
          echo "  ${RED}WARNING:${NC} Failed to upgrade: ${failed_packages[*]}"
        else
          echo "  Global packages upgraded successfully"
        fi
      else
        echo "  ${BLUE}INFO:${NC} No outdated global packages found"
      fi
    fi
    
    # Report summary of Python issues
    if [[ ${#python_errors[@]} -gt 0 ]]; then
      echo "  Python issues: ${python_errors[*]}"
    fi
    
    # Refresh command hash table after Python package updates
    hash -r 2>/dev/null || true
  else
    echo "${GREEN}[Python]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install Python, run: 'dev-tools'"
  fi

  if command -v pyenv >/dev/null 2>&1 && [[ -n "$pyenv_target" && "$pyenv_target" != "system" ]]; then
    if _is_disabled "${MACSMITH_CLEAN_PYENV:-}"; then
      echo "${GREEN}[pyenv]${NC} Cleanup disabled; set MACSMITH_CLEAN_PYENV=1 or unset to enable"
    else
      local keep_list_raw="${MACSMITH_PYENV_KEEP:-}"
      keep_list_raw="${keep_list_raw//,/ }"
      local versions_to_keep=("$pyenv_target" "system")

      if [[ -n "$keep_list_raw" ]]; then
        local keep_entry=""
        for keep_entry in ${=keep_list_raw}; do
          versions_to_keep+=("$keep_entry")
        done
      fi

      echo "${GREEN}[pyenv]${NC} Removing old versions (keeping $pyenv_target and any in MACSMITH_PYENV_KEEP)..."
      pyenv versions --bare 2>/dev/null | while read -r ver; do
        [[ -z "$ver" ]] && continue
        local should_keep=false
        local keep_ver=""
        for keep_ver in "${versions_to_keep[@]}"; do
          [[ "$ver" == "$keep_ver" ]] && should_keep=true && break
        done
        [[ "$should_keep" == true ]] && continue
        echo "  removing $ver"
        pyenv uninstall -f "$ver" || echo "  ${RED}WARNING:${NC} Failed to remove $ver"
      done
      pyenv rehash 2>/dev/null || true
    fi
  fi

  # nvm is a shell function, not a command - check if it's available
  local nvm_available=false
  if type nvm >/dev/null 2>&1 || [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
    # Source nvm if not already loaded
    if ! type nvm >/dev/null 2>&1; then
      [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]] && source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" 2>/dev/null || true
    fi
    if type nvm >/dev/null 2>&1; then
      nvm_available=true
    fi
  fi

  if [[ "$nvm_available" == "true" ]]; then
    echo "${GREEN}[Node]${NC} Ensuring latest LTS..."
    local prev_nvm="$(nvm current 2>/dev/null || true)"
    nvm install --lts --latest-npm || true
    nvm alias default 'lts/*' || true
    nvm use default || true
    local active_nvm="$(nvm current 2>/dev/null || true)"
    # Only reinstall packages if we switched to a different version
    if [[ -n "$prev_nvm" && "$prev_nvm" != "system" && -n "$active_nvm" && "$prev_nvm" != "$active_nvm" ]]; then
      nvm reinstall-packages "$prev_nvm" || true
    fi
    if [[ -n "$active_nvm" && "$active_nvm" != "system" ]]; then
      if _is_disabled "${MACSMITH_CLEAN_NVM:-}"; then
        echo "${GREEN}[nvm]${NC} Cleanup disabled; set MACSMITH_CLEAN_NVM=1 or unset to enable"
      else
        local keep_list_raw="${MACSMITH_NVM_KEEP:-}"
        keep_list_raw="${keep_list_raw//,/ }"
        local keep_versions=("$active_nvm")

        if [[ -n "$keep_list_raw" ]]; then
          local keep_entry=""
          for keep_entry in ${=keep_list_raw}; do
            [[ "$keep_entry" == v* ]] || keep_entry="v$keep_entry"
            keep_versions+=("$keep_entry")
          done
        fi

        echo "${GREEN}[nvm]${NC} Removing older Node versions (keeping $active_nvm and any in MACSMITH_NVM_KEEP)..."
        # Get only actually installed versions dynamically
        # nvm ls shows only installed versions (not remote/available versions)
        while IFS= read -r ver; do
          [[ -z "$ver" ]] && continue
          local should_keep=false
          local keep_ver=""
          for keep_ver in "${keep_versions[@]}"; do
            if [[ "$ver" == "$keep_ver" ]]; then
              should_keep=true
              break
            fi
          done
          [[ "$should_keep" == true ]] && continue
          echo "  removing $ver"
          nvm uninstall "$ver" || echo "  ${RED}WARNING:${NC} Failed to remove $ver"
        done < <(nvm ls --no-colors --no-alias 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
      fi
    fi
  elif [[ "$nvm_available" != "true" ]] && command -v brew >/dev/null 2>&1 && brew list node >/dev/null 2>&1; then
    echo "${GREEN}[Node]${NC} Updating Node via Homebrew..."
    brew upgrade node || true
  else
    echo "${GREEN}[Node]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install Node.js, run: 'dev-tools'"
  fi
  
  if command -v npm >/dev/null 2>&1; then
    # Update npm itself
    local npm_install_output=""
    local npm_install_exit_code=0
    npm_install_output="$(npm install -g npm 2>&1)" || npm_install_exit_code=$?

    if [[ $npm_install_exit_code -eq 0 ]]; then
      # Check if npm was actually updated
      if echo "$npm_install_output" | grep -qiE "(added|updated|upgraded|changed [0-9]+ packages)"; then
        # Only show success if it's not just metadata changes
        if ! echo "$npm_install_output" | grep -qiE "(unchanged|up to date|already installed)"; then
          echo "  npm updated successfully"
        fi
      fi
    else
      echo "  ${RED}WARNING:${NC} npm install failed (exit code: $npm_install_exit_code)"
    fi

    # Update global packages
    local npm_update_output=""
    local npm_update_exit_code=0
    npm_update_output="$(npm update -g 2>&1)" || npm_update_exit_code=$?

    if [[ $npm_update_exit_code -eq 0 ]]; then
      # Check if packages were actually updated
      # "changed X packages" can be just metadata, not actual upgrades
      # Look for actual upgrade indicators
      if echo "$npm_update_output" | grep -qiE "(upgraded|updated [a-z]|installed [a-z]|removed [a-z])"; then
        echo "  npm global packages updated successfully"
      elif echo "$npm_update_output" | grep -qiE "(unchanged|up to date|already installed|no updates)"; then
        echo "  ${BLUE}INFO:${NC} npm global packages are already up to date"
      elif echo "$npm_update_output" | grep -qiE "changed [0-9]+ packages"; then
        # "changed X packages" alone usually means metadata only, not actual upgrades
        echo "  ${BLUE}INFO:${NC} npm global packages checked (no updates needed)"
      else
        echo "  ${BLUE}INFO:${NC} npm global packages checked (may already be up to date)"
      fi
    else
      echo "  ${RED}WARNING:${NC} npm update failed (exit code: $npm_update_exit_code)"
    fi

    # Refresh command hash table after Node.js package updates
    hash -r 2>/dev/null || true
  fi

  local chruby_target=""
  
  if command -v gem >/dev/null 2>&1; then
    # Check if this is system Ruby (should not be modified)
    local ruby_bin=$(command -v ruby 2>/dev/null || echo "")
    if [[ -n "$ruby_bin" ]] && _is_system_ruby "$ruby_bin"; then
      echo "${GREEN}[RubyGems]${NC} Detected system Ruby ($ruby_bin) - skipping gem updates"
      echo "  ${BLUE}INFO:${NC} System Ruby should not be modified - use chruby, rbenv, or Homebrew Ruby for development"
      echo "  ${BLUE}INFO:${NC} System Ruby gems are managed by macOS and may require sudo (not recommended)"
    else
      echo "${GREEN}[RubyGems]${NC} Updating and cleaning gems..."
      local gem_update_output=""
      local gem_update_exit_code=0
      gem_update_output="$(gem update --silent --no-document 2>&1)" || gem_update_exit_code=$?

      if [[ $gem_update_exit_code -eq 0 ]]; then
        # Check if output indicates gems were actually updated
        if echo "$gem_update_output" | grep -qiE "(updating|installing|upgraded|updated|Successfully)"; then
          echo "  Gems updated successfully"
        elif [[ -z "$gem_update_output" ]] || echo "$gem_update_output" | grep -qiE "(nothing|already|up to date|No updates)"; then
          echo "  ${BLUE}INFO:${NC} Gems are already up to date"
        else
          echo "  ${BLUE}INFO:${NC} Gems checked (may already be up to date)"
        fi
      else
        echo "  ${RED}WARNING:${NC} gem update failed (exit code: $gem_update_exit_code)"
      fi
      
      local gem_cleanup_output=""
      gem_cleanup_output="$(gem cleanup 2>&1 || echo "FAILED")"
      if [[ "$gem_cleanup_output" != *"FAILED"* ]]; then
        # Check if cleanup actually removed anything
        # gem cleanup shows "Removing" or specific gem names when it removes something
        # "Clean up complete" alone (without "Removing") means nothing was removed
        if echo "$gem_cleanup_output" | grep -qiE "(Removing [a-z]|Cleaning up [a-z]|removed [0-9]+|removing [0-9]+)"; then
          echo "  Gems cleaned successfully"
        elif echo "$gem_cleanup_output" | grep -qiE "(nothing|already|No|Clean up complete)" && ! echo "$gem_cleanup_output" | grep -qiE "(Removing|removing)"; then
          echo "  ${BLUE}INFO:${NC} Gems cleanup complete (nothing to clean)"
        else
          echo "  ${BLUE}INFO:${NC} Gems cleanup complete"
        fi
      else
        echo "  ${RED}WARNING:${NC} gem cleanup failed"
      fi
    fi
  fi
  
  # chruby is a shell function, not a command - check if it's available
  local chruby_available=false
  if type chruby >/dev/null 2>&1; then
    chruby_available=true
  elif [[ -f /usr/local/share/chruby/chruby.sh ]] || [[ -f "$HOME/.local/share/chruby/chruby.sh" ]]; then
    # Try to source chruby if available but not loaded
    if [[ -f /usr/local/share/chruby/chruby.sh ]]; then
      source /usr/local/share/chruby/chruby.sh 2>/dev/null && chruby_available=true || true
    elif [[ -f "$HOME/.local/share/chruby/chruby.sh" ]]; then
      source "$HOME/.local/share/chruby/chruby.sh" 2>/dev/null && chruby_available=true || true
    fi
    # Also check Homebrew location
    if [[ "$chruby_available" != "true" ]] && command -v brew >/dev/null 2>&1; then
      local chruby_path="$(brew --prefix chruby 2>/dev/null || echo "")"
      if [[ -n "$chruby_path" && -f "$chruby_path/share/chruby/chruby.sh" ]]; then
        source "$chruby_path/share/chruby/chruby.sh" 2>/dev/null && chruby_available=true || true
      fi
    fi
  fi
  
  if [[ "$chruby_available" == "true" ]]; then
    echo "${GREEN}[chruby]${NC} Ensuring latest Ruby is active..."
    if chruby_target="$(_chruby_install_latest 2>/dev/null)"; then
      echo "${GREEN}[chruby]${NC} Installed and activated: $chruby_target"
    else
      chruby_target="$(_chruby_latest_installed 2>/dev/null || true)"
      if [[ -n "$chruby_target" ]]; then
        echo "${GREEN}[chruby]${NC} Activating existing: $chruby_target"
        chruby "$chruby_target" >/dev/null 2>&1 || echo "${GREEN}[chruby]${NC} Failed to activate $chruby_target"
      else
        echo "${GREEN}[chruby]${NC} No Ruby versions found, installing latest..."
        if command -v ruby-install >/dev/null 2>&1; then
          local latest_ruby="$(_chruby_latest_available)"
          if [[ -n "$latest_ruby" ]]; then
            echo "${GREEN}[chruby]${NC} Installing ruby-$latest_ruby..."
            ruby-install ruby "$latest_ruby" && chruby_target="ruby-$latest_ruby"
            chruby "$chruby_target" >/dev/null 2>&1 || echo "${GREEN}[chruby]${NC} Failed to activate $chruby_target"
          fi
        else
          echo "${GREEN}[chruby]${NC} ruby-install not found, cannot install Ruby"
        fi
      fi
    fi
    
    # Auto-fix Ruby gems by default allow opt-out
    if _is_disabled "${MACSMITH_FIX_RUBY_GEMS:-}"; then
      echo "${GREEN}[Ruby]${NC} Gem auto-fix disabled; set MACSMITH_FIX_RUBY_GEMS=1 or unset to enable"
    else
      _fix_all_ruby_gems
    fi
  else
    echo "${GREEN}[chruby]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install chruby, run: 'dev-tools'"
  fi

  if [[ "$chruby_available" == "true" ]] && [[ -n "$chruby_target" ]]; then
    local rubies_root="$HOME/.rubies"
    if [[ -d "$rubies_root" ]]; then
      if _is_disabled "${MACSMITH_CLEAN_CHRUBY:-}"; then
        echo "${GREEN}[chruby]${NC} Cleanup disabled; set MACSMITH_CLEAN_CHRUBY=1 or unset to enable"
      else
        local keep_list_raw="${MACSMITH_CHRUBY_KEEP:-}"
        keep_list_raw="${keep_list_raw//,/ }"
        local keep_versions=("$chruby_target")

        if [[ -n "$keep_list_raw" ]]; then
          local keep_entry=""
          for keep_entry in ${=keep_list_raw}; do
            [[ "$keep_entry" == ruby-* ]] || keep_entry="ruby-$keep_entry"
            keep_versions+=("$keep_entry")
          done
        fi

        echo "${GREEN}[chruby]${NC} Removing old rubies (keeping $chruby_target and any in MACSMITH_CHRUBY_KEEP)..."
        for dir in "$rubies_root"/ruby-*; do
          [[ -d "$dir" ]] || continue
          local ruby_version="${dir##*/}"
          local should_keep=false
          local keep_ver=""
          for keep_ver in "${keep_versions[@]}"; do
            if [[ "$ruby_version" == "$keep_ver" ]]; then
              should_keep=true
              break
            fi
          done
          [[ "$should_keep" == true ]] && continue
          echo "  removing $ruby_version"
          rm -rf "$dir" || echo "  ${RED}WARNING:${NC} Failed to remove $ruby_version"
        done
      fi
    fi
  fi

  # Go
  if command -v go >/dev/null 2>&1; then
    _go_update_toolchain || true
  else
    echo "${GREEN}[Go]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install Go, run: 'dev-tools'"
  fi

  # Swift
  if command -v swiftly >/dev/null 2>&1; then
    echo "${GREEN}[Swift]${NC} Updating Swift toolchain via swiftly..."
    
    # Check if swiftly is initialized
    if [[ -z "${SWIFTLY_HOME_DIR:-}" ]] && [[ ! -f "$HOME/.swiftly/env.sh" ]]; then
      echo "  ${BLUE}INFO:${NC} swiftly not initialized, initializing..."
      if ~/.swiftly/bin/swiftly init --quiet-shell-followup 2>/dev/null; then
        if [[ -f "$HOME/.swiftly/env.sh" ]]; then
          source "$HOME/.swiftly/env.sh" 2>/dev/null || true
          hash -r 2>/dev/null || true
          echo "  SUCCESS: swiftly initialized"
        fi
      else
        echo "  ${RED}WARNING:${NC} swiftly initialization failed"
      fi
    fi
    
    # Update swiftly itself
    echo "  Updating swiftly..."
    local swiftly_output=""
    local swiftly_exit_code=0
    swiftly_output="$({ printf "y\ny\ny\ny\ny\n"; cat /dev/null; } | swiftly self-update 2>&1)" || swiftly_exit_code=$?

    if [[ $swiftly_exit_code -eq 0 ]] && [[ "$swiftly_output" != *"error"* ]] && [[ "$swiftly_output" != *"Error"* ]]; then
      # Check if output indicates an actual update occurred
      # swiftly self-update shows "Downloading" or "Installing" when updating
      if echo "$swiftly_output" | grep -qiE "(downloading|installing|updated to|upgraded to|new version)"; then
        echo "  swiftly updated successfully"
      elif echo "$swiftly_output" | grep -qiE "(already|up to date|current|latest|unchanged|no update|already installed)"; then
        echo "  ${BLUE}INFO:${NC} swiftly is already up to date"
      else
        # If output is empty or unclear, check exit code or assume no update
        # swiftly self-update returns 0 even when already up to date
        # So if output is empty/minimal, likely no update occurred
        if [[ -z "$swiftly_output" ]] || [[ ${#swiftly_output} -lt 10 ]]; then
          echo "  ${BLUE}INFO:${NC} swiftly is already up to date"
        else
          echo "  ${BLUE}INFO:${NC} swiftly checked (may already be up to date)"
        fi
      fi
    else
      echo "  ${RED}WARNING:${NC} swiftly self-update failed (may require manual intervention)"
    fi
    
    # swiftly list shows "(in use)" for release toolchains and "(default)" for snapshots
    local current_swift=""
    # Check for release toolchain (in use)
    current_swift="$(swiftly list 2>/dev/null | grep -E '\(in use\)' | sed 's/Swift //' | sed 's/ (in use).*//' | awk '{print $1}' || echo "")"
    # If no release toolchain active, check for snapshot (default)
    if [[ -z "$current_swift" ]]; then
      current_swift="$(swiftly list 2>/dev/null | grep -E '\(default\)' | sed 's/.* //' | sed 's/ (default).*//' | awk '{print $1}' || echo "")"
    fi
    if [[ -n "$current_swift" ]]; then
      echo "  Current: Swift $current_swift"
      
      # Check if current version is a snapshot
      local is_snapshot=false
      if [[ "$current_swift" == *"snapshot"* ]] || [[ "$current_swift" == *"main"* ]] || [[ "$current_swift" == *"release"* ]]; then
        is_snapshot=true
        echo "  ${BLUE}INFO:${NC} Current version is a snapshot/development build"
      fi
      
      # Get latest stable release 
      # swiftly list-available outputs "Swift X.Y.Z" format, we need the version number
      local latest_stable="$(swiftly list-available 2>/dev/null | grep -E '^Swift [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | awk '{print $2}' || echo "")"
      
      # Get latest snapshot if user wants snapshots (optional, can be controlled via env var)
      local latest_snapshot=""
      if [[ "${MACSMITH_SWIFT_SNAPSHOTS:-0}" == "1" ]]; then
        # swiftly list-available outputs snapshot names, extract version (usually 2nd field)
        latest_snapshot="$(swiftly list-available 2>/dev/null | grep -E "(main-snapshot|release.*snapshot)" | head -n1 | awk '{print $2}' || echo "")"
      fi
      
      # Determine target version (prefer stable unless snapshot is explicitly requested)
      local swift_target_version=""
      if [[ -n "$latest_stable" && "$latest_stable" != "$current_swift" ]]; then
        swift_target_version="$latest_stable"
      elif [[ -n "$latest_snapshot" && "$latest_snapshot" != "$current_swift" && "$is_snapshot" == "true" ]]; then
        swift_target_version="$latest_snapshot"
      fi
      
      if [[ -n "$swift_target_version" ]]; then
        echo "  Latest available: Swift $swift_target_version"
        # Use --assume-yes to avoid prompts
        if swiftly install "$swift_target_version" --assume-yes 2>/dev/null; then
          # Explicitly switch active toolchain (--use on install may not switch when already installed)
          swiftly use "$swift_target_version" 2>/dev/null || true
          hash -r 2>/dev/null || true
          # Verify the switch actually happened
          local verify_active="$(swiftly list 2>/dev/null | grep '(in use)' || true)"
          if [[ "$verify_active" == *"$swift_target_version"* ]]; then
            echo "  SUCCESS: Updated to Swift $swift_target_version"
          else
            echo "  ${RED}WARNING:${NC} Installed Swift $swift_target_version but active toolchain may not have switched"
            echo "  ${BLUE}INFO:${NC} Run 'swiftly use $swift_target_version' manually to switch"
          fi
        else
          echo "  ${RED}WARNING:${NC} Failed to install Swift $swift_target_version"
        fi
      else
        echo "  Swift is up to date ($current_swift)"
      fi
      
      # Check for newer snapshots (informational only)
      if [[ "$is_snapshot" == "false" && -n "$latest_snapshot" ]]; then
        echo "  ${BLUE}INFO:${NC} Development snapshot available: $latest_snapshot (set MACSMITH_SWIFT_SNAPSHOTS=1 to enable)"
      fi
    else
      echo "  ${BLUE}INFO:${NC} No Swift version active via swiftly"
      # Check if any Swift version (release or snapshot) is installed but not active
      local installed_swift=""
      # Check for release toolchain first
      installed_swift="$(swiftly list 2>/dev/null | grep -E '^Swift [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/Swift //' | awk '{print $1}' || echo "")"
      # If no release, check for snapshot
      if [[ -z "$installed_swift" ]]; then
        installed_swift="$(swiftly list 2>/dev/null | grep -E 'snapshot' | grep -v 'Installed snapshot' | head -n1 | awk '{print $1}' || echo "")"
      fi
      if [[ -n "$installed_swift" ]]; then
        echo "  ${BLUE}INFO:${NC} Swift $installed_swift is installed but not active, activating..."
        if echo "y" | swiftly use "$installed_swift" --global-default 2>/dev/null; then
          echo "  SUCCESS: Activated Swift $installed_swift"
          hash -r 2>/dev/null || true
        else
          echo "  ${RED}WARNING:${NC} Failed to activate Swift $installed_swift"
        fi
      else
        # Install latest stable if no version is installed
        # swiftly list-available outputs "Swift X.Y.Z" format, we need the version number
        local latest_stable="$(swiftly list-available 2>/dev/null | grep -E '^Swift [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | awk '{print $2}' || echo "")"
        if [[ -n "$latest_stable" && "$latest_stable" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
          echo "  Installing latest stable: Swift $latest_stable"
          if swiftly install "$latest_stable" --assume-yes --use 2>/dev/null; then
            echo "  SUCCESS: Installed Swift $latest_stable"
            hash -r 2>/dev/null || true
          else
            echo "  ${RED}WARNING:${NC} Failed to install Swift $latest_stable"
          fi
        else
          echo "  ${BLUE}INFO:${NC} Could not determine latest stable version"
          echo "  ${BLUE}INFO:${NC} Run 'swiftly list-available' to see available Swift versions"
        fi
      fi
    fi
  elif command -v swift >/dev/null 2>&1; then
    echo "${GREEN}[Swift]${NC} Swift found (system or Homebrew installation)"
    local swift_version="$(swift --version 2>/dev/null | head -n1 | sed 's/.*version //' | cut -d' ' -f1 || echo "unknown")"
    echo "  Current: Swift $swift_version"
    # If installed via Homebrew, try to update
    if command -v brew >/dev/null 2>&1 && brew list swift >/dev/null 2>&1; then
      echo "  Updating Swift via Homebrew..."
      if brew upgrade swift 2>/dev/null; then
        local new_version="$(swift --version 2>/dev/null | head -n1 | sed 's/.*version //' | cut -d' ' -f1 || echo "unknown")"
        echo "  SUCCESS: Updated to Swift $new_version"
      else
        echo "  ${RED}WARNING:${NC} Homebrew Swift update failed"
      fi
    else
      echo "  ${BLUE}INFO:${NC} Swift is system-installed (update via Xcode or install swiftly for version management)"
      echo "  ${BLUE}INFO:${NC} Install swiftly: curl -O https://download.swift.org/swiftly/darwin/swiftly.pkg && installer -pkg swiftly.pkg -target CurrentUserHomeDirectory"
    fi
  else
    echo "${GREEN}[Swift]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install Swift, run: 'dev-tools'"
  fi

  # Rust - use rustup for comprehensive updates
  if command -v rustup >/dev/null 2>&1; then
    echo "${GREEN}[Rust]${NC} Updating Rust toolchain and components via rustup..."
    local rust_errors=()
    
    # Update rustup itself first
    echo "  Updating rustup..."
    local rustup_output=""
    local rustup_exit_code=0
    rustup_output="$(rustup self update 2>&1)" || rustup_exit_code=$?

    if [[ $rustup_exit_code -eq 0 ]]; then
      # Check if output indicates an actual update occurred
      if echo "$rustup_output" | grep -qiE "(updated|upgraded|installed|new version)"; then
        echo "    rustup updated successfully"
      elif echo "$rustup_output" | grep -qiE "(unchanged|already|up to date|current|latest)"; then
        echo "    ${BLUE}INFO:${NC} rustup is already up to date"
      else
        echo "    ${BLUE}INFO:${NC} rustup checked (may already be up to date)"
      fi
    else
      rust_errors+=("rustup_self")
      echo "    ${RED}WARNING:${NC} rustup self update failed (exit code: $rustup_exit_code)"
    fi

    # Update all installed toolchains
    echo "  Updating all Rust toolchains..."
    local toolchain_output=""
    local toolchain_exit_code=0
    toolchain_output="$(rustup update 2>&1)" || toolchain_exit_code=$?

    if [[ $toolchain_exit_code -eq 0 ]]; then
      # Check if output indicates an actual update occurred
      if echo "$toolchain_output" | grep -qiE "(updated|upgraded|installed|new version)"; then
        echo "    Toolchains updated successfully"
      elif echo "$toolchain_output" | grep -qiE "(unchanged|already|up to date|current|latest)"; then
        echo "    ${BLUE}INFO:${NC} Rust toolchains are already up to date"
      else
        echo "    ${BLUE}INFO:${NC} Rust toolchains checked (may already be up to date)"
      fi
    else
      rust_errors+=("toolchains")
      echo "    ${RED}WARNING:${NC} Toolchain update failed (exit code: $toolchain_exit_code)"
    fi

    # Set default toolchain to stable
    echo "  Setting default toolchain to stable..."
    rustup default stable 2>/dev/null || rust_errors+=("default_toolchain")
    
    # Add common rustup components if not already installed
    echo "  Ensuring rustup components are installed..."
    if rustup component add rustfmt clippy 2>/dev/null; then
      echo "    Components added/updated"
    fi
    
    # Report Rust issues
    if [[ ${#rust_errors[@]} -gt 0 ]]; then
      echo "  Rust issues: ${rust_errors[*]}"
    fi
  else
    echo "${GREEN}[Rust]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install Rust, run: 'dev-tools'"
  fi

  # Cargo (Rust package manager) - update globally installed packages
  if command -v cargo >/dev/null 2>&1; then
    _cargo_update_packages || true
  fi

  # .NET SDK - update if installed
  if command -v dotnet >/dev/null 2>&1; then
    echo "${GREEN}[.NET]${NC} Updating .NET SDK and workloads..."
    local dotnet_errors=()
    
    # Check current version
    local current_dotnet_version=""
    current_dotnet_version="$(dotnet --version 2>/dev/null || echo "")"
    if [[ -n "$current_dotnet_version" ]]; then
      echo "  Current .NET SDK version: $current_dotnet_version"
    fi
    
    # Try to update via Homebrew if installed via Homebrew
    if command -v brew >/dev/null 2>&1; then
      local brew_dotnet_info=""
      brew_dotnet_info="$(brew list --formula 2>/dev/null | grep -E '^dotnet$' || echo "")"
      if [[ -n "$brew_dotnet_info" ]]; then
        echo "  Updating .NET via Homebrew..."
        local brew_upgrade_output=""
        local brew_upgrade_exit_code=0
        brew_upgrade_output="$(brew upgrade dotnet 2>&1)" || brew_upgrade_exit_code=$?

        if [[ $brew_upgrade_exit_code -eq 0 ]]; then
          if echo "$brew_upgrade_output" | grep -qiE "(Upgrading|==> Pouring|Upgraded|changed)"; then
            echo "    SUCCESS: .NET updated via Homebrew"
          elif echo "$brew_upgrade_output" | grep -qiE "(Already up-to-date|Nothing to upgrade)"; then
            echo "    ${BLUE}INFO:${NC} .NET is already up to date via Homebrew"
          else
            echo "    ${BLUE}INFO:${NC} .NET checked via Homebrew (may already be up to date)"
          fi
        else
          dotnet_errors+=("brew_upgrade")
          echo "    ${RED}WARNING:${NC} Failed to update .NET via Homebrew (exit code: $brew_upgrade_exit_code)"
        fi
      fi
    fi
    
    # Update .NET workloads
    echo "  Updating .NET workloads..."
    local workload_output=""
    local workload_exit_code=0
    workload_output="$(dotnet workload update 2>&1)" || workload_exit_code=$?

    if [[ $workload_exit_code -eq 0 ]]; then
      if echo "$workload_output" | grep -qiE "(Updated|Installed|Successfully)"; then
        echo "    SUCCESS: .NET workloads updated"
      elif echo "$workload_output" | grep -qiE "(already|up to date|No updates)"; then
        echo "    ${BLUE}INFO:${NC} .NET workloads are already up to date"
      else
        echo "    ${BLUE}INFO:${NC} .NET workloads checked (may already be up to date)"
      fi
    else
      # Workload update failure is not critical - workloads may not be installed
      echo "    ${BLUE}INFO:${NC} No workloads to update or workload update not needed"
    fi

    # Update global .NET tools
    echo "  Updating global .NET tools..."
    # First check if there are any global tools installed
    local tool_list_output=""
    local tool_list_exit_code=0
    tool_list_output="$(dotnet tool list --global 2>&1)" || tool_list_exit_code=$?
    local tool_count=0
    if [[ $tool_list_exit_code -eq 0 ]]; then
      # Count lines that contain package info (skip header lines)
      tool_count=$(echo "$tool_list_output" | grep -E "^[a-zA-Z]" | wc -l | tr -d ' ' || echo "0")
    fi

    if [[ "$tool_count" -eq 0 ]]; then
      echo "    ${BLUE}INFO:${NC} No global .NET tools installed"
    else
      echo "    Found $tool_count global .NET tool(s), updating..."
      local tool_update_output=""
      local tool_update_exit_code=0
      tool_update_output="$(dotnet tool update --global --all 2>&1)" || tool_update_exit_code=$?

      if [[ $tool_update_exit_code -eq 0 ]]; then
        if echo "$tool_update_output" | grep -qiE "(Updated|Upgraded|Installed|Successfully)"; then
          echo "    SUCCESS: Global .NET tools updated"
        elif echo "$tool_update_output" | grep -qiE "(already|up to date|No updates)"; then
          echo "    ${BLUE}INFO:${NC} Global .NET tools are already up to date"
        else
          echo "    ${BLUE}INFO:${NC} Global .NET tools checked (may already be up to date)"
        fi
      else
        dotnet_errors+=("tool_update")
        echo "    ${RED}WARNING:${NC} Global .NET tools update failed (exit code: $tool_update_exit_code)"
        echo "    ${RED}WARNING:${NC} Failed to update global .NET tools"
      fi
    fi
    
    # Report .NET issues
    if [[ ${#dotnet_errors[@]} -gt 0 ]]; then
      echo "  .NET issues: ${dotnet_errors[*]}"
      echo "  ${BLUE}INFO:${NC} If .NET was installed via official installer, update manually from: https://dotnet.microsoft.com/download"
    fi
  else
    echo "${GREEN}[.NET]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install .NET SDK, run: 'dev-tools'"
  fi

  # Check for mas - skip if missing (install via install.sh)
  if ! command -v mas >/dev/null 2>&1; then
    echo "${GREEN}[mas]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install mas, run: 'sys-install'"
  fi
  
  # mas (Mac App Store CLI) - update App Store apps
  if command -v mas >/dev/null 2>&1; then
    echo "${GREEN}[mas]${NC} Updating Mac App Store apps..."
    local mas_errors=()
    
    # Check for outdated apps
    local outdated_output
    local outdated_exit_code=0
    outdated_output=$(mas outdated 2>&1) || outdated_exit_code=$?

    if [[ $outdated_exit_code -ne 0 ]] || [[ "$outdated_output" == *"Error"* ]]; then
      mas_errors+=("check")
      echo "  ${RED}WARNING:${NC} Failed to check for App Store updates (exit code: $outdated_exit_code)"
      echo "  ${BLUE}INFO:${NC} Make sure you're signed in to App Store: open -a 'App Store'"
    elif [[ -z "$outdated_output" ]] || echo "$outdated_output" | grep -qiE "(All.*up to date|Nothing to update)"; then
      echo "  ${BLUE}INFO:${NC} All App Store apps are up to date"
    else
      # Count outdated apps
      local outdated_count
      outdated_count=$(echo "$outdated_output" | grep -cE "^[0-9]+" 2>/dev/null)
      outdated_count=${outdated_count:-0}

      if [[ "$outdated_count" -gt 0 ]]; then
        echo "  Found $outdated_count outdated app(s):"
        echo "$outdated_output" | head -5
        [[ "$outdated_count" -gt 5 ]] && echo "  ... and $((outdated_count - 5)) more"

        echo "  Updating apps..."
        local mas_update_output
        local mas_update_exit_code=0
        # mas should run without sudo to use per-user App Store authentication
        # Try mas upgrade first
        mas_update_output=$(mas upgrade 2>&1) || mas_update_exit_code=$?

        if [[ $mas_update_exit_code -ne 0 ]] || [[ "$mas_update_output" == *"Error"* ]]; then
          mas_errors+=("update")
          echo "  ${RED}WARNING:${NC} Failed to update App Store apps (exit code: $mas_update_exit_code)"
          echo "  ${BLUE}INFO:${NC} You may need to sign in to App Store or enter your password"
        elif echo "$mas_update_output" | grep -qiE "(Upgrading|Downloading|Installed)"; then
          echo "  SUCCESS: App Store apps updated"
        else
          echo "  ${BLUE}INFO:${NC} App Store apps checked (may require manual update)"
        fi
      fi
    fi
    
    if [[ ${#mas_errors[@]} -gt 0 ]]; then
      echo "  mas issues: ${mas_errors[*]}"
    fi
  fi

  # Check for Nix - skip if missing (install via install.sh)
  if ! command -v nix >/dev/null 2>&1 && ! [[ -d /nix ]] && ! [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
    echo "${GREEN}[Nix]${NC} Not found - skipping"
    echo "  ${BLUE}INFO:${NC} To install Nix, run: 'sys-install'"
  fi
  
  # Nix - integrated update with smart preview and cleanup
  if command -v nix >/dev/null 2>&1; then
    echo "${GREEN}[Nix]${NC} Updating packages..."
    local nix_errors=()
    
    # Update nix profile packages
    local profile_count
    profile_count=$(nix profile list 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$profile_count" -gt 0 ]]; then
      local nix_profile_output=""
      local nix_profile_exit_code=0
      nix_profile_output="$(nix profile upgrade --all 2>&1)" || nix_profile_exit_code=$?

      if [[ $nix_profile_exit_code -eq 0 ]]; then
        # Check if output indicates packages were actually updated
        if echo "$nix_profile_output" | grep -qiE "(upgraded|installed|downloading|building|changed)"; then
          echo "  nix profile packages updated successfully"
        elif echo "$nix_profile_output" | grep -qiE "(unchanged|already|up to date|nothing to do)"; then
          echo "  ${BLUE}INFO:${NC} nix profile packages are already up to date"
        else
          echo "  ${BLUE}INFO:${NC} nix profile packages checked (may already be up to date)"
        fi
      else
        nix_errors+=("profile")
        echo "  ${RED}WARNING:${NC} nix profile update failed (exit code: $nix_profile_exit_code)"
      fi
    fi

    # Update nix-env packages
    local env_count
    env_count=$(nix-env -q 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$env_count" -gt 0 ]]; then
      local nix_env_output=""
      local nix_env_exit_code=0
      nix_env_output="$(nix-env -u '*' 2>&1)" || nix_env_exit_code=$?

      if [[ $nix_env_exit_code -eq 0 ]]; then
        # Check if output indicates packages were actually updated
        if echo "$nix_env_output" | grep -qiE "(upgraded|installed|downloading|building|changed)"; then
          echo "  nix-env packages updated successfully"
        elif echo "$nix_env_output" | grep -qiE "(unchanged|already|up to date|nothing to do)"; then
          echo "  ${BLUE}INFO:${NC} nix-env packages are already up to date"
        else
          echo "  ${BLUE}INFO:${NC} nix-env packages checked (may already be up to date)"
        fi
      else
        nix_errors+=("nix-env")
        echo "  ${RED}WARNING:${NC} nix-env update failed (exit code: $nix_env_exit_code)"
        echo "  ${RED}WARNING:${NC} nix-env update failed"
      fi
    fi
    
    # Cleanup Nix store (gc + optimise)
    # Try new CLI first, fall back to sudo nix-collect-garbage (works without experimental features)
    echo "  Cleaning Nix store..."
    local gc_output
    local gc_exit_code=0
    gc_output=$(nix store gc 2>&1) || gc_exit_code=$?
    if [[ $gc_exit_code -ne 0 ]]; then
      # Retry with sudo using classic command (no experimental features needed)
      gc_exit_code=0
      gc_output=$(sudo nix-collect-garbage 2>&1) || gc_exit_code=$?
    fi
    if [[ $gc_exit_code -eq 0 ]]; then
      local freed_space
      freed_space=$(echo "$gc_output" | grep -iE "(freed|removed|deleted).*[0-9]+.*(bytes|KB|MB|GB)" | head -1 || echo "")
      if [[ -n "$freed_space" ]]; then
        echo "  Nix store cleaned: $freed_space"
      else
        echo "  Nix store cleaned successfully"
      fi
    else
      nix_errors+=("gc")
      echo "  ${RED}WARNING:${NC} Nix store cleanup failed"
    fi
    
    # Optimise store (may require sudo for hardlinking in /nix/store)
    # Try new CLI first, fall back to classic nix-store --optimise (works without experimental features)
    if nix store optimise 2>/dev/null; then
      echo "  Nix store optimised successfully"
    elif sudo nix-store --optimise 2>/dev/null; then
      echo "  Nix store optimised successfully (via sudo)"
    else
      echo "  ${RED}WARNING:${NC} Nix store optimisation failed"
    fi
    
    # Smart Nix CLI upgrade check (preview and auto-skip downgrades)
    echo "  Checking for Nix CLI updates..."
    local current_nix_version
    current_nix_version=$(nix --version 2>/dev/null | head -n1 | sed 's/nix (Nix) //' || echo "")
    
    if [[ -n "$current_nix_version" && "$current_nix_version" != "not in PATH" && "$current_nix_version" != "unknown" ]]; then
      # Run preview (dry-run) to check target version
      local upgrade_preview
      upgrade_preview=$(sudo -H nix upgrade-nix --dry-run --profile /nix/var/nix/profiles/default 2>&1 || echo "")
      
      if [[ -n "$upgrade_preview" ]]; then
        # Parse target version from preview output
        local nix_target_version=""
        nix_target_version=$(echo "$upgrade_preview" | grep -iE "would upgrade to version|upgrade to" | sed -E 's/.*[vV]?([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -1 || echo "")
        
        # Only process if we have a valid target version (suppress debug output)
        if [[ -n "$nix_target_version" && "$nix_target_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$nix_target_version" != "$current_nix_version" ]]; then
          # Compare versions
          local current_major current_minor current_patch
          local target_major target_minor target_patch
          
          IFS='.' read -r current_major current_minor current_patch <<< "$current_nix_version"
          IFS='.' read -r target_major target_minor target_patch <<< "$nix_target_version"

          # Normalize: strip non-numeric suffixes (e.g., "10pre20241025" -> "10") and default to 0
          current_patch="${current_patch%%[!0-9]*}"; [[ -z "$current_patch" ]] && current_patch=0
          target_patch="${target_patch%%[!0-9]*}"; [[ -z "$target_patch" ]] && target_patch=0
          current_major="${current_major%%[!0-9]*}"; [[ -z "$current_major" ]] && current_major=0
          current_minor="${current_minor%%[!0-9]*}"; [[ -z "$current_minor" ]] && current_minor=0
          target_major="${target_major%%[!0-9]*}"; [[ -z "$target_major" ]] && target_major=0
          target_minor="${target_minor%%[!0-9]*}"; [[ -z "$target_minor" ]] && target_minor=0
          
          # Check if it's a downgrade
          local is_downgrade=false
          if [[ "$current_major" -gt "$target_major" ]] || \
             ([[ "$current_major" -eq "$target_major" ]] && [[ "$current_minor" -gt "$target_minor" ]]) || \
             ([[ "$current_major" -eq "$target_major" ]] && [[ "$current_minor" -eq "$target_minor" ]] && [[ "$current_patch" -gt "$target_patch" ]]); then
            is_downgrade=true
          fi
          
          if [[ "$is_downgrade" == "true" ]]; then
            echo "  ${RED}WARNING:${NC} Nix CLI upgrade skipped: would downgrade ($current_nix_version -> $nix_target_version)"
            echo "  nix upgrade-nix follows nixpkgs fallback and may be older than installed Nix"
          else
            echo "  ${BLUE}INFO:${NC} Nix CLI upgrade available: $current_nix_version -> $nix_target_version"
            echo "  To upgrade: sudo -H nix upgrade-nix --profile /nix/var/nix/profiles/default"
          fi
        else
          echo "  Nix CLI is up to date ($current_nix_version)"
        fi
      else
        echo "  Could not check Nix CLI upgrade (preview requires sudo or nix not properly configured)"
      fi
    else
      echo "  Could not determine current Nix version"
    fi
    
    # Fix Oh My Zsh compaudit issues if present (only if Oh My Zsh is loaded)
    # Note: compaudit is an Oh My Zsh function, so it's only available if Oh My Zsh is sourced
    if [[ -n "${ZSH:-}" ]] && [[ -f "$ZSH/oh-my-zsh.sh" ]] && command -v compaudit >/dev/null 2>&1; then
      local insecure_dirs
      insecure_dirs=$(compaudit 2>&1 || true)
      if [[ -n "$insecure_dirs" ]]; then
        echo "  Fixing Oh My Zsh insecure completion directories..."
        if echo "$insecure_dirs" | xargs -I {} chmod g-w,o-w {} 2>/dev/null; then
          echo "  Oh My Zsh permissions fixed"
        else
          echo "  ${RED}WARNING:${NC} Could not fix Oh My Zsh permissions (may require sudo)"
        fi
      fi
    fi
    
    if [[ ${#nix_errors[@]} -gt 0 ]]; then
      echo "  Nix issues: ${nix_errors[*]}"
    fi
  fi

  hash -r 2>/dev/null || true
  _ensure_system_path
  echo "${GREEN}==> Update finished $(date)${NC}"
}

# ================================ VERIFY ===================================

verify() {
  _ensure_system_path || true
  echo "${GREEN}==> Verify $(date)${NC}"
  local ok warn miss
  ok()   { printf "%-15s OK (%s)\n" "$1" "$2"; }
  warn() { printf "%-15s ${RED}WARN${NC} (%s)\n" "$1" "$2"; }
  miss() { printf "%-15s Not installed\n" "$1"; }

  if command -v ruby >/dev/null 2>&1; then
    ok "Ruby" "$(ruby -v)"
    command -v gem >/dev/null 2>&1 && ok "Gem" "$(gem -v)"
    # Source chruby if not already a shell function (zsh.sh sources it in login
    # shells, but this script can be run without the shell init path)
    if ! type chruby >/dev/null 2>&1; then
      [[ -f /usr/local/share/chruby/chruby.sh ]] && source /usr/local/share/chruby/chruby.sh 2>/dev/null || true
      [[ -f "$HOME/.local/share/chruby/chruby.sh" ]] && source "$HOME/.local/share/chruby/chruby.sh" 2>/dev/null || true
      if ! type chruby >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
        local chruby_path="$(brew --prefix chruby 2>/dev/null || echo "")"
        [[ -n "$chruby_path" && -f "$chruby_path/share/chruby/chruby.sh" ]] && source "$chruby_path/share/chruby/chruby.sh" 2>/dev/null || true
      fi
    fi
    if type chruby >/dev/null 2>&1; then
      local chruby_version="$(chruby --version 2>/dev/null | head -n1)"
      if [[ -n "$chruby_version" ]]; then
        ok "chruby" "$chruby_version"
      else
        ok "chruby" "installed"
      fi
    fi
  else
    if type chruby >/dev/null 2>&1 || [[ -f /usr/local/share/chruby/chruby.sh ]] || [[ -f "$HOME/.local/share/chruby/chruby.sh" ]]; then
      warn "Ruby" "not installed (run 'update' to install)"
    else
      miss "Ruby"
      echo "  ${BLUE}INFO:${NC} To install Ruby and chruby, run: 'dev-tools'"
    fi
  fi

  local pybin="$(command -v python3 || command -v python || true)"
  if [[ -n "$pybin" ]]; then
    # When pyenv is active with a non-system version, show pyenv-managed version as primary
    if command -v pyenv >/dev/null 2>&1; then
      local active_py="$(pyenv version-name 2>/dev/null || true)"
      local latest_py="$(_pyenv_latest_installed)"
      if [[ -n "$active_py" && "$active_py" != "system" ]]; then
        ok "Python" "Python $active_py (pyenv)"
        # Check for Homebrew python that differs from pyenv
        local brew_python=""
        local brew_pfx="$(_detect_brew_prefix)"
        if [[ -n "$brew_pfx" && -x "$brew_pfx/bin/python3" ]]; then
          brew_python="$("$brew_pfx/bin/python3" -V 2>/dev/null || true)"
        fi
        local brew_py_short="${brew_python#Python }"
        if [[ -n "$brew_python" && "$brew_py_short" != "$active_py" ]]; then
          echo "  ${BLUE}INFO:${NC} Homebrew python3 is $brew_python"
        fi
      else
        ok "Python" "$("$pybin" -V 2>/dev/null)"
      fi
      if [[ -n "$latest_py" && "$active_py" == "$latest_py" ]]; then
        ok "pyenv" "active $active_py"
      else
        warn "pyenv" "active ${active_py:-unknown}; latest ${latest_py:-unknown}"
      fi
    else
      ok "Python" "$("$pybin" -V 2>/dev/null)"
    fi
    # Check for pip (try pip, pip3, or python3 -m pip)
    local pip_cmd=""
    if command -v pip >/dev/null 2>&1; then
      pip_cmd="pip"
    elif command -v pip3 >/dev/null 2>&1; then
      pip_cmd="pip3"
    elif "$pybin" -m pip --version >/dev/null 2>&1; then
      pip_cmd="$pybin -m pip"
    fi
    if [[ -n "$pip_cmd" ]]; then
      ok "pip" "$($pip_cmd --version 2>/dev/null | head -n1 || echo "available")"
    else
      warn "pip" "not in PATH"
    fi
    command -v pipx >/dev/null 2>&1 && ok "pipx" "$(pipx --version 2>/dev/null || echo "installed")"
    if command -v conda >/dev/null 2>&1; then
      ok "conda" "$(conda --version 2>/dev/null || echo "installed")"
    else
      # Check for miniforge/anaconda in common locations
      local conda_paths=(
        "$HOME/miniforge3/bin/conda"
        "$HOME/miniforge/bin/conda"
        "$HOME/anaconda3/bin/conda"
        "$HOME/anaconda/bin/conda"
      )
      # Only add brew paths if brew is installed
      if command -v brew >/dev/null 2>&1; then
        local brew_prefix="$(brew --prefix 2>/dev/null || echo "")"
        if [[ -n "$brew_prefix" ]]; then
          conda_paths+=(
            "$brew_prefix/Caskroom/miniforge/base/bin/conda"
            "$brew_prefix/Caskroom/anaconda/base/bin/conda"
          )
        fi
      fi
      conda_paths+=(
        "/usr/local/miniforge3/bin/conda"
        "/usr/local/anaconda3/bin/conda"
      )
      local conda_found=false
      for path in "${conda_paths[@]}"; do
        if [[ -f "$path" ]]; then
          local conda_version="$("$path" --version 2>/dev/null || echo "installed")"
          warn "conda" "$conda_version (not in PATH)"
          conda_found=true
          break
        fi
      done
      if [[ "$conda_found" == false ]]; then
        miss "conda"
        echo "  ${BLUE}INFO:${NC} To install conda, run: 'dev-tools'"
      fi
    fi
  else
    if command -v pyenv >/dev/null 2>&1; then
      warn "Python" "not installed (run 'update' to install)"
    else
      miss "Python"
      echo "  ${BLUE}INFO:${NC} To install Python and pyenv, run: 'dev-tools'"
    fi
  fi

  # nvm is a shell function, check with type
  local nvm_loaded=false
  if type nvm >/dev/null 2>&1; then
    nvm_loaded=true
  elif [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
    source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" 2>/dev/null && nvm_loaded=true || true
  fi

  if command -v node >/dev/null 2>&1 || [[ "$nvm_loaded" == "true" ]]; then
    # When nvm is active with a non-system version, show nvm-managed version as primary
    if [[ "$nvm_loaded" == "true" ]]; then
      local nvm_current="$(nvm current 2>/dev/null || true)"
      local defv="$(nvm version default 2>/dev/null || true)"
      if [[ -n "$nvm_current" && "$nvm_current" != "system" && "$nvm_current" != "N/A" && "$nvm_current" != "none" ]]; then
        ok "Node" "$nvm_current (nvm)"
        # Check for Homebrew node that differs from nvm
        local brew_node=""
        local brew_pfx="$(_detect_brew_prefix)"
        if [[ -n "$brew_pfx" && -x "$brew_pfx/bin/node" ]]; then
          brew_node="$("$brew_pfx/bin/node" -v 2>/dev/null || true)"
        fi
        if [[ -n "$brew_node" && "$brew_node" != "$nvm_current" ]]; then
          echo "  ${BLUE}INFO:${NC} Homebrew node is $brew_node"
        fi
      else
        if command -v node >/dev/null 2>&1; then
          ok "Node" "$(node -v)"
        else
          warn "Node" "not installed (nvm active but no version selected)"
        fi
      fi
      if command -v npm >/dev/null 2>&1; then ok "npm" "$(npm -v)"; else warn "npm" "not in PATH"; fi
      if [[ -n "$defv" && "$nvm_current" == "$defv" ]]; then
        ok "nvm" "current $nvm_current"
      else
        warn "nvm" "current ${nvm_current:-N/A}; default ${defv:-N/A}"
      fi
    else
      ok "Node" "$(node -v)"
      if command -v npm >/dev/null 2>&1; then ok "npm" "$(npm -v)"; else warn "npm" "not in PATH"; fi
    fi
  else
    miss "Node"
    echo "  ${BLUE}INFO:${NC} To install Node.js and nvm, run: 'dev-tools'"
  fi

  if command -v rustc >/dev/null 2>&1; then
    ok "Rust" "$(rustc -V)"
  else
    if command -v rustup >/dev/null 2>&1; then
      warn "Rust" "not installed (run 'update' to install)"
    else
      miss "Rust"
      echo "  ${BLUE}INFO:${NC} To install Rust and rustup, run: 'dev-tools'"
    fi
  fi
  if command -v rustup >/dev/null 2>&1; then
    local active="$(rustup show active-toolchain 2>/dev/null | head -n1)"
    if [[ "$active" == stable* ]]; then ok "rustup" "$active"; else warn "rustup" "$active"; fi
  fi
  command -v cargo >/dev/null 2>&1 && ok "Cargo" "$(cargo --version 2>/dev/null || echo "installed")"

  # .NET
  if command -v dotnet >/dev/null 2>&1; then
    local dotnet_version="$(dotnet --version 2>/dev/null || echo "unknown")"
    local dotnet_sdks=""
    dotnet_sdks="$(dotnet --list-sdks 2>/dev/null | wc -l | tr -d ' ' || echo "0")"
    if [[ "$dotnet_sdks" -gt 0 ]]; then
      ok ".NET" "$dotnet_version ($dotnet_sdks SDK(s))"
    else
      ok ".NET" "$dotnet_version"
    fi
  else
    miss ".NET"
    echo "  ${BLUE}INFO:${NC} To install .NET SDK, run: 'dev-tools'"
  fi

  # Swift
  if command -v swift >/dev/null 2>&1; then
    local swift_version="$(swift --version 2>/dev/null | head -n1 | sed 's/.*version //' | cut -d' ' -f1 || echo "unknown")"
    local swift_source=""
    
    # Check if Swift is from swiftly
    if command -v swiftly >/dev/null 2>&1; then
      # swiftly list shows "(in use)" for active version, not "*"
      local swiftly_current="$(swiftly list 2>/dev/null | grep -E '\(in use\)' | sed 's/Swift //' | sed 's/ (in use).*//' | awk '{print $1}' || echo "")"
      if [[ -n "$swiftly_current" ]]; then
        swift_source=" (swiftly: $swiftly_current)"
        # Check if it's a snapshot
        if [[ "$swiftly_current" == *"snapshot"* ]] || [[ "$swiftly_current" == *"main"* ]]; then
          swift_source="${swift_source} [snapshot]"
        fi
        ok "Swift" "$swift_version$swift_source"
        ok "swiftly" "active $swiftly_current"
      else
        local swiftly_installed="$(swiftly list 2>/dev/null | head -n1 || echo "")"
        if [[ -n "$swiftly_installed" ]]; then
          ok "Swift" "$swift_version (system/Homebrew, swiftly installed but not active)"
          ok "swiftly" "installed (no active version)"
        else
          ok "Swift" "$swift_version (system/Homebrew)"
          warn "swiftly" "installed but no versions installed"
        fi
      fi
    else
      ok "Swift" "$swift_version (system/Homebrew)"
    fi
  else
    if command -v swiftly >/dev/null 2>&1; then
      warn "Swift" "not installed (run 'update' to install)"
      local swiftly_installed="$(swiftly list 2>/dev/null | head -n1 || echo "")"
      if [[ -n "$swiftly_installed" ]]; then
        warn "swiftly" "installed but Swift not in PATH"
      else
        warn "swiftly" "installed but not initialized"
      fi
    else
      miss "Swift"
      echo "  ${BLUE}INFO:${NC} To install Swift and swiftly, run: 'dev-tools'"
    fi
  fi

  if command -v go >/dev/null 2>&1; then
    ok "Go" "$(go version)"
  else
    miss "Go"
    echo "  ${BLUE}INFO:${NC} To install Go, run: 'dev-tools'"
  fi
  if command -v java >/dev/null 2>&1; then
    ok "Java" "$(java -version 2>&1 | head -n1)"
  else
    miss "Java"
    echo "  ${BLUE}INFO:${NC} To install Java, run: 'dev-tools'"
  fi
  if command -v clang >/dev/null 2>&1; then ok "Clang" "$(clang --version | head -n1)"; else miss "Clang"; fi
  if command -v gcc >/dev/null 2>&1; then ok "GCC" "$(gcc --version | head -n1)"; else warn "GCC" "not found"; fi
  
  # Detect MySQL dynamically
  local mysql_found=false
  if command -v mysql >/dev/null 2>&1; then
    ok "MySQL" "$(mysql --version)"
    mysql_found=true
  else
    # Check common MySQL installation locations
    local mysql_paths=(
      "/usr/local/mysql/bin/mysql"
      "/opt/homebrew/opt/mysql/bin/mysql"
      "/opt/homebrew/opt/mariadb/bin/mysql"
    )
    # Only add brew paths if brew is installed
    if command -v brew >/dev/null 2>&1; then
      local brew_mysql_prefix="$(brew --prefix mysql 2>/dev/null || echo "")"
      local brew_mariadb_prefix="$(brew --prefix mariadb 2>/dev/null || echo "")"
      [[ -n "$brew_mysql_prefix" ]] && mysql_paths+=("$brew_mysql_prefix/bin/mysql")
      [[ -n "$brew_mariadb_prefix" ]] && mysql_paths+=("$brew_mariadb_prefix/bin/mysql")
    fi
    
    for mysql_path in "${mysql_paths[@]}"; do
      if [[ -x "$mysql_path" ]]; then
        ok "MySQL" "$("$mysql_path" --version)"
        mysql_found=true
        break
      fi
    done
    
    if [[ "$mysql_found" == false ]]; then
      warn "MySQL" "not found"
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    ok "Docker" "$(docker -v)"
    if command -v docker-compose >/dev/null 2>&1; then
      ok "Compose" "$(docker-compose -v)"
    elif docker compose version >/dev/null 2>&1; then
      ok "Compose" "$(docker compose version | head -n1)"
    else
      warn "Compose" "not found"
    fi
  else
    miss "Docker"
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_version="$(brew --version 2>/dev/null | head -n1 || echo "installed")"
    ok "Homebrew" "$brew_version"
  else
    miss "Homebrew"
    echo "  ${BLUE}INFO:${NC} To install Homebrew, run: 'sys-install'"
  fi
  if command -v port >/dev/null 2>&1; then
    local port_version="$(port version 2>/dev/null || echo "installed")"
    ok "MacPorts" "$port_version"
  else
    warn "MacPorts" "not installed"
    echo "  ${BLUE}INFO:${NC} To install MacPorts, run: 'sys-install'"
  fi

  # mas (Mac App Store CLI)
  if command -v mas >/dev/null 2>&1; then
    local mas_version="$(mas version 2>/dev/null || echo "installed")"
    local mas_app_count
    mas_app_count=$(mas list 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$mas_app_count" -gt 0 ]]; then
      ok "mas" "$mas_version ($mas_app_count App Store apps)"
    else
      ok "mas" "$mas_version (no App Store apps installed)"
    fi
  else
    miss "mas"
    echo "  ${BLUE}INFO:${NC} To install mas, run: 'sys-install'"
  fi

  # Nix - comprehensive status check
  if command -v nix >/dev/null 2>&1; then
    local nix_version="$(nix --version 2>/dev/null | head -n1 | sed 's/nix (Nix) //' || echo "unknown")"
    local nix_status=""
    
    # Check installation completeness
    if [[ -d /nix ]] && [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
      # Check daemon
      if pgrep -x nix-daemon >/dev/null 2>&1; then
        nix_status=" (daemon running)"
      else
        nix_status=" (daemon not running)"
      fi
      
      # Note: We don't show package count in verify - only in versions
      ok "Nix" "$nix_version$nix_status"
    else
      warn "Nix" "$nix_version (installation incomplete)"
    fi
  else
    # Check if Nix is installed but not in PATH
    if [[ -d /nix ]] && [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
      warn "Nix" "installed but not in PATH (run: ./scripts/nix-macos-maintenance.sh ensure-path or reinstall)"
    else
      miss "Nix"
      echo "  ${BLUE}INFO:${NC} To install Nix, run: 'sys-install'"
    fi
  fi

  if command -v mongod >/dev/null 2>&1; then
    local mongodb_version="$(mongod --version 2>/dev/null | head -n1 | sed 's/db version //' || echo "unknown")"
    local mongodb_status="stopped"
    if pgrep -x mongod >/dev/null 2>&1; then
      mongodb_status="running"
    fi
    ok "MongoDB" "$mongodb_version ($mongodb_status)"
  else
    miss "MongoDB"
  fi
  
  if command -v psql >/dev/null 2>&1; then
    local postgres_version="$(psql --version 2>/dev/null | sed 's/psql (PostgreSQL) //' | sed 's/ .*//' || echo "unknown")"
    local postgres_status="stopped"
    if pgrep -x postgres >/dev/null 2>&1; then
      postgres_status="running"
    fi
    ok "PostgreSQL" "$postgres_version ($postgres_status)"
  else
    miss "PostgreSQL"
  fi
  
  # Modern language tooling (installed via dev-tools.sh)
  for _tool in uv bun pnpm deno; do
    if command -v "$_tool" >/dev/null 2>&1; then
      ok "$_tool" "$("$_tool" --version 2>/dev/null | head -n1)"
    fi
  done
  # JVM ecosystem (opt-in batch in dev-tools.sh)
  for _tool in kotlin scala clojure gradle mvn groovy; do
    if command -v "$_tool" >/dev/null 2>&1; then
      ok "$_tool" "$("$_tool" --version 2>/dev/null | head -n1)"
    fi
  done
  unset _tool

  echo "${GREEN}==> Verify done${NC}"
  return 0
}

# ================================ VERSIONS ===================================

versions() {
  _ensure_system_path
  echo "${GREEN}================== TOOL VERSIONS ==================${NC}"
  if command -v ruby >/dev/null 2>&1; then
    echo "Ruby ........... $(ruby -v)"
  else
    echo "Ruby ........... not installed"
    echo "  To install: 'dev-tools'"
  fi
  command -v gem  >/dev/null 2>&1 && echo "Gem ............ $(gem -v)" || true
  # Check for chruby (shell function)
  local chruby_check=false
  if type chruby >/dev/null 2>&1; then
    chruby_check=true
  elif [[ -f /usr/local/share/chruby/chruby.sh ]] || [[ -f "$HOME/.local/share/chruby/chruby.sh" ]]; then
    # Try to source chruby
    [[ -f /usr/local/share/chruby/chruby.sh ]] && source /usr/local/share/chruby/chruby.sh 2>/dev/null && chruby_check=true || true
    [[ "$chruby_check" != "true" && -f "$HOME/.local/share/chruby/chruby.sh" ]] && source "$HOME/.local/share/chruby/chruby.sh" 2>/dev/null && chruby_check=true || true
    if [[ "$chruby_check" != "true" ]] && command -v brew >/dev/null 2>&1; then
      local chruby_path="$(brew --prefix chruby 2>/dev/null || echo "")"
      [[ -n "$chruby_path" && -f "$chruby_path/share/chruby/chruby.sh" ]] && source "$chruby_path/share/chruby/chruby.sh" 2>/dev/null && chruby_check=true || true
    fi
  fi
  
  if [[ "$chruby_check" == "true" ]]; then
    local chruby_version="$(chruby --version 2>/dev/null | head -n1)"
    if [[ -n "$chruby_version" ]]; then
      echo "chruby ......... $chruby_version"
    else
      echo "chruby ......... installed"
    fi
  fi

  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    # When pyenv is active with a non-system version, show pyenv-managed version as primary
    if command -v pyenv >/dev/null 2>&1; then
      local active_py="$(pyenv version-name 2>/dev/null || true)"
      if [[ -n "$active_py" && "$active_py" != "system" ]]; then
        echo "Python ......... Python $active_py (pyenv)"
        # Check for Homebrew python that differs from pyenv
        local brew_python=""
        local brew_pfx="$(_detect_brew_prefix)"
        if [[ -n "$brew_pfx" && -x "$brew_pfx/bin/python3" ]]; then
          brew_python="$("$brew_pfx/bin/python3" -V 2>/dev/null || true)"
        fi
        local brew_py_short="${brew_python#Python }"
        if [[ -n "$brew_python" && "$brew_py_short" != "$active_py" ]]; then
          echo "               (Homebrew: $brew_python)"
        fi
      else
        echo "Python ......... $(python3 -V 2>/dev/null || python -V 2>/dev/null)"
      fi
      echo "pyenv .......... $active_py"
    else
      echo "Python ......... $(python3 -V 2>/dev/null || python -V 2>/dev/null)"
    fi
    if command -v pip >/dev/null 2>&1; then
      local pip_version="$(pip -V | awk '{print $2}')"
      local pip_count="$(pip list 2>/dev/null | tail -n +3 | wc -l | tr -d ' ' || echo "0")"
      echo "pip ............ $pip_version ($pip_count packages)"
    elif command -v pip3 >/dev/null 2>&1; then
      local pip_version="$(pip3 -V | awk '{print $2}')"
      local pip_count="$(pip3 list 2>/dev/null | tail -n +3 | wc -l | tr -d ' ' || echo "0")"
      echo "pip ............ $pip_version ($pip_count packages)"
    elif python3 -m pip --version >/dev/null 2>&1; then
      local pip_version="$(python3 -m pip --version 2>/dev/null | awk '{print $2}')"
      local pip_count="$(python3 -m pip list 2>/dev/null | tail -n +3 | wc -l | tr -d ' ' || echo "0")"
      echo "pip ............ $pip_version ($pip_count packages)"
    fi
    if command -v pipx >/dev/null 2>&1; then
      local pipx_version="$(pipx --version 2>/dev/null || echo "installed")"
      local pipx_count="$(pipx list --short 2>/dev/null | grep -v '^$' | wc -l | tr -d ' ' || echo "0")"
      echo "pipx ........... $pipx_version ($pipx_count packages)"
    fi
    if command -v conda >/dev/null 2>&1; then
      local conda_version="$(conda --version 2>/dev/null || echo "installed")"
      local conda_count="$(conda list 2>/dev/null | tail -n +4 | wc -l | tr -d ' ' || echo "0")"
      echo "conda .......... $conda_version ($conda_count packages)"
    else
      # Check for miniforge/anaconda in common locations
      local conda_paths=(
        "$HOME/miniforge3/bin/conda"
        "$HOME/miniforge/bin/conda"
        "$HOME/anaconda3/bin/conda"
        "$HOME/anaconda/bin/conda"
      )
      # Only add brew paths if brew is installed
      if command -v brew >/dev/null 2>&1; then
        local brew_prefix="$(brew --prefix 2>/dev/null || echo "")"
        if [[ -n "$brew_prefix" ]]; then
          conda_paths+=(
            "$brew_prefix/Caskroom/miniforge/base/bin/conda"
            "$brew_prefix/Caskroom/anaconda/base/bin/conda"
          )
        fi
      fi
      conda_paths+=(
        "/usr/local/miniforge3/bin/conda"
        "/usr/local/anaconda3/bin/conda"
      )
      for path in "${conda_paths[@]}"; do
        if [[ -f "$path" ]]; then
          local conda_version="$("$path" --version 2>/dev/null || echo "installed")"
          local conda_count=""
          if "$path" list 2>/dev/null | tail -n +4 >/dev/null 2>&1; then
            conda_count="$("$path" list 2>/dev/null | tail -n +4 | wc -l | tr -d ' ' || echo "0")"
            if [[ "$conda_count" -gt 0 ]]; then
              echo "conda .......... $conda_version ($conda_count packages, not in PATH)"
            else
              echo "conda .......... $conda_version (no packages, not in PATH)"
            fi
          else
            echo "conda .......... $conda_version (not in PATH)"
          fi
          break
        fi
      done
    fi
  else
    echo "Python ......... not installed"
    echo "  To install: 'dev-tools'"
  fi

  # nvm is a shell function, check with type
  local nvm_loaded=false
  if type nvm >/dev/null 2>&1; then
    nvm_loaded=true
  elif [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
    source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" 2>/dev/null && nvm_loaded=true || true
  fi

  if command -v node >/dev/null 2>&1 || [[ "$nvm_loaded" == "true" ]]; then
    # When nvm is active with a non-system version, show nvm-managed version as primary
    if [[ "$nvm_loaded" == "true" ]]; then
      local nvm_current="$(nvm current 2>/dev/null || true)"
      if [[ -n "$nvm_current" && "$nvm_current" != "system" && "$nvm_current" != "N/A" && "$nvm_current" != "none" ]]; then
        echo "Node.js ........ $nvm_current (nvm)"
        # Check for Homebrew node that differs from nvm
        local brew_node=""
        local brew_pfx="$(_detect_brew_prefix)"
        if [[ -n "$brew_pfx" && -x "$brew_pfx/bin/node" ]]; then
          brew_node="$("$brew_pfx/bin/node" -v 2>/dev/null || true)"
        fi
        if [[ -n "$brew_node" && "$brew_node" != "$nvm_current" ]]; then
          echo "               (Homebrew: $brew_node)"
        fi
      else
        echo "Node.js ........ $(node -v 2>/dev/null || echo "not installed")"
      fi
      echo "nvm ............ ${nvm_current:-not active}"
    else
      echo "Node.js ........ $(node -v)"
    fi
    if command -v npm >/dev/null 2>&1; then
      local npm_version="$(npm -v)"
      local npm_count="$(npm list -g --depth=0 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || echo "0")"
      echo "npm ............ $npm_version ($npm_count global packages)"
    fi
  else
    echo "Node.js ........ not installed"
    echo "  To install: 'dev-tools'"
  fi

  if command -v rustc >/dev/null 2>&1; then
    echo "Rust ........... $(rustc -V)"
  else
    echo "Rust ........... not installed"
    echo "  To install: 'dev-tools'"
  fi
  command -v rustup >/dev/null 2>&1 && echo "rustup ......... $(rustup show active-toolchain 2>/dev/null | head -n1)" || true
  if command -v cargo >/dev/null 2>&1; then
    local cargo_version="$(cargo --version 2>/dev/null || echo "installed")"
    local cargo_count="$(cargo install --list 2>/dev/null | grep -E '^[a-z]' | wc -l | tr -d ' ' || echo "0")"
    echo "Cargo .......... $cargo_version ($cargo_count packages)"
  fi
  
  if command -v dotnet >/dev/null 2>&1; then
    local dotnet_version="$(dotnet --version 2>/dev/null || echo "unknown")"
    local dotnet_info="$dotnet_version"
    
    # Check for installed SDKs
    local dotnet_sdks=""
    dotnet_sdks="$(dotnet --list-sdks 2>/dev/null | wc -l | tr -d ' ' || echo "0")"
    if [[ "$dotnet_sdks" -gt 0 ]]; then
      dotnet_info="$dotnet_version ($dotnet_sdks SDK(s) installed)"
    fi
    echo ".NET ........... $dotnet_info"
  else
    echo ".NET ........... not installed"
    echo "  To install: 'dev-tools'"
  fi

  if command -v swift >/dev/null 2>&1; then
    local swift_version="$(swift --version 2>/dev/null | head -n1 | sed 's/.*version //' | cut -d' ' -f1 || echo "unknown")"
    local swift_info="$swift_version"
    
    if command -v swiftly >/dev/null 2>&1; then
      # swiftly list shows "(in use)" for active version, not "*"
      local swiftly_current="$(swiftly list 2>/dev/null | grep -E '\(in use\)' | sed 's/Swift //' | sed 's/ (in use).*//' | awk '{print $1}' || echo "")"
      if [[ -n "$swiftly_current" ]]; then
        swift_info="$swift_version (swiftly: $swiftly_current)"
        # Check if it's a snapshot
        if [[ "$swiftly_current" == *"snapshot"* ]] || [[ "$swiftly_current" == *"main"* ]]; then
          swift_info="${swift_info} [snapshot]"
        fi
        echo "Swift .......... $swift_info"
        echo "swiftly ........ active $swiftly_current"
      else
        local swiftly_installed="$(swiftly list 2>/dev/null | head -n1 || echo "")"
        if [[ -n "$swiftly_installed" ]]; then
          echo "Swift .......... $swift_version (system/Homebrew, swiftly installed)"
          echo "swiftly ........ installed (no active version)"
        else
          echo "Swift .......... $swift_version (system/Homebrew)"
          echo "swiftly ........ installed (not initialized)"
        fi
      fi
    else
      echo "Swift .......... $swift_version (system/Homebrew)"
    fi
  else
    echo "Swift .......... not installed"
    echo "  To install: 'dev-tools'"
    if command -v swiftly >/dev/null 2>&1; then
      local swiftly_installed
      swiftly_installed="$(swiftly list 2>/dev/null | head -n1 || echo "")"
      [[ -n "$swiftly_installed" ]] && echo "swiftly ........ installed (Swift not in PATH)" || echo "swiftly ........ installed (not initialized)"
    fi
  fi

  if command -v go >/dev/null 2>&1; then
    echo "Go ............. $(go version)"
  else
    echo "Go ............. not installed"
    echo "  To install: 'dev-tools'"
  fi
  if command -v java >/dev/null 2>&1; then
    echo "Java ........... $(java -version 2>&1 | head -n1)"
  else
    echo "Java ........... not installed"
    echo "  To install: 'dev-tools'"
  fi
  if command -v clang >/dev/null 2>&1; then
    echo "Clang .......... $(clang --version | head -n1)"
  else
    echo "Clang .......... not installed"
    echo "  To install: xcode-select --install"
  fi
  if command -v gcc >/dev/null 2>&1; then
    echo "GCC ............ $(gcc --version | head -n1)"
  else
    echo "GCC ............ not installed"
    echo "  To install: xcode-select --install"
  fi

  # Detect MySQL dynamically
  local mysql_found=false
  if command -v mysql >/dev/null 2>&1; then
    echo "MySQL .......... $(mysql --version)"
    mysql_found=true
  else
    # Check common MySQL installation locations
    local mysql_paths=(
      "/usr/local/mysql/bin/mysql"
      "/opt/homebrew/opt/mysql/bin/mysql"
      "/opt/homebrew/opt/mariadb/bin/mysql"
    )
    # Only add brew paths if brew is installed
    if command -v brew >/dev/null 2>&1; then
      local brew_mysql_prefix="$(brew --prefix mysql 2>/dev/null || echo "")"
      local brew_mariadb_prefix="$(brew --prefix mariadb 2>/dev/null || echo "")"
      [[ -n "$brew_mysql_prefix" ]] && mysql_paths+=("$brew_mysql_prefix/bin/mysql")
      [[ -n "$brew_mariadb_prefix" ]] && mysql_paths+=("$brew_mariadb_prefix/bin/mysql")
    fi
    
    for mysql_path in "${mysql_paths[@]}"; do
      if [[ -x "$mysql_path" ]]; then
        echo "MySQL .......... $("$mysql_path" --version)"
        mysql_found=true
        break
      fi
    done
    
    if [[ "$mysql_found" == false ]]; then
      echo "MySQL .......... not installed"
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    echo "Docker ......... $(docker -v)"
    if command -v docker-compose >/dev/null 2>&1; then
      echo "Compose ........ $(docker-compose -v)"
    elif docker compose version >/dev/null 2>&1; then
      echo "Compose ........ $(docker compose version | head -n1)"
    fi
  else
    echo "Docker ......... not installed"
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_version="$(brew --version | head -n1)"
    local brew_count="$(brew list --formula 2>/dev/null | wc -l | tr -d ' ' || echo "0")"
    echo "Homebrew ....... $brew_version ($brew_count formulae)"
  else
    echo "Homebrew ....... not installed"
    echo "  To install: 'sys-install'"
  fi
  if command -v port >/dev/null 2>&1; then
    local port_version="$(port version)"
    local port_count="$(port installed 2>/dev/null | grep -E '^[[:space:]]+[a-z]' | wc -l | tr -d ' ' || echo "0")"
    echo "MacPorts ....... $port_version ($port_count ports)"
  else
    echo "MacPorts ....... not installed"
    echo "  To install: 'sys-install'"
  fi

  # mas (Mac App Store CLI)
  if command -v mas >/dev/null 2>&1; then
    local mas_version="$(mas version 2>/dev/null || echo "installed")"
    local mas_app_count
    mas_app_count=$(mas list 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$mas_app_count" -gt 0 ]]; then
      echo "mas ............. $mas_version ($mas_app_count App Store apps)"
    else
      echo "mas ............. $mas_version (no App Store apps)"
    fi
  else
    echo "mas ............. not installed"
    echo "  To install: 'sys-install'"
  fi

  # Nix
  if command -v nix >/dev/null 2>&1; then
    local nix_version
    nix_version="$(nix --version 2>/dev/null | head -n1 | sed 's/nix (Nix) //' || echo "unknown")"
    local profile_count
    profile_count=$(nix profile list 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    local env_count
    env_count=$(nix-env -q 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    local total_count=$((profile_count + env_count))
    if [[ "$total_count" -gt 0 ]]; then
      local pkg_info=""
      if [[ "$profile_count" -gt 0 ]] && [[ "$env_count" -gt 0 ]]; then
        pkg_info="profile:$profile_count env:$env_count"
      elif [[ "$profile_count" -gt 0 ]]; then
        pkg_info="profile:$profile_count"
      elif [[ "$env_count" -gt 0 ]]; then
        pkg_info="env:$env_count"
      fi
      echo "Nix ............. $nix_version ($total_count packages: $pkg_info)"
    else
      echo "Nix ............. $nix_version (0 packages)"
    fi
  else
    echo "Nix ............. not installed"
    echo "  To install: 'sys-install'"
  fi

  if command -v mongod >/dev/null 2>&1; then
    local mongodb_version
    mongodb_version="$(mongod --version 2>/dev/null | head -n1 | sed 's/db version //' || echo "unknown")"
    local mongodb_status="stopped"
    if pgrep -x mongod >/dev/null 2>&1; then
      mongodb_status="running"
    fi
    echo "MongoDB ........ $mongodb_version ($mongodb_status)"
  else
    echo "MongoDB ........ not installed"
  fi
  
  if command -v psql >/dev/null 2>&1; then
    local postgres_version
    postgres_version="$(psql --version 2>/dev/null | sed 's/psql (PostgreSQL) //' | sed 's/ .*//' || echo "unknown")"
    local postgres_status="stopped"
    if pgrep -x postgres >/dev/null 2>&1; then
      postgres_status="running"
    fi
    echo "PostgreSQL ..... $postgres_version ($postgres_status)"
  else
    echo "PostgreSQL ..... not installed"
  fi
  
  # Modern language tooling (installed via dev-tools.sh)
  for _tool in uv bun pnpm deno; do
    if command -v "$_tool" >/dev/null 2>&1; then
      printf '%-15s %s\n' "$_tool" "$("$_tool" --version 2>/dev/null | head -n1)"
    fi
  done
  # JVM ecosystem (opt-in batch in dev-tools.sh)
  for _tool in kotlin scala clojure gradle mvn groovy; do
    if command -v "$_tool" >/dev/null 2>&1; then
      printf '%-15s %s\n' "$_tool" "$("$_tool" --version 2>/dev/null | head -n1)"
    fi
  done
  unset _tool

  echo "${GREEN}===================================================${NC}"
  return 0
}

# ================================ SELF-UPGRADE =============================

readonly GITHUB_REPO="26zl/macsmith"
readonly DATA_DIR="$HOME/.local/share/macsmith"

_self_upgrade() {
  echo "${GREEN}=== macsmith - Self-Upgrade ===${NC}"
  echo ""

  # Read local version
  local local_version=""
  if [[ -f "$DATA_DIR/version" ]]; then
    local_version="$(<"$DATA_DIR/version")"
  fi

  if [[ -z "$local_version" ]]; then
    echo "${RED}❌ No local version found${NC}"
    echo "  Run 'sys-install' first to set up version tracking."
    return 1
  fi

  echo "Current version: ${BLUE}$local_version${NC}"

  # Fetch latest release from GitHub API
  echo "Checking for updates..."
  local api_response=""
  api_response="$(curl -s --connect-timeout 15 --max-time 30 --retry 3 "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null)"
  if [[ -z "$api_response" ]]; then
    echo "${RED}❌ Failed to reach GitHub API${NC}"
    return 1
  fi

  local remote_version=""
  remote_version="$(echo "$api_response" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  if [[ -z "$remote_version" ]]; then
    echo "${RED}❌ Could not parse latest release version${NC}"
    echo "  Check https://github.com/$GITHUB_REPO/releases"
    return 1
  fi

  echo "Latest version:  ${BLUE}$remote_version${NC}"

  # Compare versions
  if [[ "$local_version" == "$remote_version" ]]; then
    echo ""
    echo "${GREEN}✅ Already up to date${NC}"
    # Clear cached remote version
    rm -f "$DATA_DIR/latest-remote-version"
    return 0
  fi

  echo ""
  echo "Upgrading ${BLUE}$local_version${NC} -> ${BLUE}$remote_version${NC}"

  # Prefer our signed release asset (has matching .sha256) over GitHub's
  # auto-generated zipball_url which has no checksum we publish.
  local asset_url="" sha_url="" zipball_url=""
  asset_url="$(echo "$api_response" | sed -n 's/.*"browser_download_url": *"\(https:\/\/[^"]*macsmith-[^"]*\.zip\)".*/\1/p' | grep -v '\.sha256' | head -n1)"
  sha_url="$(echo "$api_response" | sed -n 's/.*"browser_download_url": *"\(https:\/\/[^"]*macsmith-[^"]*\.zip\.sha256\)".*/\1/p' | head -n1)"
  zipball_url="$(echo "$api_response" | sed -n 's/.*"zipball_url": *"\([^"]*\)".*/\1/p')"

  local tmp_dir=""
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"; rm -f "$LOCK_FILE"' EXIT INT TERM HUP

  # Download + verify against published SHA-256 when possible
  if [[ -n "$asset_url" ]] && [[ -n "$sha_url" ]]; then
    echo "Downloading release asset ($asset_url)..."
    if ! curl -sL --connect-timeout 15 --max-time 120 --retry 3 "$asset_url" -o "$tmp_dir/release.zip" 2>/dev/null; then
      echo "${RED}❌ Asset download failed${NC}"
      rm -rf "$tmp_dir"
      return 1
    fi
    echo "Fetching checksum..."
    if ! curl -sL --connect-timeout 15 --max-time 60 --retry 3 "$sha_url" -o "$tmp_dir/release.zip.sha256" 2>/dev/null; then
      echo "${YELLOW}⚠️  Could not fetch checksum; aborting to be safe${NC}"
      rm -rf "$tmp_dir"
      return 1
    fi
    # The .sha256 file format is: "<hash>  <filename>"
    local expected_sha actual_sha
    expected_sha="$(awk '{print $1}' "$tmp_dir/release.zip.sha256")"
    actual_sha="$(shasum -a 256 "$tmp_dir/release.zip" | awk '{print $1}')"
    if [[ -z "$expected_sha" ]] || [[ "$expected_sha" != "$actual_sha" ]]; then
      echo "${RED}❌ SHA-256 mismatch — refusing to install.${NC}"
      echo "  expected: $expected_sha"
      echo "  actual:   $actual_sha"
      rm -rf "$tmp_dir"
      return 1
    fi
    echo "${GREEN}✅ Checksum verified${NC}"
  elif [[ -n "$zipball_url" ]]; then
    # Fallback: no packaged asset found (pre-release-pipeline tags etc.).
    # This path is UNVERIFIED — refuse by default and require explicit opt-in.
    if [[ "${MACSMITH_ALLOW_UNSIGNED_UPGRADE:-0}" != "1" ]]; then
      echo "${RED}❌ Refusing to upgrade: no signed release asset for this tag.${NC}"
      echo "  The only available source is GitHub's auto-generated zipball, which"
      echo "  has no matching checksum we publish, so we cannot verify its integrity."
      echo ""
      echo "  Options:"
      echo "    1. Wait for a tag cut through the release pipeline (it ships .sha256)."
      echo "    2. Pull manually: git pull && ./install.sh"
      echo "    3. Opt in explicitly: MACSMITH_ALLOW_UNSIGNED_UPGRADE=1 macsmith upgrade"
      rm -rf "$tmp_dir"
      return 1
    fi
    echo "${YELLOW}⚠️  MACSMITH_ALLOW_UNSIGNED_UPGRADE=1 — downloading UNVERIFIED zipball.${NC}"
    if ! curl -sL --connect-timeout 15 --max-time 120 --retry 3 "$zipball_url" -o "$tmp_dir/release.zip" 2>/dev/null; then
      echo "${RED}❌ Download failed${NC}"
      rm -rf "$tmp_dir"
      return 1
    fi
  else
    echo "${RED}❌ Could not find download URL${NC}"
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! unzip -q "$tmp_dir/release.zip" -d "$tmp_dir" 2>/dev/null; then
    echo "${RED}❌ Failed to extract release${NC}"
    rm -rf "$tmp_dir"
    return 1
  fi

  # Find the extracted directory (GitHub zips contain a single top-level dir)
  local extract_dir=""
  extract_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [[ -z "$extract_dir" ]] || [[ ! -d "$extract_dir" ]]; then
    echo "${RED}❌ Unexpected archive structure${NC}"
    rm -rf "$tmp_dir"
    return 1
  fi

  # Track failures
  local upgrade_failed=false

  # Update macsmith binary. Write to a temp file next to the target
  # then mv into place so Ctrl-C can't leave the binary half-written (and
  # since we ARE that binary, a partial write would brick ourselves).
  local local_bin="$HOME/.local/bin"
  mkdir -p "$local_bin" 2>/dev/null || true
  if [[ -f "$extract_dir/macsmith.sh" ]]; then
    local _ms_tmp="${local_bin}/.macsmith.tmp.$$"
    if cp "$extract_dir/macsmith.sh" "$_ms_tmp" \
       && chmod +x "$_ms_tmp" \
       && mv -f "$_ms_tmp" "$local_bin/macsmith"; then
      echo "  Updated: macsmith"
    else
      rm -f "$_ms_tmp" 2>/dev/null || true
      echo "  ${RED}Failed: macsmith (check permissions on $local_bin)${NC}"
      upgrade_failed=true
    fi
  fi

  # Update zsh.sh -> ~/.zshrc (preserve user customizations). Write atomically
  # via tempfile + mv so Ctrl-C can't leave a half-written shell config.
  if [[ -f "$extract_dir/zsh.sh" ]]; then
    local zshrc="$HOME/.zshrc"
    local new_zshrc_content
    new_zshrc_content="$(cat "$extract_dir/zsh.sh")"

    if [[ -f "$zshrc" ]]; then
      cp "$zshrc" "$zshrc.backup-$(date +%Y%m%d%H%M%S)"
      # Preserve content after the USER CUSTOMIZATIONS marker (excluding marker)
      local user_section=""
      if grep -q "# USER CUSTOMIZATIONS" "$zshrc" 2>/dev/null; then
        user_section="$(sed -n '/^# USER CUSTOMIZATIONS/,$p' "$zshrc" | tail -n +2)"
      fi
      if [[ -n "$user_section" ]]; then
        # If the new zsh.sh already includes the marker, the section belongs right after it
        if ! printf '%s' "$new_zshrc_content" | grep -q "# USER CUSTOMIZATIONS"; then
          new_zshrc_content+="
# USER CUSTOMIZATIONS
"
        else
          new_zshrc_content+="
"
        fi
        new_zshrc_content+="$user_section"
      fi
    fi

    local _zsh_tmp="${zshrc}.tmp.$$"
    if printf '%s\n' "$new_zshrc_content" > "$_zsh_tmp" && mv -f "$_zsh_tmp" "$zshrc"; then
      echo "  Updated: ~/.zshrc${user_section:+ (backup created)}"
    else
      rm -f "$_zsh_tmp" 2>/dev/null || true
      echo "  ${RED}Failed: ~/.zshrc (check permissions)${NC}"
      upgrade_failed=true
    fi
  fi

  # Copy scripts to data dir
  mkdir -p "$DATA_DIR"
  for script_file in install.sh dev-tools.sh bootstrap.sh zsh.sh macsmith.sh; do
    if [[ -f "$extract_dir/$script_file" ]]; then
      cp "$extract_dir/$script_file" "$DATA_DIR/$script_file" || true
    fi
  done

  # Cleanup temp dir
  rm -rf "$tmp_dir"

  # Only update version if all critical copies succeeded
  if [[ "$upgrade_failed" == true ]]; then
    echo ""
    echo "${RED}❌ Upgrade incomplete - version not updated${NC}"
    echo "  Fix the errors above and run upgrade again."
    return 1
  fi

  # Update version file
  echo "$remote_version" > "$DATA_DIR/version"

  # Clear cached remote version (removes notification)
  rm -f "$DATA_DIR/latest-remote-version"

  echo ""
  echo "${GREEN}✅ Upgraded to $remote_version${NC}"
  echo "  Restart your terminal to apply changes."
}

# ================================ MAIN =====================================
# Concurrent-run protection
LOCK_FILE="/tmp/macsmith-maintain.lock"
if [[ -f "$LOCK_FILE" ]]; then
  lock_pid=""
  lock_pid="$(<"$LOCK_FILE")"
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    echo "ERROR: Another instance of macsmith is already running (PID $lock_pid)"
    echo "  If this is a mistake, remove the lock file: rm $LOCK_FILE"
    exit 1
  fi
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM HUP

# Dispatch based on command argument
case "${1:-}" in
  update)
    update
    ;;
  verify)
    verify || true
    ;;
  versions)
    versions
    ;;
  upgrade|self-update)
    _self_upgrade
    ;;
  install)
    if [[ -f "$DATA_DIR/install.sh" ]]; then
      zsh "$DATA_DIR/install.sh"
    else
      echo "${RED}❌ install.sh not found${NC}"
      echo "  Run 'upgrade' first to download scripts."
      exit 1
    fi
    ;;
  dev-tools)
    if [[ -f "$DATA_DIR/dev-tools.sh" ]]; then
      zsh "$DATA_DIR/dev-tools.sh" "${@:2}"
    else
      echo "${RED}❌ dev-tools.sh not found${NC}"
      echo "  Run 'upgrade' first to download scripts."
      exit 1
    fi
    ;;
  *)
    echo "Usage: macsmith [update|verify|versions|upgrade|install|dev-tools]"
    echo ""
    echo "Commands:"
    echo "  update    - Update Homebrew, Python, Node.js, Ruby, Rust, and other tools"
    echo "  verify    - Verify installed tools and their versions"
    echo "  versions  - Display detailed version information for all tools"
    echo "  upgrade   - Update the setup scripts themselves from GitHub"
    echo "  install   - Re-run the base system setup (Homebrew, Oh My Zsh, etc.)"
    echo "  dev-tools - Re-run the dev tools installer (Python, Node.js, Rust, etc.)"
    echo ""
    echo "Optional environment variables:"
    echo "  MACSMITH_FIX_RUBY_GEMS=0|disabled Disable Ruby gem auto-fix"
    echo "  MACSMITH_CLEAN_PYENV=0|disabled  Disable pyenv cleanup (MACSMITH_PYENV_KEEP=...)"
    echo "  MACSMITH_CLEAN_NVM=0|disabled    Disable Node cleanup (MACSMITH_NVM_KEEP=...)"
    echo "  MACSMITH_CLEAN_CHRUBY=0|disabled Disable chruby cleanup (MACSMITH_CHRUBY_KEEP=...)"
    echo "  MACSMITH_SWIFT_SNAPSHOTS=1       Enable Swift development snapshot updates"
    exit 1
    ;;
esac

exit $?
}
