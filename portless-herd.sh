#!/usr/bin/env bash
#
# portless-x-herd — serve portless apps at https://<app>.web.test
# https://github.com/MayR-Labs/portless-x-herd
#
# macOS (herd mode):
#   https://myapp.web.test
#     -> Herd nginx  (owns :443, wildcard *.web.test cert, forwards Host header)
#     -> portless    (plain HTTP on 127.0.0.1:1355, routes by hostname)
#     -> your app    (random port)
#
# Linux (standalone mode — there is no Herd for Linux):
#   https://myapp.web.test
#     -> portless    (HTTPS on :443 with its own trusted CA, .test TLD, /etc/hosts sync)
#     -> your app
#
# Windows: use portless-herd.ps1 instead.
#
# Run with no arguments for an interactive menu; see `--help` for commands and options.
#
# Copyright (c) 2026 Aghogho Meyoron — MIT License

set -euo pipefail

VERSION="0.1.0"
REPO_URL="https://github.com/MayR-Labs/portless-x-herd"
CMD="${PORTLESS_HERD_CMD:-portless-herd.sh}"   # how to refer to ourselves in messages

OS="$(uname -s)"
TLD="test"
STATE_DIR="${PORTLESS_STATE_DIR:-$HOME/.portless}"
CONFIG_DIR="${PORTLESS_HERD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/portless-x-herd}"
CONFIG_FILE="$CONFIG_DIR/config"
BLOCK_START="# >>> portless-herd >>>"
BLOCK_END="# <<< portless-herd <<<"

# Settings come from, in order: command-line flags > environment > saved config > defaults.
ENV_SUFFIX="${SUFFIX:-}" ENV_MODE="${MODE:-}" ENV_PORT="${PROXY_PORT:-}" ENV_RC="${SHELL_RC:-}"
CLI_SUFFIX="" CLI_MODE="" CLI_PORT="" CLI_RC=""
SAVED_SUFFIX="" SAVED_MODE="" SAVED_PORT="" SAVED_RC=""
ASSUME_YES="${PORTLESS_HERD_YES:-0}"
COMMAND=""
SUFFIX="" MODE="" PROXY_PORT="" SHELL_RC="" DOMAIN=""

# ---------- output helpers ----------
if [[ -t 1 ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=; G=; Y=; R=; D=; N=
fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
fail() { printf '  %s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
info() { printf '  %s%s%s\n' "$D" "$*" "$N"; }

have()  { command -v "$1" >/dev/null 2>&1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------- prompting ----------
# Prompts read from /dev/tty, so they work even when the script is piped in (curl | bash).
can_prompt() { (( ! ASSUME_YES )) && { : </dev/tty; } 2>/dev/null; }

# ask "<prompt>" <default> — prints the answer, or the default on an empty line.
ask() {
  local reply=""
  { exec 3</dev/tty; } 2>/dev/null || return 1
  printf '%s' "$1" >/dev/tty
  read -r -u 3 reply || true
  exec 3<&-
  printf '%s' "${reply:-$2}"
}

# ---------- configuration ----------
default_mode() { [[ "$OS" == "Darwin" ]] && echo herd || echo standalone; }
default_port() { [[ "$1" == "herd" ]] && echo 1355 || echo 443; }
default_rc() {
  case "$(basename "${SHELL:-}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) [[ "$OS" == "Darwin" ]] && echo "$HOME/.bash_profile" || echo "$HOME/.bashrc" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

load_saved_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  local key val
  while IFS='=' read -r key val; do
    case "$key" in
      SUFFIX)     SAVED_SUFFIX="$val" ;;
      MODE)       SAVED_MODE="$val" ;;
      PROXY_PORT) SAVED_PORT="$val" ;;
      SHELL_RC)   SAVED_RC="$val" ;;
    esac
  done <"$CONFIG_FILE"
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  printf 'SUFFIX=%s\nMODE=%s\nPROXY_PORT=%s\nSHELL_RC=%s\n' "$SUFFIX" "$MODE" "$PROXY_PORT" "$SHELL_RC" >"$CONFIG_FILE"
}

