#!/usr/bin/env bash
# Nix macOS Maintenance Script
# Provides safe, idempotent Nix maintenance operations for macOS

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration paths
readonly ZPROFILE="$HOME/.zprofile"
readonly ZSHRC="$HOME/.zshrc"

# Nix markers for idempotent operations
readonly NIX_MARKER_START="# BEGIN Nix macOS Maintenance Hook"
readonly NIX_MARKER_END="# END Nix macOS Maintenance Hook"

# Logging functions
_log_info() {
    echo -e "${BLUE}$*${NC}"
}

_log_success() {
    echo -e "${GREEN}$*${NC}"
}

_log_warning() {
    echo -e "${YELLOW}$*${NC}"
}

_log_error() {
    echo -e "${RED}$*${NC}" >&2
}

_log_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Check if Nix is installed
_check_nix_installed() {
    if [[ -d /nix ]] && [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
        return 0
    fi
    return 1
}

# Check if nix-daemon is running
_check_nix_daemon() {
    if pgrep -x "nix-daemon" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Get current Nix version
_get_nix_version() {
    if command -v nix > /dev/null 2>&1; then
        nix --version 2>/dev/null | head -n1 | sed 's/nix (Nix) //' || echo "unknown"
    else
        echo "not in PATH"
    fi
}

# Check if marker exists in file
_has_marker() {
    local file="$1"
    if [[ -f "$file" ]] && grep -q "$NIX_MARKER_START" "$file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Remove marker block from file
_remove_marker_block() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    
    # Use a temporary file to avoid in-place editing issues
    local temp_file orig_perms
    temp_file=$(mktemp)
    # Preserve original file permissions
    orig_perms=$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo "644")

    # Remove lines between markers (inclusive). Pass the constants as awk vars
    # so the markers stay in a single source of truth with the declarations at
    # the top of this file — previously NIX_MARKER_END was unused (SC2034).
    awk -v start="$NIX_MARKER_START" -v end="$NIX_MARKER_END" '
        index($0, start) == 1 { in_block=1; next }
        index($0, end) == 1 { in_block=0; next }
        !in_block { print }
    ' "$file" > "$temp_file"

    mv "$temp_file" "$file"
    chmod "$orig_perms" "$file" 2>/dev/null || true
}

# Add Nix hook to .zprofile
_add_nix_hook() {
    local hook_content
    hook_content=$(cat <<'EOF'
# BEGIN Nix macOS Maintenance Hook
# Managed by nix-macos-maintenance.sh - use: ./scripts/nix-macos-maintenance.sh ensure-path

if [[ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    # Multi-user installation
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [[ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    # Single-user installation
    source "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi
# END Nix macOS Maintenance Hook
EOF
)
    
    # Append to .zprofile if it doesn't exist or doesn't have marker
    if [[ ! -f "$ZPROFILE" ]] || ! _has_marker "$ZPROFILE"; then
        echo "$hook_content" >> "$ZPROFILE"
        _log_success "Added Nix hook to $ZPROFILE"
        return 0
    else
        _log_info "Nix hook already exists in $ZPROFILE (idempotent)"
        return 0
    fi
}

# Ensure Nix is in PATH
cmd_ensure_path() {
    _log_section "Ensuring Nix is in PATH"
    
    if ! _check_nix_installed; then
        _log_error "Nix is not installed. Please install Nix first."
        _log_info "Visit: https://nixos.org/download.html"
        return 1
    fi
    
    # Check if marker exists in .zshrc (should be in .zprofile instead)
    if _has_marker "$ZSHRC"; then
        _log_warning "Nix hook found in $ZSHRC (should be in $ZPROFILE)"
        # Only prompt if we have a TTY (interactive mode)
        if [[ -t 0 ]]; then
            _log_info "Would you like to remove it from $ZSHRC? (y/N)"
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                _remove_marker_block "$ZSHRC"
                _log_success "Removed Nix hook from $ZSHRC"
            else
                _log_info "Keeping hook in $ZSHRC (may cause duplicate sourcing)"
            fi
        else
            # Non-interactive mode: automatically remove from .zshrc
            _log_info "Non-interactive mode: automatically removing Nix hook from $ZSHRC"
            _remove_marker_block "$ZSHRC"
            _log_success "Removed Nix hook from $ZSHRC"
        fi
    fi
    
    # Add to .zprofile
    _add_nix_hook
    
    _log_success "Nix PATH configuration complete"
    _log_info "NEXT STEPS:"
    echo "  1. Restart your terminal or run: source $ZPROFILE"
    echo "  2. Verify with: command -v nix"
    echo "  3. Check status with: ./scripts/nix-macos-maintenance.sh status"
}

# Status command
cmd_status() {
    _log_section "Nix Status Check"
    
    local issues=0
    
    # Check /nix directory
    if [[ -d /nix ]]; then
        _log_success "/nix directory exists"
    else
        _log_error "/nix directory not found"
        ((issues++))
    fi
    
    # Check nix binary
    if [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
        _log_success "Nix binary found: /nix/var/nix/profiles/default/bin/nix"
    else
        _log_warning "Nix binary not found at expected location"
        ((issues++))
    fi
    
    # Check if nix is in PATH
    if command -v nix > /dev/null 2>&1; then
        local nix_path
        nix_path=$(command -v nix)
        _log_success "Nix in PATH: $nix_path"
    else
        _log_error "Nix not in PATH"
        _log_info "Run: ./scripts/nix-macos-maintenance.sh ensure-path"
        ((issues++))
    fi
    
    # Check version
    local version
    version=$(_get_nix_version)
    if [[ "$version" != "not in PATH" ]]; then
        _log_success "Nix version: $version"
    else
        _log_error "Cannot determine Nix version (not in PATH)"
        ((issues++))
    fi
    
    # Check nix-daemon
    if _check_nix_daemon; then
        _log_success "nix-daemon is running"
    else
        _log_warning "nix-daemon is not running"
        _log_info "For multi-user installs, nix-daemon should be running"
        ((issues++))
    fi
    
    # Check for determinate-nixd
    if command -v determinate-nixd > /dev/null 2>&1; then
        _log_info "determinate-nixd found: $(command -v determinate-nixd)"
    else
        _log_info "determinate-nixd not found (expected for standard Nix install)"
    fi
    
    # Check for /nix/nix-installer
    if [[ -d /nix/nix-installer ]]; then
        _log_info "/nix/nix-installer directory exists"
    else
        _log_info "/nix/nix-installer not found (expected for standard Nix install)"
    fi
    
    # Check nix profile packages
    echo ""
    _log_info "Checking nix profile packages..."
    local profile_count
    profile_count=$(nix profile list 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$profile_count" -gt 0 ]]; then
        _log_success "nix profile has $profile_count package(s)"
    else
        _log_info "nix profile is empty (no packages installed via nix profile)"
    fi
    
    # Check nix-env packages
    _log_info "Checking nix-env packages..."
    local env_count
    env_count=$(nix-env -q 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$env_count" -gt 0 ]]; then
        _log_success "nix-env has $env_count package(s)"
    else
        _log_info "nix-env is empty (no legacy packages installed)"
    fi
    
    # Check flakes
    echo ""
    _log_info "Checking flakes support..."
    if nix flake --help > /dev/null 2>&1; then
        _log_success "Flakes are enabled (nix-command feature)"
    else
        _log_warning "Flakes may not be enabled"
        ((issues++))
    fi
    
    # Summary
    echo ""
    if [[ $issues -eq 0 ]]; then
        _log_success "All checks passed!"
    else
        _log_warning "Found $issues issue(s) - see above for details"
    fi
}

# Preview Nix upgrade
cmd_preview_nix_upgrade() {
    _log_section "Preview Nix CLI Upgrade"
    
    if ! command -v nix > /dev/null 2>&1; then
        _log_error "Nix not in PATH. Run: ./scripts/nix-macos-maintenance.sh ensure-path"
        return 1
    fi
    
    local current_version
    current_version=$(_get_nix_version)
    _log_info "Current Nix version: $current_version"
    
    _log_info "Running dry-run upgrade check (requires sudo)..."
    echo ""
    
    local upgrade_output
    upgrade_output=$(sudo -H nix upgrade-nix --dry-run --profile /nix/var/nix/profiles/default 2>&1) || {
        _log_error "Failed to run upgrade check"
        echo "$upgrade_output"
        return 1
    }
    
    echo "$upgrade_output"
    echo ""
    
    # Parse output for version
    local target_version
    target_version=$(echo "$upgrade_output" | grep -i "would upgrade to version" | sed -E 's/.*version ([0-9.]+).*/\1/' || echo "")
    
    if [[ -z "$target_version" ]]; then
        _log_warning "Could not parse target version from output"
        _log_info "Please review the output above manually"
        return 0
    fi
    
    _log_info "Target version: $target_version"
    
    # Compare versions (simple numeric comparison)
    local current_major current_minor current_patch
    local target_major target_minor target_patch
    
    IFS='.' read -r current_major current_minor current_patch <<< "$current_version"
    IFS='.' read -r target_major target_minor target_patch <<< "$target_version"

    # Strip non-numeric suffixes (e.g., "10pre20241025" -> "10")
    current_patch="${current_patch%%[!0-9]*}"; [[ -z "$current_patch" ]] && current_patch=0
    target_patch="${target_patch%%[!0-9]*}"; [[ -z "$target_patch" ]] && target_patch=0
    current_major="${current_major%%[!0-9]*}"; [[ -z "$current_major" ]] && current_major=0
    current_minor="${current_minor%%[!0-9]*}"; [[ -z "$current_minor" ]] && current_minor=0
    target_major="${target_major%%[!0-9]*}"; [[ -z "$target_major" ]] && target_major=0
    target_minor="${target_minor%%[!0-9]*}"; [[ -z "$target_minor" ]] && target_minor=0

    # Simple version comparison
    if [[ "$current_major" -gt "$target_major" ]] || \
       [[ "$current_major" -eq "$target_major" && "$current_minor" -gt "$target_minor" ]] || \
       [[ "$current_major" -eq "$target_major" && "$current_minor" -eq "$target_minor" && "$current_patch" -gt "$target_patch" ]]; then
        _log_warning "THIS IS A DOWNGRADE!"
        _log_warning "Current: $current_version -> Target: $target_version"
        _log_info "nix upgrade-nix follows nixpkgs fallback and may be older than installed Nix"
        _log_info "Do NOT run this upgrade automatically"
    elif [[ "$current_version" == "$target_version" ]]; then
        _log_success "Already at target version: $target_version"
    else
        _log_success "This would be an upgrade: $current_version -> $target_version"
        _log_info "To apply: sudo -H nix upgrade-nix --profile /nix/var/nix/profiles/default"
    fi
}

# Update command
cmd_update() {
    _log_section "Updating Nix Packages"
    
    if ! command -v nix > /dev/null 2>&1; then
        _log_error "Nix not in PATH. Run: ./scripts/nix-macos-maintenance.sh ensure-path"
        return 1
    fi
    
    local updated=false
    
    # Check and update nix profile
    local profile_count
    profile_count=$(nix profile list 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    
    if [[ "$profile_count" -gt 0 ]]; then
        _log_info "Updating $profile_count package(s) in nix profile..."
        if nix profile upgrade --all; then
            _log_success "nix profile packages updated"
            updated=true
        else
            _log_error "Failed to update nix profile packages"
        fi
    else
        _log_info "nix profile is empty - no packages to update"
        _log_info "Install packages with: nix profile install <package>"
    fi
    
    # Check and update nix-env
    local env_count
    env_count=$(nix-env -q 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    
    if [[ "$env_count" -gt 0 ]]; then
        _log_info "Updating $env_count package(s) in nix-env..."
        if nix-env -u '*'; then
            _log_success "nix-env packages updated"
            updated=true
        else
            _log_error "Failed to update nix-env packages"
        fi
    else
        _log_info "nix-env is empty - no legacy packages to update"
        _log_info "Install packages with: nix-env -i <package>"
    fi
    
    # Nix CLI upgrade check (preview and auto-skip downgrades)
    echo ""
    _log_info "Checking for Nix CLI updates..."
    local current_nix_version
    current_nix_version=$(_get_nix_version)
    
    if [[ -n "$current_nix_version" && "$current_nix_version" != "not in PATH" && "$current_nix_version" != "unknown" ]]; then
        # Run preview (dry-run) to check target version
        local upgrade_preview
        upgrade_preview=$(sudo -H nix upgrade-nix --dry-run --profile /nix/var/nix/profiles/default 2>&1 || echo "")
        
        if [[ -n "$upgrade_preview" ]]; then
            # Parse target version from preview output
            local target_version
            target_version=$(echo "$upgrade_preview" | grep -iE "would upgrade to version|upgrade to|version [0-9]" | sed -E 's/.*[vV]?([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -1 || echo "")
            
            if [[ -n "$target_version" && "$target_version" != "$current_nix_version" ]]; then
                # Compare versions
                local current_major current_minor current_patch
                local target_major target_minor target_patch
                
                IFS='.' read -r current_major current_minor current_patch <<< "$current_nix_version"
                IFS='.' read -r target_major target_minor target_patch <<< "$target_version"

                # Strip non-numeric suffixes and default to 0
                current_patch="${current_patch%%[!0-9]*}"; [[ -z "$current_patch" ]] && current_patch=0
                target_patch="${target_patch%%[!0-9]*}"; [[ -z "$target_patch" ]] && target_patch=0
                current_major="${current_major%%[!0-9]*}"; [[ -z "$current_major" ]] && current_major=0
                current_minor="${current_minor%%[!0-9]*}"; [[ -z "$current_minor" ]] && current_minor=0
                target_major="${target_major%%[!0-9]*}"; [[ -z "$target_major" ]] && target_major=0
                target_minor="${target_minor%%[!0-9]*}"; [[ -z "$target_minor" ]] && target_minor=0
                
                # Check if it's a downgrade
                local is_downgrade=false
                if [[ "$current_major" -gt "$target_major" ]] || \
                   { [[ "$current_major" -eq "$target_major" ]] && [[ "$current_minor" -gt "$target_minor" ]]; } || \
                   { [[ "$current_major" -eq "$target_major" ]] && [[ "$current_minor" -eq "$target_minor" ]] && [[ "$current_patch" -gt "$target_patch" ]]; }; then
                    is_downgrade=true
                fi
                
                if [[ "$is_downgrade" == "true" ]]; then
                    _log_warning "Nix CLI upgrade skipped: would downgrade ($current_nix_version -> $target_version)"
                    _log_info "nix upgrade-nix follows nixpkgs fallback and may be older than installed Nix"
                else
                    _log_info "Nix CLI upgrade available: $current_nix_version -> $target_version"
                    _log_info "To upgrade: sudo -H nix upgrade-nix --profile /nix/var/nix/profiles/default"
                fi
            elif [[ -z "$target_version" ]]; then
                _log_info "Nix CLI is up to date ($current_nix_version)"
            else
                _log_info "Nix CLI is up to date ($current_nix_version)"
            fi
        else
            _log_info "Could not check Nix CLI upgrade (preview requires sudo or nix not properly configured)"
        fi
    else
        _log_info "Could not determine current Nix version"
    fi
    
    if [[ "$updated" == "true" ]]; then
        _log_success "Package updates complete"
    else
        _log_info "No packages to update"
    fi
}

# Cleanup command
cmd_cleanup() {
    _log_section "Cleaning Nix Store"
    
    if ! command -v nix > /dev/null 2>&1; then
        _log_error "Nix not in PATH. Run: ./scripts/nix-macos-maintenance.sh ensure-path"
        return 1
    fi
    
    _log_info "Running nix store gc (garbage collection)..."
    local gc_output
    gc_output=$(nix store gc 2>&1) || {
        _log_error "Garbage collection failed"
        echo "$gc_output"
        return 1
    }
    
    # Try to extract freed space
    local freed_space
    freed_space=$(echo "$gc_output" | grep -iE "(freed|removed|deleted).*[0-9]+.*(bytes|KB|MB|GB)" | head -1 || echo "")
    
    if [[ -n "$freed_space" ]]; then
        _log_success "Garbage collection: $freed_space"
    else
        _log_success "Garbage collection completed"
    fi
    
    echo ""
    _log_info "Running nix store optimise..."
    if nix store optimise 2>/dev/null; then
        _log_success "Store optimisation completed"
    elif sudo nix store optimise 2>/dev/null; then
        _log_success "Store optimisation completed (via sudo)"
    else
        _log_warning "Store optimisation failed"
    fi
    
    _log_success "Cleanup complete"
}

# Fix compaudit
cmd_fix_compaudit() {
    _log_section "Fixing Oh My Zsh Compaudit Issues"
    
    if ! command -v compaudit > /dev/null 2>&1; then
        _log_error "compaudit not found (Oh My Zsh may not be installed)"
        return 1
    fi
    
    _log_info "Checking for insecure completion directories..."
    local insecure_dirs
    insecure_dirs=$(compaudit 2>&1 || true)
    
    if [[ -z "$insecure_dirs" ]]; then
        _log_success "No insecure directories found"
        return 0
    fi
    
    _log_warning "Found insecure directories:"
    echo "$insecure_dirs"
    echo ""
    
    _log_info "Fixing permissions (removing group/other write permissions)..."
    
    # Fix permissions
    if echo "$insecure_dirs" | xargs -I {} chmod g-w,o-w {} 2>/dev/null; then
        _log_success "Permissions fixed"
    else
        _log_error "Failed to fix permissions (may require sudo)"
        _log_info "Try: compaudit | xargs sudo chmod g-w,o-w"
        return 1
    fi
    
    # Verify
    echo ""
    _log_info "Verifying fix..."
    local remaining
    remaining=$(compaudit 2>&1 || true)
    
    if [[ -z "$remaining" ]]; then
        _log_success "All issues resolved!"
    else
        _log_warning "Some issues remain:"
        echo "$remaining"
        _log_info "These may require sudo to fix"
    fi
}

# Help command
cmd_help() {
    cat <<EOF
Nix macOS Maintenance Script

USAGE:
    ./scripts/nix-macos-maintenance.sh <command>

COMMANDS:
    status              Check Nix installation status
    ensure-path         Ensure Nix is in PATH (idempotent)
    update              Update nix profile and nix-env packages
    preview-nix-upgrade Preview Nix CLI upgrade (dry-run, shows downgrade warnings)
    cleanup             Run garbage collection and store optimisation
    fix-compaudit       Fix Oh My Zsh insecure completion directory permissions
    help                Show this help message

EXAMPLES:
    # Initial setup
    ./scripts/nix-macos-maintenance.sh ensure-path
    source ~/.zprofile

    # Daily maintenance
    ./scripts/nix-macos-maintenance.sh status
    ./scripts/nix-macos-maintenance.sh update
    ./scripts/nix-macos-maintenance.sh cleanup

    # Check for Nix CLI updates (may show downgrade warning)
    ./scripts/nix-macos-maintenance.sh preview-nix-upgrade

    # Fix Oh My Zsh permissions
    ./scripts/nix-macos-maintenance.sh fix-compaudit

Nix is integrated with macsmith: 'update', 'verify', and 'versions' commands
EOF
}

# Main command dispatcher
main() {
    local command="${1:-help}"
    
    case "$command" in
        status)
            cmd_status
            ;;
        ensure-path)
            cmd_ensure_path
            ;;
        update)
            cmd_update
            ;;
        preview-nix-upgrade)
            cmd_preview_nix_upgrade
            ;;
        cleanup)
            cmd_cleanup
            ;;
        fix-compaudit)
            cmd_fix_compaudit
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            _log_error "Unknown command: $command"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
