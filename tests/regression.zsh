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

if grep -Eq 'PIPX_DEFAULT_PYTHON=' "$repo_root/macsmith.sh" "$repo_root/zsh.sh"; then
  fail "pipx venvs are pinned to the pyenv interpreter that update rotates"
else
  pass "pipx keeps its own interpreter (no PIPX_DEFAULT_PYTHON override)"
fi

if grep -Fq 'brew autoremove' "$repo_root/macsmith.sh" \
  && grep -Fq '_pipx_repair_broken_venvs' "$repo_root/macsmith.sh"; then
  pass "update removes orphaned Homebrew dependencies and repairs pipx venvs"
else
  fail "update is missing brew autoremove or pipx venv repair"
fi

# Exercise the Python hygiene helpers against fakes so they never touch the real pyenv/pipx.
hygiene_root="$tmp_root/hygiene"
mkdir -p "$hygiene_root/bin" "$hygiene_root/brew/opt/python@3.14/bin" \
  "$hygiene_root/pyenv/versions/3.15.0/bin" "$hygiene_root/venvs/good/bin" "$hygiene_root/venvs/broken/bin" \
  "$hygiene_root/venvs/good/lib/python3.14/site-packages" "$hygiene_root/venvs/stale/bin" \
  "$hygiene_root/venvs/stale/lib/python3.14/site-packages" "$hygiene_root/venvs/uvonly/bin" \
  "$hygiene_root/shared/lib/python3.14/site-packages"
ln -s "$hygiene_root/brew/opt/python@3.14" "$hygiene_root/pyenv/versions/3.14.6"
ln -s "$hygiene_root/gone" "$hygiene_root/pyenv/versions/dangling"
ln -s "$hygiene_root/pyenv/versions/3.15.0" "$hygiene_root/pyenv/versions/my-venv"
ln -s "$hygiene_root/brew/opt/python@3.14" "$hygiene_root/pyenv/versions/active-link"
ln -s /usr/bin/python3 "$hygiene_root/venvs/good/bin/python"
ln -s "$hygiene_root/gone/python3" "$hygiene_root/venvs/broken/bin/python"
printf 'home = %s\n' "$hygiene_root/gone" >"$hygiene_root/venvs/broken/pyvenv.cfg"
# pip-backend venvs borrow pip through pipx_shared.pth: `good` points at the live
# shared venv, `stale` at the python3.13 one pipx rebuilt away, `uvonly` has none.
ln -s /usr/bin/python3 "$hygiene_root/venvs/stale/bin/python"
ln -s /usr/bin/python3 "$hygiene_root/venvs/uvonly/bin/python"
print -r -- "$hygiene_root/shared/lib/python3.14/site-packages" >"$hygiene_root/venvs/good/lib/python3.14/site-packages/pipx_shared.pth"
print -r -- "$hygiene_root/shared/lib/python3.13/site-packages" >"$hygiene_root/venvs/stale/lib/python3.14/site-packages/pipx_shared.pth"
cat >"$hygiene_root/bin/pyenv" <<'FAKE'
#!/bin/sh
case "$1" in version-name) echo active-link ;; esac
exit 0
FAKE
cat >"$hygiene_root/bin/pipx" <<'FAKE'
#!/bin/sh
case "$1" in
  environment) echo "$HYGIENE_VENVS" ;;
  reinstall) echo "$2" >>"$HYGIENE_LOG" ;;
