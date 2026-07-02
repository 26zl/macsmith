#!/usr/bin/env zsh
# Quick test script for the project

if [[ -n "${NO_COLOR:-}" ]]; then
  readonly GREEN='' RED='' NC=''
else
  readonly GREEN='\033[0;32m' RED='\033[0;31m' NC='\033[0m'
fi

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

# Exercise macsmith.sh through the read-only `versions` command.
if zsh macsmith.sh versions >/dev/null 2>&1; then
  echo "${GREEN}✅ OK: repo macsmith.sh runs 'versions' cleanly${NC}"
else
  # Missing tools are reported normally, so a non-zero exit is a test failure.
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

# Confirm nested directories inherit project-root detection.
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

# Reject a sibling workdir that is still inside the detected project root.
qt_deep_output="$qt_tmp_root/deep-nested-workdir-output.txt"
qt_deep_safe="$qt_project_dir/.macsmith-workdir"
mkdir -p "$qt_nested_dir"
: > "$qt_brew_log"

(
  cd "$qt_nested_dir" || exit 1
  env \
    HOME="$qt_home_dir" \
    PATH="$qt_fake_bin:$PATH" \
    MACSMITH_UPDATE_WORKDIR="$qt_deep_safe" \
    MACSMITH_FAKE_BREW_PWD_LOG="$qt_brew_log" \
    NO_COLOR=1 \
    zsh "$repo_root/macsmith.sh" update brew > "$qt_deep_output" 2>&1
)
qt_deep_rc=$?

if [[ $qt_deep_rc -eq 0 ]]; then
  echo "FAIL: update allowed a workdir inside the project root from a nested subdir"
  test_failed=1
elif [[ -s "$qt_brew_log" ]]; then
  echo "FAIL: update invoked package-manager commands before rejecting in-project workdir (nested PWD)"
  test_failed=1
elif ! grep -q "must be outside the project directory" "$qt_deep_output"; then
  echo "FAIL: nested-subdir in-project workdir rejection did not explain the problem"
  test_failed=1
else
  echo "${GREEN}✅ OK: update rejects an in-project workdir even from a nested subdirectory${NC}"
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

# ---------------------------------------------------------------------------
# Keep regression reporting in the main shell so failures affect the suite status.
qt_pass() { echo "${GREEN}✅ OK: $1${NC}"; }
qt_fail() { echo "FAIL: $1"; test_failed=1; }

# ---------------------------------------------------------------------------
# 5. Verify the zprofile extractor contract and _curl_safe presence (M13).
# ---------------------------------------------------------------------------
echo ""
echo "5. Testing zprofile extractor contract + _curl_safe (M13)..."
# Tolerate both the unescaped heredoc marker (install.sh) and the escaped
# regex form macsmith.sh's extractor/strip use ('\(FOR \.ZPROFILE\)').
m13_start_re='FINAL PATH CLEANUP.*ZPROFILE'
m13_end='End macsmith managed block'
m13_ok=1
for m13_f in macsmith.sh install.sh; do
  if ! grep -Eq "$m13_start_re" "$repo_root/$m13_f"; then
    qt_fail "M13: start marker missing from $m13_f"; m13_ok=0
  fi
  if ! grep -Fq "$m13_end" "$repo_root/$m13_f"; then
    qt_fail "M13: end marker missing from $m13_f"; m13_ok=0
  fi
done
if [[ $m13_ok -eq 1 ]]; then
  m13_extracted="$(awk '
    /^# =+ FINAL PATH CLEANUP \(FOR \.ZPROFILE\) =+/ { grab = 1 }
    grab { print }
    grab && /^# End macsmith managed block$/ { exit }
  ' "$repo_root/install.sh")"
  m13_canonical="$(sed -n \
    '/^# =.* FINAL PATH CLEANUP (FOR \.ZPROFILE) =.*$/,/^# End macsmith managed block$/p' \
    "$repo_root/install.sh")"
  if [[ -n "$m13_extracted" && "$m13_extracted" == "$m13_canonical" ]]; then
    qt_pass "upgrade extractor returns the complete canonical zprofile block"
  else
    qt_fail "M13: upgrade extractor no longer returns the exact managed block"
  fi
