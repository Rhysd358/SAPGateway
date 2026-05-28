# Starts the SAP Gateway on this server. Edit the config block below, then:
#   pwsh run.ps1
# Leave this window open (the gateway runs in the foreground). For a long-
# lived service, wrap it with NSSM / a scheduled task — see DEPLOY.md.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# ─── Config — edit for this environment ────────────────────────────────
$env:GATEWAY_PORT      = '8080'                         # port to listen on
# Leave as admin/s3cret for this test build: the bundled UI ships with that
# as its built-in default credential and there's no in-UI auth setting yet,
# so the browser can only authenticate to its own gateway with these values.
# (Production hardening — custom creds — needs the in-UI auth config that's
# a known follow-up.)
$env:GATEWAY_AUTH_USER = 'admin'
$env:GATEWAY_AUTH_PASS = 's3cret'
$env:PYTHON_EXE        = 'python'                        # path to python3 if not on PATH
# Logging: 'quiet' (default) shows only errors. Uncomment the next line
# (or set on the command line: `$env:GATEWAY_LOG='verbose'; pwsh run.ps1`)
# to bring back the full per-request log when chasing a specific issue.
# $env:GATEWAY_LOG       = 'verbose'
# ───────────────────────────────────────────────────────────────────────

# Paths (absolute, so the gateway doesn't depend on the working directory).
$env:GATEWAY_WEB_ROOT  = Join-Path $here 'web'
$env:GATEWAY_DATA      = Join-Path $here 'data'
$env:PULL_SCRIPT       = Join-Path $here 'scripts\pull.py'

New-Item -ItemType Directory -Force $env:GATEWAY_DATA | Out-Null

Write-Host "Starting SAP Gateway on http://0.0.0.0:$($env:GATEWAY_PORT)/ …"
& (Join-Path $here 'sap-gateway.exe')
