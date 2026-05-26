#!/usr/bin/env python3
"""
Outbound puller: SAP REST -> SurrealDB.

Invoked as a subprocess by the Dart IntegrationScheduler for each scheduled
pull. Reads a JSON config blob on stdin and prints a JSON result on stdout.

Standard library only (urllib + base64 + json). No pip install required.

Config (stdin):
  {
    "gateway":       "http://localhost:8080",
    "gatewayUser":   "admin",
    "gatewayPass":   "s3cret",
    "collection":    "employees",
    "table":         "employee",
    "rename":        { "PERNR": "personnel_number", ... },   # optional
    "keyProperties": ["PERNR"],
    "surreal":       "http://host.docker.internal:8000",
    "surrealNs":     "sap",
    "surrealDb":     "gateway",
    "surrealUser":   "root",
    "surrealPass":   "root",
    "dryRun":        false
  }

Result (stdout, single JSON object):
  {
    "ok":         true,
    "scanned":    3,
    "created":    0,
    "updated":    3,
    "skipped":    0,
    "failed":     0,
    "error":      null,
    "durationMs": 145
  }

Exit code is always 0 — partial failures are recorded in the result body so
the Dart side can surface them through the existing AuditEvent shape.
Non-zero exit is reserved for catastrophic faults (e.g. JSON parse error on
stdin) and the Dart side treats them as fatal errors.
"""
import base64
import json
import sys
import time
import urllib.error
import urllib.request


def _basic_auth(user: str, pw: str) -> str:
    token = base64.b64encode(f"{user}:{pw}".encode()).decode()
    return f"Basic {token}"


def _http(method, url, *, headers=None, body=None, timeout=15):
    data = None
    if body is not None:
        if isinstance(body, (bytes, bytearray)):
            data = bytes(body)
        elif isinstance(body, str):
            data = body.encode()
        else:
            data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data, method=method, headers=headers or {}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def _row_id(row, key_props):
    if not key_props:
        return str(next(iter(row.values()), ""))
    return ",".join(str(row.get(k, "")) for k in key_props)


def _apply_rename(row, rename):
    if not rename:
        return dict(row)
    return {rename.get(k, k): v for k, v in row.items()}


def _envelope_ok(parsed):
    """SurrealDB returns an envelope; raise if any statement reports ERR."""
    if isinstance(parsed, list):
        for stmt in parsed:
            if isinstance(stmt, dict) and stmt.get("status") not in (None, "OK"):
                raise RuntimeError(stmt.get("result") or str(stmt))
    elif isinstance(parsed, dict):
        if parsed.get("status") not in (None, "OK"):
            raise RuntimeError(parsed.get("result") or str(parsed))


def main():
    started = time.monotonic()

    try:
        cfg = json.loads(sys.stdin.read())
    except json.JSONDecodeError as e:
        sys.stderr.write(f"pull.py: bad stdin JSON: {e}\n")
        sys.exit(2)

    gateway = cfg["gateway"].rstrip("/")
    collection = cfg["collection"]
    table = cfg["table"]
    rename = cfg.get("rename") or {}
    key_props = cfg.get("keyProperties") or []
    dry_run = bool(cfg.get("dryRun", False))

    gateway_headers = {"Accept": "application/json"}
    if cfg.get("gatewayUser"):
        gateway_headers["Authorization"] = _basic_auth(
            cfg["gatewayUser"], cfg.get("gatewayPass", "")
        )

    surreal = (cfg.get("surreal") or "").rstrip("/")
    surreal_headers = {
        "Accept": "application/json",
        "Surreal-NS": cfg.get("surrealNs", ""),
        "NS": cfg.get("surrealNs", ""),
        "Surreal-DB": cfg.get("surrealDb", ""),
        "DB": cfg.get("surrealDb", ""),
        "Content-Type": "text/plain",
    }
    if cfg.get("surrealUser"):
        surreal_headers["Authorization"] = _basic_auth(
            cfg["surrealUser"], cfg.get("surrealPass", "")
        )

    scanned = 0
    created = 0
    updated = 0
    skipped = 0
    failed = 0
    first_error = None

    # 1) Fetch rows from the SAP-shaped REST gateway.
    try:
        status, payload = _http(
            "GET", f"{gateway}/api/v1/{collection}", headers=gateway_headers
        )
    except Exception as e:
        _emit(
            ok=False,
            scanned=0,
            created=0,
            updated=0,
            skipped=0,
            failed=0,
            error=f"gateway fetch failed: {e}",
            started=started,
        )
        return

    if status >= 400:
        _emit(
            ok=False,
            scanned=0,
            created=0,
            updated=0,
            skipped=0,
            failed=0,
            error=f"gateway returned {status}: {payload[:200]}",
            started=started,
        )
        return

    try:
        rows = json.loads(payload).get("data", [])
    except json.JSONDecodeError as e:
        _emit(
            ok=False,
            scanned=0,
            created=0,
            updated=0,
            skipped=0,
            failed=0,
            error=f"gateway returned non-JSON: {e}",
            started=started,
        )
        return

    # 2) Walk rows, transform, upsert into Surreal.
    for row in rows:
        scanned += 1
        try:
            row_id = _row_id(row, key_props)
            transformed = _apply_rename(row, rename)

            if dry_run:
                updated += 1
                continue

            # Backtick-quote the id so zero-padded SAP keys ("00001000") and
            # composite keys ("00001000,1") stay as string ids instead of
            # being parsed as integers / tuples by SurrealQL.
            esc_id = row_id.replace("`", "\\`")
            sql = f"UPSERT {table}:`{esc_id}` CONTENT {json.dumps(transformed)};"

            sstatus, spayload = _http(
                "POST", f"{surreal}/sql", headers=surreal_headers, body=sql
            )
            if sstatus >= 400:
                failed += 1
                if first_error is None:
                    first_error = f"surreal {sstatus}: {spayload[:200]}"
                continue
            try:
                _envelope_ok(json.loads(spayload))
            except RuntimeError as e:
                failed += 1
                if first_error is None:
                    first_error = f"surreal envelope: {e}"
                continue

            updated += 1
        except Exception as e:
            failed += 1
            if first_error is None:
                first_error = str(e)

    _emit(
        ok=(failed == 0),
        scanned=scanned,
        created=created,
        updated=updated,
        skipped=skipped,
        failed=failed,
        error=first_error,
        started=started,
    )


def _emit(*, ok, scanned, created, updated, skipped, failed, error, started):
    duration_ms = int((time.monotonic() - started) * 1000)
    sys.stdout.write(
        json.dumps(
            {
                "ok": ok,
                "scanned": scanned,
                "created": created,
                "updated": updated,
                "skipped": skipped,
                "failed": failed,
                "error": error,
                "durationMs": duration_ms,
            }
        )
    )
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