fi
if grep -Eq '^_curl_safe\(\)' "$repo_root/macsmith.sh"; then
  qt_pass "macsmith.sh defines _curl_safe (TLS/--fail self-upgrade hardening)"
else
  qt_fail "M13: macsmith.sh is missing the _curl_safe helper"
fi

# ---------------------------------------------------------------------------
# 6. Replay install.sh's secret-export classification with its actual regexes (M14).
# ---------------------------------------------------------------------------
echo ""
echo "6. Testing secret-export harvest filter (M14)..."
qt_extract_install_local() {
  local var="$1" line
  line="$(grep -m1 "local ${var}='" "$repo_root/install.sh" 2>/dev/null)" || return 1
  [[ -z "$line" ]] && return 1
  line="${line#*\'}"   # drop through the opening single-quote
  line="${line%\'*}"   # drop the closing single-quote (and trailing text)
  printf '%s' "$line"
}
m14_sensitive_re="$(qt_extract_install_local sensitive_re)"
m14_key_re="$(qt_extract_install_local key_re)"
m14_benign_key_re="$(qt_extract_install_local benign_key_re)"
if [[ -z "$m14_sensitive_re" || -z "$m14_key_re" || -z "$m14_benign_key_re" ]]; then
  qt_fail "M14: could not extract sensitive_re/key_re/benign_key_re from install.sh (filter reshaped?)"
else
  # Replays install.sh's pipeline verbatim: grep -iE (case-insensitive, BSD grep).
  qt_is_sensitive() {
    local l="$1"
    if printf '%s\n' "$l" | grep -iqE "$m14_sensitive_re"; then return 0; fi
    if printf '%s\n' "$l" | grep -iqE "$m14_key_re" \
       && ! printf '%s\n' "$l" | grep -iqE "$m14_benign_key_re"; then return 0; fi
    return 1
  }
  m14_ok=1
  for m14_n in OPENAI_API_KEY ANTHROPIC_API_KEY AWS_SECRET_ACCESS_KEY GITHUB_TOKEN \
               DB_PASSWORD STRIPE_SECRET_KEY OPENAI_KEY STRIPE_KEY DEPLOY_KEY; do
    if ! qt_is_sensitive "export $m14_n=value"; then
      qt_fail "M14: $m14_n NOT classified sensitive (would leak into ~/.zshrc.local)"; m14_ok=0
    fi
  done
  for m14_line in "export EDITOR=vim" "export HOTKEY=cmd+space" "export PATH_KEY=foo" \
                  "export LANG=en_US.UTF-8" "alias gs='git status'"; do
    if qt_is_sensitive "$m14_line"; then
      qt_fail "M14: [$m14_line] WRONGLY classified sensitive (harmless line dropped)"; m14_ok=0
    fi
  done
  if [[ $m14_ok -eq 1 ]]; then
    qt_pass "secret-shaped exports flagged sensitive; harmless aliases/exports harvestable"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Verify that runtime pruning accepts only explicit true values (M15).
# ---------------------------------------------------------------------------
echo ""
echo "7. Testing runtime-cleanup gating via _is_enabled (M15)..."
m15_src="$(awk '/^_is_enabled\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$repo_root/macsmith.sh")"
if [[ -z "$m15_src" ]] || ! printf '%s\n' "$m15_src" | grep -q 'return 0'; then
  qt_fail "M15: could not extract _is_enabled from macsmith.sh"
