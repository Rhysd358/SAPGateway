# SAP Gateway mock

A mock SAP ECC 6 REST API with a Flutter web admin and a bidirectional
integration layer that mirrors data into an external SurrealDB.

The real target system is **SAP ECC 6**. The agreed integration contract is
**REST APIs** — inbound reads (employees, addresses, org units, positions,
jobs, absences, timesheets, payroll, wage types) and outbound writes
(expenses). Field names are real ECC 6 DDIC codes (`PERNR`, `BELNR`, `WRBTR`,
`WAERS`, `KOSTL`, `SAKNR`, …) with SAP-style formatting (zero-padded keys,
ISO datetimes, stringified decimals).

```
├── server/   Dart shelf server — REST, Admin, Integration mounts
└── app/      Flutter web admin (services, integration, settings)
```

## Running the server

Requires Dart SDK ^3.4.0.

```
cd server
dart pub get
dart run bin/server.dart
```

Optional flags / env vars:

| Flag | Env var | Default | Purpose |
|---|---|---|---|
| `--port 8080` | `GATEWAY_PORT` | `8080` | HTTP port |
| `--host 0.0.0.0` | `GATEWAY_HOST` | `0.0.0.0` | Bind address |
| `--data data` | `GATEWAY_DATA` | `data` | Persistence directory |
| `--auth-user USER` | `GATEWAY_AUTH_USER` | unset | Enables Basic auth when paired with a password |
| `--auth-pass PASS` | `GATEWAY_AUTH_PASS` | unset | Enables Basic auth when paired with a username |

The server creates `data/runtime.json`, `data/integration.json` and
`data/audit.json` on first boot and persists every change. All three are
gitignored. `GET /healthz` always returns `{"ok":true}` and is exempt from
auth (Docker-probe friendly).

## Running in Docker

The gateway compiles to a static native binary and ships in a scratch-based
image (~18 MB).

```
cd server
docker build -t sap-gateway:latest .

# No auth (open):
docker run --rm -p 8080:8080 -v gateway-data:/app/data sap-gateway:latest

# With Basic auth on every mount:
docker run --rm -p 8080:8080 \
  -e GATEWAY_AUTH_USER=admin \
  -e GATEWAY_AUTH_PASS=s3cret \
  -v gateway-data:/app/data \
  sap-gateway:latest

curl -u admin:s3cret http://localhost:8080/api/v1/employees
```

Hit `GET /healthz` for an unauthenticated liveness probe.

## Running the Flutter app

Requires Flutter ≥ 3.22.0. The `web/` folder is gitignored — regenerate it
locally with `flutter create .`:

```
cd app
flutter create . --platforms=web --org com.sapgateway
flutter pub get
flutter run -d chrome
```

Default base URL is `http://localhost:8080`. Change it under **Settings**.

## REST shape

All REST calls live under `/api/v1/`. The wire format is plain JSON — no
OData, no EDMX, no `$filter` or `$metadata`. Schema metadata is plain JSON
type tags (`type: 'string'`, not `Edm.String`).

### Discovery

```
GET /api/v1/
```

Returns `{ services: [{ name, entityTypes, collections }] }`, where each
collection entry includes its REST name, source `EntitySet`, `EntityType`,
key property list and row count.

### Collection naming

Collection name = entity-set name lowercased, trailing `Set` stripped,
pluralised with simple English rules:

- `CustomerSet` → `customers`
- `ExpenseSet` → `expenses`
- `AddressSet` → `addresses`

### List

```
GET /api/v1/{collection}?limit=&offset=&sort=&search=&{any}=…
```

- `limit` (default 100), `offset` (default 0)
- `sort=FIELD` (or `-FIELD` for descending; comma-separate for multiple)
- `search` matches case-insensitively across all string properties
- Any other query param is an equality filter (e.g. `?WAERS=GBP`)

Response envelope:

```json
{ "data": [...], "total": 12, "limit": 100, "offset": 0 }
```

### Get / Create / Update / Delete

```
GET    /api/v1/{collection}/{id}
POST   /api/v1/{collection}
PUT    /api/v1/{collection}/{id}
PATCH  /api/v1/{collection}/{id}
DELETE /api/v1/{collection}/{id}
```

Composite keys are comma-joined in the URL, in the property order they are
declared on the entity type — e.g. `GET /api/v1/addresses/00001000,1`.

## Admin endpoints

`/admin/` exposes schema + row CRUD that the Flutter app uses to manage
services, entity types, properties, entity sets and rows. Property renames
cascade through existing rows. `POST /admin/reset` restores the bundled
seed.

## Integration endpoints

`/api/v1/integration/` is the SurrealDB sync layer.

| Method | Path | Purpose |
|---|---|---|
| GET    | `/config` | Surreal connection (password redacted as `passwordSet: bool`) + mappings |
| PUT    | `/config/surreal` | Update connection (endpoint, namespace, database, username, password) |
| PUT    | `/config/mappings/{collection}` | Upsert a mapping |
| DELETE | `/config/mappings/{collection}` | Remove a mapping |
| POST   | `/test-connection` | Probe Surreal `/version` |
| POST   | `/pull/{collection}?dryRun=true` | SAP → Surreal |
| POST   | `/push/{collection}?dryRun=true` | Surreal → SAP |
| GET    | `/audit?limit=&action=&collection=` | Read audit log |
| DELETE | `/audit` | Clear audit log |

