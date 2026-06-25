#!/usr/bin/env zsh
# Quick test script for the project

# Colors for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# Track if any test fails
test_failed=0

echo "${GREEN}=== Quick Test ===${NC}"
echo "1. Testing syntax..."
if zsh -n install.sh; then
  echo "${GREEN}✅ OK: install.sh syntax valid${NC}"
else
  echo "FAIL: install.sh syntax error"
  test_failed=1
fi

if zsh -n dev-tools.sh; then
  echo "${GREEN}✅ OK: dev-tools.sh syntax valid${NC}"
else
  echo "FAIL: dev-tools.sh syntax error"
  test_failed=1
fi

if zsh -n zsh.sh; then
  echo "${GREEN}✅ OK: zsh.sh syntax valid${NC}"
else
  echo "FAIL: zsh.sh syntax error"
  test_failed=1
fi

if zsh -n macsmith.sh; then
  echo "${GREEN}✅ OK: macsmith.sh syntax valid${NC}"
else
  echo "FAIL: macsmith.sh syntax error"
  test_failed=1
fi

if zsh -n bootstrap.sh; then
  echo "${GREEN}✅ OK: bootstrap.sh syntax valid${NC}"
else
  echo "FAIL: bootstrap.sh syntax error"
  test_failed=1
fi

if bash -n scripts/nix-macos-maintenance.sh; then
  echo "${GREEN}✅ OK: scripts/nix-macos-maintenance.sh syntax valid${NC}"
else
  echo "FAIL: scripts/nix-macos-maintenance.sh syntax error"
  test_failed=1
fi

if bash -n scripts/uninstall-nix-macos.sh; then
  echo "${GREEN}✅ OK: scripts/uninstall-nix-macos.sh syntax valid${NC}"
else
  echo "FAIL: scripts/uninstall-nix-macos.sh syntax error"
  test_failed=1
fi

if bash -n scripts/uninstall-macsmith.sh; then
  echo "${GREEN}✅ OK: scripts/uninstall-macsmith.sh syntax valid${NC}"
else
  echo "FAIL: scripts/uninstall-macsmith.sh syntax error"
  test_failed=1
fi

echo ""
echo "2. Testing file existence..."
if [[ -f install.sh ]]; then
  echo "${GREEN}✅ OK: install.sh exists${NC}"
else
  echo "FAIL: install.sh missing"
  test_failed=1
fi

if [[ -f dev-tools.sh ]]; then
  echo "${GREEN}✅ OK: dev-tools.sh exists${NC}"
else
  echo "FAIL: dev-tools.sh missing"
  test_failed=1
fi

if [[ -f zsh.sh ]]; then
  echo "${GREEN}✅ OK: zsh.sh exists${NC}"
else
  echo "FAIL: zsh.sh missing"
  test_failed=1
fi

if [[ -f macsmith.sh ]]; then
  echo "${GREEN}✅ OK: macsmith.sh exists${NC}"
else
  echo "FAIL: macsmith.sh missing"
  test_failed=1
fi

echo ""
echo "3. Testing macsmith script..."

# 3a. Test the repo's macsmith.sh with a real read-only subcommand. `versions`
# is safe (just prints tool versions) and actually exercises code paths rather
# than a trivial help branch, so this is a meaningful runtime smoke test.
if zsh macsmith.sh versions >/dev/null 2>&1; then
  echo "${GREEN}✅ OK: repo macsmith.sh runs 'versions' cleanly${NC}"
else
  # versions runs every detection block; a non-zero here means a real bug
  # (not a missing tool — versions prints "not installed" rather than failing).
  echo "FAIL: repo macsmith.sh exits non-zero on 'versions'"
  zsh macsmith.sh versions 2>&1 | tail -10 | sed 's/^/  /'
  test_failed=1
fi

# 3b. If a binary is installed, verify IT also works.
get_macsmith_path() {
  local local_bin="$HOME/.local/bin"
  if [[ -x "$local_bin/macsmith" ]]; then echo "$local_bin/macsmith"; return 0; fi
  if command -v macsmith >/dev/null 2>&1; then command -v macsmith; return 0; fi
  return 1
}

macsmith_path="$(get_macsmith_path || true)"
if [[ -n "$macsmith_path" ]]; then
  if "$macsmith_path" versions > /dev/null 2>&1; then
    echo "${GREEN}✅ OK: installed macsmith works ($macsmith_path)${NC}"
  else
    echo "FAIL: installed macsmith failed ($macsmith_path)"
    test_failed=1
  fi
else
  echo "INFO: no installed macsmith binary (run ./install.sh to install; repo file already verified above)"
fi

