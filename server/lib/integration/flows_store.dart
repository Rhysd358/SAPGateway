import 'dart:convert';
import 'dart:io';

/// A persisted source/target connection. Backs the Flutter Connections tab.
///
/// REST + OData connections use the auth* fields; SurrealDB connections also
/// use [namespace] and [database] and always speak Basic auth. Stored
/// plaintext on disk (mirroring [SurrealConnection]) and redacted in API
/// responses via [toRedactedJson].
class Connection {
  final String id;
  String name;
  String type; // 'rest' | 'surreal' | 'odata'
  String endpoint;
  String authScheme; // 'none' | 'basic' | 'bearer' | 'oauth2-client-credentials' | 'sso-saml-bearer'
  String authUser;
  String authPass;
  String bearerToken;
  String namespace; // surreal only
  String database; // surreal only

  Connection({
    required this.id,
    required this.name,
    required this.type,
    this.endpoint = '',
    this.authScheme = 'none',
    this.authUser = '',
    this.authPass = '',
    this.bearerToken = '',
    this.namespace = '',
    this.database = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'endpoint': endpoint,
        'authScheme': authScheme,
        'authUser': authUser,
        'authPass': authPass,
        'bearerToken': bearerToken,
        'namespace': namespace,
        'database': database,
      };

  Map<String, dynamic> toRedactedJson() => {
        'id': id,
        'name': name,
        'type': type,
        'endpoint': endpoint,
        'authScheme': authScheme,
        'authUser': authUser,
        'passwordSet': authPass.isNotEmpty,
        'bearerSet': bearerToken.isNotEmpty,
        'namespace': namespace,
        'database': database,
      };

  factory Connection.fromJson(Map<String, dynamic> j) => Connection(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        type: j['type'] as String? ?? 'rest',
        endpoint: j['endpoint'] as String? ?? '',
        authScheme: j['authScheme'] as String? ?? 'none',
        authUser: j['authUser'] as String? ?? '',
        authPass: j['authPass'] as String? ?? '',
        bearerToken: j['bearerToken'] as String? ?? '',
        namespace: j['namespace'] as String? ?? '',
        database: j['database'] as String? ?? '',
      );

  /// Apply a JSON patch from the admin UI. Password / token are write-only:
  /// the UI passes a non-empty value to replace, omits to keep.
  void applyPatch(Map<String, dynamic> j) {
    if (j['name'] is String) name = j['name'] as String;
    if (j['type'] is String) type = j['type'] as String;
    if (j['endpoint'] is String) endpoint = j['endpoint'] as String;
    if (j['authScheme'] is String) authScheme = j['authScheme'] as String;
    if (j['authUser'] is String) authUser = j['authUser'] as String;
    if (j['authPass'] is String &&
        (j['authPass'] as String).isNotEmpty) {
      authPass = j['authPass'] as String;
    }
    if (j['bearerToken'] is String &&
        (j['bearerToken'] as String).isNotEmpty) {
      bearerToken = j['bearerToken'] as String;
    }
    if (j['namespace'] is String) namespace = j['namespace'] as String;
    if (j['database'] is String) database = j['database'] as String;
  }
}

/// A persisted outbound (REST → SurrealDB) flow. Mirrors the Flutter
/// [OutboundFlow] model exactly.
class OutboundFlow {
  final String id;
  String name;
  String sourceConnectionId;
  String extractType; // 'full' | 'delta'
  String dataset;
  String deltaBasis; // 'change_date' | 'key_date'
  String deltaSince; // YYYYMMDDhhmmss
  String targetConnectionId;
  String targetTable;
  int? pullIntervalSeconds;
  List<FieldPair> mappings;

  OutboundFlow({
    required this.id,
    this.name = '',
    this.sourceConnectionId = '',
    this.extractType = 'full',
    this.dataset = '',
    this.deltaBasis = 'change_date',
    this.deltaSince = '',
    this.targetConnectionId = '',
    this.targetTable = '',
    this.pullIntervalSeconds,
    List<FieldPair>? mappings,
  }) : mappings = mappings ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourceConnectionId': sourceConnectionId,
        'extractType': extractType,
        'dataset': dataset,
        'deltaBasis': deltaBasis,
        'deltaSince': deltaSince,
        'targetConnectionId': targetConnectionId,
        'targetTable': targetTable,
        if (pullIntervalSeconds != null)
          'pullIntervalSeconds': pullIntervalSeconds,
        'mappings': mappings.map((m) => m.toJson()).toList(),
      };

