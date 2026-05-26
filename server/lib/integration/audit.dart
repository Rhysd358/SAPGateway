import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
    this.dryRun = false,
    this.rowsScanned = 0,
    this.rowsCreated = 0,
    this.rowsUpdated = 0,
    this.rowsSkipped = 0,
    this.rowsFailed = 0,
    this.durationMs = 0,
    this.error,
    this.details,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'action': action,
        if (collection != null) 'collection': collection,
        'status': status,
        'dryRun': dryRun,
        'rowsScanned': rowsScanned,
        'rowsCreated': rowsCreated,
        'rowsUpdated': rowsUpdated,
        'rowsSkipped': rowsSkipped,
        'rowsFailed': rowsFailed,
        'durationMs': durationMs,
        if (error != null) 'error': error,
        if (details != null) 'details': details,
      };

  factory AuditEvent.fromJson(Map<String, dynamic> j) => AuditEvent(
        id: j['id'] as String,
        timestamp: DateTime.parse(j['timestamp'] as String),
        action: j['action'] as String,
        collection: j['collection'] as String?,
        status: j['status'] as String,
        dryRun: j['dryRun'] as bool? ?? false,
        rowsScanned: j['rowsScanned'] as int? ?? 0,
        rowsCreated: j['rowsCreated'] as int? ?? 0,
        rowsUpdated: j['rowsUpdated'] as int? ?? 0,
        rowsSkipped: j['rowsSkipped'] as int? ?? 0,
        rowsFailed: j['rowsFailed'] as int? ?? 0,
        durationMs: j['durationMs'] as int? ?? 0,
        error: j['error'] as String?,
        details: j['details'] is Map
            ? Map<String, dynamic>.from(j['details'] as Map)
            : null,
      );
}

class AuditLog {
  final File _file;
  final List<AuditEvent> _events;
  static const int cap = 5000;
  static final _rand = Random();

  AuditLog._(this._file, this._events);

  static Future<AuditLog> load(String path) async {
    final file = File(path);
    final events = <AuditEvent>[];
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          events.add(AuditEvent.fromJson(Map<String, dynamic>.from(item as Map)));
        }
      } catch (e) {
        stderr.writeln('Failed to load audit log from $path: $e');
      }
    }
    return AuditLog._(file, events);
  }

  List<AuditEvent> all() => List.unmodifiable(_events);

  List<AuditEvent> query({int? limit, String? action, String? collection}) {
    Iterable<AuditEvent> out = _events.reversed;
    if (action != null && action.isNotEmpty) {
      out = out.where((e) => e.action == action);
    }
    if (collection != null && collection.isNotEmpty) {
      out = out.where((e) => e.collection == collection);
    }
    if (limit != null && limit > 0) {
      out = out.take(limit);
    }
    return out.toList();
  }

  Future<void> add(AuditEvent event) async {
    _events.add(event);
    if (_events.length > cap) {
      _events.removeRange(0, _events.length - cap);
    }
    await _write();
  }

  Future<void> clear() async {
    _events.clear();
    await _write();
  }

  Future<void> _write() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_events.map((e) => e.toJson()).toList()));
    await tmp.rename(_file.path);
  }

  static String generateId() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final r = _rand.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    return '$ts-$r';
  }

  static String truncate(String s, {int max = 500}) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
  }
}