resolve_config() {
  SUFFIX="${CLI_SUFFIX:-${ENV_SUFFIX:-${SAVED_SUFFIX:-web}}}"
  MODE="${CLI_MODE:-${ENV_MODE:-${SAVED_MODE:-$(default_mode)}}}"
  PROXY_PORT="${CLI_PORT:-${ENV_PORT:-${SAVED_PORT:-$(default_port "$MODE")}}}"
  SHELL_RC="${CLI_RC:-${ENV_RC:-${SAVED_RC:-$(default_rc)}}}"
  apply_config
}

# Validate the current settings and derive everything that depends on them.
apply_config() {
  SUFFIX="$(lower "$SUFFIX")"
  MODE="$(lower "$MODE")"
  SHELL_RC="${SHELL_RC/#\~/$HOME}"
  [[ "$SUFFIX" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || fail "Suffix '$SUFFIX' must be lowercase letters, digits, dots or dashes."
  case "$MODE" in
    herd|standalone) ;;
    *) fail "Mode must be 'herd' or 'standalone', got '$MODE'." ;;
  esac
  [[ "$MODE" == "herd" && "$OS" != "Darwin" ]] && fail "Herd isn't available on $OS. Use --mode standalone."
  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && (( PROXY_PORT > 0 && PROXY_PORT < 65536 )) || fail "Port must be 1-65535, got '$PROXY_PORT'."
  [[ "$MODE" == "herd" && ( "$PROXY_PORT" == 80 || "$PROXY_PORT" == 443 ) ]] && fail "In herd mode Herd owns ports 80/443 — pick another port (default 1355)."
  DOMAIN="$SUFFIX.$TLD"
}

has_saved_config() { [[ -f "$CONFIG_FILE" ]]; }
config_changed() {
  has_saved_config && [[ "$SAVED_SUFFIX|$SAVED_MODE|$SAVED_PORT|$SAVED_RC" != "$SUFFIX|$MODE|$PROXY_PORT|$SHELL_RC" ]]
}

print_config() {
  printf '    %-12s %s\n' "Apps:"  "https://<app>.$DOMAIN"
  printf '    %-12s %s\n' "Mode:"  "$MODE$([[ "$MODE" == herd ]] && echo " (behind Laravel Herd)" || echo " (portless serves HTTPS itself)")"
  printf '    %-12s %s\n' "Port:"  "$PROXY_PORT"
  printf '    %-12s %s\n' "Shell file:" "$SHELL_RC"
}

# Ask for each setting, showing the current value as the default. Returns 1 if the user cancels.
configure_interactively() {
  can_prompt || return 0
  local a old_mode="$MODE"

  step "Configure (press Enter to keep the value in [brackets])"
  a="$(ask "  App suffix — apps at https://<app>.<suffix>.test [$SUFFIX]: " "$SUFFIX")"; SUFFIX="$a"

  if [[ "$OS" == "Darwin" ]]; then
    a="$(ask "  Mode — 'herd' (behind Laravel Herd) or 'standalone' (portless owns :443) [$MODE]: " "$MODE")"
    MODE="$(lower "$a")"
  fi
  # Switching mode switches the sensible default port too, unless the port was set explicitly.
  if [[ "$MODE" != "$old_mode" && -z "$CLI_PORT$ENV_PORT" ]]; then PROXY_PORT="$(default_port "$MODE")"; fi

  if [[ "$MODE" == "herd" ]]; then
    a="$(ask "  portless port (any free port; Herd keeps 80/443) [$PROXY_PORT]: " "$PROXY_PORT")"
  else
    a="$(ask "  portless port (443 gives URLs without a port) [$PROXY_PORT]: " "$PROXY_PORT")"
  fi
  PROXY_PORT="$a"

  a="$(ask "  Shell file for the PORTLESS_* exports [$SHELL_RC]: " "$SHELL_RC")"; SHELL_RC="$a"

  apply_config
  echo
  print_config
  echo
  a="$(lower "$(ask "  Proceed? [Y/n] " y)")"
  [[ "$a" == y* ]]
}