  factory OutboundFlow.fromJson(Map<String, dynamic> j) => OutboundFlow(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        sourceConnectionId: j['sourceConnectionId'] as String? ?? '',
        extractType: j['extractType'] as String? ?? 'full',
        dataset: j['dataset'] as String? ?? '',
        deltaBasis: j['deltaBasis'] as String? ?? 'change_date',
        deltaSince: j['deltaSince'] as String? ?? '',
        targetConnectionId: j['targetConnectionId'] as String? ?? '',
        targetTable: j['targetTable'] as String? ?? '',
        pullIntervalSeconds: (j['pullIntervalSeconds'] as num?)?.toInt(),
        mappings: [
          for (final m in (j['mappings'] as List? ?? []))
            FieldPair.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
      );

  void applyPatch(Map<String, dynamic> j) {
    if (j['name'] is String) name = j['name'] as String;
    if (j['sourceConnectionId'] is String) {
      sourceConnectionId = j['sourceConnectionId'] as String;
    }
    if (j['extractType'] is String) extractType = j['extractType'] as String;
    if (j['dataset'] is String) dataset = j['dataset'] as String;
    if (j['deltaBasis'] is String) deltaBasis = j['deltaBasis'] as String;
    if (j['deltaSince'] is String) deltaSince = j['deltaSince'] as String;
    if (j['targetConnectionId'] is String) {
      targetConnectionId = j['targetConnectionId'] as String;
    }
    if (j['targetTable'] is String) targetTable = j['targetTable'] as String;
    if (j.containsKey('pullIntervalSeconds')) {
      final raw = j['pullIntervalSeconds'];
      pullIntervalSeconds = raw == null ? null : (raw as num).toInt();
    }
    if (j['mappings'] is List) {
      mappings = [
        for (final m in (j['mappings'] as List))
          FieldPair.fromJson(Map<String, dynamic>.from(m as Map)),
      ];
    }
  }
}

class FieldPair {
  String source;
  String target;
  FieldPair({required this.source, required this.target});

  Map<String, String> toJson() => {'source': source, 'target': target};

  factory FieldPair.fromJson(Map<String, dynamic> j) => FieldPair(
        source: j['source']?.toString() ?? '',
        target: j['target']?.toString() ?? '',
      );
}

/// A persisted inbound (SurrealDB → SAP OData V2) flow. The runtime selects
/// rows from [sourceTable] matching [triggerFilter], maps fields via
/// [mappings], and POSTs each row to [targetEntity] on [targetConnectionId].
/// On success, the SAP-returned key (e.g. REINR) is written back to the
/// Surreal record under [writeBackField] so downstream consumers can see it.
class InboundFlow {
  final String id;
  String name;
  String sourceConnectionId;
  String sourceTable;
  Map<String, String> triggerFilter;
  String targetConnectionId;
  String targetEntity;
  String writeBackField;
  int? pushIntervalSeconds;
  List<FieldPair> mappings;

  InboundFlow({
    required this.id,
    this.name = '',
    this.sourceConnectionId = '',
    this.sourceTable = '',
    Map<String, String>? triggerFilter,
    this.targetConnectionId = '',
    this.targetEntity = '',
    this.writeBackField = '',
    this.pushIntervalSeconds,
    List<FieldPair>? mappings,
  })  : triggerFilter = triggerFilter ?? {},
        mappings = mappings ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourceConnectionId': sourceConnectionId,
        'sourceTable': sourceTable,
        'triggerFilter': triggerFilter,
        'targetConnectionId': targetConnectionId,
        'targetEntity': targetEntity,
        'writeBackField': writeBackField,
        if (pushIntervalSeconds != null)
          'pushIntervalSeconds': pushIntervalSeconds,
        'mappings': mappings.map((m) => m.toJson()).toList(),
      };

