import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class GatewayException implements Exception {
  final int statusCode;
  final String message;
  GatewayException(this.statusCode, this.message);
  @override
  String toString() => message;
}

/// Thrown when DELETE /connections/<id> is refused because flows reference
/// the connection. Carries the list of dependent flows so the UI can offer
/// a cascade-delete option ("Delete connection + 3 flows").
class ConnectionInUseException extends GatewayException {
  final String connectionId;
  final String connectionName;
  final List<Map<String, dynamic>> outboundFlows;
  final List<Map<String, dynamic>> inboundFlows;

  ConnectionInUseException({
    required this.connectionId,
    required this.connectionName,
    required this.outboundFlows,
    required this.inboundFlows,
  }) : super(409,
            'Connection "$connectionName" is used by '
            '${outboundFlows.length + inboundFlows.length} flow(s)');

  int get totalReferences => outboundFlows.length + inboundFlows.length;
}

class GatewayApi {
  final String baseUrl;
  final String authMode;
  final String authUser;
  final String authPass;

  GatewayApi(
    this.baseUrl, {
    this.authMode = 'none',
    this.authUser = '',
    this.authPass = '',
  });

  String get _base => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  Map<String, String> _authHeaders() {
    if (authMode == 'basic' && authUser.isNotEmpty) {
      final token = base64.encode(utf8.encode('$authUser:$authPass'));
      return {'Authorization': 'Basic $token'};
    }
    return const {};
  }

