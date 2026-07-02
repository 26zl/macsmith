#!/usr/bin/env zsh
set -u

repo_root="${0:a:h:h}"
failures=0

pass() { print -r -- "PASS: $1"; }
fail() { print -ru2 -- "FAIL: $1"; ((failures++)); }

extract_function() {
  local file="$1" name="$2"
  awk -v start="^${name}[(][)] [{]$" '
    $0 ~ start { copy=1 }
    copy { print }
    copy && /^}$/ { exit }
  ' "$file"
}

test_env_parser() {
  local file="$1" parser=""
  parser="$(extract_function "$file" _env_true)"
  if [[ -z "$parser" ]]; then
    fail "$file exposes _env_true"
    return
  fi
  (
    eval "$parser"
    local value
    for value in 1 true TRUE yes on enable enabled; do
      _env_true "$value" || exit 1
    done
    for value in 0 false FALSE no off disable disabled random ""; do
      _env_true "$value" && exit 1
    done
    exit 0
  )
  if [[ $? -eq 0 ]]; then
    pass "$file accepts only explicit true values"
  else
    fail "$file boolean environment parsing"
  fi
}

test_env_parser "$repo_root/bootstrap.sh"
test_env_parser "$repo_root/install.sh"
test_env_parser "$repo_root/dev-tools.sh"

bootstrap_bool="$(
  extract_function "$repo_root/bootstrap.sh" _env_true
  extract_function "$repo_root/bootstrap.sh" _is_autoyes
)"
(
  eval "$bootstrap_bool"
  MACSMITH_YES=0 NONINTERACTIVE=false CI=off _is_autoyes && exit 1
  MACSMITH_YES=1 NONINTERACTIVE=0 CI=0 _is_autoyes || exit 1
)
if [[ $? -eq 0 ]]; then
  pass "bootstrap auto-approval rejects 0/false/off"
else
  fail "bootstrap auto-approval truthiness"
fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/macsmith-regression.XXXXXX")" || exit 1
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/doctor-home"
HOME="$tmp_root/doctor-home" PATH="/usr/bin:/bin" NO_COLOR=1 \
  zsh "$repo_root/macsmith.sh" doctor >"$tmp_root/doctor.out" 2>&1 || true
if [[ -z "$(find "$tmp_root/doctor-home" -mindepth 1 -print -quit)" ]]; then
  pass "doctor is read-only in an empty HOME"
else
  fail "doctor wrote files in an empty HOME"
  find "$tmp_root/doctor-home" -mindepth 1 -print >&2
fi

mkdir -p "$tmp_root/help-home"
if HOME="$tmp_root/help-home" PATH="/usr/bin:/bin" NO_COLOR=1 \
  zsh "$repo_root/macsmith.sh" --help >"$tmp_root/help.out" 2>&1 \
  && [[ -z "$(find "$tmp_root/help-home" -mindepth 1 -print -quit)" ]]; then
  pass "macsmith --help exits zero without writing state"
else
  fail "macsmith --help status or read-only contract"
fi

fake_bin="$tmp_root/fake-bin"
mkdir -p "$fake_bin" "$tmp_root/nix-home"
for command_name in nix nix-env nix-collect-garbage sudo; do
  printf '#!/bin/sh\nexit 1\n' >"$fake_bin/$command_name"
  chmod 700 "$fake_bin/$command_name"
done
if HOME="$tmp_root/nix-home" PATH="$fake_bin:/usr/bin:/bin" NO_COLOR=1 \
  zsh "$repo_root/macsmith.sh" update nix >"$tmp_root/nix.out" 2>&1; then
  fail "targeted Nix update returned success when every command failed"
else
  pass "targeted Nix update propagates command failures"
fi

atomic_source="$(extract_function "$repo_root/macsmith.sh" _atomic_write_preserving_mode)"
mode_target="$tmp_root/mode-target"
print -r -- old >"$mode_target"
chmod 600 "$mode_target"
(
  typeset -ga _UPGRADE_TMP_FILES=()
  eval "$atomic_source"
  print -r -- new | _atomic_write_preserving_mode "$mode_target"
)
mode="$(stat -f '%Lp' "$mode_target" 2>/dev/null || print unknown)"
if [[ "$mode" == 600 ]] && [[ "$(<"$mode_target")" == new ]]; then
  pass "atomic config replacement preserves mode 0600"
