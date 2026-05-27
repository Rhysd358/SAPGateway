# Deploying the SAP Gateway (Windows Server, no Docker)

The gateway ships as a **single self-contained native binary** that serves
both the REST/admin API and the Flutter admin UI on one port. There is no
Dart/Flutter SDK and no Docker required on the server.

## What's in the package (`dist/`)

| File | Purpose |
|---|---|
| `sap-gateway.exe` | The gateway — REST mock, integration API, scheduler, **and** the admin UI |
| `web/` | Flutter admin UI (static assets, served by the gateway) |
| `scripts/pull.py` | The outbound puller (REST → SurrealDB), run as a subprocess |
| `run.ps1` | Launcher — edit the config block, then run it |
| `DEPLOY.md` | This file |

## Prerequisites on the server

1. **Python 3** installed. The puller is standard-library only (no `pip`,
   no internet). If `python` isn't on `PATH`, set `PYTHON_EXE` in `run.ps1`
   to the full path (e.g. `C:\Python312\python.exe`).
2. **Network reachability** from this server to:
   - the SAP `/ai/extract` API (`https://cssapfb3.<org>.co.uk`)
   - the SurrealDB instance you sync into
3. Nothing else — no SDKs, no Docker.

## Install

1. Copy the whole `dist/` folder to the server (e.g. `C:\sap-gateway\`).
2. Open `run.ps1` and set:
   - `GATEWAY_PORT` — the port to listen on (default 8080)
   - `GATEWAY_AUTH_USER` / `GATEWAY_AUTH_PASS` — **change these**; they
     gate the API (the UI itself is public, the API calls it makes are not)
   - `PYTHON_EXE` — if Python isn't on `PATH`
3. Run it:
   ```powershell
   pwsh run.ps1
   ```
4. Open `http://<server-host>:8080/` in a browser. The admin UI loads and
   talks to the API on the same origin automatically — no client config.

## First-run configuration (in the UI)

The bundled defaults point at the dev mock + a local SurrealDB. On the real
server, open **Connections** and edit the two seeded connections:

- **SAP REST (mock)** → set the endpoint to the real `/ai/extract` base URL
  (e.g. `https://cssapfb3.<org>.co.uk`), auth **HTTP Basic**, real username
  + password. Hit **Test** — expect a green result.
- **SurrealDB · Nucleus** → set the endpoint, namespace, database, and
  credentials of your SurrealDB. **Test** it.

Then the Outbound jobs run against real infrastructure.

## Gotchas

- **HTTPS certificates.** If the SAP API presents an internal-CA or
  self-signed certificate, both the gateway and `pull.py` will reject it
  until the server trusts that CA (Windows certificate store). This is the
  most common "works in dev, fails on the server" surprise.
- **State lives in `data/`** (`flows.json`, `audit.json`, …). It persists
  across restarts. Back it up if the connection/flow config matters.
- **Running as a service.** `run.ps1` runs in the foreground. For an
  always-on service, wrap `sap-gateway.exe` (with the same env vars) using
  NSSM or a Scheduled Task set to run at startup.

## Rebuilding after code changes

On a dev machine with the Flutter + Dart SDKs:
```powershell
pwsh deploy/build.ps1
```
This regenerates `dist/`. Copy it over the old one on the server and restart.
Source development is unaffected — packaging only ever reads the source.