# ---------- Herd ----------
HERD_BIN_DIR="$HOME/Library/Application Support/Herd/bin"
ensure_herd_on_path() { have herd || export PATH="$HERD_BIN_DIR:$PATH"; }
herd_installed()  { ensure_herd_on_path; have herd; }
herd_running()    { [[ "$(curl -sk -m 3 -o /dev/null -w '%{http_code}' https://127.0.0.1/ || true)" != "000" ]]; }
herd_proxy_line() { herd proxies 2>/dev/null </dev/null | grep "https://$DOMAIN " || true; }

# ---------- portless ----------
proxy_scheme() { [[ "$MODE" == "herd" ]] && echo http || echo https; }
portless_running() {
  curl -sk -m 2 -o /dev/null -D - "$(proxy_scheme)://127.0.0.1:$PROXY_PORT/" 2>/dev/null | grep -qi '^x-portless'
}
port_taken_by_other() {
  local code
  code="$(curl -sk -m 2 -o /dev/null -w '%{http_code}' "$(proxy_scheme)://127.0.0.1:$PROXY_PORT/" 2>/dev/null || true)"
  [[ "$code" != "000" ]] && ! portless_running
}
portless_tld() { cat "$STATE_DIR/proxy.tld" 2>/dev/null || echo localhost; }

# URL users should open (no port in herd mode or on 443).
app_url() { [[ "$PROXY_PORT" == "443" || "$MODE" == "herd" ]] && echo "https://$1.$DOMAIN" || echo "https://$1.$DOMAIN:$PROXY_PORT"; }

# Does https://<anything>.<suffix>.test reach portless? Prints "trusted", "untrusted" or nothing.
chain_check() {
  local host="setup-check.$DOMAIN" port=443 args=()
  [[ "$MODE" == "standalone" ]] && port="$PROXY_PORT"
  # Standalone mode only has /etc/hosts entries for real routes, so pin the test name to loopback.
  [[ "$MODE" == "standalone" ]] && args=(--resolve "$host:$port:127.0.0.1")
  if curl -s -m 5 ${args[@]+"${args[@]}"} -o /dev/null -D - "https://$host:$port/" 2>/dev/null | grep -qi '^x-portless'; then
    echo trusted
  elif curl -sk -m 5 ${args[@]+"${args[@]}"} -o /dev/null -D - "https://$host:$port/" 2>/dev/null | grep -qi '^x-portless'; then
    echo untrusted
  fi
}

# ---------- shell rc block (portable: no sed -i) ----------
remove_shell_block() {
  [[ -f "$SHELL_RC" ]] && grep -qF "$BLOCK_START" "$SHELL_RC" || return 0
  local tmp; tmp="$(mktemp)"
  awk -v s="$BLOCK_START" -v e="$BLOCK_END" '$0==s{skip=1} !skip{print} $0==e{skip=0}' "$SHELL_RC" >"$tmp"
  cat "$tmp" >"$SHELL_RC"   # keep the original file's permissions / symlink
  rm -f "$tmp"
}

write_shell_block() {
  touch "$SHELL_RC"
  remove_shell_block
  {
    echo "$BLOCK_START"
    echo "# portless apps at https://<app>.$DOMAIN — $REPO_URL"
    echo "export PORTLESS_TLD=$TLD"
    if [[ "$MODE" == "herd" ]]; then
      echo "export PORTLESS_PORT=$PROXY_PORT"
      echo "export PORTLESS_HTTPS=0         # Herd terminates TLS"
      echo "export PORTLESS_SYNC_HOSTS=0    # Herd's DNS already resolves *.test"
    elif [[ "$PROXY_PORT" != "443" ]]; then
      echo "export PORTLESS_PORT=$PROXY_PORT"
    fi
    echo "$BLOCK_END"
  } >>"$SHELL_RC"
  ok "PORTLESS_* exports written to $SHELL_RC"
}