esac
exit 0
FAKE
chmod 700 "$hygiene_root/bin/pyenv" "$hygiene_root/bin/pipx"
hygiene_fns="$(
  extract_function "$repo_root/macsmith.sh" _pyenv_remove_homebrew_links
  extract_function "$repo_root/macsmith.sh" _pipx_repair_broken_venvs
)"
(
  GREEN='' RED='' YELLOW='' BLUE='' NC=''
  # shellcheck disable=SC2329  # called by the extracted helpers after eval
  _detect_brew_prefix() { print -r -- "$hygiene_root/brew"; }
  eval "$hygiene_fns"
  export PATH="$hygiene_root/bin:/usr/bin:/bin" PYENV_ROOT="$hygiene_root/pyenv" HOME="$hygiene_root"
  export HYGIENE_VENVS="$hygiene_root/venvs" HYGIENE_LOG="$hygiene_root/reinstalled"
  _pyenv_remove_homebrew_links >/dev/null
  _pipx_repair_broken_venvs >/dev/null
)
if [[ ! -L "$hygiene_root/pyenv/versions/3.14.6" ]] \
  && [[ ! -L "$hygiene_root/pyenv/versions/dangling" ]] \
  && [[ -L "$hygiene_root/pyenv/versions/my-venv" ]] \
  && [[ -L "$hygiene_root/pyenv/versions/active-link" ]] \
  && [[ -d "$hygiene_root/pyenv/versions/3.15.0" ]] \
  && [[ -d "$hygiene_root/brew/opt/python@3.14" ]]; then
  pass "pyenv link cleanup drops Homebrew/dangling links, keeps builds, virtualenvs and the active version"
else
  fail "pyenv link cleanup touched the wrong entries"
fi
if [[ "$(cat "$hygiene_root/reinstalled" 2>/dev/null)" == $'broken\nstale' ]]; then
  pass "pipx repair reinstalls only venvs with a missing interpreter or a stale shared-pip link"
else
  fail "pipx repair reinstalled: $(tr '\n' ' ' <"$hygiene_root/reinstalled" 2>/dev/null || print none)"
fi

# `mas outdated` right-aligns app IDs, so all but the widest line start with spaces.
mas_count_fn="$(extract_function "$repo_root/macsmith.sh" _mas_count_outdated)"
mas_sample=$'1339170533  CleanMyMac   (5.7.1  -> 5.7.2)\n 545519333  Prime Video  (10.152 -> 10.153.2)'
if [[ -n "$mas_count_fn" ]] && (
  eval "$mas_count_fn"
  [[ "$(_mas_count_outdated "$mas_sample")" == 2 && "$(_mas_count_outdated "")" == 0 ]]
); then
  pass "mas outdated count includes right-aligned app IDs"
else
  fail "mas outdated count mis-counts right-aligned app IDs"
fi

# A tap cask warning on stderr must not turn an empty autoremove dry-run into a "would remove" list.
autoremove_root="$tmp_root/autoremove"
mkdir -p "$autoremove_root/quiet/bin" "$autoremove_root/listed/bin"
cat >"$autoremove_root/quiet/bin/brew" <<'FAKE'
#!/bin/sh
echo 'Warning: Calling `postflight` is deprecated! Use `postflight_steps` instead.' >&2
exit 0
FAKE
cat >"$autoremove_root/listed/bin/brew" <<'FAKE'
#!/bin/sh
echo 'Warning: Calling `postflight` is deprecated! Use `postflight_steps` instead.' >&2
printf '==> Would autoremove 1 unneeded formula:\nicu4c@77\n'
exit 0
FAKE
chmod 700 "$autoremove_root/quiet/bin/brew" "$autoremove_root/listed/bin/brew"
autoremove_fns="$(
  extract_function "$repo_root/macsmith.sh" _is_enabled
  extract_function "$repo_root/macsmith.sh" _brew_autoremove_guarded
)"
# Prefix assignments scope PATH to the call (zsh restores it afterwards).
autoremove_quiet="$(
  GREEN='' RED='' YELLOW='' BLUE='' NC=''
  eval "$autoremove_fns"
  PATH="$autoremove_root/quiet/bin:/usr/bin:/bin" MACSMITH_CLEAN_BREW="" _brew_autoremove_guarded 2>&1
)"
autoremove_listed="$(
  GREEN='' RED='' YELLOW='' BLUE='' NC=''
  eval "$autoremove_fns"
  PATH="$autoremove_root/listed/bin:/usr/bin:/bin" MACSMITH_CLEAN_BREW="" _brew_autoremove_guarded 2>&1
)"
if [[ -z "$autoremove_quiet" && "$autoremove_listed" == *"icu4c@77"* && "$autoremove_listed" != *postflight* ]]; then
  pass "autoremove dry-run reports stdout only (tap warnings on stderr are not a removal list)"
