# portless-x-herd

**Clean HTTPS URLs for every local dev server: `https://<app>.web.test`**, with no port numbers and no fighting [Laravel Herd](https://herd.laravel.com) over ports 80 and 443.

[portless](https://github.com/vercel-labs/portless) gives each dev server a stable name instead of a port. Herd already owns `:443` and `*.test` on your machine. This project connects the two, so your Laravel sites keep working at `*.test` and your Node/Next.js apps get `*.web.test`:

```text
https://myapp.web.test
  → Herd nginx   owns :443, wildcard TLS for *.web.test, forwards the Host header
  → portless     plain HTTP on 127.0.0.1:1355, routes by hostname
  → your app     random port (4000–4999) picked by portless
```

Run the script with no arguments. It checks what's already set up, then offers the next step: set it up, change the settings, repair it, or remove it.

```bash
./portless-herd.sh                    # interactive: status, then setup / change / repair / teardown
cd ~/code/myapp && portless           # → https://myapp.web.test
```

---

## Platforms

| Platform                   | Mode         | How it works                                                                    | Status                      |
| -------------------------- | ------------ | ------------------------------------------------------------------------------- | --------------------------- |
| **macOS**                  | `herd`       | Herd nginx → portless on :1355. Herd's DNS resolves `*.test`.                   | ✅ Tested                    |
| **Windows**                | `herd`       | Herd nginx → portless on :1355. Hosts-file entries are written by portless.     | 🧪 Experimental              |
| **Linux**                  | `standalone` | No Herd on Linux, so portless serves HTTPS on :443 itself with the `.test` TLD. | ✅ Supported (CI smoke test) |
| macOS/Windows without Herd | `standalone` | Same as Linux.                                                                  | ✅ Supported                 |

The URLs are the same in every mode (`https://<app>.web.test`), so a team on mixed operating systems uses the same app names.

---

## Quick start

### Run it remotely (no clone)

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/MayR-Labs/portless-x-herd/main/portless-herd.sh | bash
```

**Windows** (PowerShell, **run as Administrator** so portless can write hosts-file entries)

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/MayR-Labs/portless-x-herd/main/portless-herd.ps1)))
```

Both commands start the interactive menu, and the prompts work even when the script is piped in. To skip the menu, pass a command and options, for example for scripts or CI:

```bash
curl -fsSL https://raw.githubusercontent.com/MayR-Labs/portless-x-herd/main/portless-herd.sh | bash -s -- setup --suffix apps -y
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/MayR-Labs/portless-x-herd/main/portless-herd.ps1))) setup -Suffix apps -Yes
```

> Piping a script from the internet into a shell runs it with your permissions. Read [`portless-herd.sh`](portless-herd.sh) / [`portless-herd.ps1`](portless-herd.ps1) first. Each is a single readable file.

### Install it as a command

**macOS / Linux**

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/MayR-Labs/portless-x-herd/main/portless-herd.sh -o ~/.local/bin/portless-herd
chmod +x ~/.local/bin/portless-herd
PORTLESS_HERD_CMD=portless-herd portless-herd
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/MayR-Labs/portless-x-herd/main/portless-herd.ps1 -OutFile $HOME\portless-herd.ps1
powershell -ExecutionPolicy Bypass -File $HOME\portless-herd.ps1
```

### From a clone

```bash
git clone https://github.com/MayR-Labs/portless-x-herd.git
cd portless-x-herd
./portless-herd.sh                # macOS / Linux
.\portless-herd.ps1               # Windows
```

---

## Using it with your apps

Name every app `<app>.web`, either in `package.json`:

```json
{
  "scripts": { "dev": "next dev" },
  "portless": { "name": "myapp.web" }
}
```

or in `portless.json`:

```json
{ "name": "myapp.web" }
```

Then start the app with portless:

```bash
cd ~/code/myapp && portless
```

Open **<https://myapp.web.test>**.

- In herd mode, portless prints `http://myapp.web.test:1355`. **Ignore it** and use the `https://` URL without a port.
- **Next.js:** if hot reload is blocked on the custom domain, add this to `next.config`:

  ```ts
  allowedDevOrigins: ["*.web.test"],
  ```

- **Monorepos:** give each workspace app its own `<name>.web` in the root `portless.json` (`{ "apps": { "apps/web": { "name": "site.web" } } }`).

---

## Running it

### Interactive (no arguments)

The script shows the status of every piece, then offers what fits:

| State | You're asked |
| --- | --- |
| Not set up | **Set it up now? [Y/n]** |
| Set up and working | **[c]hange settings, [t]ear down, or [q]uit?** |
| Partly set up / broken | **[r]epair, [c]hange settings, [t]ear down, or [q]uit?** |

### Configurable setup

`setup` asks for each setting. Press Enter to keep the value shown in brackets:

```text
==> Configure (press Enter to keep the value in [brackets])
  App suffix — apps at https://<app>.<suffix>.test [web]: apps
  Mode — 'herd' (behind Laravel Herd) or 'standalone' (portless owns :443) [herd]:
  portless port (any free port; Herd keeps 80/443) [1355]:
  Shell file for the PORTLESS_* exports [/Users/you/.zshrc]:

    Apps:       https://<app>.apps.test
    Mode:       herd (behind Laravel Herd)
    Port:       1355
    Shell file: /Users/you/.zshrc

  Proceed? [Y/n]
```

Your answers are saved to `~/.config/portless-x-herd/config`, so later runs of `status`, `teardown` and the menu use them. When you **change settings** on a working setup, the script removes the old one first (its Herd proxy, portless settings and shell exports), so nothing is left behind.

### Commands

To skip the menu, pass a command:

| Command    | What it does |
| ---------- | --- |
| `setup`    | Asks for settings, installs anything missing, configures everything, and tests the whole chain. Safe to re-run. |
| `status`   | Checks each piece, runs an end-to-end test, and lists running apps with their real URLs. |
| `teardown` | Undoes everything `setup` did, including the saved settings. Herd and portless stay installed. |
| `version`  | Prints the script version. |

### Options

Options override the saved settings. The priority order is **flag, then environment variable, then saved setting, then default**.

| Bash flag | Env var | PowerShell | Default | Meaning |
| --- | --- | --- | --- | --- |
| `-s, --suffix <name>` | `SUFFIX` | `-Suffix` | `web` | Apps live at `*.<suffix>.test` |
| `-m, --mode <mode>` | `MODE` | `-Mode` | herd if Herd is available, else standalone | `herd` or `standalone`, see [Platforms](#platforms) |
| `-p, --port <port>` | `PROXY_PORT` | `-ProxyPort` | `1355` (herd), `443` (standalone) | Port portless listens on |
| `--rc <file>` | `SHELL_RC` | n/a | your shell's rc file | Where the `PORTLESS_*` exports go |
| `-y, --yes` | `PORTLESS_HERD_YES=1` | `-Yes` | off | Don't prompt; use flags, saved settings or defaults |

With no terminal (CI, cron), the script never prompts: the menu only prints the status, and `setup` uses your flags, saved settings or defaults.

---

## What `setup` does

**macOS (herd mode)**

1. Checks Herd is installed (`brew install --cask herd` if missing) and running (starts it if not).
2. Checks Node 20+ is available, and runs `npm install -g portless` if portless is missing.
3. Writes a marked block to your shell rc:

   ```bash
   # >>> portless-herd >>>
   export PORTLESS_TLD=test
   export PORTLESS_PORT=1355
   export PORTLESS_HTTPS=0         # Herd terminates TLS
   export PORTLESS_SYNC_HOSTS=0    # Herd's DNS already resolves *.test
   # <<< portless-herd <<<
   ```

   These make `portless` restart the proxy with the right settings after a reboot.
4. Starts the portless proxy: `portless proxy start -p 1355 --tld test --no-tls`.
5. Creates the Herd proxy: `herd proxy web http://127.0.0.1:1355 --secure`. This adds an nginx site for `web.test` and `*.web.test`, with a wildcard certificate your Mac already trusts.
6. Sends a test request to `https://setup-check.web.test` and checks that portless answers it over trusted HTTPS.

**Windows (herd mode)** follows the same steps, with these differences:

- It sets **user environment variables** instead of editing a shell rc file.
- It leaves hosts-file sync on, because Herd for Windows resolves `.test` through the hosts file instead of wildcard DNS.
- Run it as **Administrator** so portless can add a hosts entry for each app.

**Linux (standalone mode)**

1. Checks Node 20+ is available and installs portless if needed.
2. Writes `export PORTLESS_TLD=test` to your shell rc.
3. Runs `portless proxy start --tld test`, which binds :443 with sudo and trusts its own CA.
4. Portless adds each app to `/etc/hosts` automatically.

## What `teardown` does

- Removes the Herd proxy (`herd unproxy web`).
- Deletes the saved settings (`~/.config/portless-x-herd/config`).
- Stops the portless proxy.
- Resets portless's TLD back to `.localhost`.
- Removes the `PORTLESS_*` block or variables.
- **Standalone mode only:** cleans portless's `/etc/hosts` entries.

Herd, Node and portless stay installed. To remove portless completely:

```bash
npm uninstall -g portless && rm -rf ~/.portless
```

To do all of this by hand instead, see **[docs/manual-setup.md](docs/manual-setup.md)**.

---

## Troubleshooting

| Symptom                                                 | Fix                                                                                                                                                                                                  |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `https://…:1355` → `ERR_SSL_PROTOCOL_ERROR`             | Expected in herd mode, because portless speaks plain HTTP. Use `https://<app>.web.test` with no port.                                                                                                |
| portless "no site registered" page                      | The app name is missing `.web`, or the app isn't running. Check with `portless list`.                                                                                                                |
| Herd's nginx 404                                        | The Herd proxy is missing. Run `setup` again, or check `herd proxies`.                                                                                                                               |
| `Port 443 is already in use` in `~/.portless/proxy.log` | Someone ran `sudo portless …` while Herd holds :443. Run `sudo pkill -f 'portless proxy start' && sudo chown -R $(whoami) ~/.portless`, then `setup`. **Don't run portless with sudo in herd mode.** |
| Windows: app URL doesn't resolve                        | No hosts entry. Run `portless hosts sync` from an Administrator terminal.                                                                                                                            |
| Certificate warning                                     | Herd mode: `herd secure web`. Standalone: `portless trust`.                                                                                                                                          |
| Hot reload / HMR not connecting (Next.js)               | Add `allowedDevOrigins: ["*.web.test"]` to `next.config`.                                                                                                                                            |

Run `status` first. It shows which part of the chain is broken.

---

## Credits

- **[portless](https://github.com/vercel-labs/portless)** (Vercel Labs, Apache-2.0) routes stable names to dev servers. This project only configures it.
- **[Laravel Herd](https://herd.laravel.com)** provides the nginx, DNS and trusted certificates that the herd mode relies on.

## Contributing

Issues and PRs are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). The Windows herd mode especially needs people to try it on real machines.

## License

[MIT](LICENSE) © 2026 [Aghogho Meyoron](https://mayrcodes.com.ng) · <youngmayor.dev@gmail.com>