else
  (
    eval "$m15_src"
    for v in 1 true yes on enable TRUE; do
      _is_enabled "$v" || { echo "  enabled-case [$v] wrongly DISABLED"; exit 11; }
    done
    for v in 0 false no off random FALSE; do
      _is_enabled "$v" && { echo "  disabled-case [$v] wrongly ENABLED"; exit 12; }
    done
    _is_enabled "" && { echo "  empty wrongly ENABLED"; exit 13; }
    _is_enabled    && { echo "  unset wrongly ENABLED (gate inversion!)"; exit 14; }
    exit 0
  )
  if [[ $? -eq 0 ]]; then
    qt_pass "_is_enabled: only 1/true/yes/on/enable enable; unset/0/false/etc stay DISABLED"
  else
    qt_fail "M15: _is_enabled gating regression (destructive cleanup could run when unset)"
  fi
fi

# ---------------------------------------------------------------------------
# 8. Verify selection of the oldest non-macsmith .zshrc backup in a dry run (M16).
# ---------------------------------------------------------------------------
echo ""
echo "8. Testing uninstall-macsmith restore-selection (M16)..."
m16_tmp="$(mktemp -d 2>/dev/null || mktemp -d -t macsmith-m16)"
m16_home="$m16_tmp/home"
mkdir -p "$m16_home/.local/bin" "$m16_home/.local/share/macsmith"
m16_old="$m16_home/.zshrc.backup.20200101_000000"   # pre-macsmith original (no ^macsmith_bin=)
m16_new="$m16_home/.zshrc.backup.20251231_235959"   # macsmith-written template (has ^macsmith_bin=)
# Only the `^macsmith_bin=` signature matters to backup selection.
{ print -r -- '# the user original zshrc'; print -r -- "alias ll='ls -la'"; } > "$m16_old"
m16_users_root='/Users'
{ print -r -- "macsmith_bin=${m16_users_root}/test/.local/bin/macsmith"; print -r -- 'alias update=run'; } > "$m16_new"
print -r -- "macsmith_bin=${m16_users_root}/test/.local/bin/macsmith" > "$m16_home/.zshrc"
m16_out="$m16_tmp/out.txt"
HOME="$m16_home" XDG_CONFIG_HOME="$m16_home/.config" \
  bash "$repo_root/scripts/uninstall-macsmith.sh" --dry-run </dev/null > "$m16_out" 2>&1
if grep -q "chose oldest non-managed backup:.*20200101_000000" "$m16_out" \
   && ! grep -q "chose oldest non-managed backup:.*20251231_235959" "$m16_out"; then
  qt_pass "uninstall-macsmith restores the OLDER non-managed backup, not the newer managed one"
else
  qt_fail "M16: uninstall-macsmith restore-selection chose the wrong backup"
  grep -i "backup" "$m16_out" 2>/dev/null | sed 's/^/  /'
fi
rm -rf "$m16_tmp"

# ---------------------------------------------------------------------------
# 9. Verify strict confirmation and exact Nix Store APFS detection (M17).
# ---------------------------------------------------------------------------
echo ""
echo "9. Testing uninstall-nix strict_confirm + APFS detection (M17)..."
m17_strict_src="$(awk '/^strict_confirm\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$repo_root/scripts/uninstall-nix-macos.sh")"
if [[ -z "$m17_strict_src" ]]; then
  qt_fail "M17a: could not extract strict_confirm from uninstall-nix-macos.sh"
