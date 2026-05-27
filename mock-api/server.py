#!/usr/bin/env python3
"""Mock SAP `/ai/extract` endpoint — stdlib only, no pip install.

Serves canned JSON envelopes (dropped in ./samples) so the gateway's
outbound puller can be exercised end-to-end without the real
`cssapfb3.<org>.co.uk/ai/extract` API.

Request shape (matches production):
    GET /ai/extract?type=full|delta&dataset=<name>&key_date=YYYYMMDDhhmmss
    GET /ai/extract?type=full|delta&dataset=<name>&change_date=YYYYMMDDhhmmss

Behaviour learned from the first real sample:
  - One call returns the FULL envelope (all datasets), regardless of the
    `dataset` param. We mirror that — `dataset` is accepted but doesn't
    narrow the response.
  - `token_key` in the response echoes the key_date / change_date sent.
  - `msg_type` is "S" on success.

Config via env (all optional):
  MOCK_PORT        default 9000
  MOCK_SAMPLES     default ./samples
  MOCK_AUTH_USER   + MOCK_AUTH_PASS to require HTTP Basic
"""
import base64
import glob
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("MOCK_PORT", "9000"))
SAMPLES_DIR = os.environ.get(
    "MOCK_SAMPLES", os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples")
)
# When set, always serve this exact sample file (by filename). Lets several
# mock instances share one samples/ folder while each serves a different
# response. Falls back to filename scoring when unset.
FORCED_SAMPLE = os.environ.get("MOCK_SAMPLE", "")
AUTH_USER = os.environ.get("MOCK_AUTH_USER", "")
AUTH_PASS = os.environ.get("MOCK_AUTH_PASS", "")


def _load_samples():
    """Load every samples/*.json into memory, keyed by filename."""
    out = {}
    for path in sorted(glob.glob(os.path.join(SAMPLES_DIR, "*.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                out[os.path.basename(path)] = json.load(f)
        except Exception as e:  # noqa: BLE001 — log + skip bad files
            print(f"mock: skipping {path}: {e}", flush=True)
    return out


SAMPLES = _load_samples()


def _pick(extract_type: str, dataset: str):
    """Choose the sample file for the request.

    If MOCK_SAMPLE pins a filename, always serve that. Otherwise score
    filenames: +2 if the type (full/delta) appears, +1 if the dataset name
    appears — falls back to the only/first sample so a single dropped file
    'just works'.
    """
    if not SAMPLES:
        return None
    if FORCED_SAMPLE and FORCED_SAMPLE in SAMPLES:
        return SAMPLES[FORCED_SAMPLE]
    names = list(SAMPLES.keys())

    def score(name: str) -> int:
        low = name.lower()
        s = 0
        if extract_type and extract_type in low:
            s += 2
        if dataset and dataset in low:
            s += 1
        return s

    best = max(names, key=score)
    return SAMPLES[best]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # quieter, single-line logs
        print(f"mock: {self.address_string()} {fmt % args}", flush=True)

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        if not AUTH_USER:
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            user, _, pw = (
                base64.b64decode(header[6:]).decode("utf-8").partition(":")
            )
        except Exception:  # noqa: BLE001
            return False
        return user == AUTH_USER and pw == AUTH_PASS

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/healthz"):
            self._send_json(200, {
                "ok": True,
                "service": "sap-extract-mock",
                "endpoints": ["/ai/extract?type=&dataset=&key_date=|change_date="],
                "samples": list(SAMPLES.keys()),
            })
            return

        if parsed.path != "/ai/extract":
            self._send_json(404, {"error": f"no route for {parsed.path}"})
            return

        if not self._authed():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="mock"')
            self.end_headers()
            return

        q = parse_qs(parsed.query)
        extract_type = (q.get("type", [""])[0] or "").lower()
        dataset = (q.get("dataset", [""])[0] or "").lower()
        cutoff = q.get("key_date", q.get("change_date", [None]))[0]

        if extract_type not in ("full", "delta"):
            self._send_json(
                400,
                {"msg_type": "E", "error": "type must be 'full' or 'delta'"},
            )
            return
        # Only delta needs a cutoff; a full extract returns everything.
        if extract_type == "delta" and not q.get("key_date") and not q.get(
            "change_date"
        ):
            self._send_json(
                400,
                {
                    "msg_type": "E",
                    "error": "delta requires one of key_date or change_date",
                },
            )
            return

        envelope = _pick(extract_type, dataset)
        if envelope is None:
            self._send_json(
                501,
                {"msg_type": "E", "error": "no sample loaded for this request"},
            )
            return

        # Echo the requested cutoff into token_key, mirroring the real API.
        out = dict(envelope)
        if cutoff is not None:
            try:
                out["token_key"] = int(cutoff)
            except ValueError:
                out["token_key"] = cutoff
        self._send_json(200, out)


def main():
    if not SAMPLES:
        print(f"mock: WARNING no samples found in {SAMPLES_DIR}", flush=True)
    else:
        print(f"mock: loaded {len(SAMPLES)} sample(s): {list(SAMPLES)}", flush=True)
    auth = f"basic (user={AUTH_USER})" if AUTH_USER else "none"
    print(f"mock: listening on http://0.0.0.0:{PORT}/ai/extract · auth={auth}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
