# Builds the on-prem deployable into ../dist :
#   sap-gateway.exe   self-contained native gateway (serves API + admin UI)
#   web/              Flutter web build
#   scripts/pull.py   stdlib-only Python puller
#   run.ps1           launcher (edit its config for the target server)
#   DEPLOY.md         install instructions
#
# Run this on a DEV machine that has the Flutter + Dart SDKs. The target
# server needs none of that — just the dist/ folder + Python 3.
#
#   pwsh deploy/build.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'

New-Item -ItemType Directory -Force $dist | Out-Null

Write-Host '[1/3] Building Flutter web…' -ForegroundColor Cyan
Push-Location (Join-Path $root 'app')
flutter build web
Pop-Location

Write-Host '[2/3] Compiling gateway → native exe…' -ForegroundColor Cyan
Push-Location (Join-Path $root 'server')
dart compile exe bin/server.dart -o (Join-Path $dist 'sap-gateway.exe')
Pop-Location

Write-Host '[3/3] Assembling package…' -ForegroundColor Cyan
$web = Join-Path $dist 'web'
if (Test-Path $web) { Remove-Item -Recurse -Force $web }
New-Item -ItemType Directory -Force $web | Out-Null
Copy-Item -Recurse -Force (Join-Path $root 'app/build/web/*') $web

$scripts = Join-Path $dist 'scripts'
New-Item -ItemType Directory -Force $scripts | Out-Null
Copy-Item -Force (Join-Path $root 'server/scripts/pull.py') (Join-Path $scripts 'pull.py')

Copy-Item -Force (Join-Path $PSScriptRoot 'run.ps1') (Join-Path $dist 'run.ps1')
Copy-Item -Force (Join-Path $PSScriptRoot 'DEPLOY.md') (Join-Path $dist 'DEPLOY.md')

Write-Host "Done. Deployable package: $dist" -ForegroundColor Green
Write-Host 'Copy the whole dist/ folder to the server, edit run.ps1, then run it.'