apply_env_now() {
  unset PORTLESS_PORT PORTLESS_HTTPS PORTLESS_SYNC_HOSTS
  export PORTLESS_TLD="$TLD"
  if [[ "$MODE" == "herd" ]]; then
    export PORTLESS_PORT="$PROXY_PORT" PORTLESS_HTTPS=0 PORTLESS_SYNC_HOSTS=0
  elif [[ "$PROXY_PORT" != "443" ]]; then
    export PORTLESS_PORT="$PROXY_PORT"
  fi
}

# ---------- setup ----------
setup_herd() {
  step "Laravel Herd"
  if ! herd_installed; then
    if have brew; then
      info "Herd not found — installing with Homebrew..."
      brew install --cask herd </dev/null
      warn "Open Herd once to finish its setup (it asks for your password), then run $CMD again."
      exit 0
    fi
    fail "Herd is not installed. Get it from https://herd.laravel.com, open it once, then run $CMD again."
  fi
  ok "Herd installed"

  if ! herd_running; then
    info "Herd isn't serving on :443 — starting it..."
    open -a Herd 2>/dev/null || true
    herd start >/dev/null 2>&1 </dev/null || true
    for _ in {1..20}; do herd_running && break; sleep 1; done
    herd_running || fail "Herd didn't start. Open the Herd app and check its services."
  fi
  ok "Herd running (nginx on :443)"
}

setup_node() {
  step "Node & portless"
  have node && have npm || fail "Node/npm not found. Install Node 20+ (Herd → Node, nvm, or nodejs.org) and run $CMD again."
  local major; major="$(node -p 'process.versions.node.split(".")[0]')"
  (( major >= 20 )) || fail "portless needs Node 20+, you have $(node -v)."
  ok "node $(node -v)"
  if ! have portless; then
    info "Installing portless globally..."
    npm install -g portless </dev/null || fail "npm install -g portless failed. If npm needs sudo on this machine, use nvm/fnm instead of a system Node."
    hash -r
  fi
  ok "portless $(portless --version)"
}

start_portless() {
  if [[ "$MODE" == "herd" ]]; then
    step "portless proxy (HTTP on 127.0.0.1:$PROXY_PORT, TLD .test)"
  else
    step "portless proxy (HTTPS on :$PROXY_PORT, TLD .test)"
  fi

  if portless_running && [[ "$(portless_tld)" == "$TLD" ]]; then
    ok "already running with the right settings"
    return
  fi
  if port_taken_by_other; then
    fail "Something other than portless is using port $PROXY_PORT. Free it, or pick another port: $CMD setup --port 1356"
  fi
  if portless_running; then
    info "Restarting proxy with new settings..."
    portless proxy stop -p "$PROXY_PORT" >/dev/null 2>&1 </dev/null || true
  fi

  if [[ "$MODE" == "herd" ]]; then
    portless proxy start -p "$PROXY_PORT" --tld "$TLD" --no-tls >/dev/null </dev/null
  else
    info "portless may ask for your password (binding :$PROXY_PORT, trusting its CA, editing /etc/hosts)."
    portless proxy start -p "$PROXY_PORT" --tld "$TLD"
  fi
  for _ in {1..20}; do portless_running && break; sleep 0.5; done
  portless_running || fail "portless proxy didn't start. See $STATE_DIR/proxy.log"
  ok "started"
}

setup_herd_proxy() {
  step "Herd proxy *.$DOMAIN -> 127.0.0.1:$PROXY_PORT"
  local line; line="$(herd_proxy_line)"
  if [[ "$line" == *"127.0.0.1:$PROXY_PORT"* ]]; then
    ok "already exists"
    return
  fi
  [[ -n "$line" ]] && herd unproxy "$SUFFIX" >/dev/null </dev/null
  herd proxy "$SUFFIX" "http://127.0.0.1:$PROXY_PORT" --secure >/dev/null </dev/null
  ok "created https://$DOMAIN (wildcard cert for *.$DOMAIN)"
}

