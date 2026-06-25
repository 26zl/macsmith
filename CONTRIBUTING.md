# Contributing

Thanks for helping make macsmith safer and more useful.

## Local Checks

Run these before opening a PR:

```bash
./quick-test.sh
zsh -n bootstrap.sh install.sh dev-tools.sh macsmith.sh zsh.sh
zsh -n scripts/nix-macos-maintenance.sh
bash -n scripts/uninstall-nix-macos.sh scripts/uninstall-macsmith.sh quick-test.sh
# ShellCheck — same flags + exclusion list CI uses (checks.yml). Outputs nothing on a clean tree.
shellcheck -s bash -S info \
  -e SC1090,SC1091,SC2148,SC3010,SC3030,SC3043,SC3054,SC3024,SC3014,SC3006,SC3018,SC3011,SC3001,SC3046,SC3060,SC2139,SC2155,SC2207,SC2034,SC2012,SC2162 \
  install.sh dev-tools.sh macsmith.sh zsh.sh bootstrap.sh quick-test.sh scripts/*.sh
```

The exclusion list covers zsh-dialect noise (`[[ ]]`, `local`, arrays) that
ShellCheck flags when linting zsh as bash. Running raw `shellcheck` instead
will report ~190 such warnings — that's not lint breakage. Any *new* warning
outside the excluded codes (quoting, temp files, traps, command injection,
`rm -rf`) is real; fix it.

## Safety Rules

- Keep destructive operations narrow and allowlisted.
- Prefer `mktemp` and private state dirs over predictable `/tmp` paths.
- Back up user config before rewriting it.
- Do not modify project-local dependency files during `update`.
- Keep `NONINTERACTIVE=1` conservative; use `MACSMITH_YES=1` for full auto-yes.
- Pin third-party GitHub Actions to commit SHAs.

## Manual Testing

For installer work, test in a disposable macOS account or VM when possible.
For uninstallers, run `--dry-run` first and inspect every planned change.