else
  fail "autoremove dry-run output — quiet: [$autoremove_quiet] listed: [$autoremove_listed]"
fi

# Default runtime pruning removes only superseded versions (fixtures mirror a real
# machine: nine nvm Nodes, one of them pinned by .nvmrc; four ~5 GB Swift toolchains).
superseded_fn="$(extract_function "$repo_root/macsmith.sh" _superseded_versions)"
superseded_ok=1
superseded_check() {  # depth installed protected expected
  local got=""
  got="$(eval "$superseded_fn"; _superseded_versions "$1" "$2" "$3" | tr '\n' ' ')"
  [[ "$got" == "$4" ]] && return 0
  print -ru2 -- "  _superseded_versions $1: got [$got], want [$4]"
  return 1
}
node_installed=$'24.18.0\n24.18.1\n24.19.0\n24.20.0\n24.21.0\n24.22.0\n24.22.1\n26.13.0\n26.13.1'
swift_installed=$'6.3.3\n6.4.0\n6.4.1\n6.4.2'
if [[ -z "$superseded_fn" ]]; then
  superseded_ok=0
else
  superseded_check 1 "$node_installed" $'26.13.1\n24.21.0' '24.18.0 24.18.1 24.19.0 24.20.0 24.22.0 26.13.0 ' || superseded_ok=0
  superseded_check 1 "$node_installed" $'26.13.1\n24.21\nN/A\nlts/*' '24.18.0 24.18.1 24.19.0 24.20.0 24.22.0 26.13.0 ' || superseded_ok=0
  superseded_check 2 $'3.14.2\n3.15.0\n3.15.1\n3.15.2\n3.15.0t\nmy-venv' '3.15.2' '3.15.0 3.15.1 ' || superseded_ok=0
  superseded_check 1 "$swift_installed" '6.4.2' '6.3.3 6.4.0 6.4.1 ' || superseded_ok=0
  superseded_check 1 "$swift_installed" $'6.4.2\n6.3' '6.4.0 6.4.1 ' || superseded_ok=0
  superseded_check 2 $'3.4.10\n3.4.6\n3.3.9' 'ruby-x' '3.4.6 ' || superseded_ok=0
  superseded_check 1 '' '26.13.1' '' || superseded_ok=0
fi
if [[ $superseded_ok -eq 1 ]]; then
  pass "runtime pruning selects only superseded versions (newest per line, protected and prefix-pinned ones stay)"
else
  fail "runtime pruning selection"
fi

# The pin/venv scan is bounded to $HOME (6 levels, Library/node_modules skipped) plus Poetry's cache.
refs_home="$tmp_root/refs-home"
mkdir -p "$refs_home/code/app" "$refs_home/code/web/node_modules/dep" "$refs_home/a/b/c/d/e/f" \
  "$refs_home/code/api/.venv" "$refs_home/Library/Caches/pypoetry/virtualenvs/tool-py3.12" \
  "$refs_home/Library/Other" "$refs_home/.pyenv/versions/3.14.1/envs/legacy"
print -r -- 'v24.21.0' >"$refs_home/code/app/.nvmrc"
print -r -- '99.0.0' >"$refs_home/code/web/node_modules/dep/.nvmrc"
print -r -- '98.0.0' >"$refs_home/a/b/c/d/e/f/.nvmrc"
print -r -- '97.0.0' >"$refs_home/Library/Other/.nvmrc"
printf '%s\n' '# project pin' '3.15.1 3.13.9' >"$refs_home/code/app/.python-version"
printf 'home = %s\n' "$refs_home/.pyenv/versions/3.15.0/bin" >"$refs_home/code/api/.venv/pyvenv.cfg"
printf 'home = %s\n' "$refs_home/.pyenv/versions/3.12.4/bin" \
  >"$refs_home/Library/Caches/pypoetry/virtualenvs/tool-py3.12/pyvenv.cfg"
