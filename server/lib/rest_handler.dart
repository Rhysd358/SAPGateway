import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'schema.dart';
import 'store.dart';

class RestHandler {
  final GatewayStore store;
  RestHandler(this.store);

  Handler get handler {
    final router = Router();
    router.get('/', _discovery);
    router.get('/<collection>', _list);
    router.post('/<collection>', _create);
    router.get('/<collection>/<id>', _read);
    router.put('/<collection>/<id>', _upsert);
    router.patch('/<collection>/<id>', _patch);
    router.delete('/<collection>/<id>', _delete);
    return router.call;
  }

  Response _discovery(Request request) {
    final services = <Map<String, dynamic>>[];
    for (final svc in store.services) {
      final collections = <Map<String, dynamic>>[];
      for (final set in svc.entitySets) {
        final type = svc.entityType(set.entityType);
        if (type == null) continue;
        collections.add({
          'collection': collectionNameFor(set.name),
          'entitySet': set.name,
          'entityType': set.entityType,
          'count': set.rows.length,
          'keyProperties': type.keyProperties.map((p) => p.name).toList(),
        });
      }
      services.add({
        'name': svc.name,
        'entityTypes': svc.entityTypes.map((t) => t.name).toList(),
        'collections': collections,
      });
    }
    return _json({'services': services});
  }

  Response _list(Request request, String collection) {
    final ref = store.collection(collection);
    if (ref == null) return _err(404, 'Unknown collection: $collection');

    final qp = request.requestedUri.queryParameters;
    final qpAll = request.requestedUri.queryParametersAll;

    final limit = int.tryParse(qp['limit'] ?? '') ?? 100;
    final offset = int.tryParse(qp['offset'] ?? '') ?? 0;
    final search = qp['search'];
    final sort = qp['sort'];

    var rows = List<Map<String, dynamic>>.from(ref.entitySet.rows);

    const reserved = {'limit', 'offset', 'sort', 'search'};
    final filters = <String, List<String>>{};
    for (final entry in qpAll.entries) {
      if (reserved.contains(entry.key)) continue;
      filters[entry.key] = entry.value;
    }
    if (filters.isNotEmpty) {
      rows = rows.where((row) {
        for (final f in filters.entries) {
          final v = row[f.key]?.toString() ?? '';
          if (!f.value.contains(v)) return false;
        }
        return true;
      }).toList();
    }

    if (search != null && search.isNotEmpty) {
      final needle = search.toLowerCase();
      rows = rows.where((row) {
        for (final p in ref.entityType.properties) {
          if (p.type != 'string') continue;
          final v = row[p.name];
          if (v != null && v.toString().toLowerCase().contains(needle)) {
            return true;
          }
        }
        return false;
      }).toList();
    }

    if (sort != null && sort.isNotEmpty) {
      final parts = sort.split(',');
      rows.sort((a, b) {
        for (final raw in parts) {
          var key = raw.trim();
          var desc = false;
          if (key.startsWith('-')) {
            desc = true;
            key = key.substring(1);
          }
          final cmp = _compare(a[key], b[key]);
          if (cmp != 0) return desc ? -cmp : cmp;
        }
        return 0;
      });
    }

    final total = rows.length;
    final paged = rows.skip(offset).take(limit).toList();
    return _json({
      'data': paged,
      'total': total,
      'limit': limit,
      'offset': offset,
    });
  }

  Response _read(Request request, String collection, String id) {
    final ref = store.collection(collection);
    if (ref == null) return _err(404, 'Unknown collection: $collection');
    final idx = _indexOf(ref.entityType, ref.entitySet.rows, id);
    if (idx < 0) return _err(404, 'Row $id not found in $collection');
    return _json(ref.entitySet.rows[idx]);
  }