else
  fail "atomic replacement mode/content (mode=$mode)"
fi

uninstall_home="$tmp_root/uninstall-home"
mkdir -p "$uninstall_home"
cat >"$uninstall_home/.zprofile" <<'ZPROFILE'
export KEEP_ME=1
# ==================== FINAL PATH CLEANUP (FOR .ZPROFILE) ====================
export PATH="$HOME/.local/bin:$PATH"
# End macsmith managed block
ZPROFILE
chmod 600 "$uninstall_home/.zprofile"
HOME="$uninstall_home" NO_COLOR=1 \
  bash "$repo_root/scripts/uninstall-macsmith.sh" --yes >"$tmp_root/uninstall.out" 2>&1
uninstall_rc=$?
uninstall_backups=("$uninstall_home"/.zprofile.backup-before-macsmith-uninstall-*(N))
if [[ $uninstall_rc -eq 0 ]] \
  && [[ "$(stat -f '%Lp' "$uninstall_home/.zprofile" 2>/dev/null)" == 600 ]] \
  && grep -q '^export KEEP_ME=1$' "$uninstall_home/.zprofile" \
  && ! grep -q 'FINAL PATH CLEANUP' "$uninstall_home/.zprofile" \
  && (( ${#uninstall_backups[@]} > 0 )); then
  pass "uninstall backs up first and preserves zprofile mode"
else
  fail "uninstall backup/mode contract"
fi

if [[ $EUID -ne 0 ]]; then
  blocked_home="$tmp_root/blocked-home"
  mkdir -p "$blocked_home"
  cp "$uninstall_home/.zprofile" "$blocked_home/.zprofile"
  print -r -- '# ==================== FINAL PATH CLEANUP (FOR .ZPROFILE) ====================' >>"$blocked_home/.zprofile"
  print -r -- '# End macsmith managed block' >>"$blocked_home/.zprofile"
  blocked_before="$(shasum -a 256 "$blocked_home/.zprofile" | awk '{print $1}')"
  chmod 500 "$blocked_home"
  HOME="$blocked_home" NO_COLOR=1 \
    bash "$repo_root/scripts/uninstall-macsmith.sh" --yes >"$tmp_root/blocked.out" 2>&1
  blocked_rc=$?
  chmod 700 "$blocked_home"
  blocked_after="$(shasum -a 256 "$blocked_home/.zprofile" | awk '{print $1}')"
  if [[ $blocked_rc -ne 0 && "$blocked_before" == "$blocked_after" ]]; then
    pass "uninstall refuses replacement when backup creation fails"
  else
    fail "uninstall modified config or returned success after backup failure"
  fi
fi

if grep -Eq 'ln -s[f]?.*(Cellar|PYENV_ROOT/versions)' "$repo_root/macsmith.sh" "$repo_root/zsh.sh"; then
  fail "Python management still links into Homebrew/pyenv version paths"
else
  pass "Python management does not fabricate pyenv versions or write Cellar"
fi

if grep -Fq 'gh attestation verify' "$repo_root/macsmith.sh"; then
  pass "self-upgrade verifies GitHub provenance"
else
  fail "self-upgrade provenance verification is missing"
fi

manifest="$repo_root/config/profiles.conf"
manifest_errors="$(awk -F'|' '
  /^#/ || NF == 0 { next }
  NF != 3 { print "invalid field count at line " NR; next }
  $1 !~ /^(power-user|crypto|netsec|devops|databases)$/ { print "invalid profile at line " NR }
  $2 !~ /^(formula|cask)$/ { print "invalid kind at line " NR }
  $3 !~ /^[A-Za-z0-9@._+\/-]+$/ { print "invalid package at line " NR }
  seen[$1 FS $2 FS $3]++ { print "duplicate package at line " NR }
' "$manifest")"
if [[ -z "$manifest_errors" ]] \
  && grep -Fq 'config/profiles.conf' "$repo_root/install.sh" \
  && grep -Fq 'config/profiles.conf' "$repo_root/macsmith.sh"; then
  pass "install and uninstall share one validated profile manifest"
else
  fail "shared profile manifest validation"
  [[ -n "$manifest_errors" ]] && print -ru2 -- "$manifest_errors"
fi

if [[ $failures -ne 0 ]]; then
  print -ru2 -- "$failures regression test(s) failed"
  exit 1
fi

print -r -- "All regression tests passed"
