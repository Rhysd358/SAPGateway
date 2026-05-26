import 'dart:convert';
import 'dart:io';

class SurrealConnection {
  String endpoint;
  String namespace;
  String database;
  String username;
  String password;

  SurrealConnection({
    this.endpoint = '',
    this.namespace = '',
    this.database = '',
    this.username = '',
    this.password = '',
  });

  Map<String, dynamic> toJson() => {
        'endpoint': endpoint,
        'namespace': namespace,
        'database': database,
        'username': username,
        'password': password,
      };

  Map<String, dynamic> toRedactedJson() => {
        'endpoint': endpoint,
        'namespace': namespace,
        'database': database,
        'username': username,
        'passwordSet': password.isNotEmpty,
      };

  factory SurrealConnection.fromJson(Map<String, dynamic> j) =>
      SurrealConnection(
        endpoint: j['endpoint'] as String? ?? '',
        namespace: j['namespace'] as String? ?? '',
        database: j['database'] as String? ?? '',
        username: j['username'] as String? ?? '',
        password: j['password'] as String? ?? '',
      );

  bool get isConfigured =>
      endpoint.isNotEmpty && namespace.isNotEmpty && database.isNotEmpty;
}

class Mapping {
  String collection;
  String table;
  String direction;
  Map<String, String> rename;
  Map<String, String> pushFilter;

  /// When set and > 0, the scheduler fires a pull this often. Null = manual only.
  int? pullIntervalSeconds;

  /// When set and > 0, the scheduler fires a push this often. Null = manual only.
  int? pushIntervalSeconds;

  Mapping({
    required this.collection,
    required this.table,
    this.direction = 'both',
    Map<String, String>? rename,
    Map<String, String>? pushFilter,
    this.pullIntervalSeconds,
    this.pushIntervalSeconds,
  })  : rename = rename ?? {},
        pushFilter = pushFilter ?? {};

  // Convention: direction is described from SAP's point of view.
  //   outbound = SAP -> Surreal (integration layer PULLs from SAP)
  //   inbound  = Surreal -> SAP (integration layer PUSHes to SAP)
  //   both     = the mapping supports both directions
  bool get canPull => direction == 'outbound' || direction == 'both';
  bool get canPush => direction == 'inbound' || direction == 'both';

  bool get pullScheduled =>
      canPull && pullIntervalSeconds != null && pullIntervalSeconds! > 0;
  bool get pushScheduled =>
      canPush && pushIntervalSeconds != null && pushIntervalSeconds! > 0;

  Map<String, dynamic> toJson() => {
        'collection': collection,
        'table': table,
        'direction': direction,
        'rename': rename,
        'pushFilter': pushFilter,
        if (pullIntervalSeconds != null)
          'pullIntervalSeconds': pullIntervalSeconds,
        if (pushIntervalSeconds != null)
          'pushIntervalSeconds': pushIntervalSeconds,
      };

  factory Mapping.fromJson(Map<String, dynamic> j) => Mapping(
        collection: j['collection'] as String,
        table: j['table'] as String,
        direction: j['direction'] as String? ?? 'both',
        rename: (j['rename'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            {},
        pushFilter: (j['pushFilter'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            {},
        pullIntervalSeconds: (j['pullIntervalSeconds'] as num?)?.toInt(),
        pushIntervalSeconds: (j['pushIntervalSeconds'] as num?)?.toInt(),
      );
}

class IntegrationConfig {
  /// Schema version of `data/integration.json`. Bumped on any change to the
  /// on-disk shape; `load()` runs migrations from older versions on read.
  static const int currentSchemaVersion = 2;

  SurrealConnection surreal;
  final List<Mapping> mappings;
  final File _file;

  IntegrationConfig._(this._file, this.surreal, this.mappings);

  static Future<IntegrationConfig> load(String path) async {
    final file = File(path);
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final version = (j['schemaVersion'] as num?)?.toInt() ?? 1;
        final conn = SurrealConnection.fromJson(
            Map<String, dynamic>.from(j['surreal'] as Map? ?? {}));
        final maps = <Mapping>[
          for (final m in (j['mappings'] as List? ?? []))
            Mapping.fromJson(Map<String, dynamic>.from(m as Map))
        ];
        if (version < 2) {
          // v1 -> v2: flip direction strings to the SAP-centric convention
          // (outbound = SAP -> elsewhere). Previously direction was named
          // from the integration layer's point of view (inbound = into us).
          for (final m in maps) {
            if (m.direction == 'inbound') {
              m.direction = 'outbound';
            } else if (m.direction == 'outbound') {
              m.direction = 'inbound';
            }
          }
          stderr.writeln(
              'Migrated $path from schema v$version to v$currentSchemaVersion (direction flip)');
        }
        final cfg = IntegrationConfig._(file, conn, maps);
        if (version < currentSchemaVersion) await cfg.save();
        return cfg;
      } catch (e) {
        stderr.writeln('Failed to load integration config: $e — using defaults');
      }
    }
    final cfg = IntegrationConfig._(file, SurrealConnection(), _defaults());
    await cfg.save();
    return cfg;
  }

  Mapping? forCollection(String collection) {
    for (final m in mappings) {
      if (m.collection == collection) return m;
    }
    return null;
  }

  void upsertMapping(Mapping m) {
    final idx = mappings.indexWhere((x) => x.collection == m.collection);
    if (idx >= 0) {
      mappings[idx] = m;
    } else {
      mappings.add(m);
    }
  }

  bool removeMapping(String collection) {
    final idx = mappings.indexWhere((x) => x.collection == collection);
    if (idx < 0) return false;
    mappings.removeAt(idx);
    return true;
  }

  Future<void> save() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': currentSchemaVersion,
      'surreal': surreal.toJson(),
      'mappings': mappings.map((m) => m.toJson()).toList(),
    }));
    await tmp.rename(_file.path);
  }

  Map<String, dynamic> toRedactedJson() => {
        'surreal': surreal.toRedactedJson(),
        'mappings': mappings.map((m) => m.toJson()).toList(),
      };
}

List<Mapping> _defaults() => [
      // Expenses are bidirectional today: pulled from SAP (outbound) for read-back
      // and pushed to SAP (inbound) for write-back. The inbound side will move to
      // OData + SSO + trips in a future revision.
      Mapping(
        collection: 'expenses',
        table: 'expense',
        direction: 'both',
        pushFilter: {'Status': 'SUBMITTED'},
      ),
      // HR data flows out of SAP only.
      Mapping(collection: 'employees', table: 'employee', direction: 'outbound'),
      Mapping(collection: 'addresses', table: 'address', direction: 'outbound'),
      Mapping(collection: 'orgunits', table: 'orgunit', direction: 'outbound'),
      Mapping(collection: 'positions', table: 'position', direction: 'outbound'),
      Mapping(collection: 'jobs', table: 'job', direction: 'outbound'),
      Mapping(collection: 'absences', table: 'absence', direction: 'outbound'),
      Mapping(collection: 'timesheets', table: 'timesheet', direction: 'outbound'),
      Mapping(
          collection: 'payrollresults',
          table: 'payrollresult',
          direction: 'outbound'),
      Mapping(collection: 'wagetypes', table: 'wagetype', direction: 'outbound'),
    ];