echo ""
echo "4. Testing update project-file protection..."
repo_root="${0:A:h}"
qt_tmp_root="$(mktemp -d 2>/dev/null || mktemp -d -t macsmith-quick-test)"
qt_project_dir="$qt_tmp_root/project"
qt_home_dir="$qt_tmp_root/home"
qt_safe_dir="$qt_tmp_root/safe-update-workdir"
qt_fake_bin="$qt_tmp_root/bin"
qt_output="$qt_tmp_root/update-output.txt"
qt_brew_log="$qt_tmp_root/brew-pwd.log"

mkdir -p "$qt_project_dir" "$qt_home_dir" "$qt_safe_dir" "$qt_fake_bin"
cat > "$qt_fake_bin/brew" <<'BREW_STUB'
#!/usr/bin/env sh
printf '%s\n' "$PWD" >> "$MACSMITH_FAKE_BREW_PWD_LOG"
exit 0
BREW_STUB
chmod +x "$qt_fake_bin/brew"

printf '{"name":"test","version":"1.0.0"}\n' > "$qt_project_dir/package.json"
printf 'package-lock-json content\n' > "$qt_project_dir/package-lock.json"
printf 'module test\n' > "$qt_project_dir/go.mod"

(
  cd "$qt_project_dir" || exit 1
  env \
    HOME="$qt_home_dir" \
    PATH="$qt_fake_bin:$PATH" \
    MACSMITH_UPDATE_WORKDIR="$qt_safe_dir" \
    MACSMITH_FAKE_BREW_PWD_LOG="$qt_brew_log" \
    NO_COLOR=1 \
    zsh "$repo_root/macsmith.sh" update brew > "$qt_output" 2>&1
)
qt_update_rc=$?

if [[ $qt_update_rc -ne 0 ]]; then
  echo "FAIL: project-safe update smoke test failed"
  tail -20 "$qt_output" 2>/dev/null | sed 's/^/  /'
  test_failed=1
elif [[ "$(<"$qt_project_dir/package-lock.json")" != "package-lock-json content" ]]; then
  echo "FAIL: update modified package-lock.json in a project directory"
  test_failed=1
elif [[ ! -s "$qt_brew_log" ]]; then
  echo "FAIL: fake brew was not invoked during project-safe update test"
  test_failed=1
elif grep -Fxq "$qt_project_dir" "$qt_brew_log"; then
  echo "FAIL: update ran package-manager commands from the project directory"
  test_failed=1
elif ! grep -Fxq "$qt_safe_dir" "$qt_brew_log"; then
  echo "FAIL: update did not run package-manager commands from the safe workdir"
  sed 's/^/  brew cwd: /' "$qt_brew_log"
  test_failed=1
elif ! grep -q "Running update from" "$qt_output"; then
  echo "FAIL: update did not report switching to the safe workdir"
  test_failed=1
else
  echo "${GREEN}✅ OK: update runs package-manager commands outside project directories${NC}"
fi

# Nested case: a subdir with NO markers of its own, inside a project. Detection
# must walk up to the project root and still relocate to the safe workdir.
qt_nested_dir="$qt_project_dir/src/deep"
mkdir -p "$qt_nested_dir"
: > "$qt_brew_log"
(
  cd "$qt_nested_dir" || exit 1
  env \
    HOME="$qt_home_dir" \
    PATH="$qt_fake_bin:$PATH" \
    MACSMITH_UPDATE_WORKDIR="$qt_safe_dir" \
    MACSMITH_FAKE_BREW_PWD_LOG="$qt_brew_log" \
    NO_COLOR=1 \
    zsh "$repo_root/macsmith.sh" update brew > "$qt_output" 2>&1
)
if grep -Fxq "$qt_nested_dir" "$qt_brew_log"; then
  echo "FAIL: update ran package-manager commands from a project subdirectory"
  test_failed=1
elif ! grep -Fxq "$qt_safe_dir" "$qt_brew_log"; then
  echo "FAIL: update did not detect the parent project root from a subdirectory"
  test_failed=1
else
  echo "${GREEN}✅ OK: update detects the project root from a nested subdirectory${NC}"
fi

qt_same_output="$qt_tmp_root/same-workdir-output.txt"
: > "$qt_brew_log"

(
  cd "$qt_project_dir" || exit 1
  env \
    HOME="$qt_home_dir" \
    PATH="$qt_fake_bin:$PATH" \
    MACSMITH_UPDATE_WORKDIR="$qt_project_dir" \
    MACSMITH_FAKE_BREW_PWD_LOG="$qt_brew_log" \
    NO_COLOR=1 \
    zsh "$repo_root/macsmith.sh" update brew > "$qt_same_output" 2>&1
)
qt_same_rc=$?

if [[ $qt_same_rc -eq 0 ]]; then
  echo "FAIL: update allowed MACSMITH_UPDATE_WORKDIR to equal the project directory"
  test_failed=1
