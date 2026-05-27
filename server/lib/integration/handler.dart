import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth.dart';
import '../schema.dart';
import '../store.dart';
import 'audit.dart';
import 'config.dart';
import 'flows_store.dart';
import 'surreal_client.dart';

class IntegrationException implements Exception {
  final int statusCode;
  final String message;
  IntegrationException(this.statusCode, this.message);
  @override
  String toString() => message;
}

class IntegrationHandler {
  final GatewayStore store;
  final IntegrationConfig config;
  final FlowsStore flowsStore;
  final AuditLog audit;

  /// Base URL the Python pull script uses to call back into the gateway's
  /// SAP-shaped REST mount. Typically `http://localhost:{port}`.
  final String gatewayUrl;

  /// Auth config the Python pull script uses when calling the gateway. The
  /// Surreal-side credentials are sourced from [config.surreal].
  final AuthConfig authConfig;

  IntegrationHandler({
    required this.store,
    required this.config,
    required this.flowsStore,
    required this.audit,
    required this.gatewayUrl,
    required this.authConfig,
  });

  Handler get handler {
    final router = Router();
    router.get('/config', _getConfig);
    router.put('/config/surreal', _putSurreal);
    router.put('/config/mappings/<collection>', _putMapping);
    router.delete('/config/mappings/<collection>', _deleteMapping);
    router.post('/test-connection', _testConnection);
    router.get('/surreal/tables', _surrealTables);
    router.get('/surreal/tables/<name>', _surrealTableInfo);
    router.post('/surreal/tables', _surrealDefineTable);
    router.get('/connections', _listConnections);
    router.put('/connections/<id>', _putConnection);
    router.delete('/connections/<id>', _deleteConnection);
    router.post('/connections/<id>/test', _testConnectionById);
    router.get('/connections/<id>/source-fields', _sourceFields);
    router.get('/flows/outbound', _listOutboundFlows);
    router.put('/flows/outbound/<id>', _putOutboundFlow);
    router.delete('/flows/outbound/<id>', _deleteOutboundFlow);
    router.post('/flows/outbound/<id>/run', _runOutboundFlowRoute);
    router.get('/flows/inbound', _listInboundFlows);
    router.put('/flows/inbound/<id>', _putInboundFlow);
    router.delete('/flows/inbound/<id>', _deleteInboundFlow);
    router.post('/pull/<collection>', _pull);
    router.post('/push/<collection>', _push);
    router.get('/audit', _getAudit);
    router.delete('/audit', _clearAudit);
    return router.call;
  }

  // ────────────────────────────────────────────────────────────
  // Connections + outbound-flow CRUD (new model).
  // The existing /config/* + /pull|push routes stay backed by the legacy
  // IntegrationConfig so the scheduler keeps working unchanged.
  // ────────────────────────────────────────────────────────────

  Response _listConnections(Request request) {
    return _json({
      'connections':
          flowsStore.connections.map((c) => c.toRedactedJson()).toList(),
    });
  }

