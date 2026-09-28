# Manual setup & teardown

These are the steps `portless-herd.sh` / `portless-herd.ps1` run for you. Use this page if you want to understand the setup, do it by hand, or fix a machine the script can't.

Throughout, `web` is the suffix (apps at `*.web.test`) and `1355` is the portless port. Change both consistently if you want different values.

---

## macOS (with Herd)

**Prerequisites:** Herd installed and running, and Node 20+.

1. **Install portless**
   ```bash
   npm install -g portless
   ```

2. **Configure your shell.** Add these lines to `~/.zshrc`, then open a new terminal:
   ```bash
   export PORTLESS_TLD=test        # names end in .test
   export PORTLESS_PORT=1355       # stay off Herd's 80/443
   export PORTLESS_HTTPS=0         # Herd terminates TLS
   export PORTLESS_SYNC_HOSTS=0    # Herd's dnsmasq already resolves *.test
   ```

3. **Start the portless proxy.** Don't use sudo.
   ```bash
   portless proxy start -p 1355 --tld test --no-tls
   ```

4. **Create the Herd wildcard proxy**
   ```bash
   herd proxy web http://127.0.0.1:1355 --secure
   ```
   Herd writes an nginx site whose `server_name` is `web.test www.web.test *.web.test`, issues a certificate covering `web.test` and `*.web.test`, and forwards the original `Host` header. That header is how portless knows which app you asked for.

5. **Name apps `<app>.web`** in `package.json` (`"portless": { "name": "myapp.web" }`) or `portless.json`, then run `portless` in the app folder.

**Verify**
```bash
herd proxies                                       # web.test -> http://127.0.0.1:1355
portless list                                      # your running apps
curl -sI https://anything.web.test | grep -i x-portless
```

**Undo**
```bash
herd unproxy web
portless proxy stop -p 1355
```
Then delete the four `PORTLESS_*` lines from `~/.zshrc`.

---

## Windows (with Herd)

**Prerequisites:** Herd for Windows installed and running, Node 20+, and an **Administrator** PowerShell.

1. **Install portless**
   ```powershell
   npm install -g portless
   ```

2. **Set user environment variables.** Open a new terminal afterwards.
   ```powershell
   [Environment]::SetEnvironmentVariable('PORTLESS_TLD',   'test', 'User')
   [Environment]::SetEnvironmentVariable('PORTLESS_PORT',  '1355', 'User')
   [Environment]::SetEnvironmentVariable('PORTLESS_HTTPS', '0',    'User')
   ```
   Leave `PORTLESS_SYNC_HOSTS` unset. Herd for Windows resolves `.test` names through the hosts file, so portless needs to add an entry for each app.

3. **Start the portless proxy.** Use the Administrator terminal, so portless can write hosts entries.
   ```powershell
   portless proxy start -p 1355 --tld test --no-tls
   ```

4. **Create the Herd proxy**
   ```powershell
   herd proxy web http://127.0.0.1:1355 --secure
   ```
   If your Herd version rejects `--secure`, run `herd proxy web http://127.0.0.1:1355` and then `herd secure web`.

5. **Name apps `<app>.web`** and run `portless`. If an app's URL doesn't resolve, run `portless hosts sync` as Administrator.

**Undo**
```powershell
herd unproxy web
portless proxy stop -p 1355
portless hosts clean
'PORTLESS_TLD','PORTLESS_PORT','PORTLESS_HTTPS' | % { [Environment]::SetEnvironmentVariable($_, $null, 'User') }
```

---

## Linux (standalone, no Herd)

There's no Herd for Linux, and port 443 is usually free, so portless serves HTTPS itself.

1. **Install portless**
   ```bash
   npm install -g portless
   ```

2. **Configure your shell.** Add this line to `~/.bashrc` or `~/.zshrc`:
   ```bash
   export PORTLESS_TLD=test
   ```

3. **Start the proxy.** portless asks for sudo to bind :443, trust its CA and edit `/etc/hosts`.
   ```bash
   portless proxy start --tld test
   ```

4. **Name apps `<app>.web`** and run `portless`. Each route is added to `/etc/hosts` automatically.

If something else (nginx, Apache, Caddy) already holds :443, use another port instead, for example `portless proxy start -p 1355 --tld test` with `export PORTLESS_PORT=1355`. Your URLs will then include `:1355`.

**Undo**
```bash
portless proxy stop
portless hosts clean
```
Then remove the `PORTLESS_TLD` line from your shell rc.

**Browsers on Linux:** Chrome and Firefox use their own NSS certificate store. If `portless trust` didn't cover them, import `~/.portless/ca.pem` in the browser's certificate settings.

---

## Why not just `portless proxy start` on :443 on macOS?

Herd's nginx already listens on `127.0.0.1:443`. If you run a root portless proxy on :443 too (for example `sudo portless proxy start`), the two split the traffic by address. IPv4 requests reach Herd and IPv6 (`::1`) requests reach portless, so pages behave inconsistently. The run also leaves root-owned files in `~/.portless` that break later non-sudo runs. Putting portless behind Herd avoids both problems.