elif [[ -s "$qt_brew_log" ]]; then
  echo "FAIL: update invoked package-manager commands before rejecting project safe workdir"
  test_failed=1
elif ! grep -q "must be outside the project directory" "$qt_same_output"; then
  echo "FAIL: project safe workdir rejection did not explain the problem"
  test_failed=1
else
  echo "${GREEN}✅ OK: update rejects project directories as safe workdirs${NC}"
fi

qt_nested_output="$qt_tmp_root/nested-workdir-output.txt"
qt_nested_safe="$qt_project_dir/.macsmith-workdir"
: > "$qt_brew_log"

(
  cd "$qt_project_dir" || exit 1
  env \
    HOME="$qt_home_dir" \
    PATH="$qt_fake_bin:$PATH" \
    MACSMITH_UPDATE_WORKDIR="$qt_nested_safe" \
    MACSMITH_FAKE_BREW_PWD_LOG="$qt_brew_log" \
    NO_COLOR=1 \
    zsh "$repo_root/macsmith.sh" update brew > "$qt_nested_output" 2>&1
)
qt_nested_rc=$?

if [[ $qt_nested_rc -eq 0 ]]; then
  echo "FAIL: update allowed MACSMITH_UPDATE_WORKDIR inside the project directory"
  test_failed=1
elif [[ -s "$qt_brew_log" ]]; then
  echo "FAIL: update invoked package-manager commands before rejecting nested safe workdir"
  test_failed=1
elif ! grep -q "must be outside the project directory" "$qt_nested_output"; then
  echo "FAIL: nested safe workdir rejection did not explain the problem"
  test_failed=1
else
  echo "${GREEN}✅ OK: update rejects safe workdirs inside project directories${NC}"
fi

qt_optin_output="$qt_tmp_root/optin-output.txt"
: > "$qt_brew_log"

(
  cd "$qt_project_dir" || exit 1
  env \
    HOME="$qt_home_dir" \
    PATH="$qt_fake_bin:$PATH" \
    MACSMITH_ALLOW_PROJECT_MODIFY=1 \
    MACSMITH_UPDATE_WORKDIR="$qt_safe_dir" \
    MACSMITH_FAKE_BREW_PWD_LOG="$qt_brew_log" \
    NO_COLOR=1 \
    zsh "$repo_root/macsmith.sh" update brew > "$qt_optin_output" 2>&1
)
qt_optin_rc=$?

if [[ $qt_optin_rc -ne 0 ]]; then
  echo "FAIL: explicit project-modify opt-in update failed"
  tail -20 "$qt_optin_output" 2>/dev/null | sed 's/^/  /'
  test_failed=1
elif grep -q "Running update from" "$qt_optin_output"; then
  echo "FAIL: explicit project-modify opt-in still switched to safe workdir"
  test_failed=1
elif ! grep -Fxq "$qt_project_dir" "$qt_brew_log"; then
  echo "FAIL: explicit project-modify opt-in did not run from the project directory"
  sed 's/^/  brew cwd: /' "$qt_brew_log"
  test_failed=1
else
  echo "${GREEN}✅ OK: explicit opt-in preserves project working directory${NC}"
fi

qt_home_output="$qt_tmp_root/home-update-output.txt"
: > "$qt_brew_log"
printf "source 'https://rubygems.org'\n" > "$qt_home_dir/Gemfile"

(
  cd "$qt_home_dir" || exit 1
  env \
    HOME="$qt_home_dir" \
    PATH="$qt_fake_bin:$PATH" \
    MACSMITH_UPDATE_WORKDIR="$qt_safe_dir" \
    MACSMITH_FAKE_BREW_PWD_LOG="$qt_brew_log" \
    NO_COLOR=1 \
    zsh "$repo_root/macsmith.sh" update brew > "$qt_home_output" 2>&1
)
qt_home_update_rc=$?

if [[ $qt_home_update_rc -ne 0 ]]; then
  echo "FAIL: HOME update smoke test failed"
  tail -20 "$qt_home_output" 2>/dev/null | sed 's/^/  /'
  test_failed=1
elif grep -q "Running update from" "$qt_home_output"; then
  echo "FAIL: update treated HOME as a project directory"
  test_failed=1
elif ! grep -Fxq "$qt_home_dir" "$qt_brew_log"; then
  echo "FAIL: update did not preserve HOME as the working directory"
  sed 's/^/  brew cwd: /' "$qt_brew_log"
  test_failed=1
else
  echo "${GREEN}✅ OK: update preserves HOME for global package files${NC}"
fi

rm -rf "$qt_tmp_root"

echo ""
if [[ $test_failed -eq 0 ]]; then
  echo "${GREEN}=== Test Complete ===${NC}"
  exit 0
else
  echo "${RED}=== Test Complete (with failures) ===${NC}"
  exit 1
fi