  Future<Response> _create(Request request, String collection) async {
    final ref = store.collection(collection);
    if (ref == null) return _err(404, 'Unknown collection: $collection');
    Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } catch (e) {
      return _err(400, 'Invalid JSON: $e');
    }
    for (final k in ref.entityType.keyProperties) {
      if (body[k.name] == null) {
        return _err(400, 'Missing key property ${k.name}');
      }
    }
    final id = rowKeyOf(ref.entityType, body);
    if (_indexOf(ref.entityType, ref.entitySet.rows, id) >= 0) {
      return _err(409, 'Row with key $id already exists in $collection');
    }
    ref.entitySet.rows.add(body);
    store.scheduleSave();
    return _json(body, status: 201);
  }

  Future<Response> _upsert(Request request, String collection, String id) async {
    final ref = store.collection(collection);
    if (ref == null) return _err(404, 'Unknown collection: $collection');
    Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } catch (e) {
      return _err(400, 'Invalid JSON: $e');
    }
    final urlKey = _splitId(ref.entityType, id);
    if (urlKey == null) return _err(400, 'Bad composite key: $id');
    for (final entry in urlKey.entries) {
      body.putIfAbsent(entry.key, () => entry.value);
    }
    final bodyKey = rowKeyOf(ref.entityType, body);
    if (bodyKey != id) {
      return _err(400, 'Body key $bodyKey does not match URL key $id');
    }
    final idx = _indexOf(ref.entityType, ref.entitySet.rows, id);
    if (idx >= 0) {
      ref.entitySet.rows[idx] = body;
    } else {
      ref.entitySet.rows.add(body);
    }
    store.scheduleSave();
    return _json(body, status: idx >= 0 ? 200 : 201);
  }

  Future<Response> _patch(Request request, String collection, String id) async {
    final ref = store.collection(collection);
    if (ref == null) return _err(404, 'Unknown collection: $collection');
    final idx = _indexOf(ref.entityType, ref.entitySet.rows, id);
    if (idx < 0) return _err(404, 'Row $id not found in $collection');
    Map<String, dynamic> body;
    try {
      body = await _readJson(request);
    } catch (e) {
      return _err(400, 'Invalid JSON: $e');
    }
    final current = Map<String, dynamic>.from(ref.entitySet.rows[idx]);
    current.addAll(body);
    final newKey = rowKeyOf(ref.entityType, current);
    if (newKey != id) {
      final collision = _indexOf(ref.entityType, ref.entitySet.rows, newKey);
      if (collision >= 0 && collision != idx) {
        return _err(409, 'Patch would collide with existing row $newKey');
      }
    }
    ref.entitySet.rows[idx] = current;
    store.scheduleSave();
    return _json(current);
  }

  Response _delete(Request request, String collection, String id) {
    final ref = store.collection(collection);
    if (ref == null) return _err(404, 'Unknown collection: $collection');
    final idx = _indexOf(ref.entityType, ref.entitySet.rows, id);
    if (idx < 0) return _err(404, 'Row $id not found in $collection');
    ref.entitySet.rows.removeAt(idx);
    store.scheduleSave();
    return Response(204);
  }
}

int _indexOf(EntityType type, List<Map<String, dynamic>> rows, String id) {
  for (var i = 0; i < rows.length; i++) {
    if (rowKeyOf(type, rows[i]) == id) return i;
  }
  return -1;
}

Map<String, dynamic>? _splitId(EntityType type, String id) {
  final parts = id.split(',');
  final keys = type.keyProperties;
  if (parts.length != keys.length) return null;
  final out = <String, dynamic>{};
  for (var i = 0; i < keys.length; i++) {
    out[keys[i].name] = _coerce(keys[i].type, parts[i]);
  }
  return out;
}

dynamic _coerce(String type, String s) {
  switch (type) {
    case 'int':
      return int.tryParse(s) ?? s;
    case 'boolean':
      return s.toLowerCase() == 'true';
    default:
      return s;
  }
}

int _compare(dynamic a, dynamic b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  if (a is num && b is num) return a.compareTo(b);
  final na = a is num ? a : num.tryParse(a.toString());
  final nb = b is num ? b : num.tryParse(b.toString());
  if (na != null && nb != null) return na.compareTo(nb);
  return a.toString().compareTo(b.toString());
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
