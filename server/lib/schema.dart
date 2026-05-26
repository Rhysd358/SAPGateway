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

  factory Property.fromJson(Map<String, dynamic> j) => Property(
        name: j['name'] as String,
        type: j['type'] as String,
        maxLength: j['maxLength'] as int?,
        precision: j['precision'] as int?,
        scale: j['scale'] as int?,
        nullable: j['nullable'] as bool? ?? true,
        key: j['key'] as bool? ?? false,
        label: j['label'] as String?,
      );
}

class EntityType {
  String name;
  final List<Property> properties;

  EntityType({required this.name, required this.properties});

  List<Property> get keyProperties =>
      properties.where((p) => p.key).toList(growable: false);

  Property? property(String name) {
    for (final p in properties) {
      if (p.name == name) return p;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'properties': properties.map((p) => p.toJson()).toList(),
      };

  factory EntityType.fromJson(Map<String, dynamic> j) => EntityType(
        name: j['name'] as String,
        properties: (j['properties'] as List)
            .map((p) => Property.fromJson(p as Map<String, dynamic>))
            .toList(),
      );
}

class EntitySet {
  String name;
  String entityType;
  final List<Map<String, dynamic>> rows;

  EntitySet({required this.name, required this.entityType, required this.rows});

  Map<String, dynamic> toJson() => {
        'name': name,
        'entityType': entityType,
        'rows': rows,
      };

  factory EntitySet.fromJson(Map<String, dynamic> j) => EntitySet(
        name: j['name'] as String,
        entityType: j['entityType'] as String,
        rows: (j['rows'] as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList(),
      );
}

class Service {
  String name;
  final List<EntityType> entityTypes;
  final List<EntitySet> entitySets;

  Service({
    required this.name,
    required this.entityTypes,
    required this.entitySets,
  });

  EntityType? entityType(String name) {
    for (final t in entityTypes) {
      if (t.name == name) return t;
    }
    return null;
  }

  EntitySet? entitySet(String name) {
    for (final s in entitySets) {
      if (s.name == name) return s;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'entityTypes': entityTypes.map((t) => t.toJson()).toList(),
        'entitySets': entitySets.map((s) => s.toJson()).toList(),
      };

  factory Service.fromJson(Map<String, dynamic> j) => Service(
        name: j['name'] as String,
        entityTypes: (j['entityTypes'] as List)
            .map((t) => EntityType.fromJson(t as Map<String, dynamic>))
            .toList(),
        entitySets: (j['entitySets'] as List)
            .map((s) => EntitySet.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class GatewayState {
  final List<Service> services;

  GatewayState({required this.services});

  Map<String, dynamic> toJson() => {
        'services': services.map((s) => s.toJson()).toList(),
      };

  factory GatewayState.fromJson(Map<String, dynamic> j) => GatewayState(
        services: (j['services'] as List)
            .map((s) => Service.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

String collectionNameFor(String entitySetName) {
  var n = entitySetName.toLowerCase();
  if (n.endsWith('set')) n = n.substring(0, n.length - 3);
  if (n.endsWith('s') ||
      n.endsWith('x') ||
      n.endsWith('z') ||
      n.endsWith('ch') ||
      n.endsWith('sh')) {
    return '${n}es';
  }
  return '${n}s';
}

String rowKeyOf(EntityType type, Map<String, dynamic> row) {
  final keys = type.keyProperties;
  if (keys.isEmpty) {
    throw StateError('Entity type ${type.name} has no key properties');
  }
  return keys.map((p) => row[p.name]?.toString() ?? '').join(',');
}
