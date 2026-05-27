#!/usr/bin/env python3
"""Outbound puller: SAP REST -> SurrealDB.

Invoked as a subprocess by the Dart gateway for each pull. Reads a JSON
config blob on stdin and prints a JSON result on stdout.

Standard library only (urllib + base64 + json). No pip install required.

Two source modes:

  mode = "extract"  (the real SAP API shape)
    Calls  {source}/ai/extract?type=<full|delta>&dataset=<name>[&<basis>=<since>]
    and reads the dataset's array out of the returned envelope:
      { "token_key": …, "msg_type": "S",
        "employees": [...], "user_data": [...], "exp_priv": [...],
        "line_managers": [...] }
    `envelopeKey` says which array to read (e.g. dataset "expense_priv"
    maps to envelope key "exp_priv").

  mode = "rest"  (legacy gateway mock; the default)
    Calls  {gateway}/api/v1/{collection}  and reads the `.data` array.

Result (stdout, single JSON object):
  { "ok": true, "scanned": 3, "created": 0, "updated": 3,
    "skipped": 0, "failed": 0, "error": null, "durationMs": 145 }

Exit code is always 0 for handled outcomes — partial failures live in the
result body. Non-zero exit is reserved for catastrophic faults (bad stdin).
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


def _http(method, url, *, headers=None, body=None, timeout=30):
    data = None
    if body is not None:
        if isinstance(body, (bytes, bytearray)):
            data = bytes(body)
        elif isinstance(body, str):
            data = body.encode()
        else:
            data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def _row_id(row, key_field):
    if key_field and key_field in row:
        return str(row.get(key_field, ""))
    return str(next(iter(row.values()), ""))


def _transform(row, rename, project_only):
    """Shape a source row for the target table.

    project_only=True  → output ONLY mapped fields (renamed to their target
        names). Required for SCHEMAFULL Surreal tables, which reject any
        field not in their definition.
    project_only=False → rename matched fields, pass everything else through
        unchanged (fine for SCHEMALESS tables).
    """
    if project_only:
        return {rename[k]: v for k, v in row.items() if k in rename}
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


def _fetch_extract(cfg):
    """Fetch rows from the real /ai/extract API. Returns (rows, error)."""
    source = (cfg.get("source") or "").rstrip("/")
    extract_type = cfg.get("extractType", "full")
    dataset = cfg.get("dataset", "")
    envelope_key = cfg.get("envelopeKey") or dataset
    delta_basis = cfg.get("deltaBasis", "change_date")
    delta_since = cfg.get("deltaSince", "")

    params = [f"type={extract_type}", f"dataset={dataset}"]
    if extract_type == "delta" and delta_since:
        params.append(f"{delta_basis}={delta_since}")
    url = f"{source}/ai/extract?{'&'.join(params)}"

    headers = {"Accept": "application/json"}
    if cfg.get("sourceUser"):
        headers["Authorization"] = _basic_auth(
            cfg["sourceUser"], cfg.get("sourcePass", "")
        )

    try:
        status, payload = _http("GET", url, headers=headers)
    except Exception as e:  # noqa: BLE001
        return None, f"source fetch failed: {e}"
    if status >= 400:
        return None, f"source returned {status}: {payload[:200]}"
    try:
        envelope = json.loads(payload)
    except json.JSONDecodeError as e:
        return None, f"source returned non-JSON: {e}"

    if isinstance(envelope, dict) and envelope.get("msg_type") == "E":
        return None, f"source error: {envelope.get('error') or 'msg_type=E'}"
    rows = envelope.get(envelope_key) if isinstance(envelope, dict) else None
    if rows is None:
        return None, f"envelope has no '{envelope_key}' array"
    if not isinstance(rows, list):
        return None, f"envelope '{envelope_key}' is not an array"
    return rows, None


def _fetch_rest(cfg):
    """Legacy: fetch `.data` from {gateway}/api/v1/{collection}."""
    gateway = (cfg.get("gateway") or "").rstrip("/")
    collection = cfg["collection"]
    headers = {"Accept": "application/json"}
    if cfg.get("gatewayUser"):
        headers["Authorization"] = _basic_auth(
            cfg["gatewayUser"], cfg.get("gatewayPass", "")
        )
    try:
        status, payload = _http(
            "GET", f"{gateway}/api/v1/{collection}", headers=headers
        )
    except Exception as e:  # noqa: BLE001
        return None, f"gateway fetch failed: {e}"
    if status >= 400:
        return None, f"gateway returned {status}: {payload[:200]}"
    try:
        return json.loads(payload).get("data", []), None
    except json.JSONDecodeError as e:
        return None, f"gateway returned non-JSON: {e}"


def main():
    started = time.monotonic()

    try:
        cfg = json.loads(sys.stdin.read())
    except json.JSONDecodeError as e:
        sys.stderr.write(f"pull.py: bad stdin JSON: {e}\n")
        sys.exit(2)

    mode = cfg.get("mode", "rest")
    table = cfg["table"]
    rename = cfg.get("rename") or {}
    project_only = bool(cfg.get("projectOnly", False))
    key_field = cfg.get("keyField") or ""
    dry_run = bool(cfg.get("dryRun", False))

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

    # 1) Fetch source rows.
    rows, fetch_err = (
        _fetch_extract(cfg) if mode == "extract" else _fetch_rest(cfg)
    )
    if fetch_err is not None:
        _emit(ok=False, scanned=0, created=0, updated=0, skipped=0,
              failed=0, error=fetch_err, started=started)
        return

    scanned = created = updated = skipped = failed = 0
    first_error = None

    # 2) Walk rows, transform, upsert into Surreal.
    for row in rows:
        scanned += 1
        try:
            row_id = _row_id(row, key_field)
            transformed = _transform(row, rename, project_only)

            if dry_run:
                updated += 1
                continue

            # Backtick-quote the id so numeric / padded SAP keys stay string
            # ids instead of being parsed as ints / tuples by SurrealQL.
            # MERGE (not CONTENT) so only the mapped fields are set — schema
            # defaults (created_at, is_active, …) survive on re-runs and on
            # duplicate keys that land as updates.
            esc_id = row_id.replace("`", "\\`")
            sql = f"UPSERT {table}:`{esc_id}` MERGE {json.dumps(transformed)};"

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
        except Exception as e:  # noqa: BLE001
            failed += 1
            if first_error is None:
                first_error = str(e)

    _emit(ok=(failed == 0), scanned=scanned, created=created, updated=updated,
          skipped=skipped, failed=failed, error=first_error, started=started)


def _emit(*, ok, scanned, created, updated, skipped, failed, error, started):
    duration_ms = int((time.monotonic() - started) * 1000)
    sys.stdout.write(json.dumps({
        "ok": ok,
        "scanned": scanned,
        "created": created,
        "updated": updated,
        "skipped": skipped,
        "failed": failed,
        "error": error,
        "durationMs": duration_ms,
    }))
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
