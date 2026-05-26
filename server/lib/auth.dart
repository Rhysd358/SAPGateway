import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Auth configuration for the gateway. Today supports `none` (default,
/// backward-compatible) and `basic` (HTTP Basic with a single shared
/// credential). OAuth2 modes are the next slot to wire in here.
class AuthConfig {
  final String mode;
  final String? username;
  final String? password;
  final String realm;

  const AuthConfig.none()
      : mode = 'none',
        username = null,
        password = null,
        realm = 'SAP Gateway';

  const AuthConfig.basic({
    required String this.username,
    required String this.password,
    this.realm = 'SAP Gateway',
  }) : mode = 'basic';

  /// Build config from process env + optional CLI overrides. Returns a
  /// `none` config unless both a username and password are present.
  factory AuthConfig.from({
    required Map<String, String> env,
    String? cliUser,
    String? cliPass,
  }) {
    final user = cliUser ?? env['GATEWAY_AUTH_USER'];
    final pass = cliPass ?? env['GATEWAY_AUTH_PASS'];
    if (user != null && user.isNotEmpty && pass != null && pass.isNotEmpty) {
      return AuthConfig.basic(username: user, password: pass);
    }
    return const AuthConfig.none();
  }

  bool get enabled => mode != 'none';
}

/// Single shelf middleware in front of every mount. No-op when `mode=none`;
/// validates Basic credentials when `mode=basic`. CORS preflight (OPTIONS) and
/// `/healthz` always pass through so browsers and Docker probes work without
/// credentials.
Middleware authMiddleware({AuthConfig config = const AuthConfig.none()}) {
  return (Handler inner) {
    return (Request request) async {
      if (!config.enabled) return inner(request);
      if (request.method == 'OPTIONS') return inner(request);
      if (request.requestedUri.path == '/healthz') return inner(request);

      final header = request.headers['authorization'] ?? '';
      if (!header.toLowerCase().startsWith('basic ')) {
        return _unauthorized(config.realm);
      }
      final token = header.substring(6).trim();
      String decoded;
      try {
        decoded = utf8.decode(base64.decode(token));
      } catch (_) {
        return _unauthorized(config.realm);
      }
      final colon = decoded.indexOf(':');
      if (colon < 0) return _unauthorized(config.realm);
      final user = decoded.substring(0, colon);
      final pass = decoded.substring(colon + 1);

      if (!_constantTimeEq(user, config.username!) ||
          !_constantTimeEq(pass, config.password!)) {
        return _unauthorized(config.realm);
      }
      return inner(request);
    };
  };
}

bool _constantTimeEq(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

Response _unauthorized(String realm) => Response.unauthorized(
      '{"error":"Authentication required"}',
      headers: {
        'WWW-Authenticate': 'Basic realm="$realm", charset="UTF-8"',
        'content-type': 'application/json; charset=utf-8',
      },
    );