  Future<Response> _putConnection(Request request, String id) async {
    if (!_safeId(id)) return _err(400, 'Invalid connection id');
    Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } catch (e) {
      return _err(400, 'Invalid JSON: $e');
    }
    var existing = flowsStore.findConnection(id);
    if (existing == null) {
      existing = Connection(
        id: id,
        name: body['name'] as String? ?? id,
        type: body['type'] as String? ?? 'rest',
      );
      existing.applyPatch(body);
      flowsStore.upsertConnection(existing);
    } else {
      existing.applyPatch(body);
    }
    await flowsStore.save();
    return _json(existing.toRedactedJson());
  }

  Future<Response> _deleteConnection(Request request, String id) async {
    final removed = flowsStore.removeConnection(id);
    if (!removed) return _err(404, 'Connection $id not found');
    await flowsStore.save();
    return Response(204);
  }

  /// POST /connections/<id>/test — probe a stored connection server-side
  /// (using its saved credentials, which the admin UI never sees). Done on
  /// the server so there's no browser CORS issue reaching the source.
  ///
  ///   surreal  → GET /version
  ///   rest/odata → GET the base URL; any HTTP response means "reachable"
  ///                (a 404 on a bare API root is normal). 401/403 = auth
  ///                failure.
  Future<Response> _testConnectionById(Request request, String id) async {
    final conn = flowsStore.findConnection(id);
    if (conn == null) return _err(404, 'Connection $id not found');

    if (conn.type == 'surreal') {
      final client = SurrealClient(
        endpoint: conn.endpoint,
        namespace: conn.namespace,
        database: conn.database,
        username: conn.authUser,
        password: conn.authPass,
      );
      try {
        final version = await client.version();
        return _json({'ok': true, 'detail': 'SurrealDB $version'});
      } catch (e) {
        return _json({'ok': false, 'error': e.toString()});
      }
    }

    // rest / odata — reachability probe with the stored auth header.
    try {
      final (status: status, body: _) = await _connGet(conn, '');
      if (status == 401 || status == 403) {
        return _json(
            {'ok': false, 'status': status, 'error': 'auth failed (HTTP $status)'});
      }
      return _json({'ok': true, 'status': status, 'detail': 'HTTP $status'});
    } catch (e) {
      return _json({'ok': false, 'error': e.toString()});
    }
  }

  /// GET /connections/<id>/source-fields?dataset=<name>[&type=&deltaBasis=&deltaSince=]
  /// Probes the source `/ai/extract` API server-side and returns the field
  /// names found on the first row of the requested dataset's array. Used by
  /// the Outbound editor to populate the source-field dropdown.
  Future<Response> _sourceFields(Request request, String id) async {
    final conn = flowsStore.findConnection(id);
    if (conn == null) return _err(404, 'Connection $id not found');
    final q = request.url.queryParameters;
    final dataset = q['dataset'] ?? '';
    if (dataset.isEmpty) return _err(400, 'dataset query param required');

    final type = q['type'] == 'full' ? 'full' : 'delta';
    final basis = q['deltaBasis'] == 'key_date' ? 'key_date' : 'change_date';
    // Default to the epoch so a delta probe returns everything — we only
    // read one row for its field names.
    final since = (q['deltaSince']?.isNotEmpty ?? false)
        ? q['deltaSince']!
        : '19700101000000';
    final envKey = _envelopeKeyFor(dataset);

    final params = ['type=$type', 'dataset=$dataset'];
    if (type == 'delta') params.add('$basis=$since');
    final path = '/ai/extract?${params.join('&')}';

    try {
      final (status: status, body: body) = await _connGet(conn, path);
      if (status >= 400) {
        return _json({'fields': const [], 'error': 'source returned $status'});
      }
      final parsed = jsonDecode(body);
      if (parsed is! Map) {
        return _json({'fields': const [], 'error': 'unexpected response shape'});
      }
      if (parsed['msg_type'] == 'E') {
        return _json({'fields': const [], 'error': parsed['error']?.toString()});
      }
      final arr = parsed[envKey];
      if (arr is! List || arr.isEmpty) {
        return _json({'fields': const []});
      }
      final first = Map<String, dynamic>.from(arr.first as Map);
      final fields = first.keys.toList()..sort();
      return _json({'fields': fields});
    } catch (e) {
      return _json({'fields': const [], 'error': e.toString()});
    }
  }

  /// Auth'd server-side GET against a connection's endpoint. `pathAndQuery`
  /// is appended to the (de-trailing-slashed) endpoint. Returns the status
  /// and decoded body.
  Future<({int status, String body})> _connGet(
      Connection conn, String pathAndQuery) async {
    final base = conn.endpoint.endsWith('/')
        ? conn.endpoint.substring(0, conn.endpoint.length - 1)
        : conn.endpoint;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client
          .getUrl(Uri.parse('$base$pathAndQuery'))
          .timeout(const Duration(seconds: 8));
      if (conn.authScheme == 'basic' && conn.authUser.isNotEmpty) {
        final token =
            base64.encode(utf8.encode('${conn.authUser}:${conn.authPass}'));
        req.headers.set('Authorization', 'Basic $token');
      } else if (conn.authScheme == 'bearer' && conn.bearerToken.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer ${conn.bearerToken}');
      }
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp.transform(utf8.decoder).join();
      return (status: resp.statusCode, body: body);
    } finally {
      client.close(force: false);
    }
  }

  Response _listOutboundFlows(Request request) {
    return _json({
      'flows': flowsStore.outboundFlows.map((f) => f.toJson()).toList(),
    });
  }

  Future<Response> _putOutboundFlow(Request request, String id) async {
    if (!_safeId(id)) return _err(400, 'Invalid flow id');
    Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } catch (e) {
      return _err(400, 'Invalid JSON: $e');
    }
    var existing = flowsStore.findFlow(id);
    if (existing == null) {
      existing = OutboundFlow(id: id);
      existing.applyPatch(body);
      flowsStore.upsertFlow(existing);
    } else {
      existing.applyPatch(body);
    }
    await flowsStore.save();
    return _json(existing.toJson());
  }

  Future<Response> _deleteOutboundFlow(Request request, String id) async {
    final removed = flowsStore.removeFlow(id);
    if (!removed) return _err(404, 'Flow $id not found');
    await flowsStore.save();
    return Response(204);
  }

  /// POST /flows/outbound/<id>/run?dryRun=true|false — execute an outbound
  /// flow by spawning the Python puller with the flow's resolved source /
  /// target connection details. Writes an AuditEvent (tagged with flowId in
  /// details) and returns the event JSON.
  Future<Response> _runOutboundFlowRoute(Request request, String id) async {
    final dryRun = request.url.queryParameters['dryRun'] == 'true';
    try {
      final event = await runOutboundFlowById(id, dryRun: dryRun);
      return _json(event.toJson());
    } on IntegrationException catch (e) {
      return _err(e.statusCode, e.message);
    }
  }

  /// Public so the scheduler (future) can fire flow-shape pulls directly.
  /// Mirrors [runPull] but operates on the new [OutboundFlow] model:
  /// source/target connections are looked up by id from [flowsStore], and
  /// the AuditEvent carries the flowId in [AuditEvent.details] so the
  /// Logs UI can filter by flow.
  Future<AuditEvent> runOutboundFlowById(String flowId,
      {bool dryRun = false}) async {
    final started = DateTime.now();
    final flow = flowsStore.findFlow(flowId);
    if (flow == null) {
      throw IntegrationException(404, 'Flow $flowId not found');
    }
    final src = flowsStore.findConnection(flow.sourceConnectionId);
    if (src == null) {
      throw IntegrationException(
          400, 'Source connection ${flow.sourceConnectionId} not found');
    }
    final tgt = flowsStore.findConnection(flow.targetConnectionId);
    if (tgt == null) {
      throw IntegrationException(
          400, 'Target connection ${flow.targetConnectionId} not found');
    }

    final rename = <String, String>{
      for (final m in flow.mappings) m.source: m.target,
    };

    final scriptPath =
        Platform.environment['PULL_SCRIPT'] ?? 'scripts/pull.py';
    final pyConfig = <String, dynamic>{
      // New /ai/extract envelope shape — see scripts/pull.py.
      'mode': 'extract',
      'source': src.endpoint,
      'sourceUser': src.authUser,
      'sourcePass': src.authPass,
      'extractType': flow.extractType, // 'full' | 'delta'
      'dataset': flow.dataset,
      'envelopeKey': _envelopeKeyFor(flow.dataset),
      'deltaBasis': flow.deltaBasis, // 'change_date' | 'key_date'
      'deltaSince': flow.deltaSince,
      'keyField': _keyFieldFor(flow.dataset),
      'table': flow.targetTable,
      'rename': rename,
      // When the flow declares field mappings, treat them as a projection:
      // only those fields are written, renamed to the target columns. This
      // is required for SCHEMAFULL Surreal tables, which reject stray fields.
      'projectOnly': rename.isNotEmpty,
      'surreal': tgt.endpoint,
      'surrealNs': tgt.namespace,
      'surrealDb': tgt.database,
      'surrealUser': tgt.authUser,
      'surrealPass': tgt.authPass,
      'dryRun': dryRun,
    };

    String stdoutStr;
    String stderrStr;
    int exitCode;
    String pythonCmd;
    try {
      final res = await _runPython(scriptPath, jsonEncode(pyConfig));
      stdoutStr = res.stdout;
      stderrStr = res.stderr;
      exitCode = res.exitCode;
      pythonCmd = res.command;
    } catch (e) {
      final event = _flowErrorEvent(
        flow,
        dryRun,
        started,
        'python invocation failed: $e',
      );
      await audit.add(event);
      return event;
    }

    if (exitCode != 0) {
      final event = _flowErrorEvent(
        flow,
        dryRun,
        started,
        'python ($pythonCmd) exit=$exitCode: ${stderrStr.trim()}',
      );
      await audit.add(event);
      return event;
    }

    Map<String, dynamic> result;
    try {
      result = jsonDecode(stdoutStr.trim()) as Map<String, dynamic>;
    } catch (e) {
      final event = _flowErrorEvent(
        flow,
        dryRun,
        started,
        'python output not JSON: ${stdoutStr.trim()}',
      );
      await audit.add(event);
      return event;
    }

    final scanned = (result['scanned'] as num?)?.toInt() ?? 0;
    final created = (result['created'] as num?)?.toInt() ?? 0;
    final updated = (result['updated'] as num?)?.toInt() ?? 0;
    final skipped = (result['skipped'] as num?)?.toInt() ?? 0;
    final failed = (result['failed'] as num?)?.toInt() ?? 0;
    final pyError = result['error'] as String?;

    final event = AuditEvent(
      id: AuditLog.generateId(),
      timestamp: DateTime.now(),
      action: 'pull',
      collection: flow.name.isEmpty ? flow.dataset : flow.name,
      status: failed > 0 ? 'error' : (dryRun ? 'dry-run' : 'success'),
      dryRun: dryRun,
      rowsScanned: scanned,
      rowsCreated: created,
      rowsUpdated: updated,
      rowsSkipped: skipped,
      rowsFailed: failed,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      error: pyError != null ? AuditLog.truncate(pyError) : null,
      details: {
        'runner': 'python',
        'cmd': pythonCmd,
        'script': scriptPath,
        'flowId': flow.id,
        'dataset': flow.dataset,
        'extractType': flow.extractType,
      },
    );
    await audit.add(event);
    return event;
  }

  AuditEvent _flowErrorEvent(
      OutboundFlow flow, bool dryRun, DateTime started, String error) {
    return AuditEvent(
      id: AuditLog.generateId(),
      timestamp: DateTime.now(),
      action: 'pull',
      collection: flow.name.isEmpty ? flow.dataset : flow.name,
      status: 'error',
      dryRun: dryRun,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      error: AuditLog.truncate(error),
      details: {'flowId': flow.id, 'dataset': flow.dataset},
    );
  }

  Response _listInboundFlows(Request request) {
    return _json({
      'flows': flowsStore.inboundFlows.map((f) => f.toJson()).toList(),
    });
  }

  Future<Response> _putInboundFlow(Request request, String id) async {
    if (!_safeId(id)) return _err(400, 'Invalid flow id');
    Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } catch (e) {
      return _err(400, 'Invalid JSON: $e');
    }
    var existing = flowsStore.findInboundFlow(id);
    if (existing == null) {
      existing = InboundFlow(id: id);
      existing.applyPatch(body);
      flowsStore.upsertInboundFlow(existing);
    } else {
      existing.applyPatch(body);
    }
    await flowsStore.save();
    return _json(existing.toJson());
  }

  Future<Response> _deleteInboundFlow(Request request, String id) async {
    final removed = flowsStore.removeInboundFlow(id);
    if (!removed) return _err(404, 'Flow $id not found');
    await flowsStore.save();
    return Response(204);
  }

  /// Build a SurrealClient from request query params, falling back to the
  /// saved config for any field not provided. Query keys: endpoint,
  /// namespace, database, username, password. This lets the admin UI probe
  /// arbitrary Surreal endpoints without persisting them as the active
  /// connection.
  SurrealClient _surrealFromQuery(Request request) {
    final q = request.url.queryParameters;
    return SurrealClient(
      endpoint: q['endpoint'] ?? config.surreal.endpoint,
      namespace: q['namespace'] ?? config.surreal.namespace,
      database: q['database'] ?? config.surreal.database,
      username: q['username'] ?? config.surreal.username,
      password: q['password'] ?? config.surreal.password,
    );
  }

  /// GET /surreal/tables — list table names in the Surreal database.
  /// Supports override via query params (see [_surrealFromQuery]).
  Future<Response> _surrealTables(Request request) async {
    final client = _surrealFromQuery(request);
    try {
      final resp = await client.sql('INFO FOR DB;');
      final tables = _extractKeys(resp, 'tables');
      return _json({'tables': tables});
    } catch (e) {
      return _err(502, 'Surreal probe failed: $e');
    }
  }

  /// GET /surreal/tables/<name> — return field names for a table.
  Future<Response> _surrealTableInfo(Request request, String name) async {
    if (name.isEmpty || !_safeIdent(name)) {
      return _err(400, 'Invalid table name');
    }
    final client = _surrealFromQuery(request);
    try {
      final resp = await client.sql('INFO FOR TABLE $name;');
      final fields = _extractKeys(resp, 'fields');
      final indexes = _extractKeys(resp, 'indexes');
      return _json({'name': name, 'fields': fields, 'indexes': indexes});
    } catch (e) {
      return _err(502, 'Surreal table probe failed: $e');
    }
  }

  /// POST /surreal/tables { name, schemaless? } — create a new Surreal table.
  /// Default mode is SCHEMALESS to match the Outbound flow shape.
  Future<Response> _surrealDefineTable(Request request) async {
    Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } catch (e) {
      return _err(400, 'Invalid JSON: $e');
    }
    final name = (body['name'] as String?)?.trim() ?? '';
    final schemaless = body['schemaless'] != false; // default true
    if (name.isEmpty || !_safeIdent(name)) {
      return _err(400, 'Invalid table name');
    }
    final client = _surrealFromQuery(request);
    try {
      final mode = schemaless ? 'SCHEMALESS' : 'SCHEMAFULL';
      await client.sql('DEFINE TABLE IF NOT EXISTS $name $mode;');
      return _json({'ok': true, 'name': name, 'mode': mode.toLowerCase()});
    } catch (e) {
      return _err(502, 'Surreal table create failed: $e');
    }
  }

  Response _getConfig(Request request) => _json(config.toRedactedJson());

  Future<Response> _putSurreal(Request request) async {
    final started = DateTime.now();
    Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } catch (e) {
      return _err(400, 'Invalid JSON: $e');
    }
    if (body['endpoint'] is String) config.surreal.endpoint = body['endpoint'] as String;
    if (body['namespace'] is String) config.surreal.namespace = body['namespace'] as String;
    if (body['database'] is String) config.surreal.database = body['database'] as String;
    if (body['username'] is String) config.surreal.username = body['username'] as String;
    if (body['password'] is String) config.surreal.password = body['password'] as String;
    await config.save();
    await audit.add(AuditEvent(
      id: AuditLog.generateId(),
      timestamp: DateTime.now(),
      action: 'config-update',
      status: 'success',
      durationMs: DateTime.now().difference(started).inMilliseconds,
      details: {'target': 'surreal-connection'},
    ));
    return _json(config.toRedactedJson());
  }

  Future<Response> _putMapping(Request request, String collection) async {
    final started = DateTime.now();
    Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } catch (e) {
      return _err(400, 'Invalid JSON: $e');
    }
    final m = Mapping(
      collection: collection,
      table: (body['table'] as String?) ?? collection,
      direction: (body['direction'] as String?) ?? 'both',
      rename: (body['rename'] as Map?)
              ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
          {},
      pushFilter: (body['pushFilter'] as Map?)
              ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
          {},
      pullIntervalSeconds: (body['pullIntervalSeconds'] as num?)?.toInt(),
      pushIntervalSeconds: (body['pushIntervalSeconds'] as num?)?.toInt(),
    );
    if (!{'inbound', 'outbound', 'both'}.contains(m.direction)) {
      return _err(400, 'Invalid direction: ${m.direction}');
    }
    config.upsertMapping(m);
    await config.save();
    await audit.add(AuditEvent(
      id: AuditLog.generateId(),
      timestamp: DateTime.now(),
      action: 'mapping-upsert',
      collection: collection,
      status: 'success',
      durationMs: DateTime.now().difference(started).inMilliseconds,
      details: {
        'direction': m.direction,
        'table': m.table,
        if (m.pullIntervalSeconds != null)
          'pullIntervalSeconds': m.pullIntervalSeconds,
        if (m.pushIntervalSeconds != null)
          'pushIntervalSeconds': m.pushIntervalSeconds,
      },
    ));
    return _json(m.toJson());
  }

  Future<Response> _deleteMapping(Request request, String collection) async {
    final removed = config.removeMapping(collection);
    if (!removed) return _err(404, 'Mapping for $collection not found');
    await config.save();
    await audit.add(AuditEvent(
      id: AuditLog.generateId(),
      timestamp: DateTime.now(),
      action: 'mapping-delete',
      collection: collection,
      status: 'success',
    ));
    return Response(204);
  }

  Future<Response> _testConnection(Request request) async {
    final started = DateTime.now();
    if (!config.surreal.isConfigured) {
      await audit.add(AuditEvent(
        id: AuditLog.generateId(),
        timestamp: DateTime.now(),
        action: 'test-connection',
        status: 'error',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: 'SurrealDB connection is not configured',
      ));
      return _err(400, 'SurrealDB connection is not configured');
    }
    final client = _surreal();
    try {
      final version = await client.version();
      await audit.add(AuditEvent(
        id: AuditLog.generateId(),
        timestamp: DateTime.now(),
        action: 'test-connection',
        status: 'success',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        details: {'version': version},
      ));
      return _json({'ok': true, 'version': version});
    } catch (e) {
      final msg = e.toString();
      await audit.add(AuditEvent(
        id: AuditLog.generateId(),
        timestamp: DateTime.now(),
        action: 'test-connection',
        status: 'error',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: AuditLog.truncate(msg),
      ));
      return _json({'ok': false, 'error': msg}, status: 502);
    }
  }

  /// Public so the scheduler can fire pulls directly. Throws
  /// [IntegrationException] for pre-conditions (mapping/collection missing,
  /// direction mismatch, surreal not configured for non-dry-run); otherwise
  /// returns the [AuditEvent] (which itself records partial failures).
  ///
  /// The actual SAP REST → Surreal HTTP work happens in `scripts/pull.py`
  /// (a stdlib-only Python script). We spawn it as a subprocess for each
  /// pull, pass the config blob on stdin, and fold the JSON result on
  /// stdout into an [AuditEvent]. The Dart side still owns scheduling,
  /// audit logging, and mapping config.
  Future<AuditEvent> runPull(String collection, {bool dryRun = false}) async {
    final started = DateTime.now();
    final mapping = config.forCollection(collection);
    if (mapping == null) {
      throw IntegrationException(404, 'No mapping for collection $collection');
    }
    if (!mapping.canPull) {
      throw IntegrationException(
          400, 'Mapping for $collection is direction=${mapping.direction}; pull not allowed');
    }
    final ref = store.collection(collection);
    if (ref == null) {
      throw IntegrationException(404, 'Unknown collection: $collection');
    }
    if (!dryRun && !config.surreal.isConfigured) {
      throw IntegrationException(400, 'SurrealDB connection is not configured');
    }

    final scriptPath =
        Platform.environment['PULL_SCRIPT'] ?? 'scripts/pull.py';
    final pyConfig = <String, dynamic>{
      'gateway': gatewayUrl,
      'gatewayUser': authConfig.username ?? '',
      'gatewayPass': authConfig.password ?? '',
      'collection': collection,
      'table': mapping.table,
      'rename': mapping.rename,
      'keyProperties':
          ref.entityType.keyProperties.map((p) => p.name).toList(),
      'surreal': config.surreal.endpoint,
      'surrealNs': config.surreal.namespace,
      'surrealDb': config.surreal.database,
      'surrealUser': config.surreal.username,
      'surrealPass': config.surreal.password,
      'dryRun': dryRun,
    };

    String stdoutStr;
    String stderrStr;
    int exitCode;
    String pythonCmd;
    try {
      final res = await _runPython(scriptPath, jsonEncode(pyConfig));
      stdoutStr = res.stdout;
      stderrStr = res.stderr;
      exitCode = res.exitCode;
      pythonCmd = res.command;
    } catch (e) {
      final event = _pullErrorEvent(
        collection,
        dryRun,
        started,
        'python invocation failed: $e',
      );
      await audit.add(event);
      return event;
    }

    if (exitCode != 0) {
      final event = _pullErrorEvent(
        collection,
        dryRun,
        started,
        'python ($pythonCmd) exit=$exitCode: ${stderrStr.trim()}',
      );
      await audit.add(event);
      return event;
    }

    Map<String, dynamic> result;
    try {
      result = jsonDecode(stdoutStr.trim()) as Map<String, dynamic>;
    } catch (e) {
      final event = _pullErrorEvent(
        collection,
        dryRun,
        started,
        'python output not JSON: ${stdoutStr.trim()}',
      );
      await audit.add(event);
      return event;
    }

    final scanned = (result['scanned'] as num?)?.toInt() ?? 0;
    final created = (result['created'] as num?)?.toInt() ?? 0;
    final updated = (result['updated'] as num?)?.toInt() ?? 0;
    final skipped = (result['skipped'] as num?)?.toInt() ?? 0;
    final failed = (result['failed'] as num?)?.toInt() ?? 0;
    final pyError = result['error'] as String?;

    final event = AuditEvent(
      id: AuditLog.generateId(),
      timestamp: DateTime.now(),
      action: 'pull',
      collection: collection,
      status: failed > 0 ? 'error' : (dryRun ? 'dry-run' : 'success'),
      dryRun: dryRun,
      rowsScanned: scanned,
      rowsCreated: created,
      rowsUpdated: updated,
      rowsSkipped: skipped,
      rowsFailed: failed,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      error: pyError != null ? AuditLog.truncate(pyError) : null,
      details: {'runner': 'python', 'cmd': pythonCmd, 'script': scriptPath},
    );
    await audit.add(event);
    return event;
  }

  AuditEvent _pullErrorEvent(
      String collection, bool dryRun, DateTime started, String error) {
    return AuditEvent(
      id: AuditLog.generateId(),
      timestamp: DateTime.now(),
      action: 'pull',
      collection: collection,
      status: 'error',
      dryRun: dryRun,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      error: AuditLog.truncate(error),
    );
  }

  Future<_PythonRunResult> _runPython(String script, String stdinJson) async {
    final fromEnv = Platform.environment['PYTHON_EXE'];
    final candidates = [
      if (fromEnv != null && fromEnv.isNotEmpty) fromEnv,
      'python3',
      'python',
    ];
    Object? lastErr;
    for (final cmd in candidates) {
      try {
        final proc = await Process.start(cmd, [script]);
        proc.stdin.add(utf8.encode(stdinJson));
        await proc.stdin.close();
        final out = StringBuffer();
        final err = StringBuffer();
        await Future.wait([
          proc.stdout.transform(utf8.decoder).forEach(out.write),
          proc.stderr.transform(utf8.decoder).forEach(err.write),
        ]);
        final exitCode = await proc.exitCode;
        return _PythonRunResult(cmd, exitCode, out.toString(), err.toString());
      } on ProcessException catch (e) {
        lastErr = e;
        continue;
      }
    }
    throw IntegrationException(
      500,
      'Could not find a Python executable on PATH (tried '
      '${candidates.join(", ")}). Set PYTHON_EXE to override. '
      'Last error: $lastErr',
    );
  }

  /// Public so the scheduler can fire pushes directly. See [runPull] for
  /// error semantics. When SurrealDB is unreachable for the initial select,
  /// the returned event has `status=error` and `rowsScanned=0`.
  Future<AuditEvent> runPush(String collection, {bool dryRun = false}) async {
    final started = DateTime.now();
    final mapping = config.forCollection(collection);
    if (mapping == null) {
      throw IntegrationException(404, 'No mapping for collection $collection');
    }
    if (!mapping.canPush) {
      throw IntegrationException(
          400, 'Mapping for $collection is direction=${mapping.direction}; push not allowed');
    }
    final ref = store.collection(collection);
    if (ref == null) {
      throw IntegrationException(404, 'Unknown collection: $collection');
    }
    if (!config.surreal.isConfigured) {
      throw IntegrationException(400, 'SurrealDB connection is not configured');
    }

    final client = _surreal();
    var scanned = 0, created = 0, updated = 0, skipped = 0, failed = 0;
    String? firstError;

    List<Map<String, dynamic>> rows;
    try {
      rows = await client.select(mapping.table);
    } catch (e) {
      final event = AuditEvent(
        id: AuditLog.generateId(),
        timestamp: DateTime.now(),
        action: 'push',
        collection: collection,
        status: 'error',
        dryRun: dryRun,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: AuditLog.truncate(e.toString()),
      );
      await audit.add(event);
      return event;
    }

    final inverse = _invertRename(mapping.rename);
    final keys = ref.entityType.keyProperties;

    for (final row in rows) {
      scanned++;
      try {
        var sap = _applyRenameBack(row, inverse);
        if (keys.length == 1 &&
            (sap[keys.first.name] == null || sap[keys.first.name].toString().isEmpty)) {
          final fullId = row['id']?.toString() ?? '';
          final idPart = _extractIdPart(fullId, mapping.table);
          if (idPart.isNotEmpty) sap[keys.first.name] = idPart;
        }
        sap.remove('id');

        if (!_passesFilter(sap, mapping.pushFilter)) {
          skipped++;
          continue;
        }

        for (final k in keys) {
          if (sap[k.name] == null) {
            throw FormatException('Missing key property ${k.name} on Surreal row');
          }
        }
        final id = rowKeyOf(ref.entityType, sap);
        final idx = _indexOfRow(ref.entityType, ref.entitySet.rows, id);
        if (dryRun) {
          if (idx >= 0) {
            updated++;
          } else {
            created++;
          }
          continue;
        }
        if (idx >= 0) {
          ref.entitySet.rows[idx] = sap;
          updated++;
        } else {
          ref.entitySet.rows.add(sap);
          created++;
        }
      } catch (e) {
        failed++;
        firstError ??= e.toString();
      }
    }
    if (!dryRun) store.scheduleSave();

    final event = AuditEvent(
      id: AuditLog.generateId(),
      timestamp: DateTime.now(),
      action: 'push',
      collection: collection,
      status: failed > 0 ? 'error' : (dryRun ? 'dry-run' : 'success'),
      dryRun: dryRun,
      rowsScanned: scanned,
      rowsCreated: created,
      rowsUpdated: updated,
      rowsSkipped: skipped,
      rowsFailed: failed,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      error: firstError != null ? AuditLog.truncate(firstError) : null,
    );
    await audit.add(event);
    return event;
  }

  Future<Response> _pull(Request request, String collection) async {
    final dryRun = request.requestedUri.queryParameters['dryRun'] == 'true';
    try {
      final event = await runPull(collection, dryRun: dryRun);
      return _json(event.toJson());
    } on IntegrationException catch (e) {
      return _err(e.statusCode, e.message);
    }
  }

  Future<Response> _push(Request request, String collection) async {
    final dryRun = request.requestedUri.queryParameters['dryRun'] == 'true';
    try {
      final event = await runPush(collection, dryRun: dryRun);
      final unreachable = event.rowsScanned == 0 && event.status == 'error';
      return _json(event.toJson(), status: unreachable ? 502 : 200);
    } on IntegrationException catch (e) {
      return _err(e.statusCode, e.message);
    }
  }

  Response _getAudit(Request request) {
    final qp = request.requestedUri.queryParameters;
    final limit = int.tryParse(qp['limit'] ?? '');
    final list = audit.query(
      limit: limit,
      action: qp['action'],
      collection: qp['collection'],
    );
    return _json({'events': list.map((e) => e.toJson()).toList()});
  }

  Future<Response> _clearAudit(Request request) async {
    await audit.clear();
    return Response(204);
  }

  SurrealClient _surreal() => SurrealClient(
        endpoint: config.surreal.endpoint,
        namespace: config.surreal.namespace,
        database: config.surreal.database,
        username: config.surreal.username,
        password: config.surreal.password,
      );
}

