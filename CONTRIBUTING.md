# Contributing

Thanks for helping make macsmith safer and more useful.

## Local Checks

Run these before opening a PR:

```bash
./quick-test.sh
zsh -n bootstrap.sh install.sh dev-tools.sh macsmith.sh zsh.sh
zsh -n scripts/nix-macos-maintenance.sh
bash -n scripts/uninstall-nix-macos.sh scripts/uninstall-macsmith.sh quick-test.sh
shellcheck -x -s bash bootstrap.sh install.sh dev-tools.sh macsmith.sh scripts/*.sh quick-test.sh
```

ShellCheck is noisy because most scripts are zsh. Treat new warnings around
quoting, temp files, traps, redirects, command injection, and `rm -rf` as
important even when style warnings remain.

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