# setup [--no-prompt]: --no-prompt reuses the current settings (used by "repair").
setup() {
  have curl || fail "curl is required."

  if [[ "${1:-}" != "--no-prompt" ]]; then
    configure_interactively || { info "Cancelled — nothing changed."; return 0; }
  fi

  printf '\n%sportless-x-herd %s%s — mode: %s%s%s, apps at https://<app>.%s\n' "$B" "$VERSION" "$N" "$B" "$MODE" "$N" "$DOMAIN"

  # Moving to different settings? Remove the old setup first so nothing is left behind.
  if config_changed; then
    step "Removing the previous setup (*.$SAVED_SUFFIX.$TLD, $SAVED_MODE mode, port $SAVED_PORT)"
    (
      SUFFIX="$SAVED_SUFFIX" MODE="$SAVED_MODE" PROXY_PORT="$SAVED_PORT" SHELL_RC="$SAVED_RC"
      apply_config
      teardown_steps
    )
  fi

  [[ "$MODE" == "herd" ]] && setup_herd
  setup_node

  step "Shell config"
  write_shell_block
  apply_env_now
  save_config
  ok "settings saved to $CONFIG_FILE"

  start_portless

  if [[ "$MODE" == "herd" ]]; then
    if pgrep -u root -f "portless proxy start" >/dev/null 2>&1; then
      warn "A root portless proxy is also running (from an old 'sudo portless'). It can fight Herd for :443."
      info "Stop it: sudo pkill -f 'portless proxy start' && sudo chown -R \$(whoami) ~/.portless"
    fi
    setup_herd_proxy
  fi

  step "Checking the whole chain"
  sleep 1
  case "$(chain_check)" in
    trusted)   ok "https://<anything>.$DOMAIN reaches portless with trusted HTTPS" ;;
    untrusted) warn "Reaches portless, but the certificate isn't trusted yet. Run: portless trust" ;;
    *)         fail "https://setup-check.$DOMAIN did not reach portless. Run '$CMD status' for details." ;;
  esac

  print_next_steps
}

print_next_steps() {
  local url; url="$(app_url myapp)"
  cat <<EOF

${G}${B}All set.${N}

${B}Name each app${N} ${B}<app>.$SUFFIX${N} — in package.json:

    "portless": { "name": "myapp.$SUFFIX" }

  or in portless.json:

    { "name": "myapp.$SUFFIX" }

${B}Then run${N}  ${B}portless${N}  in the app folder and open  ${B}$url${N}

${D}Notes:
EOF
  if [[ "$MODE" == "herd" ]]; then
    echo "  • Ignore the http://…:$PROXY_PORT URL portless prints — use $url."
  fi
  cat <<EOF
  • Open a new terminal (or: source $SHELL_RC) so the PORTLESS_* settings apply.
  • Next.js: if hot reload is blocked, add  allowedDevOrigins: ["*.$DOMAIN"]  to next.config.
  • Check, change or undo anytime: just run $CMD again.${N}
EOF
}

# ---------- teardown ----------
# The undo steps for the current settings, without banners (also used when switching settings).
teardown_steps() {
  if [[ "$MODE" == "herd" ]]; then
    step "Herd proxy"
    if herd_installed && [[ -n "$(herd_proxy_line)" ]]; then
      herd unproxy "$SUFFIX" >/dev/null </dev/null && ok "removed https://$DOMAIN"
    else
      ok "nothing to remove"
    fi
  fi

  step "portless proxy"
  if have portless && portless_running; then
    portless proxy stop -p "$PROXY_PORT" >/dev/null 2>&1 </dev/null || true
    ok "stopped"
  else
    ok "not running"
  fi
  if [[ "$MODE" == "standalone" ]] && have portless; then
    portless hosts clean >/dev/null 2>&1 </dev/null && ok "removed portless entries from /etc/hosts" || true
  fi
  if [[ "$(portless_tld)" == "$TLD" ]]; then
    rm -f "$STATE_DIR/proxy.tld" 2>/dev/null && ok "reset TLD to .localhost" || true
  fi

  step "Shell config"
  remove_shell_block
  ok "PORTLESS_* exports removed from $SHELL_RC"
}