refs_fns="$(
  extract_function "$repo_root/macsmith.sh" _runtime_ref_scan
  extract_function "$repo_root/macsmith.sh" _runtime_pins
  extract_function "$repo_root/macsmith.sh" _pyenv_referenced_versions
)"
refs_script="$(cat <<'SCRIPT'
_RUNTIME_REF_FILES='' _RUNTIME_REF_SCANNED=false
_runtime_ref_scan
print -r -- "nvm:$(_runtime_pins .nvmrc | tr '\n' ' ')"
print -r -- "py:$(_runtime_pins .python-version | tr '\n' ' ')"
print -r -- "venv:$(_pyenv_referenced_versions | sort | tr '\n' ' ')"
SCRIPT
)"
refs_out="$(env -i HOME="$refs_home" PYENV_ROOT="$refs_home/.pyenv" PATH=/usr/bin:/bin \
  /bin/zsh -f -c "$refs_fns"$'\n'"$refs_script")"
if [[ "$refs_out" == $'nvm:v24.21.0 \npy:3.15.1 3.13.9 \nvenv:3.12.4 3.14.1 3.15.0 ' ]]; then
  pass "pin/venv scan finds project pins and venv interpreters, skips node_modules, Library and >6 levels"
else
  fail "pin/venv scan returned: $refs_out"
fi

# Each tool's pruning keeps its active/default/pinned/venv-backed versions and removes only the rest.
prune_root="$tmp_root/prune"
mkdir -p "$prune_root/bin" "$prune_root/home/proj" "$prune_root/home/api/.venv" "$prune_root/home/.nvm/alias" \
  "$prune_root/home/.pyenv/versions/3.14.0/envs/legacy" "$prune_root/home/.rubies/ruby-3.3.9" \
  "$prune_root/home/.rubies/ruby-3.4.5" "$prune_root/home/.rubies/ruby-3.4.6" "$prune_root/home/.rubies/ruby-3.4.7"
print -r -- 'v24.21.0' >"$prune_root/home/proj/.nvmrc"
print -r -- '3.15.1' >"$prune_root/home/proj/.python-version"
print -r -- 'ruby-3.4.6' >"$prune_root/home/proj/.ruby-version"
print -r -- '6.3' >"$prune_root/home/proj/.swift-version"
print -r -- '24.20' >"$prune_root/home/.nvm/alias/default"
print -r -- '3.15.2' >"$prune_root/home/.pyenv/version"
printf 'home = %s\n' "$prune_root/home/.pyenv/versions/3.15.0/bin" >"$prune_root/home/api/.venv/pyvenv.cfg"
cat >"$prune_root/bin/pyenv" <<'FAKE'
#!/bin/sh
case "$1" in
  versions) printf '%s\n' 3.13.7 3.13.8 3.13.9 3.14.0 3.14.2 3.15.0 3.15.1 3.15.2 3.15.0t legacy ;;
  version-name) echo 3.15.2 ;;
  uninstall) echo "pyenv $3" >>"$PRUNE_LOG" ;;
esac
exit 0
FAKE
cat >"$prune_root/bin/swiftly" <<'FAKE'
#!/bin/sh
case "$1" in
  list)
    marks=' (in use) (default)'
    [ -n "${SWIFTLY_UNMARKED:-}" ] && marks=''
    printf '%s\n' 'Installed release toolchains' '----------------------------' "Swift 6.4.2$marks" \
      'Swift 6.4.1' 'Swift 6.4.0' 'Swift 6.3.3' 'Swift 6.2.1' '' 'Installed snapshot toolchains' \
      '-----------------------------' 'main-snapshot-2026-10-01' ;;
  uninstall) echo "swiftly $2 $3" >>"$PRUNE_LOG" ;;
