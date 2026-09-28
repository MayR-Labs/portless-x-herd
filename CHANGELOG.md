# Changelog

All notable changes to this project are documented here. This project follows [Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-09-28

### Added
- `portless-herd.sh` for macOS and Linux with `setup`, `status`, `teardown` and `version` commands.
- Interactive mode: run with no arguments to see the status and choose setup, change settings, repair or teardown.
- Configurable setup: prompts for suffix, mode, port and shell file. Settings are saved to `~/.config/portless-x-herd/config` and reused. Changing settings removes the old setup first.
- `--suffix`, `--mode`, `--port`, `--rc` and `-y/--yes` flags (`-Suffix`, `-Mode`, `-ProxyPort`, `-Yes` on Windows).
- `portless-herd.ps1` for Windows (PowerShell 5.1 and 7) with the same commands.
- **herd mode**: Herd nginx terminates TLS for `*.<suffix>.test` and forwards to portless on `127.0.0.1:1355`.
- **standalone mode**: portless serves HTTPS on :443 with the `.test` TLD (Linux, or any machine without Herd).
- End-to-end check that `https://<anything>.<suffix>.test` reaches portless over trusted HTTPS.
- Manual setup and teardown guide in `docs/manual-setup.md`.
