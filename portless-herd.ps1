<#
.SYNOPSIS
  portless-x-herd - serve portless apps at https://<app>.web.test on Windows.

.DESCRIPTION
  Herd mode (default when Laravel Herd for Windows is installed):
    https://myapp.web.test
      -> Herd nginx  (owns :443, TLS for *.web.test, forwards Host header)
      -> portless    (plain HTTP on 127.0.0.1:1355, routes by hostname)
      -> your app    (random port)

  Standalone mode (no Herd): portless itself serves HTTPS on :443 with the .test TLD.

  Herd for Windows resolves *.test through the hosts file (no wildcard DNS), so each
  app needs a hosts entry. portless writes those automatically when its proxy runs
  elevated - run setup from an Administrator terminal.

  Run with no command for an interactive menu. Settings are saved and reused.

  https://github.com/MayR-Labs/portless-x-herd
  Copyright (c) 2026 Aghogho Meyoron - MIT License

.EXAMPLE
  .\portless-herd.ps1                       # interactive: status + setup / change / repair / teardown
  .\portless-herd.ps1 setup                 # asks for settings, then sets up
  .\portless-herd.ps1 setup -Suffix apps -Yes
  .\portless-herd.ps1 status
  .\portless-herd.ps1 teardown -Yes
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'status', 'teardown', 'uninstall', 'version', 'help')]
  [string]$Command,

  [string]$Suffix,

  [ValidateSet('herd', 'standalone')]
  [string]$Mode,

  [int]$ProxyPort,

  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Version = '0.1.0'
$RepoUrl = 'https://github.com/MayR-Labs/portless-x-herd'
$Tld = 'test'
$StateDir = if ($env:PORTLESS_STATE_DIR) { $env:PORTLESS_STATE_DIR } else { Join-Path $HOME '.portless' }
$ConfigDir = if ($env:PORTLESS_HERD_CONFIG_DIR) { $env:PORTLESS_HERD_CONFIG_DIR } else { Join-Path $HOME '.config\portless-x-herd' }
$ConfigFile = Join-Path $ConfigDir 'config'
$HerdBinDir = Join-Path $HOME '.config\herd\bin'
$ManagedVars = @('PORTLESS_TLD', 'PORTLESS_PORT', 'PORTLESS_HTTPS', 'PORTLESS_SYNC_HOSTS')
$AssumeYes = $Yes.IsPresent -or ($env:PORTLESS_HERD_YES -eq '1')

# Settings come from, in order: parameters > environment > saved config > defaults.
$Cli = @{ Suffix = $Suffix; Mode = $Mode; Port = $(if ($ProxyPort) { "$ProxyPort" } else { '' }) }
# Drop the typed/validated parameter variables so prompts can reassign them freely (and fail with our own messages).
Remove-Variable -Name Suffix, Mode, ProxyPort -Scope Script
$Suffix = ''; $Mode = ''; $ProxyPort = ''