esac
exit 0
FAKE
chmod 700 "$prune_root/bin/pyenv" "$prune_root/bin/swiftly"
prune_fns="$(
  for prune_fn in _runtime_ref_scan _runtime_pins _pyenv_referenced_versions _superseded_versions \
    _prune_superseded _pyenv_prune_superseded _nvm_prune_superseded _chruby_remove_ruby \
    _chruby_prune_superseded _swiftly_prune_superseded; do
    extract_function "$repo_root/macsmith.sh" "$prune_fn"
  done
)"
# The nvm stand-in replaces the shell function the extracted helpers call.
prune_script="$(cat <<'SCRIPT'
GREEN='' RED='' NC='' _RUNTIME_REF_FILES='' _RUNTIME_REF_SCANNED=false
nvm() {
  case "$1" in
    ls) printf '%s\n' '       v24.18.0' '       v24.20.0' '       v24.21.0' '       v24.22.1' '->     v26.13.0' '       v26.13.1' ;;
    version)
      case "$2" in
        default) print -r -- v24.20.0 ;;
        v24.21.0) print -r -- v24.21.0 ;;
        *) print -r -- N/A; return 3 ;;
      esac ;;
    uninstall) print -r -- "nvm $2" >>"$PRUNE_LOG" ;;
  esac
}
_pyenv_prune_superseded 3.15.2 3.13.8 >/dev/null
_nvm_prune_superseded v26.13.0 >/dev/null
_chruby_prune_superseded ruby-3.4.7 >/dev/null
_swiftly_prune_superseded >/dev/null
export SWIFTLY_UNMARKED=1
_swiftly_prune_superseded >/dev/null
SCRIPT
)"
env -i HOME="$prune_root/home" PYENV_ROOT="$prune_root/home/.pyenv" NVM_DIR="$prune_root/home/.nvm" \
  PATH="$prune_root/bin:/usr/bin:/bin" PRUNE_LOG="$prune_root/removed" MACSMITH_SWIFTLY_KEEP='6.1.0, 6.4.0' \
  /bin/zsh -f -c "$prune_fns"$'\n'"$prune_script"
prune_log="$(tr '\n' '|' <"$prune_root/removed" 2>/dev/null)"
prune_rubies="$(cd "$prune_root/home/.rubies" && print -r -- *)"
if [[ "$prune_log" == 'pyenv 3.13.7|nvm 24.18.0|swiftly --assume-yes 6.2.1|swiftly --assume-yes 6.4.1|' \
  && "$prune_rubies" == 'ruby-3.3.9 ruby-3.4.6 ruby-3.4.7' ]]; then
  pass "pyenv/nvm/chruby/swiftly pruning keeps active, default, KEEP, pinned and venv-backed versions"
else
  fail "runtime pruning removed: [$prune_log], rubies left: [$prune_rubies]"
fi

# Final PATH cleanups: pyenv's shims stay ahead of Homebrew (python@3.x links python3/pip3
# into Homebrew's bin), and nothing else moves ahead of Homebrew (CI's login-PATH contract).
path_home="$tmp_root/path-home"
path_brew="$tmp_root/path-brew"
path_shims="$path_home/.pyenv/shims"
mkdir -p "$path_shims" "$path_brew/bin" "$path_brew/sbin"
zshrc_cleanup="$(sed -n '/^# =* FINAL PATH CLEANUP =*$/,/^# TOOL HOOKS$/p' "$repo_root/zsh.sh")"
zprofile_block="$(sed -n '/^# =.* FINAL PATH CLEANUP (FOR \.ZPROFILE) =.*$/,/^# End macsmith managed block$/p' "$repo_root/install.sh")"
path_after() {  # script PATH [HOMEBREW_PREFIX]
  env -i HOME="$path_home" PYENV_ROOT="$path_home/.pyenv" PATH="$2" HOMEBREW_PREFIX="${3:-}" \
    /bin/zsh -f -c "$1"$'\n'"print -r -- \"\$PATH\""
}
path_ok=1
[[ -n "$zshrc_cleanup" && -n "$zprofile_block" ]] || path_ok=0
[[ "$(path_after "$zshrc_cleanup" "$path_shims:$path_home/.local/bin:$path_brew/bin:/usr/bin:/bin" "$path_brew")" \
  == "$path_shims:$path_brew/bin:$path_brew/sbin:$path_home/.local/bin:/usr/bin:/bin" ]] || path_ok=0