/// Extract the set of keys under a named map inside Surreal's INFO envelope.
/// Surreal returns `[{result: {tables: {name: "DEFINE ..."}, fields: {...}}, status: "OK"}]`
/// — this normalises that into a sorted list of identifier names.
List<String> _extractKeys(dynamic resp, String key) {
  Map<String, dynamic>? info;
  if (resp is List) {
    for (final stmt in resp) {
      if (stmt is Map && stmt['status'] == 'OK') {
        final r = stmt['result'];
        if (r is Map) info = Map<String, dynamic>.from(r);
        break;
      }
    }
  } else if (resp is Map && resp['result'] is Map) {
    info = Map<String, dynamic>.from(resp['result'] as Map);
  }
  if (info == null) return const [];
  final inner = info[key];
  if (inner is! Map) return const [];
  final keys = inner.keys.map((k) => k.toString()).toList()..sort();
  return keys;
}

/// Whitelist for table / namespace / database identifiers we inject into
/// SurrealQL. Allow letters, digits, and underscores — block everything else
/// to avoid injection through user-supplied names from the admin UI.
bool _safeIdent(String s) =>
    s.isNotEmpty && RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(s);

/// Whitelist for record IDs (connection IDs, flow IDs). Allows hyphens in
/// addition to the SQL-identifier set so seeded ids like `sap-rest` work.
bool _safeId(String s) =>
    s.isNotEmpty && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s);