else
  # Redirect only the terminal read so the real confirmation logic remains under test.
  m17_strict_stdin="$(printf '%s\n' "$m17_strict_src" | sed 's#/dev/tty#/dev/stdin#g')"
  qt_run_strict() {
    # Any log_* calls inside strict_confirm just hit "command not found" and are
    # swallowed by the >/dev/null 2>&1 below; the return value is unaffected.
    printf '%s\n' "$1" | (
      DRY_RUN=0; ASSUME_YES="${2:-0}"
      eval "$m17_strict_stdin"
      strict_confirm "confirm?" >/dev/null 2>&1
    )
  }
  m17a_ok=1
  for m17_bad in no y YES Y Yes ""; do
    if qt_run_strict "$m17_bad"; then
      qt_fail "M17a: strict_confirm accepted [$m17_bad] (only lowercase 'yes' may pass)"; m17a_ok=0
    fi
  done
  if ! qt_run_strict "yes"; then
    qt_fail "M17a: strict_confirm rejected the exact 'yes'"; m17a_ok=0
  fi
  if qt_run_strict "no" 1; then
    qt_fail "M17a: strict_confirm honored --yes/ASSUME_YES (must never auto-confirm)"; m17a_ok=0
  fi
  if ! qt_run_strict "yes" 1; then
    qt_fail "M17a: strict_confirm rejected 'yes' under ASSUME_YES"; m17a_ok=0
  fi
  if [[ $m17a_ok -eq 1 ]]; then
    qt_pass "strict_confirm: only lowercase 'yes' passes; --yes never auto-confirms"
  fi
  # Test no-TTY refusal live in CI and statically when a terminal is present.
  if [[ ! -r /dev/tty ]]; then
    if printf '%s\n' "yes" | (
        DRY_RUN=0; ASSUME_YES=0
        eval "$m17_strict_src"
        strict_confirm "confirm?" >/dev/null 2>&1
      ); then
      qt_fail "M17a: strict_confirm accepted piped input with no /dev/tty (must refuse)"
    else
      qt_pass "strict_confirm refuses when no controlling terminal (runtime)"
    fi
  else
    if printf '%s\n' "$m17_strict_src" | grep -q 'refusing irreversible operation' \
       && printf '%s\n' "$m17_strict_src" | grep -qE 'return 1'; then
      qt_pass "strict_confirm no-tty branch refuses (static; tty present, not run live)"
    else
      qt_fail "M17a: strict_confirm lost its no-tty refusal branch"
    fi
  fi
fi

# (b) APFS "Nix Store" volume awk matcher — extract the path-(b) awk program.
m17_awk="$(awk '
  index($0,"diskutil apfs list") && index($0,"awk") { cap=1; next }
  cap && index($0,"|| true)") { cap=0 }
  cap { print }
' "$repo_root/scripts/uninstall-nix-macos.sh")"
if [[ -z "$m17_awk" ]] || ! printf '%s\n' "$m17_awk" | grep -q 'Nix Store'; then
  qt_fail "M17b: could not extract the APFS 'Nix Store' awk matcher from uninstall-nix-macos.sh"
else
  qt_apfs_match() {
    # Feed a volume-id line + the candidate Name line through the real awk; it
    # prints the disk id on a match and nothing on a miss.
    printf 'APFS Volume Disk (Role):   disk3s7\n%s\n' "$1" | awk "$m17_awk"
  }
  m17b_ok=1
  for m17_good in "Name:   Nix Store (Case-sensitive)" "Name:   Nix Store"; do
    if [[ -z "$(qt_apfs_match "$m17_good")" ]]; then
      qt_fail "M17b: awk failed to match a real Nix Store volume line: [$m17_good]"; m17b_ok=0
    fi
  done
  for m17_bad in "Name:   Nix Store Backup" "Name:   Nix Store 2 (Case-sensitive)"; do
    if [[ -n "$(qt_apfs_match "$m17_bad")" ]]; then
      qt_fail "M17b: awk WRONGLY matched a decoy volume line: [$m17_bad] (deletion risk)"; m17b_ok=0
    fi
  done
  if [[ $m17b_ok -eq 1 ]]; then
    qt_pass "APFS matcher selects exact 'Nix Store' (incl. (Case-sensitive)) but not decoys"
  fi
fi

echo ""
echo "10. Running production regression suite..."
if zsh "$repo_root/tests/regression.zsh"; then
  qt_pass "production regression suite"
else
  qt_fail "production regression suite failed"
fi

echo ""
if [[ $test_failed -eq 0 ]]; then
  echo "${GREEN}=== Test Complete ===${NC}"
  exit 0
else
  echo "${RED}=== Test Complete (with failures) ===${NC}"
  exit 1
fi