  factory InboundFlow.fromJson(Map<String, dynamic> j) => InboundFlow(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        sourceConnectionId: j['sourceConnectionId'] as String? ?? '',
        sourceTable: j['sourceTable'] as String? ?? '',
        triggerFilter: (j['triggerFilter'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            {},
        targetConnectionId: j['targetConnectionId'] as String? ?? '',
        targetEntity: j['targetEntity'] as String? ?? '',
        writeBackField: j['writeBackField'] as String? ?? '',
        pushIntervalSeconds: (j['pushIntervalSeconds'] as num?)?.toInt(),
        mappings: [
          for (final m in (j['mappings'] as List? ?? []))
            FieldPair.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
      );

  void applyPatch(Map<String, dynamic> j) {
    if (j['name'] is String) name = j['name'] as String;
    if (j['sourceConnectionId'] is String) {
      sourceConnectionId = j['sourceConnectionId'] as String;
    }
    if (j['sourceTable'] is String) sourceTable = j['sourceTable'] as String;
    if (j['triggerFilter'] is Map) {
      triggerFilter = (j['triggerFilter'] as Map)
          .map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    if (j['targetConnectionId'] is String) {
      targetConnectionId = j['targetConnectionId'] as String;
    }
    if (j['targetEntity'] is String) {
      targetEntity = j['targetEntity'] as String;
    }
    if (j['writeBackField'] is String) {
      writeBackField = j['writeBackField'] as String;
    }
    if (j.containsKey('pushIntervalSeconds')) {
      final raw = j['pushIntervalSeconds'];
      pushIntervalSeconds = raw == null ? null : (raw as num).toInt();
    }
    if (j['mappings'] is List) {
      mappings = [
        for (final m in (j['mappings'] as List))
          FieldPair.fromJson(Map<String, dynamic>.from(m as Map)),
      ];
    }
  }
}

/// Persists [Connection]s + [OutboundFlow]s to a single JSON file alongside
/// the legacy `integration.json`. Kept separate so the existing scheduler
/// keeps working unchanged while the new model lands.
class FlowsStore {
  static const int currentSchemaVersion = 1;

  final List<Connection> connections;
  final List<OutboundFlow> outboundFlows;
  final List<InboundFlow> inboundFlows;
  final File _file;

  FlowsStore._(this._file, this.connections, this.outboundFlows,
      this.inboundFlows);

  static Future<FlowsStore> load(String path) async {
    final file = File(path);
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final cs = <Connection>[
          for (final c in (j['connections'] as List? ?? []))
            Connection.fromJson(Map<String, dynamic>.from(c as Map)),
        ];
        final fs = <OutboundFlow>[
          for (final f in (j['outboundFlows'] as List? ?? []))
            OutboundFlow.fromJson(Map<String, dynamic>.from(f as Map)),
        ];
        final ins = <InboundFlow>[
          for (final f in (j['inboundFlows'] as List? ?? []))
            InboundFlow.fromJson(Map<String, dynamic>.from(f as Map)),
        ];
        return FlowsStore._(file, cs, fs, ins);
      } catch (e) {
        stderr.writeln('Failed to load flows store: $e — using defaults');
      }
    }
    // First boot — seed with the dev defaults so the admin has something
    // to look at out of the box.
    final cfg = FlowsStore._(
        file, _defaultConnections(), _defaultFlows(), <InboundFlow>[]);
    await cfg.save();
    return cfg;
  }

  Future<void> save() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': currentSchemaVersion,
      'connections': connections.map((c) => c.toJson()).toList(),
      'outboundFlows': outboundFlows.map((f) => f.toJson()).toList(),
      'inboundFlows': inboundFlows.map((f) => f.toJson()).toList(),
    }));
    await tmp.rename(_file.path);
  }

  InboundFlow? findInboundFlow(String id) {
    for (final f in inboundFlows) {
      if (f.id == id) return f;
    }
    return null;
  }

  void upsertInboundFlow(InboundFlow f) {
    final idx = inboundFlows.indexWhere((x) => x.id == f.id);
    if (idx >= 0) {
      inboundFlows[idx] = f;
    } else {
      inboundFlows.add(f);
    }
  }

  bool removeInboundFlow(String id) {
    final idx = inboundFlows.indexWhere((x) => x.id == id);
    if (idx < 0) return false;
    inboundFlows.removeAt(idx);
    return true;
  }

  Connection? findConnection(String id) {
    for (final c in connections) {
      if (c.id == id) return c;
    }
    return null;
  }

  void upsertConnection(Connection c) {
    final idx = connections.indexWhere((x) => x.id == c.id);
    if (idx >= 0) {
      connections[idx] = c;
    } else {
      connections.add(c);
    }
  }

  bool removeConnection(String id) {
    final idx = connections.indexWhere((x) => x.id == id);
    if (idx < 0) return false;
    connections.removeAt(idx);
    return true;
  }

  OutboundFlow? findFlow(String id) {
    for (final f in outboundFlows) {
      if (f.id == id) return f;
    }
    return null;
  }

  void upsertFlow(OutboundFlow f) {
    final idx = outboundFlows.indexWhere((x) => x.id == f.id);
    if (idx >= 0) {
      outboundFlows[idx] = f;
    } else {
      outboundFlows.add(f);
    }
  }

  bool removeFlow(String id) {
    final idx = outboundFlows.indexWhere((x) => x.id == id);
    if (idx < 0) return false;
    outboundFlows.removeAt(idx);
    return true;
  }
}

