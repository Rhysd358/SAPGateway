# Architecture

Current state of the SAP integration interfaces and the planned future shape.
Updated whenever a decision lands.

![Architecture overview](docs/architecture-overview.png)

> *If the image above isn't rendering, save the diagram from chat as
> `docs/architecture-overview.png` — see [docs/README.md](docs/README.md).*

## Scope

This repo owns the **interfaces between SAP ECC and SurrealDB** — nothing
else. The iOS-side API layer and the Flutter Expenses App in the reference
diagram are owned by another team and out of scope here. The Flutter web app
we ship is a *dev admin tool* for inspecting and exercising our interfaces;
it is not the production consumer.

## Terminology

`Mapping.direction` is described from the **SAP system's point of view**:

| String | Meaning | Integration-layer op |
|---|---|---|
| `outbound` | Data leaving SAP (SAP → elsewhere) | Pull |
| `inbound`  | Data entering SAP (elsewhere → SAP) | Push |
| `both`     | Either, on the same mapping | Pull and Push |

The verbs `pull` and `push` describe what the integration layer *does*; the
direction strings describe what the data is *doing* from SAP's vantage.

## Current state — built

### Outbound — REST + Basic auth → SurrealDB

```
┌────────────────────┐                                     ┌──────────────┐
│ SAP ECC (mock)     │ ─ /api/v1/{collection} ──────────▶  │ Integration  │
│ Gateway, shelf     │   REST + HTTP Basic                 │ layer        │
│ port 8080          │                                     └──────┬───────┘
└────────────────────┘                                            │ UPSERT
                                                                  ▼
                                                          ┌──────────────┐
                                                          │ SurrealDB    │
                                                          │ ns=sap       │
                                                          │ db=gateway   │
                                                          │ port 8000    │
                                                          └──────────────┘
```

- 10 collections sync this direction: `employees`, `addresses`, `orgunits`,
  `positions`, `jobs`, `absences`, `timesheets`, `payrollresults`,
  `wagetypes`, `expenses`.
- HTTP Basic with `GATEWAY_AUTH_USER` / `GATEWAY_AUTH_PASS`. CORS preflight
  and `/healthz` exempt.
- Scheduler ticks every 5 s; per-direction intervals on each mapping
  (`pullIntervalSeconds`, `pushIntervalSeconds`). Schedules persist via
  `data/integration.json`.

### Deviations from the reference diagram

The diagram shows a "Custom Python Script" doing the SAP → Surreal sync. We
have the same job in Dart today (`IntegrationHandler.runPull` invoked by
`IntegrationScheduler`). Moving the actual HTTP call to Python is in flight
— see *Planned: Python-based pull* below. The Dart side keeps owning the
scheduler, audit log and mapping config; Python owns the wire transfer.

### Inbound (interim) — REST + Basic → expenses write-back

The gateway currently accepts expense write-backs over the same REST mount
(`POST /api/v1/expenses`, `PATCH /api/v1/expenses/{BELNR}`). This is a
**placeholder** until the proper inbound interface (OData + SSO + trips)
lands.

## Future state — not built yet

### Inbound — SAP OData + SSO ← approved trips

```
┌──────────────┐
│ SurrealDB    │
│ approved     │
│ trips        │
└──────┬───────┘
       │  Status = APPROVED
       ▼
┌──────────────┐    /sap/opu/odata/sap/ZTRIP_SRV/TripSet    ┌──────────┐
│ Integration  │ ──── OData (Atom/JSON), SSO ──────────────▶│ SAP ECC  │
│ layer        │                                            │          │
└──────────────┘ ◀── 201 { d: { REINR: '1000123' } } ───────│          │
                 ◀── 4xx { error: { message: '...' } } ─────│          │
                                                            └──────────┘
```

- **Protocol**: OData (not the current REST). Requires `$metadata`, EDMX
  schemas, `$filter`/`$top` query options, Atom or JSON envelopes.
- **Auth**: SSO. Scheme TBD — likely OAuth2 SAML bearer assertion.
- **Trigger**: rows in the Surreal trip (or expense) table with
  `Status = APPROVED`.
- **Response, synchronous**:
  - Success: SAP returns the trip ID (`REINR`). The integration layer
    writes it back onto the originating Surreal record so downstream
    consumers see "submitted, ID = …".
  - Failure: SAP returns an error message. The integration layer records
    it on the Surreal record (and in the audit log) and leaves `Status`
    unchanged so the next scheduled run will retry.

### Planned — Python-based outbound pull

The reference diagram labels the SAP → Surreal mover as a "Custom Python
Script". We'll align by moving the actual HTTP call out of Dart into a
small Python script invoked by the Dart scheduler. See the open decision
below for the exact integration pattern.

### Decisions still open

| Decision | Status |
|---|---|
| Python integration pattern: embedded subprocess, sidecar service, or full replacement | Open — see question to user |
| Entity model for inbound: standalone `Trip` vs `Expense` with `Status=APPROVED` vs `Trip` header + `Expense` line items | Open |
| SSO scheme: SAML bearer / OAuth2 SAML-bearer / OIDC | Open |
| OData mount location: second surface on the gateway, or a separate service | Likely gateway (symmetric with the REST mock) |
| Existing REST `expense` write-back: keep as a parallel path or retire when OData lands | Open |

### When we pick up the inbound work — suggested order

1. Pin the Trip entity (`REINR`, `PERNR`, `BEGDA`, `ENDDA`, `KOSTL`, line items).
2. Add `/sap/opu/odata/sap/ZTRIP_SRV/` mount on the gateway: `$metadata`
   EDMX + `TripSet` with OData query semantics.
3. Stub the SSO middleware (`AuthConfig.mode = 'sso'`, returns 401 with a
   clear "SSO not configured" body until a real scheme drops in).
4. Add a `trips` mapping (`direction: inbound`,
   `pushFilter: {Status: APPROVED}`, on-success write back the returned
   `REINR` to the Surreal record).
