# Mock SAP /ai/extract API. Stdlib-only Python — no pip install, so this
# builds and runs fully offline once the base image is present.
FROM python:3.12-alpine

WORKDIR /app
COPY server.py ./
# Samples are baked in at build time; override at run with a bind mount
# (-v) or by rebuilding after dropping new files in ./samples.
COPY samples/ ./samples/

EXPOSE 9000
ENV MOCK_PORT=9000 \
    MOCK_SAMPLES=/app/samples

# Optional Basic auth: pass -e MOCK_AUTH_USER=… -e MOCK_AUTH_PASS=…
HEALTHCHECK --interval=10s --timeout=3s \
    CMD wget -qO- http://localhost:9000/healthz || exit 1

ENTRYPOINT ["python", "server.py"]