List<Connection> _defaultConnections() => [
      Connection(
        id: 'sap-rest',
        name: 'SAP REST (mock)',
        type: 'rest',
        // The /ai/extract mock (mock-api/, Dockerised on 9000). Swap for the
        // real cssapfb3 base URL once creds land.
        endpoint: 'http://localhost:9000',
        authScheme: 'basic',
        authUser: 'admin',
        authPass: 's3cret',
      ),
      Connection(
        id: 'surreal-nucleus',
        name: 'SurrealDB · Nucleus',
        type: 'surreal',
        // 127.0.0.1 (not localhost) — SurrealDB binds IPv4 only, and the
        // Python puller stalls ~2s/row resolving localhost to ::1 first.
        endpoint: 'http://127.0.0.1:8000',
        namespace: 'nucleus',
        database: 'test',
        authScheme: 'basic',
        authUser: 'root',
        authPass: 'root',
      ),
    ];

List<OutboundFlow> _defaultFlows() => [
      OutboundFlow(
        id: 'flow-employees',
        name: 'employees',
        sourceConnectionId: 'sap-rest',
        extractType: 'delta',
        dataset: 'employees',
        deltaBasis: 'key_date',
        deltaSince: '20260101000000',
        targetConnectionId: 'surreal-nucleus',
        targetTable: 'employee',
        // Manual by default; set an interval in the editor to schedule.
        mappings: [
          // SAP /ai/extract employee fields → Nucleus SCHEMAFULL employee
          // columns. butxt + pbtxt are intentionally dropped (no target).
          FieldPair(source: 'pernr', target: 'pernr'),
          FieldPair(source: 'ename', target: 'name'),
          FieldPair(source: 'bukrs', target: 'company_code'),
          FieldPair(source: 'werks', target: 'personnel_area_code'),
          FieldPair(source: 'plans', target: 'position_id'),
          FieldPair(source: 'plstx', target: 'position_text'),
        ],
      ),
      OutboundFlow(
        id: 'flow-line-managers',
        name: 'line_managers',
        sourceConnectionId: 'sap-rest',
        extractType: 'full',
        dataset: 'line_managers',
        targetConnectionId: 'surreal-nucleus',
        targetTable: 'line_manager',
      ),
      OutboundFlow(
        id: 'flow-expense-priv',
        name: 'expense_priv',
        sourceConnectionId: 'sap-rest',
        extractType: 'delta',
        dataset: 'expense_priv',
        deltaBasis: 'key_date',
        deltaSince: '20260101000000',
        targetConnectionId: 'surreal-nucleus',
        targetTable: 'expense_claim',
        pullIntervalSeconds: 60,
      ),
    ];