teardown() {
  printf '%sportless-x-herd %s%s — removing %s mode setup for *.%s\n' "$B" "$VERSION" "$N" "$MODE" "$DOMAIN"
  teardown_steps
  rm -f "$CONFIG_FILE"
  rmdir "$CONFIG_DIR" 2>/dev/null || true

  cat <<EOF

${G}${B}Undone.${N} Herd/portless are still installed; only this setup was removed.
${D}Open a new terminal to clear the PORTLESS_* variables from your session.
To remove portless entirely: npm uninstall -g portless && rm -rf ~/.portless${N}
EOF
}

# ---------- status ----------
status() {
  printf '%sportless-x-herd %s%s — mode: %s, *.%s, port %s\n' "$B" "$VERSION" "$N" "$MODE" "$DOMAIN" "$PROXY_PORT"
  step "Checks"
  if [[ "$MODE" == "herd" ]]; then
    herd_installed && ok "Herd installed" || warn "Herd not installed"
    herd_installed && herd_running && ok "Herd serving on :443" || warn "Herd not serving on :443"
    herd_installed && [[ -n "$(herd_proxy_line)" ]] && ok "Herd proxy $DOMAIN exists" || warn "Herd proxy $DOMAIN missing"
  fi
  have portless && ok "portless $(portless --version)" || warn "portless not installed"
  portless_running && ok "portless proxy on :$PROXY_PORT" || warn "portless proxy not running on :$PROXY_PORT"
  [[ "$(portless_tld)" == "$TLD" ]] && ok "portless TLD .$TLD" || warn "portless TLD is .$(portless_tld) (should be .$TLD)"
  grep -qF "$BLOCK_START" "$SHELL_RC" 2>/dev/null && ok "shell exports in $SHELL_RC" || warn "shell exports missing from $SHELL_RC"
  has_saved_config && ok "settings saved in $CONFIG_FILE" || warn "no saved settings ($CONFIG_FILE)"
  case "$(chain_check)" in
    trusted)   ok "end-to-end: https://*.$DOMAIN -> portless (trusted)" ;;
    untrusted) warn "end-to-end works but certificate isn't trusted (run: portless trust)" ;;
    *)         warn "end-to-end check failed" ;;
  esac

  if have portless; then
    step "Running apps"
    portless list 2>/dev/null </dev/null | sed "s#http://\([^: ]*\):$PROXY_PORT#https://\1#" | sed 's/^/  /'
  fi
}

# ---------- interactive (no command given) ----------
# Sets STATE to: ready (everything works), absent (nothing of ours exists), partial (anything else).
detect_state() {
  local any=0 all=1
  if [[ "$MODE" == "herd" ]]; then
    if herd_installed && [[ -n "$(herd_proxy_line)" ]]; then any=1; else all=0; fi
  fi
  if grep -qF "$BLOCK_START" "$SHELL_RC" 2>/dev/null; then any=1; else all=0; fi
  if [[ "$(portless_tld)" == "$TLD" ]]; then any=1; else all=0; fi
  has_saved_config && any=1
  portless_running || all=0
  [[ "$(chain_check)" == "trusted" ]] || all=0
  if (( all )); then STATE=ready; elif (( any )); then STATE=partial; else STATE=absent; fi
}