# ---------- output helpers ----------
function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor White }
function Ok($msg)   { Write-Host "  + $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Info($msg) { Write-Host "  $msg" -ForegroundColor DarkGray }
# Throw instead of exit: when run remotely via a scriptblock, exit would close the user's shell.
function Fail($msg) { throw [System.OperationCanceledException]::new($msg) }

function Have($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function First { foreach ($v in $args) { if ($v) { return "$v" } } return '' }

# Prefer .cmd/.bat shims: npm's .ps1 shims can be blocked by the execution policy.
function Resolve-Exe([string]$name) {
  foreach ($n in @("$name.cmd", "$name.bat", "$name.exe", $name)) {
    $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
  }
  return $name
}

# Run a native command without PowerShell 5.1 turning stderr into terminating errors.
function Run {
  param([string]$Exe, [string[]]$Arguments)
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $global:LASTEXITCODE = 0
  try { $out = & (Resolve-Exe $Exe) @Arguments 2>&1 | Out-String } finally { $ErrorActionPreference = $old }
  [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
}

function Is-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- prompting ----------
function Can-Prompt {
  if ($AssumeYes) { return $false }
  try { return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { return $false }
}
function Ask([string]$prompt, [string]$default) {
  $a = Read-Host -Prompt $prompt
  if ([string]::IsNullOrWhiteSpace($a)) { $default } else { $a.Trim() }
}

# ---------- configuration ----------
if (-not (Have 'herd') -and (Test-Path (Join-Path $HerdBinDir 'herd.bat'))) {
  $env:PATH = "$HerdBinDir;$env:PATH"
}
function Default-Mode { if (Have 'herd') { 'herd' } else { 'standalone' } }
function Default-Port($m) { if ($m -eq 'herd') { '1355' } else { '443' } }

$Saved = @{ SUFFIX = ''; MODE = ''; PROXY_PORT = '' }
function Load-SavedConfig {
  if (-not (Test-Path $ConfigFile)) { return }
  foreach ($line in Get-Content $ConfigFile) {
    $k, $v = $line -split '=', 2
    if ($Saved.ContainsKey($k)) { $Saved[$k] = "$v".Trim() }
  }
}
function Save-Config {
  New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
  "SUFFIX=$script:Suffix`nMODE=$script:Mode`nPROXY_PORT=$script:ProxyPort`n" | Set-Content -Path $ConfigFile -NoNewline -Encoding ASCII
}
function Has-SavedConfig { Test-Path $ConfigFile }

function Resolve-Config {
  $script:Suffix = First $Cli.Suffix $env:SUFFIX $Saved.SUFFIX 'web'
  $script:Mode = First $Cli.Mode $env:MODE $Saved.MODE (Default-Mode)
  $script:ProxyPort = First $Cli.Port $env:PROXY_PORT $Saved.PROXY_PORT (Default-Port $script:Mode)
  Apply-Config
}

# Validate the current settings and derive everything that depends on them.
function Apply-Config {
  $script:Suffix = "$($script:Suffix)".ToLower()
  $script:Mode = "$($script:Mode)".ToLower()
  if ($script:Suffix -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$') { Fail "Suffix '$($script:Suffix)' must be lowercase letters, digits, dots or dashes." }
  if ($script:Mode -notin @('herd', 'standalone')) { Fail "Mode must be 'herd' or 'standalone', got '$($script:Mode)'." }
  $p = 0
  if (-not [int]::TryParse("$($script:ProxyPort)", [ref]$p) -or $p -lt 1 -or $p -gt 65535) { Fail "Port must be 1-65535, got '$($script:ProxyPort)'." }
  $script:ProxyPort = $p
  if ($script:Mode -eq 'herd' -and $p -in @(80, 443)) { Fail 'In herd mode Herd owns ports 80/443 - pick another port (default 1355).' }
  $script:Domain = "$($script:Suffix).$Tld"
  $script:Scheme = if ($script:Mode -eq 'herd') { 'http' } else { 'https' }
}

function Config-Changed {
  (Has-SavedConfig) -and ("$($Saved.SUFFIX)|$($Saved.MODE)|$($Saved.PROXY_PORT)" -ne "$Suffix|$Mode|$ProxyPort")
}

function Print-Config {
  $modeText = if ($Mode -eq 'herd') { 'herd (behind Laravel Herd)' } else { 'standalone (portless serves HTTPS itself)' }
  Write-Host ("    {0,-8} https://<app>.{1}" -f 'Apps:', $Domain)
  Write-Host ("    {0,-8} {1}" -f 'Mode:', $modeText)
  Write-Host ("    {0,-8} {1}" -f 'Port:', $ProxyPort)
}

# Ask for each setting with the current value as default. Returns $false if the user cancels.
function Configure-Interactively {
  if (-not (Can-Prompt)) { return $true }
  $oldMode = $script:Mode
  Step 'Configure (press Enter to keep the value in [brackets])'
  $script:Suffix = Ask "  App suffix - apps at https://<app>.<suffix>.test [$Suffix]" $Suffix
  $script:Mode = (Ask "  Mode - 'herd' (behind Laravel Herd) or 'standalone' (portless owns :443) [$Mode]" $Mode).ToLower()
  # Switching mode switches the sensible default port too, unless the port was set explicitly.
  if ($script:Mode -ne $oldMode -and -not ($Cli.Port -or $env:PROXY_PORT)) { $script:ProxyPort = Default-Port $script:Mode }
  $hint = if ($script:Mode -eq 'herd') { 'any free port; Herd keeps 80/443' } else { '443 gives URLs without a port' }
  $script:ProxyPort = Ask "  portless port ($hint) [$($script:ProxyPort)]" "$($script:ProxyPort)"
  Apply-Config
  Write-Host ""
  Print-Config
  Write-Host ""
  (Ask '  Proceed? [Y/n]' 'y').ToLower().StartsWith('y')
}

# ---------- checks ----------
# curl.exe ships with Windows 10 1803+ and uses the Windows certificate store.
function Curl-Headers {
  param([string]$Url, [switch]$Insecure, [string]$Resolve)
  $a = @('-s', '-m', '5', '-o', 'NUL', '-D', '-')
  if ($Insecure) { $a += '-k' }
  if ($Resolve) { $a += @('--resolve', $Resolve) }
  (Run 'curl.exe' ($a + $Url)).Output
}
function Curl-Code([string]$Url) {
  ((Run 'curl.exe' @('-sk', '-m', '3', '-o', 'NUL', '-w', '%{http_code}', $Url)).Output).Trim()
}

function Herd-Running    { (Curl-Code 'https://127.0.0.1/') -ne '000' }
function Herd-ProxyLine  { ((Run 'herd' @('proxies')).Output -split "`n") | Where-Object { $_ -match [regex]::Escape("https://$Domain") } | Select-Object -First 1 }
function Portless-Running { (Curl-Headers "${Scheme}://127.0.0.1:$ProxyPort/" -Insecure) -match '(?im)^x-portless' }
function Port-TakenByOther { ((Curl-Code "${Scheme}://127.0.0.1:$ProxyPort/") -ne '000') -and -not (Portless-Running) }
function Portless-Tld {
  $f = Join-Path $StateDir 'proxy.tld'
  if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { 'localhost' }
}
function App-Url($name) {
  if ($Mode -eq 'herd' -or $ProxyPort -eq 443) { "https://$name.$Domain" } else { "https://$name.${Domain}:$ProxyPort" }
}

# Returns 'trusted', 'untrusted' or $null. Pins the test name to loopback so it works without a hosts entry.
function Chain-Check {
  $h = "setup-check.$Domain"
  $port = if ($Mode -eq 'herd') { 443 } else { $ProxyPort }
  $url = "https://${h}:$port/"
  $pin = "${h}:${port}:127.0.0.1"
  if ((Curl-Headers $url -Resolve $pin) -match '(?im)^x-portless') { return 'trusted' }
  if ((Curl-Headers $url -Resolve $pin -Insecure) -match '(?im)^x-portless') { return 'untrusted' }
  return $null
}

# ---------- env vars (persisted per-user) ----------
function Desired-Env {
  $e = [ordered]@{ PORTLESS_TLD = $Tld }
  if ($Mode -eq 'herd') {
    $e.PORTLESS_PORT = "$ProxyPort"
    $e.PORTLESS_HTTPS = '0'          # Herd terminates TLS
  } elseif ($ProxyPort -ne 443) {
    $e.PORTLESS_PORT = "$ProxyPort"
  }
  # PORTLESS_SYNC_HOSTS stays at its default (on): Windows needs hosts entries per app.
  $e
}
function Write-Env {
  $want = Desired-Env
  foreach ($k in $ManagedVars) {
    $v = if ($want.Contains($k)) { $want[$k] } else { $null }
    [Environment]::SetEnvironmentVariable($k, $v, 'User')
    if ($null -eq $v) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item -Path "Env:$k" -Value $v }
  }
  Ok ('user environment: ' + (($want.Keys | ForEach-Object { "$_=$($want[$_])" }) -join ' '))
}
function Clear-Env {
  foreach ($k in $ManagedVars) {
    [Environment]::SetEnvironmentVariable($k, $null, 'User')
    Remove-Item "Env:$k" -ErrorAction SilentlyContinue
  }
}

# ---------- setup ----------
function Setup-Herd {
  Step 'Laravel Herd'
  if (-not (Have 'herd')) { Fail 'Herd is not installed. Get it from https://herd.laravel.com, open it once, then run again (or use -Mode standalone).' }
  Ok 'Herd installed'
  if (-not (Herd-Running)) {
    Info "Herd isn't serving on :443 - starting it..."
    Run 'herd' @('start') | Out-Null
    for ($i = 0; $i -lt 20 -and -not (Herd-Running); $i++) { Start-Sleep 1 }
    if (-not (Herd-Running)) { Fail "Herd didn't start. Open the Herd app and check its services." }
  }
  Ok 'Herd running (nginx on :443)'
}

function Setup-Node {
  Step 'Node & portless'
  if (-not (Have 'node') -or -not (Have 'npm')) { Fail 'Node/npm not found. Install Node 20+ (Herd -> Node, nvm-windows, or nodejs.org) and run again.' }
  $major = [int]((Run 'node' @('-p', 'process.versions.node.split(".")[0]')).Output.Trim())
  if ($major -lt 20) { Fail "portless needs Node 20+, you have $((Run 'node' @('-v')).Output.Trim())." }
  Ok "node $((Run 'node' @('-v')).Output.Trim())"
  if (-not (Have 'portless')) {
    Info 'Installing portless globally...'
    $r = Run 'npm' @('install', '-g', 'portless')
    if ($r.Code -ne 0) { Write-Host $r.Output; Fail 'npm install -g portless failed.' }
  }
  Ok "portless $((Run 'portless' @('--version')).Output.Trim())"
}

function Start-Portless {
  Step ("portless proxy ({0} on :{1}, TLD .test)" -f $Scheme.ToUpper(), $ProxyPort)
  if ((Portless-Running) -and (Portless-Tld) -eq $Tld) { Ok 'already running with the right settings'; return }
  if (Port-TakenByOther) { Fail "Something other than portless is using port $ProxyPort. Free it, or pick another: -ProxyPort 1356" }
  if (Portless-Running) { Info 'Restarting proxy with new settings...'; Run 'portless' @('proxy', 'stop', '-p', "$ProxyPort") | Out-Null }

  $a = @('proxy', 'start', '-p', "$ProxyPort", '--tld', $Tld)
  if ($Mode -eq 'herd') { $a += '--no-tls' }
  $r = Run 'portless' $a
  for ($i = 0; $i -lt 20 -and -not (Portless-Running); $i++) { Start-Sleep -Milliseconds 500 }
  if (-not (Portless-Running)) { Write-Host $r.Output; Fail "portless proxy didn't start. See $StateDir\proxy.log" }
  Ok 'started'
}

function Setup-HerdProxy {
  Step "Herd proxy *.$Domain -> 127.0.0.1:$ProxyPort"
  $line = Herd-ProxyLine
  if ($line -and $line -match "127\.0\.0\.1:$ProxyPort") { Ok 'already exists'; return }
  if ($line) { Run 'herd' @('unproxy', $Suffix) | Out-Null }
  $r = Run 'herd' @('proxy', $Suffix, "http://127.0.0.1:$ProxyPort", '--secure')
  if ($r.Code -ne 0) {
    # Herd for Windows builds without --secure on proxy: create, then secure.
    $r = Run 'herd' @('proxy', $Suffix, "http://127.0.0.1:$ProxyPort")
    if ($r.Code -ne 0) { Write-Host $r.Output; Fail 'herd proxy failed.' }
    Run 'herd' @('secure', $Suffix) | Out-Null
  }
  Ok "created https://$Domain"
}

# The undo steps for the current settings, without banners (also used when switching settings).
function Teardown-Steps {
  if ($Mode -eq 'herd' -and (Have 'herd')) {
    Step 'Herd proxy'
    if (Herd-ProxyLine) { Run 'herd' @('unproxy', $Suffix) | Out-Null; Ok "removed https://$Domain" } else { Ok 'nothing to remove' }
  }
  Step 'portless proxy'
  if ((Have 'portless') -and (Portless-Running)) { Run 'portless' @('proxy', 'stop', '-p', "$ProxyPort") | Out-Null; Ok 'stopped' } else { Ok 'not running' }
  if (Have 'portless') {
    $r = Run 'portless' @('hosts', 'clean')
    if ($r.Code -eq 0) { Ok 'removed portless entries from the hosts file' } else { Warn 'could not clean hosts file (run "portless hosts clean" as Administrator)' }
  }
  if ((Portless-Tld) -eq $Tld) { Remove-Item (Join-Path $StateDir 'proxy.tld') -ErrorAction SilentlyContinue; Ok 'reset TLD to .localhost' }
  Step 'Environment'
  Clear-Env
  Ok 'PORTLESS_* user variables removed'
}

function Do-Setup([switch]$NoPrompt) {
  if (-not (Have 'curl.exe')) { Fail 'curl.exe is required (built into Windows 10 1803+).' }
  if (-not $NoPrompt) {
    if (-not (Configure-Interactively)) { Info 'Cancelled - nothing changed.'; return }
  }

  Write-Host ""
  Write-Host "portless-x-herd $Version - mode: $Mode, apps at https://<app>.$Domain"
  if (-not (Is-Admin)) {
    Warn 'Not running as Administrator: portless will not be able to add hosts-file entries for your apps.'
    Info 'Re-run from an elevated terminal, or run "portless hosts sync" as Administrator after starting each new app.'
  }

  # Moving to different settings? Remove the old setup first so nothing is left behind.
  if (Config-Changed) {
    Step "Removing the previous setup (*.$($Saved.SUFFIX).$Tld, $($Saved.MODE) mode, port $($Saved.PROXY_PORT))"
    $keep = @($script:Suffix, $script:Mode, $script:ProxyPort)
    $script:Suffix = $Saved.SUFFIX; $script:Mode = $Saved.MODE; $script:ProxyPort = $Saved.PROXY_PORT
    Apply-Config
    Teardown-Steps
    $script:Suffix, $script:Mode, $script:ProxyPort = $keep
    Apply-Config
  }

  if ($Mode -eq 'herd') { Setup-Herd }
  Setup-Node
  Step 'Environment'
  Write-Env
  Save-Config
  Ok "settings saved to $ConfigFile"
  Start-Portless
  if ($Mode -eq 'herd') { Setup-HerdProxy }

  Step 'Checking the whole chain'
  Start-Sleep 1
  switch (Chain-Check) {
    'trusted'   { Ok "https://<anything>.$Domain reaches portless with trusted HTTPS" }
    'untrusted' { Warn "Reaches portless, but the certificate isn't trusted yet. Run: portless trust (as Administrator)" }
    default     { Fail "https://setup-check.$Domain did not reach portless. Run '.\portless-herd.ps1 status' for details." }
  }

  $url = App-Url 'myapp'
  Write-Host ""
  Write-Host 'All set.' -ForegroundColor Green
  Write-Host ""
  Write-Host "Name each app <app>.$Suffix - in package.json:"
  Write-Host ""
  Write-Host "    `"portless`": { `"name`": `"myapp.$Suffix`" }"
  Write-Host ""
  Write-Host '  or in portless.json:'
  Write-Host ""
  Write-Host "    { `"name`": `"myapp.$Suffix`" }"
  Write-Host ""
  Write-Host "Then run  portless  in the app folder and open  $url"
  Write-Host ""
  if ($Mode -eq 'herd') { Info "- Ignore the http://...:$ProxyPort URL portless prints - use $url." }
  Info '- Open a new terminal so the PORTLESS_* variables apply.'
  Info "- Next.js: if hot reload is blocked, add  allowedDevOrigins: [`"*.$Domain`"]  to next.config."
  Info '- Check, change or undo anytime: just run .\portless-herd.ps1 again.'
}

function Do-Teardown {
  Write-Host "portless-x-herd $Version - removing $Mode mode setup for *.$Domain"
  Teardown-Steps
  Remove-Item $ConfigFile -ErrorAction SilentlyContinue
  Remove-Item $ConfigDir -ErrorAction SilentlyContinue
  Write-Host ""
  Write-Host 'Undone. Herd/portless are still installed; only this setup was removed.' -ForegroundColor Green
  Info 'Open a new terminal to clear the PORTLESS_* variables from your session.'
  Info 'To remove portless entirely: npm uninstall -g portless; Remove-Item -Recurse ~\.portless'
}

# ---------- status ----------
function Do-Status {
  Write-Host "portless-x-herd $Version - mode: $Mode, *.$Domain, port $ProxyPort"
  Step 'Checks'
  if ($Mode -eq 'herd') {
    if (Have 'herd') { Ok 'Herd installed' } else { Warn 'Herd not installed' }
    if ((Have 'herd') -and (Herd-Running)) { Ok 'Herd serving on :443' } else { Warn 'Herd not serving on :443' }
    if ((Have 'herd') -and (Herd-ProxyLine)) { Ok "Herd proxy $Domain exists" } else { Warn "Herd proxy $Domain missing" }
  }
  if (Have 'portless') { Ok "portless $((Run 'portless' @('--version')).Output.Trim())" } else { Warn 'portless not installed' }
  if (Portless-Running) { Ok "portless proxy on :$ProxyPort" } else { Warn "portless proxy not running on :$ProxyPort" }
  if ((Portless-Tld) -eq $Tld) { Ok "portless TLD .$Tld" } else { Warn "portless TLD is .$(Portless-Tld) (should be .$Tld)" }
  if ([Environment]::GetEnvironmentVariable('PORTLESS_TLD', 'User') -eq $Tld) { Ok 'PORTLESS_* user variables set' } else { Warn 'PORTLESS_* user variables missing' }
  if (Has-SavedConfig) { Ok "settings saved in $ConfigFile" } else { Warn "no saved settings ($ConfigFile)" }
  if (-not (Is-Admin)) { Info '(not elevated - hosts-file entries may be missing for new apps)' }
  switch (Chain-Check) {
    'trusted'   { Ok "end-to-end: https://*.$Domain -> portless (trusted)" }
    'untrusted' { Warn "end-to-end works but certificate isn't trusted (run: portless trust)" }
    default     { Warn 'end-to-end check failed' }
  }
  if (Have 'portless') {
    Step 'Running apps'
    ((Run 'portless' @('list')).Output -replace "http://([^: ]+):$ProxyPort", 'https://$1') -split "`n" | ForEach-Object { "  $_" }
  }
}

# ---------- interactive (no command given) ----------
# Returns 'ready' (everything works), 'absent' (nothing of ours exists) or 'partial'.
function Detect-State {
  $any = $false; $all = $true
  if ($Mode -eq 'herd') { if ((Have 'herd') -and (Herd-ProxyLine)) { $any = $true } else { $all = $false } }
  if ([Environment]::GetEnvironmentVariable('PORTLESS_TLD', 'User') -eq $Tld) { $any = $true } else { $all = $false }
  if ((Portless-Tld) -eq $Tld) { $any = $true } else { $all = $false }
  if (Has-SavedConfig) { $any = $true }
  if (-not (Portless-Running)) { $all = $false }
  if ((Chain-Check) -ne 'trusted') { $all = $false }
  if ($all) { 'ready' } elseif ($any) { 'partial' } else { 'absent' }
}

function Do-Interactive {
  Do-Status
  $state = Detect-State
  Write-Host ""
  if (-not (Can-Prompt)) { Info 'No terminal to ask on. Run: .\portless-herd.ps1 setup | status | teardown'; return }
  switch ($state) {
    'ready' {
      Write-Host "portless-x-herd is set up. Apps are served at https://<app>.$Domain" -ForegroundColor Green
      Write-Host ""
      $a = (Ask '[c]hange settings, [t]ear down, or [q]uit? [q]' 'q').ToLower()
      if ($a.StartsWith('c')) { Do-Setup } elseif ($a.StartsWith('t')) { Write-Host ""; Do-Teardown } else { Info 'Nothing changed.' }
    }
    'absent' {
      Write-Host 'portless-x-herd is not set up yet.'
      Write-Host ""
      $a = (Ask 'Set it up now? [Y/n]' 'y').ToLower()
      if ($a.StartsWith('y')) { Do-Setup } else { Info 'Nothing changed.' }
    }
    default {
      Write-Host 'portless-x-herd is partly set up - see the warnings above.' -ForegroundColor Yellow
      Write-Host ""
      $a = (Ask '[r]epair, [c]hange settings, [t]ear down, or [q]uit? [r]' 'r').ToLower()
      if ($a.StartsWith('r')) { Do-Setup -NoPrompt }
      elseif ($a.StartsWith('c')) { Do-Setup }
      elseif ($a.StartsWith('t')) { Write-Host ""; Do-Teardown }
      else { Info 'Nothing changed.' }
    }
  }
}

function Show-Usage {
  @"
portless-x-herd $Version - https://<app>.<suffix>.test for your portless dev servers
$RepoUrl

Usage: .\portless-herd.ps1 [command] [-Suffix web] [-Mode herd|standalone] [-ProxyPort 1355] [-Yes]

Run with no command to see the current state and choose what to do.

Commands:
  setup      Configure, install and verify everything (asks for settings; safe to re-run)
  status     Check every piece and list running apps
  teardown   Undo everything setup did
  version    Print the version

-Yes (or PORTLESS_HERD_YES=1) skips all prompts.
Saved settings: $ConfigFile
"@ | Write-Host
}

try {
  switch ($Command) {
    'help'    { Show-Usage; return }
    'version' { Write-Host $Version; return }
  }
  Load-SavedConfig
  Resolve-Config
  switch ($Command) {
    'setup'     { Do-Setup }
    'status'    { Do-Status }
    'teardown'  { Do-Teardown }
    'uninstall' { Do-Teardown }
    default     { Do-Interactive }
  }
} catch [System.OperationCanceledException] {
  Write-Host "  x $($_.Exception.Message)" -ForegroundColor Red
  if ($PSCommandPath) { exit 1 }   # only exit when run as a file, never from a remote scriptblock
}