[[ "$(path_after "$zshrc_cleanup" "$path_home/.cargo/bin:$path_brew/bin:/usr/bin:/bin" "$path_brew")" \
  == "$path_brew/bin:$path_brew/sbin:$path_home/.cargo/bin:/usr/bin:/bin" ]] || path_ok=0
real_brew="$(eval "$(extract_function "$repo_root/zsh.sh" _detect_brew_prefix)"; _detect_brew_prefix)"
if [[ -n "$real_brew" ]]; then
  [[ "$(path_after "$zprofile_block" "$path_shims:/usr/bin:/bin")" == "$path_shims:$real_brew/bin:"* ]] || path_ok=0
  [[ "$(path_after "$zprofile_block" "/usr/bin:/bin")" == "$real_brew/bin:"* ]] || path_ok=0
fi
if [[ $path_ok -eq 1 ]]; then
  pass "final PATH cleanups keep pyenv shims ahead of Homebrew and Homebrew ahead of everything else"
else
  fail "final PATH cleanup ordering (pyenv shims vs Homebrew)"
fi

# nvm.sh declares `local VERSION` twice in nvm(); without TYPESET_SILENT zsh echoes VERSION='' mid-update.
if grep -Eq '^setopt typeset_silent' "$repo_root/macsmith.sh"; then
  pass "update silences zsh's duplicate-local echo (nvm's VERSION='' line)"
else
  fail "macsmith.sh lost 'setopt typeset_silent' — nvm reinstall-packages prints VERSION='' under zsh"
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

# A gem whose CLI fails --version/-v/--help is reinstalled only when it does not load: minitest 6's
# test runner exits 1 outside a project, and update used to "fix" it with a reinstall every run.
gem_root="$(mktemp -d "${TMPDIR:-/tmp}/macsmith-gems.XXXXXX")"
mkdir -p "$gem_root/bin"
print -rl -- '#!/bin/sh' 'exit 1' > "$gem_root/bin/runner-cli"
print -rl -- '#!/bin/sh' 'exit 1' > "$gem_root/bin/broken-cli"
print -rl -- '#!/bin/sh' 'exit 0' > "$gem_root/bin/good-cli"
chmod +x "$gem_root/bin/"*
gem_fix_out="$(
  PATH="$gem_root/bin:/usr/bin:/bin"
  GREEN="" RED="" BLUE="" NC=""
  eval "$(extract_function "$repo_root/macsmith.sh" _probe_gem_executable)"
  eval "$(extract_function "$repo_root/macsmith.sh" _fix_all_ruby_gems)"
  # shellcheck disable=SC2329  # stand-ins called by the extracted function after eval
  _timeout() { shift; "$@"; }
  # shellcheck disable=SC2329
  _is_enabled() { return 1; }
  # shellcheck disable=SC2329
  _is_project_directory() { return 1; }
  # shellcheck disable=SC2329
  _gem_loads() { [[ "$1" == runner-gem ]]; }
  # shellcheck disable=SC2329
  ruby() {
    if [[ "$1" == -v ]]; then print -r -- "ruby 3.4.6 (test)"; return 0; fi
    local last=""
    for last; do :; done
    case "$last" in runner-gem) print runner-cli ;; broken-gem) print broken-cli ;; good-gem) print good-cli ;; esac
  }
  # shellcheck disable=SC2329
  gem() {
    case "$1 $2" in
      "list --no-versions") print -l runner-gem broken-gem good-gem ;;
      list\ *) print -r -- "$2 (1.0.0)" ;;
      install\ *) print -r -- "$2" >> "$gem_root/installed" ;;
    esac
  }
  _fix_all_ruby_gems 2>&1
)"
if [[ "$(cat "$gem_root/installed" 2>/dev/null)" == broken-gem ]] \
  && [[ "$gem_fix_out" == *"DETECTED: broken-gem executable is broken"* ]] \
  && [[ "$gem_fix_out" != *"DETECTED: runner-gem"* ]] \
  && [[ "$gem_fix_out" != *"DETECTED: good-gem"* ]] \
  && [[ "$gem_fix_out" == *"(2 working properly)"* ]]; then
  pass "gem auto-fix reinstalls only gems that do not load, not CLIs without a version flag"