A **mapping** binds one REST collection to one SurrealDB table with a
`direction` (`outbound` = SAP → Surreal, `inbound` = Surreal → SAP, `both`),
an optional `rename` map (`{ sapField: surrealField }`), an optional
`pushFilter` (equality predicate gating push), and optional per-direction
schedules (`pullIntervalSeconds`, `pushIntervalSeconds`). See
[ARCHITECTURE.md](ARCHITECTURE.md) for the direction convention, the
end-to-end reference diagram, and the planned OData/SSO inbound flow.

### Scheduled runs

The gateway runs an internal scheduler that ticks every 5 seconds. When a
mapping has `pullIntervalSeconds` (or `pushIntervalSeconds`) set, the
scheduler fires real (non-dry-run) pulls/pushes at that cadence. Schedules
persist via `data/integration.json` so they resume after a restart, and the
audit log captures every fired run.

```
# Schedule employees to pull from SAP into Surreal every 5 minutes
curl -X PUT http://localhost:8080/api/v1/integration/config/mappings/employees \
  -u admin:s3cret -H 'Content-Type: application/json' \
  -d '{"table":"employee","direction":"inbound","pullIntervalSeconds":300}'

# Inspect current schedules + last-run timestamps
curl -u admin:s3cret http://localhost:8080/api/v1/integration/schedules
```

From the Flutter app: **Integration → Mappings → edit a card**, set Pull or
Push frequency (Manual / 1m / 5m / 15m / 1h / Custom minutes), Save. An
`auto-pull every 5m` chip appears on the card while a schedule is active.

The Surreal client uses `dart:io` `HttpClient`, sends both `Surreal-NS`/`NS`
and `Surreal-DB`/`DB` headers, Basic auth, and tolerates Surreal's statement
envelope (`[{ result, status }]`) on read and write paths.

Every run, config change and connection test appends an `AuditEvent` to
`data/audit.json` (timestamp, action, collection, status, dryRun flag, row
counters, durationMs, optional error excerpt). The audit log is capped at
5000 events with FIFO trim.

## Worked example: writing an expense back to SAP

### Via REST (direct outbound write)

```
curl -X POST http://localhost:8080/api/v1/expenses \
  -H 'Content-Type: application/json' \
  -d '{
    "BELNR":"0000002001",
    "PERNR":"00001000",
    "BLDAT":"2026-05-22T00:00:00",
    "WRBTR":"42.50",
    "WAERS":"GBP",
    "KOSTL":"CC100200",
    "SAKNR":"0000476100",
    "SGTXT":"Taxi to airport",
    "Status":"SUBMITTED"
  }'

curl -X PATCH http://localhost:8080/api/v1/expenses/0000002001 \
  -H 'Content-Type: application/json' \
  -d '{"Status":"POSTED"}'
```

### Via integration push (Surreal → SAP)

1. Configure the Surreal connection:

   ```
   curl -X PUT http://localhost:8080/api/v1/integration/config/surreal \
     -H 'Content-Type: application/json' \
     -d '{
       "endpoint":"http://localhost:8000",
       "namespace":"sap",
       "database":"gateway",
       "username":"root",
       "password":"root"
     }'
   ```

2. Confirm the seeded mapping for `expenses` (direction `both`, push filter
   `Status=SUBMITTED`):

   ```
   curl http://localhost:8080/api/v1/integration/config | jq '.mappings[] | select(.collection=="expenses")'
   ```

3. Push: the integration layer reads rows from Surreal's `expense` table,
   applies the inverse rename, backfills the single key (`BELNR`) from the
   Surreal record id if missing, filters to `Status=SUBMITTED`, and upserts
   into the gateway store:

   ```
   curl -X POST 'http://localhost:8080/api/v1/integration/push/expenses?dryRun=true'
   curl -X POST  http://localhost:8080/api/v1/integration/push/expenses
   ```

   The response is the `AuditEvent` for the run, with row counters and any
   error excerpt.

## Authentication

The agreed contract with ECC 6 is REST APIs; the exact auth scheme is still
being finalised. **HTTP Basic is wired in** today, with OAuth2 modes left as
clearly-marked stubs.

- Server: `server/lib/auth.dart` exposes an `AuthConfig` and a single
  `authMiddleware()` that all three mounts pass through. With
  `GATEWAY_AUTH_USER` + `GATEWAY_AUTH_PASS` set, every request without a
  matching `Authorization: Basic` header gets a 401 + `WWW-Authenticate`.
  Without either env var, the middleware is a no-op (backward compatible).
  `OPTIONS` preflight and `/healthz` are always exempt.
- Flutter: `GatewayApi._authHeaders()` returns the `Authorization: Basic`
  header when **Settings → Authentication** is set to `HTTP Basic`. The
  username + password persist via `SharedPreferences`; the password is
  write-only end-to-end (the Settings hint reads "A password is already
  stored …" once one is saved).
- OAuth2 client credentials and SAML bearer assertion are still TBD and
  shown disabled in Settings — the seam (`AuthConfig.mode`,
  `_authHeaders()`) is the one place to wire them in.

SurrealDB-side auth (Basic + NS/DB headers) is unrelated and already
implemented separately.

## Seed data

Five SAP-style services, HR + Expenses only:

- `ZHR_EMPLOYEE_SRV` — Employee, Address
- `ZHR_ORG_SRV` — OrgUnit, Position, Job
- `ZHR_TIME_SRV` — Absence, Timesheet
- `ZHR_PAYROLL_SRV` — PayrollResult, WageType
- `ZEXPENSE_SRV` — Expense (the outbound write target)

Reset to seed any time with:

```
curl -X POST http://localhost:8080/admin/reset
```
