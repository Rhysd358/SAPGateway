# Starts the SAP Gateway on this server. Edit the config block below, then:
#   pwsh run.ps1
# Leave this window open (the gateway runs in the foreground). For a long-
# lived service, wrap it with NSSM / a scheduled task — see DEPLOY.md.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# ─── Config — edit for this environment ────────────────────────────────
$env:GATEWAY_PORT      = '8080'                         # port to listen on
$env:GATEWAY_AUTH_USER = 'admin'                        # CHANGE ME
$env:GATEWAY_AUTH_PASS = 'change-me'                    # CHANGE ME
$env:PYTHON_EXE        = 'python'                        # path to python3 if not on PATH
# ───────────────────────────────────────────────────────────────────────

# Paths (absolute, so the gateway doesn't depend on the working directory).
$env:GATEWAY_WEB_ROOT  = Join-Path $here 'web'
$env:GATEWAY_DATA      = Join-Path $here 'data'
$env:PULL_SCRIPT       = Join-Path $here 'scripts\pull.py'

New-Item -ItemType Directory -Force $env:GATEWAY_DATA | Out-Null

Write-Host "Starting SAP Gateway on http://0.0.0.0:$($env:GATEWAY_PORT)/ …"
& (Join-Path $here 'sap-gateway.exe')