else
  fail "gem auto-fix reinstalled: $(tr '\n' ' ' <"$gem_root/installed" 2>/dev/null || print none)"
  print -ru2 -- "$gem_fix_out"
fi

if command -v ruby >/dev/null 2>&1 && ruby -e 'exit(Gem::Specification.find_by_name("bundler") ? 0 : 1)' >/dev/null 2>&1; then
  print -r -- '#!/nonexistent/ruby' > "$gem_root/dead-shebang"
  gem_loads_result="$(
    eval "$(extract_function "$repo_root/macsmith.sh" _gem_loads)"
    # shellcheck disable=SC2329
    _timeout() { shift; "$@"; }
    if _gem_loads bundler ""; then print -n "ok "; else print -n "FAIL "; fi
    if _gem_loads bundler "$gem_root/dead-shebang"; then print -n "FAIL "; else print -n "ok "; fi
    if _gem_loads no-such-gem-macsmith ""; then print -n "FAIL"; else print -n "ok"; fi
  )"
  if [[ "$gem_loads_result" == "ok ok ok" ]]; then
    pass "_gem_loads accepts an installed gem and rejects a dead interpreter or a missing gem"
  else
    fail "_gem_loads verdicts wrong (bundler, dead shebang, missing gem): $gem_loads_result"
  fi
else
  pass "_gem_loads real-Ruby check skipped (no Ruby with bundler on PATH)"
fi
command rm -rf -- "$gem_root"

# zsh ties the array `path` (and fpath, cdpath, manpath, module_path, mailpath) to its scalar
# twin: a loop or local named `path` replaces PATH for the rest of the function, which made
# `update` report Go, Rust, .NET, chruby and mas as "Not found" once conda was absent.
special_var_hits="$(grep -nE '(for|local|typeset|declare)[[:space:]]+([^#]*[[:space:]])?(path|fpath|cdpath|manpath|module_path|mailpath)([=[:space:]]|$)' \
  "$repo_root"/*.sh "$repo_root"/scripts/*.sh "$repo_root"/tests/*.zsh 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*#|special_var_hits' || true)"
if [[ -z "$special_var_hits" ]]; then
  pass "no zsh script names a variable after a PATH-tied array"
else
  fail "a variable is named after a PATH-tied zsh array"
  print -ru2 -- "$special_var_hits"
fi

mysql_tmp="$(mktemp -d "${TMPDIR:-/tmp}/macsmith-mysql.XXXXXX")"
mkdir -p "$mysql_tmp/mysql/bin" "$mysql_tmp/mysql/support-files"
print -r -- '#!/bin/sh' > "$mysql_tmp/mysql/bin/mysql"
chmod +x "$mysql_tmp/mysql/bin/mysql"
: > "$mysql_tmp/mysql/support-files/mysql.server"
mysql_found="$(
  HOMEBREW_PREFIX="$mysql_tmp/no-brew"
  PATH="$mysql_tmp/mysql/bin:/usr/bin:/bin"
  eval "$(extract_function "$repo_root/zsh.sh" _detect_mysql_path)"
  _detect_mysql_path
)"
if [[ "$mysql_found" == "$mysql_tmp/mysql" ]]; then
  pass "_detect_mysql_path keeps PATH for its command -v fallback"
else
  fail "_detect_mysql_path lost PATH after its loop (got '${mysql_found}')"
fi
command rm -rf -- "$mysql_tmp"

if [[ $failures -ne 0 ]]; then
  print -ru2 -- "$failures regression test(s) failed"
  exit 1
fi

print -r -- "All regression tests passed"
