import 'dart:convert';
import 'dart:io';

class SurrealException implements Exception {
  final int statusCode;
  final String message;
  SurrealException(this.statusCode, this.message);
  @override
  String toString() => 'SurrealException($statusCode): $message';
}

class SurrealClient {
  final String endpoint;
  final String namespace;
  final String database;
  final String username;
  final String password;
  final Duration timeout;

  SurrealClient({
    required this.endpoint,
    required this.namespace,
    required this.database,
    required this.username,
    required this.password,
    this.timeout = const Duration(seconds: 15),
  });

  Future<String> version() async {
    final resp = await _request('GET', '/version', includeNsDb: false);
    if (resp is String) return resp.trim();
    if (resp is Map && resp['version'] != null) return resp['version'].toString();
    return resp?.toString() ?? '';
  }

  Future<List<Map<String, dynamic>>> select(String table) async {
    final resp = await _sql('SELECT * FROM $table;');
    return _extractRows(resp);
  }

  Future<dynamic> _sql(String statement) async {
    return await _request('POST', '/sql', body: statement, rawBody: true);
  }

  /// Execute a raw SurrealQL statement and return the decoded envelope.
  /// Used by [IntegrationHandler] for INFO FOR DB / INFO FOR TABLE / DEFINE TABLE
  /// calls invoked from the admin UI.
  Future<dynamic> sql(String statement) => _sql(statement);

  Future<dynamic> _request(String method, String path,
      {Object? body, bool includeNsDb = true, bool rawBody = false}) async {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    // Validate synchronously: malformed endpoints (missing scheme, empty
    // host) have triggered cryptic native errors on Windows in earlier
    // builds. Surface a clear FormatException instead.
    final Uri uri;
    try {
      uri = Uri.parse('$base$path');
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw FormatException(
            'Surreal endpoint must start with http:// or https:// (got "${uri.scheme}")');
      }
      if (uri.host.isEmpty) {
        throw FormatException('Surreal endpoint host is empty');
      }
    } on FormatException catch (e) {
      throw SurrealException(0, e.message);
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.openUrl(method, uri).timeout(timeout);
      req.headers.set('Accept', 'application/json');
      if (includeNsDb) {
        req.headers.set('Surreal-NS', namespace);
        req.headers.set('NS', namespace);
        req.headers.set('Surreal-DB', database);
        req.headers.set('DB', database);
      }
      if (username.isNotEmpty || password.isNotEmpty) {
        final token = base64.encode(utf8.encode('$username:$password'));
        req.headers.set('Authorization', 'Basic $token');
      }
      if (body != null) {
        final bytes = rawBody && body is String
            ? utf8.encode(body)
            : utf8.encode(jsonEncode(body));
        req.headers.set(
            'Content-Type', rawBody ? 'text/plain' : 'application/json');
        req.headers.contentLength = bytes.length;
        req.add(bytes);
      }
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode >= 400) {
        throw SurrealException(resp.statusCode, _stripErr(text));
      }
      if (text.isEmpty) return null;
      dynamic decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        return text;
      }
      _assertEnvelopeOk(decoded);
      return decoded;
    } finally {
      // Swallow any error from close(): on Windows with certain socket states
      // (peer reset mid-handshake, etc.) HttpClient.close has been observed
      // to throw synchronously, which would mask the original error AND
      // propagate uncaught from the finally block.
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  void _assertEnvelopeOk(dynamic decoded) {
    if (decoded is Map && decoded['status'] is String) {
      if (decoded['status'] != 'OK') {
        throw SurrealException(0, decoded['result']?.toString() ?? decoded.toString());
      }
    } else if (decoded is List) {
      for (final stmt in decoded) {
        if (stmt is Map && stmt['status'] is String && stmt['status'] != 'OK') {
          throw SurrealException(0, stmt['result']?.toString() ?? stmt.toString());
        }
      }
    }
  }

  String _stripErr(String text) {
    try {
      final j = jsonDecode(text);
      if (j is Map && j['information'] != null) return j['information'].toString();
      if (j is Map && j['description'] != null) return j['description'].toString();
    } catch (_) {}
    return text;
  }
}

List<Map<String, dynamic>> _extractRows(dynamic resp) {
  if (resp == null) return [];
  // Single envelope (v3 /key endpoints): { kind, result, status, ... }
  if (resp is Map && resp.containsKey('status') && resp.containsKey('result')) {
    return _coerceRows(resp['result']);
  }
  // List of envelopes (v2 /sql or multi-statement)
  if (resp is List) {
    if (resp.isNotEmpty &&
        resp.first is Map &&
        (resp.first as Map).containsKey('status')) {
      final out = <Map<String, dynamic>>[];
      for (final stmt in resp) {
        if (stmt is! Map) continue;
        out.addAll(_coerceRows(stmt['result']));
      }
      return out;
    }
    return _coerceRows(resp);
  }
  if (resp is Map) return [Map<String, dynamic>.from(resp)];
  return [];
}

List<Map<String, dynamic>> _coerceRows(dynamic result) {
  if (result == null) return [];
  if (result is List) {
    return result
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }
  if (result is Map) return [Map<String, dynamic>.from(result)];
  return [];
}