/// Maps a flow's dataset name (the `?dataset=` URL value) to the key it
/// appears under in the `/ai/extract` response envelope. They mostly match;
/// `expense_priv` is the known exception (envelope key is `exp_priv`).
String _envelopeKeyFor(String dataset) => switch (dataset) {
      'expense_priv' => 'exp_priv',
      _ => dataset,
    };

/// The field used as the SurrealDB record id for each dataset. Empty string
/// tells pull.py to fall back to the first field in the row.
String _keyFieldFor(String dataset) => switch (dataset) {
      'employees' => 'pernr',
      'user_data' => 'bname',
      'expense_priv' || 'exp_priv' => 'pernr',
      'line_managers' => 'employee',
      _ => '',
    };

class _PythonRunResult {
  final String command;
  final int exitCode;
  final String stdout;
  final String stderr;
  _PythonRunResult(this.command, this.exitCode, this.stdout, this.stderr);
}

Map<String, String> _invertRename(Map<String, String> rename) {
  final out = <String, String>{};
  for (final entry in rename.entries) {
    out[entry.value] = entry.key;
  }
  return out;
}

Map<String, dynamic> _applyRenameBack(
    Map<String, dynamic> row, Map<String, String> inverse) {
  if (inverse.isEmpty) return Map<String, dynamic>.from(row);
  final out = <String, dynamic>{};
  for (final entry in row.entries) {
    final newKey = inverse[entry.key] ?? entry.key;
    out[newKey] = entry.value;
  }
  return out;
}

