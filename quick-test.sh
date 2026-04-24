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
if [[ $test_failed -eq 0 ]]; then
  echo "${GREEN}=== Test Complete ===${NC}"
  exit 0
else
  echo "${RED}=== Test Complete (with failures) ===${NC}"
  exit 1
fi
