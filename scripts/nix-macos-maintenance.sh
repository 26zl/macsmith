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

# Count profile packages from JSON or old-style index lines and return 0 on errors.
_nix_profile_count() {
    local json count
    if command -v jq > /dev/null 2>&1; then
        json=$(nix profile list --json 2>/dev/null) || json=""
        if [[ -n "$json" ]]; then
            count=$(printf '%s' "$json" | jq '(.elements | if type=="array" then length else (keys | length) end)' 2>/dev/null) || count=""
            if [[ "$count" =~ ^[0-9]+$ ]]; then
                printf '%s' "$count"
                return 0
            fi
        fi
    fi
    count=$(nix profile list 2>/dev/null | grep -cE '^[0-9]+ ') || count=0
    printf '%s' "$count"
}

# Check if marker exists in file
_has_marker() {
    local file="$1"
    # Anchor markers to match the remover's line-start rule.
    if [[ -f "$file" ]] && grep -q "^${NIX_MARKER_START}" "$file" 2>/dev/null; then
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

    # Leave files without a managed marker untouched.
    if ! _has_marker "$file"; then
        return 0
    fi

    # Abort the edit if the shell-config backup fails.
    if ! cp "$file" "$file.macsmith-bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null; then
        _log_warning "Could not back up $file before editing; left unchanged."
        return 1
    fi

    # Keep only the 5 most recent backups so repeated runs don't accumulate them.
    local old
    while IFS= read -r old; do
        [[ -n "$old" ]] && rm -f "$old"
    done < <(ls -1t "$file".macsmith-bak.* 2>/dev/null | tail -n +6)

    # Create the temporary file beside the destination for an atomic rename.
    local temp_file orig_perms
    temp_file=$(mktemp "${file}.XXXXXX")
    # Preserve original file permissions
    orig_perms=$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo "644")

    # Remove a complete marker block and reject an unmatched start marker.
    if ! awk -v start="$NIX_MARKER_START" -v end="$NIX_MARKER_END" '
        index($0, start) == 1 { in_block=1; next }
        index($0, end) == 1 { in_block=0; next }
        !in_block { print }
        END { if (in_block) exit 3 }
    ' "$file" > "$temp_file"; then
        rm -f "$temp_file"
        _log_warning "Unterminated Nix marker block in $file (missing '$NIX_MARKER_END'); left unchanged."
        return 1
    fi

    if ! mv "$temp_file" "$file"; then
        rm -f "$temp_file" 2>/dev/null || true
        _log_warning "Could not replace $file; left unchanged."
        return 1
    fi
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
        # Back up and atomically replace the file instead of appending in place.
        if [[ -f "$ZPROFILE" ]]; then
            if ! cp "$ZPROFILE" "$ZPROFILE.macsmith-bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null; then
                _log_warning "Could not back up $ZPROFILE before editing; left unchanged."
                return 1
            fi
            # Keep only the 5 most recent backups so repeated runs don't accumulate them.
            local old
            while IFS= read -r old; do
                [[ -n "$old" ]] && rm -f "$old"
            done < <(ls -1t "$ZPROFILE".macsmith-bak.* 2>/dev/null | tail -n +6)
        fi

        local temp_file orig_perms
        temp_file=$(mktemp "${ZPROFILE}.XXXXXX")
        orig_perms=$(stat -f '%Lp' "$ZPROFILE" 2>/dev/null || stat -c '%a' "$ZPROFILE" 2>/dev/null || echo "644")

        if [[ -s "$ZPROFILE" ]]; then
            cat "$ZPROFILE" > "$temp_file"
            # Add a trailing newline before the managed block.
            [[ -n "$(tail -c1 "$ZPROFILE")" ]] && printf '\n' >> "$temp_file"
        fi
        printf '%s\n' "$hook_content" >> "$temp_file"

        mv "$temp_file" "$ZPROFILE"
        chmod "$orig_perms" "$ZPROFILE" 2>/dev/null || true
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
            # Treat EOF as the safe default under set -e.
            read -r response || response=""
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if _remove_marker_block "$ZSHRC"; then
                    _log_success "Removed Nix hook from $ZSHRC"
                fi
            else
                _log_info "Keeping hook in $ZSHRC (may cause duplicate sourcing)"
            fi
        else
            # Non-interactive mode: automatically remove from .zshrc
            _log_info "Non-interactive mode: automatically removing Nix hook from $ZSHRC"
            if _remove_marker_block "$ZSHRC"; then
                _log_success "Removed Nix hook from $ZSHRC"
            fi
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
        issues=$((issues + 1))
    fi

    # Check nix binary
    if [[ -f /nix/var/nix/profiles/default/bin/nix ]]; then
        _log_success "Nix binary found: /nix/var/nix/profiles/default/bin/nix"
    else
        _log_warning "Nix binary not found at expected location"
        issues=$((issues + 1))
    fi

    # Check if nix is in PATH
    if command -v nix > /dev/null 2>&1; then
        local nix_path
        nix_path=$(command -v nix)
        _log_success "Nix in PATH: $nix_path"
    else
        _log_error "Nix not in PATH"
        _log_info "Run: ./scripts/nix-macos-maintenance.sh ensure-path"
        issues=$((issues + 1))
    fi

    # Check version
    local version
    version=$(_get_nix_version)
    if [[ "$version" != "not in PATH" ]]; then
        _log_success "Nix version: $version"
    else
        _log_error "Cannot determine Nix version (not in PATH)"
        issues=$((issues + 1))
    fi

    # Check nix-daemon
    if _check_nix_daemon; then
        _log_success "nix-daemon is running"
    else
        _log_warning "nix-daemon is not running"
        _log_info "For multi-user installs, nix-daemon should be running"
        issues=$((issues + 1))
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
    profile_count=$(_nix_profile_count)
    if [[ "$profile_count" -gt 0 ]]; then
        _log_success "nix profile has $profile_count package(s)"
    else
        _log_info "nix profile is empty (no packages installed via nix profile)"
    fi
    
    # Keep an unavailable nix-env from aborting diagnostic status output.
    _log_info "Checking nix-env packages..."
    local env_count
    env_count=$(nix-env -q 2>/dev/null | wc -l | tr -d ' ') || env_count=0
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
        issues=$((issues + 1))
    fi
    
    # Summary
    echo ""
    if [[ $issues -eq 0 ]]; then
        _log_success "All checks passed!"
    else
        _log_warning "Found $issues issue(s) - see above for details"
    fi
}