  Map<String, String> _headers({bool json = false}) {
    final h = <String, String>{'Accept': 'application/json', ..._authHeaders()};
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String?>? query,
  }) async {
    var uri = Uri.parse('$_base$path');
    if (query != null) {
      final cleaned = <String, String>{};
      for (final entry in query.entries) {
        if (entry.value != null) cleaned[entry.key] = entry.value!;
      }
      uri = uri.replace(queryParameters: cleaned);
    }
    final headers = _headers(json: body != null);
    final encoded = body == null ? null : jsonEncode(body);
    final req = http.Request(method, uri);
    req.headers.addAll(headers);
    if (encoded != null) req.body = encoded;
    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 400) {
      String message;
      try {
        final j = jsonDecode(resp.body);
        message = (j is Map && j['error'] != null)
            ? j['error'].toString()
            : resp.body;
      } catch (_) {
        message = resp.body.isEmpty ? resp.reasonPhrase ?? 'HTTP ${resp.statusCode}' : resp.body;
      }
      throw GatewayException(resp.statusCode, message);
    }
    if (resp.body.isEmpty) return null;
    try {
      return jsonDecode(resp.body);
    } on FormatException {
      // A 2xx with a non-JSON body almost always means the request reached a
      // static/SPA file server instead of the gateway API — e.g. the gateway
      // URL points at the web-app host (which answers every path with
      // index.html) rather than the API. Convert it to a GatewayException so
      // callers' existing `on GatewayException` handling shows a clear message
      // and a Retry button, instead of the raw FormatException escaping and
      // leaving the screen stuck on its loading spinner.
      final looksHtml = resp.body.trimLeft().startsWith('<');
      throw GatewayException(
        resp.statusCode,
        looksHtml
            ? 'Gateway returned HTML, not JSON. Check the gateway URL in '
                'Settings — it must point at the API server, not the web app.'
            : 'Gateway returned a non-JSON response.',
      );
    }
  }

  Future<List<ServiceSummary>> listServices() async {
    final j = await _send('GET', '/admin/services') as Map<String, dynamic>;
    return (j['services'] as List)
        .map((s) => ServiceSummary.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList();
  }

  Future<ServiceSummary> getService(String name) async {
    final j = await _send('GET', '/admin/services/$name') as Map<String, dynamic>;
    return ServiceSummary.fromJson({
      'name': j['name'],
      'entityTypes': j['entityTypes'],
      'entitySets': (j['entitySets'] as List).map((s) {
        final m = Map<String, dynamic>.from(s as Map);
        m['rowCount'] = (m['rows'] as List?)?.length ?? m['rowCount'] ?? 0;
        m['collection'] = m['collection'] ?? '';
        return m;
      }).toList(),
    });
  }

  Future<void> createService(String name) async {
    await _send('POST', '/admin/services', body: {'name': name});
  }

  Future<void> renameService(String oldName, String newName) async {
    await _send('PATCH', '/admin/services/$oldName', body: {'name': newName});
  }

  Future<void> deleteService(String name) async {
    await _send('DELETE', '/admin/services/$name');
  }

  Future<void> createType(String service, EntityType type) async {
    await _send('POST', '/admin/services/$service/types', body: {
      'name': type.name,
      'properties': type.properties.map((p) => p.toJson()).toList(),
    });
  }

  Future<void> renameType(String service, String oldName, String newName) async {
    await _send('PATCH', '/admin/services/$service/types/$oldName',
        body: {'name': newName});
  }

  Future<void> deleteType(String service, String name) async {
    await _send('DELETE', '/admin/services/$service/types/$name');
  }

  Future<void> createProperty(String service, String type, Property prop) async {
    await _send('POST', '/admin/services/$service/types/$type/properties',
        body: prop.toJson());
  }

  Future<void> updateProperty(
      String service, String type, String prop, Map<String, dynamic> changes) async {
    await _send('PATCH',
        '/admin/services/$service/types/$type/properties/$prop',
        body: changes);
  }

  Future<void> deleteProperty(String service, String type, String prop) async {
    await _send('DELETE',
        '/admin/services/$service/types/$type/properties/$prop');
  }

  Future<void> createSet(String service, String name, String entityType) async {
    await _send('POST', '/admin/services/$service/sets',
        body: {'name': name, 'entityType': entityType});
  }

  Future<void> renameSet(String service, String oldName, String newName) async {
    await _send('PATCH', '/admin/services/$service/sets/$oldName',
        body: {'name': newName});
  }

  Future<void> deleteSet(String service, String name) async {
    await _send('DELETE', '/admin/services/$service/sets/$name');
  }

  Future<List<Map<String, dynamic>>> listSetRows(String service, String set) async {
    final j =
        await _send('GET', '/admin/services/$service/sets/$set/rows')
            as Map<String, dynamic>;
    return (j['data'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  Future<void> createSetRow(
      String service, String set, Map<String, dynamic> row) async {
    await _send('POST', '/admin/services/$service/sets/$set/rows', body: row);
  }

  Future<void> patchSetRow(String service, String set, String id,
      Map<String, dynamic> patch) async {
    await _send('PATCH', '/admin/services/$service/sets/$set/rows/$id',
        body: patch);
  }

  Future<void> deleteSetRow(String service, String set, String id) async {
    await _send('DELETE', '/admin/services/$service/sets/$set/rows/$id');
  }

  Future<void> resetSeed() async {
    await _send('POST', '/admin/reset');
  }

  Future<IntegrationConfigView> getIntegrationConfig() async {
    final j = await _send('GET', '/api/v1/integration/config')
        as Map<String, dynamic>;
    return IntegrationConfigView.fromJson(j);
  }

  Future<void> putSurreal({
    required String endpoint,
    required String namespace,
    required String database,
    required String username,
    String? password,
  }) async {
    final body = <String, dynamic>{
      'endpoint': endpoint,
      'namespace': namespace,
      'database': database,
      'username': username,
    };
    if (password != null) body['password'] = password;
    await _send('PUT', '/api/v1/integration/config/surreal', body: body);
  }

  Future<void> putMapping(Mapping mapping) async {
    await _send(
      'PUT',
      '/api/v1/integration/config/mappings/${mapping.collection}',
      body: mapping.toJson(),
    );
  }

  Future<void> deleteMapping(String collection) async {
    await _send('DELETE', '/api/v1/integration/config/mappings/$collection');
  }

  Future<Map<String, dynamic>> testConnection({
    String? endpoint,
    String? namespace,
    String? database,
    String? username,
    String? password,
  }) async {
    return await _send(
      'POST',
      '/api/v1/integration/test-connection',
      query: {
        if (endpoint != null) 'endpoint': endpoint,
        if (namespace != null) 'namespace': namespace,
        if (database != null) 'database': database,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
      },
    ) as Map<String, dynamic>;
  }

  /// List tables in the Surreal database.
  ///
  /// Prefer `connectionId` — the server resolves the unredacted credentials
  /// from `flows.json` and the password never leaves the server. The raw
  /// endpoint/namespace/database/username/password fields are kept only for
  /// pre-save Test flows (where there is no saved connection yet).
  Future<List<String>> listSurrealTables({
    String? connectionId,
    String? endpoint,
    String? namespace,
    String? database,
    String? username,
    String? password,
  }) async {
    final j = await _send(
      'GET',
      '/api/v1/integration/surreal/tables',
      query: {
        if (connectionId != null) 'connectionId': connectionId,
        if (endpoint != null) 'endpoint': endpoint,
        if (namespace != null) 'namespace': namespace,
        if (database != null) 'database': database,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
      },
    ) as Map<String, dynamic>;
    return (j['tables'] as List).map((e) => e.toString()).toList();
  }

  /// Get field names for a single Surreal table. See [listSurrealTables] for
  /// the `connectionId` vs raw-field trade-off.
  Future<List<String>> listSurrealTableFields(
    String table, {
    String? connectionId,
    String? endpoint,
    String? namespace,
    String? database,
    String? username,
    String? password,
  }) async {
    final j = await _send(
      'GET',
      '/api/v1/integration/surreal/tables/$table',
      query: {
        if (connectionId != null) 'connectionId': connectionId,
        if (endpoint != null) 'endpoint': endpoint,
        if (namespace != null) 'namespace': namespace,
        if (database != null) 'database': database,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
      },
    ) as Map<String, dynamic>;
    return (j['fields'] as List).map((e) => e.toString()).toList();
  }

  /// Define a new Surreal table (default SCHEMALESS). See [listSurrealTables]
  /// for the `connectionId` vs raw-field trade-off.
  Future<void> defineSurrealTable(
    String name, {
    bool schemaless = true,
    String? connectionId,
    String? endpoint,
    String? namespace,
    String? database,
    String? username,
    String? password,
  }) async {
    await _send(
      'POST',
      '/api/v1/integration/surreal/tables',
      body: {'name': name, 'schemaless': schemaless},
      query: {
        if (connectionId != null) 'connectionId': connectionId,
        if (endpoint != null) 'endpoint': endpoint,
        if (namespace != null) 'namespace': namespace,
        if (database != null) 'database': database,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
      },
    );
  }

  // ─────────────────────────────────────────────────────────────
  // Connections + outbound flows (persisted on the gateway).
  // ─────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listConnections() async {
    final j = await _send('GET', '/api/v1/integration/connections')
        as Map<String, dynamic>;
    return (j['connections'] as List)
        .map((c) => Map<String, dynamic>.from(c as Map))
        .toList();
  }

  Future<Map<String, dynamic>> putConnection(
      String id, Map<String, dynamic> body) async {
    final j = await _send(
      'PUT',
      '/api/v1/integration/connections/$id',
      body: body,
    ) as Map<String, dynamic>;
    return j;
  }

  /// Delete a connection.
  ///
  /// Default: server refuses with 409 if any outbound or inbound flow still
  /// references the connection — we throw [ConnectionInUseException] in
  /// that case so the UI can prompt the user to choose one of:
  ///   - [cascade] = true → remove the connection AND every referencing
  ///     flow in one atomic save.
  ///   - [force]   = true → remove ONLY the connection; referencing flows
  ///     remain in place with a now-dangling reference, to be repointed
  ///     manually later.
  ///
  /// [cascade] and [force] are mutually exclusive; passing both raises
  /// `GatewayException(400, …)`.
  ///
  /// Done with a raw http call (not [_send]) so the 409 body — which
  /// carries the structured `inUse` info — is parsed instead of being
  /// flattened into a generic GatewayException message.
  Future<Map<String, dynamic>> deleteConnection(
    String id, {
    bool cascade = false,
    bool force = false,
  }) async {
    assert(!(cascade && force), 'cascade and force are mutually exclusive');
    final Map<String, String> qp = {};
    if (cascade) qp['cascade'] = 'true';
    if (force) qp['force'] = 'true';
    final uri = Uri.parse('$_base/api/v1/integration/connections/$id').replace(
      queryParameters: qp.isEmpty ? null : qp,
    );
    final req = http.Request('DELETE', uri);
    req.headers.addAll(_authHeaders());
    final resp = await http.Response.fromStream(await req.send());
    if (resp.statusCode == 204 ||
        (resp.statusCode == 200 && resp.body.isEmpty)) {
      return const {};
    }
    if (resp.statusCode == 200) {
      try {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      } on FormatException {
        return const {};
      }
    }
    if (resp.statusCode == 409) {
      try {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final inUse = (j['inUse'] as Map?) ?? const {};
        throw ConnectionInUseException(
          connectionId: j['connectionId']?.toString() ?? id,
          connectionName: j['connectionName']?.toString() ?? id,
          outboundFlows: [
            for (final f in (inUse['outbound'] as List? ?? []))
              Map<String, dynamic>.from(f as Map),
          ],
          inboundFlows: [
            for (final f in (inUse['inbound'] as List? ?? []))
              Map<String, dynamic>.from(f as Map),
          ],
        );
      } on FormatException {
        throw GatewayException(409, resp.body);
      }
    }
    String message = resp.body;
    try {
      final j = jsonDecode(resp.body);
      if (j is Map && j['error'] != null) message = j['error'].toString();
    } catch (_) {}
    throw GatewayException(resp.statusCode, message);
  }

  /// Probe a stored connection server-side (uses its saved creds, avoids
  /// browser CORS). Returns `{ok, status?, detail?, error?}`.
  Future<Map<String, dynamic>> testConnectionById(String id) async {
    return await _send('POST', '/api/v1/integration/connections/$id/test')
        as Map<String, dynamic>;
  }

  /// Discover the datasets exposed by a REST source connection's
  /// `/ai/extract` API. The gateway probes the connection server-side with
  /// its stored credentials and returns the array-valued keys it found in
  /// the response envelope.
  ///
  /// Returns a list of `{urlParam, envelopeKey}` records; the dropdown
  /// should display + submit `urlParam`. Returns an empty list (no throw)
  /// if the probe failed for any reason — callers fall back to a baked-in
  /// default. The probe's error message, if any, is exposed via the
  /// optional [errorSink] for surfacing a "couldn't reach source" hint.
  Future<List<Map<String, String>>> listConnectionDatasets(
    String connectionId, {
    void Function(String error)? errorSink,
  }) async {
    final j = await _send(
      'GET',
      '/api/v1/integration/connections/$connectionId/datasets',
    ) as Map<String, dynamic>;
    final err = j['error'];
    if (err is String && err.isNotEmpty && errorSink != null) {
      errorSink(err);
    }
    final raw = j['datasets'];
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map)
          {
            for (final e in entry.entries) e.key.toString(): e.value.toString(),
          },
    ];
  }

  Future<List<Map<String, dynamic>>> listOutboundFlows() async {
    final j = await _send('GET', '/api/v1/integration/flows/outbound')
        as Map<String, dynamic>;
    return (j['flows'] as List)
        .map((f) => Map<String, dynamic>.from(f as Map))
        .toList();
  }

  Future<Map<String, dynamic>> putOutboundFlow(
      String id, Map<String, dynamic> body) async {
    final j = await _send(
      'PUT',
      '/api/v1/integration/flows/outbound/$id',
      body: body,
    ) as Map<String, dynamic>;
    return j;
  }

  Future<void> deleteOutboundFlow(String id) async {
    await _send('DELETE', '/api/v1/integration/flows/outbound/$id');
  }

  /// Trigger a one-shot run of an outbound flow. The gateway spawns the
  /// Python puller and returns the resulting [AuditEvent] (also persisted
  /// to data/audit.json so the Logs tab shows it).
  Future<AuditEvent> runOutboundFlow(String id, {bool dryRun = false}) async {
    final j = await _send(
      'POST',
      '/api/v1/integration/flows/outbound/$id/run',
      query: {'dryRun': dryRun ? 'true' : null},
    ) as Map<String, dynamic>;
    return AuditEvent.fromJson(j);
  }

  Future<List<Map<String, dynamic>>> listInboundFlows() async {
    final j = await _send('GET', '/api/v1/integration/flows/inbound')
        as Map<String, dynamic>;
    return (j['flows'] as List)
        .map((f) => Map<String, dynamic>.from(f as Map))
        .toList();
  }

  Future<Map<String, dynamic>> putInboundFlow(
      String id, Map<String, dynamic> body) async {
    final j = await _send(
      'PUT',
      '/api/v1/integration/flows/inbound/$id',
      body: body,
    ) as Map<String, dynamic>;
    return j;
  }

  Future<void> deleteInboundFlow(String id) async {
    await _send('DELETE', '/api/v1/integration/flows/inbound/$id');
  }

  /// Probe a source connection's `/ai/extract` API (server-side, via the
  /// gateway) and return the field names on the first row of the requested
  /// dataset. Populates the Outbound editor's source-field dropdown.
  Future<List<String>> probeSourceFields(
    String connectionId,
    String dataset, {
    String? type,
    String? deltaBasis,
    String? deltaSince,
  }) async {
    final j = await _send(
      'GET',
      '/api/v1/integration/connections/$connectionId/source-fields',
      query: {
        'dataset': dataset,
        if (type != null) 'type': type,
        if (deltaBasis != null) 'deltaBasis': deltaBasis,
        if (deltaSince != null && deltaSince.isNotEmpty) 'deltaSince': deltaSince,
      },
    ) as Map<String, dynamic>;
    return (j['fields'] as List).map((e) => e.toString()).toList();
  }

  Future<AuditEvent> pull(String collection, {bool dryRun = false}) async {
    final j = await _send(
      'POST',
      '/api/v1/integration/pull/$collection',
      query: {'dryRun': dryRun ? 'true' : null},
    ) as Map<String, dynamic>;
    return AuditEvent.fromJson(j);
  }

  Future<AuditEvent> push(String collection, {bool dryRun = false}) async {
    final j = await _send(
      'POST',
      '/api/v1/integration/push/$collection',
      query: {'dryRun': dryRun ? 'true' : null},
    ) as Map<String, dynamic>;
    return AuditEvent.fromJson(j);
  }

  Future<List<AuditEvent>> getAudit({
    int? limit,
    String? action,
    String? collection,
  }) async {
    final j = await _send(
      'GET',
      '/api/v1/integration/audit',
      query: {
        if (limit != null) 'limit': limit.toString(),
        if (action != null && action.isNotEmpty) 'action': action,
        if (collection != null && collection.isNotEmpty) 'collection': collection,
      },
    ) as Map<String, dynamic>;
    return (j['events'] as List)
        .map((e) => AuditEvent.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> clearAudit() async {
    await _send('DELETE', '/api/v1/integration/audit');
  }
}