bool _passesFilter(Map<String, dynamic> row, Map<String, String> filter) {
  if (filter.isEmpty) return true;
  for (final entry in filter.entries) {
    final v = row[entry.key]?.toString() ?? '';
    if (v != entry.value) return false;
  }
  return true;
}

String _extractIdPart(String fullId, String table) {
  if (fullId.isEmpty) return '';
  final prefix = '$table:';
  var s = fullId.startsWith(prefix) ? fullId.substring(prefix.length) : fullId;
  if (s.startsWith('⟨') && s.endsWith('⟩')) {
    s = s.substring(1, s.length - 1);
  } else if (s.startsWith('`') && s.endsWith('`')) {
    s = s.substring(1, s.length - 1);
  }
  return s;
}

int _indexOfRow(EntityType type, List<Map<String, dynamic>> rows, String id) {
  for (var i = 0; i < rows.length; i++) {
    if (rowKeyOf(type, rows[i]) == id) return i;
  }
  return -1;
}

Future<Map<String, dynamic>> _readJson(Request request) async {
  final raw = await request.readAsString();
  if (raw.isEmpty) return <String, dynamic>{};
  return Map<String, dynamic>.from(jsonDecode(raw) as Map);
}

Response _json(Object body, {int status = 200}) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Response _err(int status, String message) =>
    _json({'error': message}, status: status);
