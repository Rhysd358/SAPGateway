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

Write-Host '[1/4] Building Flutter web…' -ForegroundColor Cyan
Push-Location (Join-Path $root 'app')
# --no-web-resources-cdn forces canvaskit to be served from the bundle
# (web/canvaskit/…) instead of fetched from www.gstatic.com at runtime.
# REQUIRED for the air-gapped on-prem target; without it the admin UI shows
# a white screen on a server with no internet. Roboto is bundled separately
# via pubspec.yaml (app/fonts/Roboto/) so font requests don't go to the CDN
# either.
flutter build web --no-web-resources-cdn
Pop-Location

# Belt-and-braces post-build patch. The Flutter web engine still carries the
# CDN base URLs as string constants in main.dart.js / flutter_bootstrap.js /
# flutter.js, even when the runtime config tells it to use local assets.
#   - "https://fonts.gstatic.com/s/" is the engine's font-fallback prefix:
#     it fires only when a glyph isn't in any loaded font (e.g. NotoSans
#     symbols), but on the air-gapped target it would still attempt that
#     DNS resolution and connection. Rewriting the prefix to a same-origin
#     path means a fallback request becomes a harmless local 404 — no
#     outbound traffic at all.
#   - "https://www.gstatic.com/flutter-canvaskit" is the canvaskit CDN
#     fallback. It's dead code with useLocalCanvasKit:true set above, but
#     scrubbing it removes any confusion about what the bundle references.
Write-Host '[1b/4] Patching CDN URLs out of the bundle…' -ForegroundColor Cyan
$bundle = Join-Path $root 'app/build/web'
$mainJs = Join-Path $bundle 'main.dart.js'
$bootJs = Join-Path $bundle 'flutter_bootstrap.js'
$flutterJs = Join-Path $bundle 'flutter.js'
(Get-Content $mainJs -Raw) `
  -replace 'https://fonts\.gstatic\.com/s/', '/no-cdn-fonts/' `
  | Set-Content -NoNewline $mainJs
foreach ($f in @($bootJs, $flutterJs)) {
  (Get-Content $f -Raw) `
    -replace 'https://www\.gstatic\.com/flutter-canvaskit', '/no-cdn-canvaskit' `
    | Set-Content -NoNewline $f
}

Write-Host '[2/4] Compiling gateway → native exe…' -ForegroundColor Cyan
Push-Location (Join-Path $root 'server')
dart compile exe bin/server.dart -o (Join-Path $dist 'sap-gateway.exe')
Pop-Location

Write-Host '[3/4] Assembling package…' -ForegroundColor Cyan
$web = Join-Path $dist 'web'
if (Test-Path $web) { Remove-Item -Recurse -Force $web }
New-Item -ItemType Directory -Force $web | Out-Null
Copy-Item -Recurse -Force (Join-Path $root 'app/build/web/*') $web

$scripts = Join-Path $dist 'scripts'
New-Item -ItemType Directory -Force $scripts | Out-Null
Copy-Item -Force (Join-Path $root 'server/scripts/pull.py') (Join-Path $scripts 'pull.py')

Copy-Item -Force (Join-Path $PSScriptRoot 'run.ps1') (Join-Path $dist 'run.ps1')
Copy-Item -Force (Join-Path $PSScriptRoot 'DEPLOY.md') (Join-Path $dist 'DEPLOY.md')

Write-Host '[4/4] Zipping + emitting checksum…' -ForegroundColor Cyan
# Produce a single-file transport artifact alongside the dist/ folder so
# the package can be carried to an offline server with an integrity check.
# release/ sits next to dist/ — both are gitignored.
$release = Join-Path $root 'release'
New-Item -ItemType Directory -Force $release | Out-Null

$ver = ((Get-Content (Join-Path $root 'app/pubspec.yaml') |
         Where-Object { $_ -match '^version:\s*(.+)\s*$' } |
         Select-Object -First 1) -replace '^version:\s*', '').Trim()
$date = Get-Date -Format 'yyyyMMdd'
$zipName = "sap-gateway-$ver-$date.zip"
$zipPath = Join-Path $release $zipName
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zipPath -CompressionLevel Optimal

# CHECKSUMS.txt uses the `sha256sum -c` line format (lowercase hash + two
# spaces + filename) so it verifies with both `sha256sum -c CHECKSUMS.txt`
# on a Unix box and `Get-FileHash` on Windows.
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
$checksumPath = Join-Path $release 'CHECKSUMS.txt'
"$hash  $zipName" | Set-Content -NoNewline $checksumPath

$zipSize = '{0:N1} MB' -f ((Get-Item $zipPath).Length / 1MB)
Write-Host "Done." -ForegroundColor Green
Write-Host "  Deployable folder: $dist"
Write-Host "  Transport zip:     $zipPath ($zipSize)"
Write-Host "  Checksum:          $checksumPath"
Write-Host 'Copy release\*.zip + release\CHECKSUMS.txt to the server, verify, unzip, edit run.ps1, then run it.'