interactive() {
  # </dev/null: stop herd/portless/curl from swallowing anything typed before the prompt.
  status </dev/null
  detect_state </dev/null
  echo
  if ! can_prompt; then
    info "No terminal to ask on. Run: $CMD setup | status | teardown"
    return
  fi

  local a
  case "$STATE" in
    ready)
      printf '%s%s✓ portless-x-herd is set up.%s Apps are served at %shttps://<app>.%s%s\n\n' "$G" "$B" "$N" "$B" "$DOMAIN" "$N"
      a="$(lower "$(ask "[c]hange settings, [t]ear down, or [q]uit? [q] " q)")"
      case "$a" in
        c*) setup ;;
        t*) echo; teardown ;;
        *)  info "Nothing changed." ;;
      esac
      ;;
    absent)
      printf '%sportless-x-herd is not set up yet.%s\n\n' "$B" "$N"
      a="$(lower "$(ask "Set it up now? [Y/n] " y)")"
      if [[ "$a" == y* ]]; then setup; else info "Nothing changed."; fi
      ;;
    partial)
      printf '%s%s! portless-x-herd is partly set up%s — see the warnings above.\n\n' "$Y" "$B" "$N"
      a="$(lower "$(ask "[r]epair, [c]hange settings, [t]ear down, or [q]uit? [r] " r)")"
      case "$a" in
        r*) setup --no-prompt ;;
        c*) setup ;;
        t*) echo; teardown ;;
        *)  info "Nothing changed." ;;
      esac
      ;;
  esac
}

usage() {
  cat <<EOF
portless-x-herd $VERSION — https://<app>.<suffix>.test for your portless dev servers
$REPO_URL

Usage: $CMD [command] [options]

Run with no command to see the current state and choose what to do.

Commands:
  setup      Configure, install and verify everything (asks for settings; safe to re-run)
  status     Check every piece and list running apps
  teardown   Undo everything setup did
  version    Print the version

Options (override saved settings; env var in brackets):
  -s, --suffix <name>        apps at *.<name>.test               [SUFFIX]      default: web
  -m, --mode <herd|standalone>                                    [MODE]        default: herd on macOS, standalone on Linux
  -p, --port <port>          port portless listens on            [PROXY_PORT]  default: 1355 herd, 443 standalone
      --rc <file>            where PORTLESS_* exports are written [SHELL_RC]   default: your shell's rc file
  -y, --yes                  don't prompt; use flags/saved/default settings [PORTLESS_HERD_YES=1]

Saved settings: $CONFIG_FILE
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -s|--suffix) CLI_SUFFIX="${2:?$1 needs a value}"; shift ;;
      --suffix=*)  CLI_SUFFIX="${1#*=}" ;;
      -m|--mode)   CLI_MODE="${2:?$1 needs a value}"; shift ;;
      --mode=*)    CLI_MODE="${1#*=}" ;;
      -p|--port)   CLI_PORT="${2:?$1 needs a value}"; shift ;;
      --port=*)    CLI_PORT="${1#*=}" ;;
      --rc)        CLI_RC="${2:?$1 needs a value}"; shift ;;
      --rc=*)      CLI_RC="${1#*=}" ;;
      -y|--yes)    ASSUME_YES=1 ;;
      -h|--help|help)        COMMAND=help ;;
      -v|--version|version)  COMMAND=version ;;
      -*) echo "Unknown option: $1 (see $CMD --help)" >&2; exit 1 ;;
      *)
        [[ -z "$COMMAND" ]] || { echo "Unexpected argument: $1 (see $CMD --help)" >&2; exit 1; }
        COMMAND="$1" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  case "$COMMAND" in
    help)    usage; return ;;
    version) echo "$VERSION"; return ;;
  esac
  load_saved_config
  resolve_config
  case "$COMMAND" in
    "")                 interactive ;;
    setup)              setup ;;
    teardown|uninstall) teardown ;;
    status)             status ;;
    *) echo "Unknown command: $COMMAND (see $CMD --help)" >&2; exit 1 ;;
  esac
}

# Everything above is only definitions, so bash has read the whole file before anything runs —
# important when the script is piped in (curl | bash).
main "$@"
