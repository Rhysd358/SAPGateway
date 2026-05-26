# Compile the Dart server to a self-contained native executable, then ship
# it in a minimal runtime image. Final image is ~25 MB and runs in scratch
# with no Dart SDK or shell.
FROM dart:stable AS build

WORKDIR /app

COPY pubspec.* ./
RUN dart pub get

COPY . ./
RUN dart compile exe bin/server.dart -o /app/server.exe

# ──────────────────────────────────────────────────────────────────────────
FROM scratch

# Dart AOT runtime files (libdart_precompiled_runtime, etc.)
COPY --from=build /runtime/ /
COPY --from=build /app/server.exe /app/server

WORKDIR /app

EXPOSE 8080
VOLUME ["/app/data"]

# Configuration via env (all optional):
#   GATEWAY_PORT       default 8080
#   GATEWAY_HOST       default 0.0.0.0
#   GATEWAY_DATA       default /app/data
#   GATEWAY_AUTH_USER  + GATEWAY_AUTH_PASS to enable Basic auth on every mount
ENV GATEWAY_PORT=8080 \
    GATEWAY_HOST=0.0.0.0 \
    GATEWAY_DATA=/app/data

ENTRYPOINT ["/app/server"]
