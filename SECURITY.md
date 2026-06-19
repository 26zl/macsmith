# Security Policy

macsmith installs and maintains developer tooling on macOS, so security issues
are treated as release blockers.

## Supported Versions

Security fixes are made on `main` and shipped through the latest GitHub release.
Use the newest tag from the Releases page for reproducible installs.

## Reporting a Vulnerability

Please report vulnerabilities privately through GitHub Security Advisories:

https://github.com/26zl/macsmith/security/advisories/new

If advisories are unavailable, open a minimal public issue that says a private
security report is needed, without exploit details.

Useful details:

- macOS version and CPU architecture
- command used to run macsmith
- relevant environment variables, with secrets redacted
- expected behavior, actual behavior, and why it is unsafe

## Safety Expectations

- No script should delete broad system paths or user data without a narrow
  allowlist and confirmation.
- Nix APFS volume deletion must always require typing `yes`, even when `--yes`
  or `MACSMITH_YES=1` is used elsewhere.
- Existing shell config must be backed up before replacement.
- Release automation must not run untrusted workflow input as shell code.
- Network downloads must use HTTPS and bounded timeouts.
