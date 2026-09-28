# Contributing

Thanks for helping out! This project is two small scripts, so contributing is simple.

## Ground rules

- **Keep each script a single file** with no dependencies beyond what the OS ships (bash + curl, or PowerShell + curl.exe), plus Node/portless/Herd. Users run the scripts remotely with `curl | bash` and `irm`.
- **Keep the two scripts in step.** A feature or fix in `portless-herd.sh` should get the same change in `portless-herd.ps1`, or the PR should explain why it doesn't apply.
- **Keep `setup` idempotent.** Running it twice must be safe and must not duplicate anything.
- **Make `teardown` undo everything `setup` does**, including anything you add.
- **Compatibility:** bash 3.2 (macOS's default) and Windows PowerShell 5.1. Keep `portless-herd.ps1` ASCII-only, because PowerShell 5.1 misreads UTF-8 files that have no BOM.

## Testing your change

Test in isolation so you don't disturb your real setup. Give it a throwaway suffix, port, state folder, config folder and rc file:

```bash
export SUFFIX=zz PROXY_PORT=1366 SHELL_RC=/tmp/rc PORTLESS_STATE_DIR=/tmp/pl PORTLESS_HERD_CONFIG_DIR=/tmp/cfg
./portless-herd.sh setup -y
./portless-herd.sh status
./portless-herd.sh            # interactive menu
./portless-herd.sh teardown -y
```

Standalone mode on a free port:

```bash
MODE=standalone SUFFIX=yy PROXY_PORT=1377 SHELL_RC=/tmp/rc2 PORTLESS_STATE_DIR=/tmp/pl2 PORTLESS_HERD_CONFIG_DIR=/tmp/cfg2 ./portless-herd.sh setup -y
```

Always pass an explicit throwaway `SUFFIX`. Otherwise an unexpected default could act on your real `web` setup.

Lint before opening a PR:

```bash
shellcheck portless-herd.sh
pwsh -c "Invoke-ScriptAnalyzer ./portless-herd.ps1"
```

CI runs both linters, plus standalone smoke tests on Ubuntu and Windows.

## Reporting a bug

Include:
- the output of `status`
- your OS, your Herd version (`herd --version`) and your portless version (`portless --version`)
- the last lines of `~/.portless/proxy.log`
