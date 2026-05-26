class Property {
  String name;
  String type;
  int? maxLength;
  int? precision;
  int? scale;
  bool nullable;
  bool key;
  String? label;

  Property({
    required this.name,
    required this.type,
    this.maxLength,
    this.precision,
    this.scale,
    this.nullable = true,
    this.key = false,
    this.label,
  });

  factory Property.fromJson(Map<String, dynamic> j) => Property(
        name: j['name'] as String,
        type: j['type'] as String,
        maxLength: (j['maxLength'] as num?)?.toInt(),
        precision: (j['precision'] as num?)?.toInt(),
        scale: (j['scale'] as num?)?.toInt(),
        nullable: j['nullable'] as bool? ?? true,
        key: j['key'] as bool? ?? false,
        label: j['label'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        if (maxLength != null) 'maxLength': maxLength,
        if (precision != null) 'precision': precision,
        if (scale != null) 'scale': scale,
        'nullable': nullable,
        'key': key,
        if (label != null) 'label': label,
      };
}

class EntityType {
  String name;
  List<Property> properties;
  EntityType({required this.name, required this.properties});

  List<Property> get keyProperties =>
      properties.where((p) => p.key).toList(growable: false);

  factory EntityType.fromJson(Map<String, dynamic> j) => EntityType(
        name: j['name'] as String,
        properties: (j['properties'] as List)
            .map((p) => Property.fromJson(Map<String, dynamic>.from(p as Map)))
            .toList(),
      );
}

class EntitySetSummary {
  final String name;
  final String entityType;
  final String collection;
  final int rowCount;
  EntitySetSummary({
    required this.name,
    required this.entityType,
    required this.collection,
    required this.rowCount,
  });
  factory EntitySetSummary.fromJson(Map<String, dynamic> j) => EntitySetSummary(
        name: j['name'] as String,
        entityType: j['entityType'] as String,
        collection: j['collection'] as String,
        rowCount: (j['rowCount'] as num).toInt(),
      );
}

class ServiceSummary {
  final String name;
  final List<EntityType> entityTypes;
  final List<EntitySetSummary> entitySets;
  ServiceSummary({
    required this.name,
    required this.entityTypes,
    required this.entitySets,
  });

  factory ServiceSummary.fromJson(Map<String, dynamic> j) => ServiceSummary(
        name: j['name'] as String,
        entityTypes: (j['entityTypes'] as List)
            .map((t) => EntityType.fromJson(Map<String, dynamic>.from(t as Map)))
            .toList(),
        entitySets: (j['entitySets'] as List)
            .map((s) =>
                EntitySetSummary.fromJson(Map<String, dynamic>.from(s as Map)))
            .toList(),
      );
}

class ListPage {
  final List<Map<String, dynamic>> data;
  final int total;
  final int limit;
  final int offset;
  ListPage({
    required this.data,
    required this.total,
    required this.limit,
    required this.offset,
  });
  factory ListPage.fromJson(Map<String, dynamic> j) => ListPage(
        data: (j['data'] as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList(),
        total: (j['total'] as num).toInt(),
        limit: (j['limit'] as num?)?.toInt() ?? 0,
        offset: (j['offset'] as num?)?.toInt() ?? 0,
      );
}

class SurrealConnectionInfo {
  String endpoint;
  String namespace;
  String database;
  String username;
  bool passwordSet;

  SurrealConnectionInfo({
    this.endpoint = '',
    this.namespace = '',
    this.database = '',
    this.username = '',
    this.passwordSet = false,
  });

  factory SurrealConnectionInfo.fromJson(Map<String, dynamic> j) =>
      SurrealConnectionInfo(
        endpoint: j['endpoint'] as String? ?? '',
        namespace: j['namespace'] as String? ?? '',
        database: j['database'] as String? ?? '',
        username: j['username'] as String? ?? '',
        passwordSet: j['passwordSet'] as bool? ?? false,
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
  int? pullIntervalSeconds;
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

  // SAP-centric direction strings:
  //   outbound = SAP -> Surreal (Pull op in the integration layer)
  //   inbound  = Surreal -> SAP (Push op in the integration layer)
  bool get canPull => direction == 'outbound' || direction == 'both';
  bool get canPush => direction == 'inbound' || direction == 'both';

  bool get pullScheduled =>
      canPull && pullIntervalSeconds != null && pullIntervalSeconds! > 0;
  bool get pushScheduled =>
      canPush && pushIntervalSeconds != null && pushIntervalSeconds! > 0;

  String get directionLabel {
    switch (direction) {
      case 'outbound':
        return 'Outbound (SAP → Surreal)';
      case 'inbound':
        return 'Inbound (Surreal → SAP)';
      default:
        return 'Bidirectional';
    }
  }

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
}

class IntegrationConfigView {
  SurrealConnectionInfo surreal;
  List<Mapping> mappings;
  IntegrationConfigView({required this.surreal, required this.mappings});
  factory IntegrationConfigView.fromJson(Map<String, dynamic> j) =>
      IntegrationConfigView(
        surreal: SurrealConnectionInfo.fromJson(
            Map<String, dynamic>.from(j['surreal'] as Map)),
        mappings: (j['mappings'] as List)
            .map((m) => Mapping.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
      );
}

class AuditEvent {
  final String id;
  final DateTime timestamp;
  final String action;
  final String? collection;
  final String status;
  final bool dryRun;
  final int rowsScanned;
  final int rowsCreated;
  final int rowsUpdated;
  final int rowsSkipped;
  final int rowsFailed;
  final int durationMs;
  final String? error;
  final Map<String, dynamic>? details;

  AuditEvent({
    required this.id,
    required this.timestamp,
    required this.action,
    this.collection,
    required this.status,
    required this.dryRun,
    required this.rowsScanned,
    required this.rowsCreated,
    required this.rowsUpdated,
    required this.rowsSkipped,
    required this.rowsFailed,
    required this.durationMs,
    this.error,
    this.details,
  });

  factory AuditEvent.fromJson(Map<String, dynamic> j) => AuditEvent(
        id: j['id'] as String,
        timestamp: DateTime.parse(j['timestamp'] as String),
        action: j['action'] as String,
        collection: j['collection'] as String?,
        status: j['status'] as String,
        dryRun: j['dryRun'] as bool? ?? false,
        rowsScanned: (j['rowsScanned'] as num?)?.toInt() ?? 0,
        rowsCreated: (j['rowsCreated'] as num?)?.toInt() ?? 0,
        rowsUpdated: (j['rowsUpdated'] as num?)?.toInt() ?? 0,
        rowsSkipped: (j['rowsSkipped'] as num?)?.toInt() ?? 0,
        rowsFailed: (j['rowsFailed'] as num?)?.toInt() ?? 0,
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        error: j['error'] as String?,
        details: j['details'] is Map
            ? Map<String, dynamic>.from(j['details'] as Map)
            : null,
      );
}