# Parse only the canonical dry-run upgrade target and always exit successfully.
_parse_nix_upgrade_target() {
    printf '%s\n' "$1" \
        | grep -i "would upgrade to version" \
        | sed -E 's/.*version ([0-9.]+).*/\1/' \
        | head -1 || true
}

# Return 0 (true) when $1 (current version) is newer than $2 (target version),
# i.e. applying the "upgrade" would actually be a downgrade.
_is_nix_downgrade() {
    local current="$1" target="$2"
    local current_major current_minor current_patch
    local target_major target_minor target_patch

    IFS='.' read -r current_major current_minor current_patch <<< "$current"
    IFS='.' read -r target_major target_minor target_patch <<< "$target"

    # Strip non-numeric suffixes (e.g., "10pre20241025" -> "10") and default to 0
    current_patch="${current_patch%%[!0-9]*}"; [[ -z "$current_patch" ]] && current_patch=0
    target_patch="${target_patch%%[!0-9]*}"; [[ -z "$target_patch" ]] && target_patch=0
    current_major="${current_major%%[!0-9]*}"; [[ -z "$current_major" ]] && current_major=0
    current_minor="${current_minor%%[!0-9]*}"; [[ -z "$current_minor" ]] && current_minor=0
    target_major="${target_major%%[!0-9]*}"; [[ -z "$target_major" ]] && target_major=0
    target_minor="${target_minor%%[!0-9]*}"; [[ -z "$target_minor" ]] && target_minor=0

    if [[ "$current_major" -gt "$target_major" ]] || \
       { [[ "$current_major" -eq "$target_major" ]] && [[ "$current_minor" -gt "$target_minor" ]]; } || \
       { [[ "$current_major" -eq "$target_major" ]] && [[ "$current_minor" -eq "$target_minor" ]] && [[ "$current_patch" -gt "$target_patch" ]]; }; then
        return 0
    fi
    return 1
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
    target_version=$(_parse_nix_upgrade_target "$upgrade_output")

    if [[ -z "$target_version" ]]; then
        _log_warning "Could not parse target version from output"
        _log_info "Please review the output above manually"
        return 0
    fi

    _log_info "Target version: $target_version"

    if _is_nix_downgrade "$current_version" "$target_version"; then
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
    local failed=false
    
    # Check and update nix profile
    local profile_count
    profile_count=$(_nix_profile_count)
    
    if [[ "$profile_count" -gt 0 ]]; then
        _log_info "Updating $profile_count package(s) in nix profile..."
        if nix profile upgrade --all; then
            _log_success "nix profile packages updated"
            updated=true
        else
            _log_error "Failed to update nix profile packages"
            failed=true
        fi
    else
        _log_info "nix profile is empty - no packages to update"
        _log_info "Install packages with: nix profile install <package>"
    fi
    
    # Check and update nix-env
    local env_count
    env_count=$(nix-env -q 2>/dev/null | wc -l | tr -d ' ') || env_count=0
    
    if [[ "$env_count" -gt 0 ]]; then
        _log_info "Updating $env_count package(s) in nix-env..."
        if nix-env -u '*'; then
            _log_success "nix-env packages updated"
            updated=true
        else
            _log_error "Failed to update nix-env packages"
            failed=true
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
        # Check the upgrade target only with already-cached sudo credentials.
        if ! sudo -n true 2>/dev/null; then
            _log_info "Could not check Nix CLI upgrade without cached sudo credentials."
            _log_info "Run: ./scripts/nix-macos-maintenance.sh preview-nix-upgrade"
        else
            local upgrade_preview target_version
            upgrade_preview=$(sudo -n nix upgrade-nix --dry-run --profile /nix/var/nix/profiles/default 2>&1 || echo "")
            target_version=$(_parse_nix_upgrade_target "$upgrade_preview")

            if [[ -z "$target_version" || "$target_version" == "$current_nix_version" ]]; then
                _log_info "Nix CLI is up to date ($current_nix_version)"
            elif _is_nix_downgrade "$current_nix_version" "$target_version"; then
                _log_warning "Nix CLI upgrade skipped: would downgrade ($current_nix_version -> $target_version)"
                _log_info "nix upgrade-nix follows nixpkgs fallback and may be older than installed Nix"
            else
                _log_info "Nix CLI upgrade available: $current_nix_version -> $target_version"
                _log_info "To upgrade: sudo -H nix upgrade-nix --profile /nix/var/nix/profiles/default"
            fi
        fi
    else
        _log_info "Could not determine current Nix version"
    fi
    
    if [[ "$updated" == "true" ]]; then
        _log_success "Package updates complete"
    else
        _log_info "No packages to update"
    fi
    if [[ "$failed" == "true" ]]; then
        _log_error "One or more Nix package updates failed"
        return 1
    fi
    return 0
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
    _log_section "Fixing zsh insecure completion directories"

    # Invoke the autoloaded zsh compaudit function through a zsh subprocess.
    if ! command -v zsh >/dev/null 2>&1; then
        _log_error "zsh not found; cannot run compaudit"
        return 1
    fi

    _log_info "Checking for insecure completion directories..."
    local insecure_dirs
    insecure_dirs=$(zsh -c 'autoload -Uz compaudit && compaudit' 2>/dev/null || true)

    if [[ -z "$insecure_dirs" ]]; then
        _log_success "No insecure directories found"
        return 0
    fi

    _log_warning "Found insecure directories:"
    echo "$insecure_dirs"
    echo ""

    _log_info "Fixing permissions (removing group/other write permissions)..."

    # Use the follow-up compaudit result instead of xargs' aggregate status.
    echo "$insecure_dirs" | xargs -I {} chmod g-w,o-w {} 2>/dev/null || true

    # Verify
    echo ""
    _log_info "Verifying fix..."
    local remaining
    remaining=$(zsh -c 'autoload -Uz compaudit && compaudit' 2>/dev/null || true)

    if [[ -z "$remaining" ]]; then
        _log_success "All issues resolved!"
    else
        _log_warning "Some issues remain:"
        echo "$remaining"
        _log_info "These may require sudo to fix:"
        _log_info "  zsh -c 'autoload -Uz compaudit && compaudit' | xargs sudo chmod g-w,o-w"
    fi
}

# Remove the managed Nix maintenance hook block from ~/.zprofile
cmd_remove_path() {
    _log_info "Removing the Nix maintenance hook block from $ZPROFILE..."
    if _remove_marker_block "$ZPROFILE"; then
        _log_success "Nix maintenance hook removed (or already absent)."
        _log_info "Open a new shell or run: source ~/.zprofile"
    else
        _log_warning "Could not remove the hook block (see message above)."
        return 1
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
    remove-path         Remove the Nix maintenance hook block from ~/.zprofile
    update              Update nix profile and nix-env packages
    preview-nix-upgrade Preview Nix CLI upgrade (dry-run, shows downgrade warnings)
    cleanup             Run garbage collection and store optimisation
    fix-compaudit       Fix zsh insecure completion directory permissions
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

    # Fix zsh completion permissions
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
        remove-path)
            cmd_remove_path
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
