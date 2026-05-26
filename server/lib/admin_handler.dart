import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'schema.dart';
import 'store.dart';

class AdminHandler {
  final GatewayStore store;
  AdminHandler(this.store);

  Handler get handler {
    final router = Router();

    router.post('/reset', _reset);

    router.get('/services', _listServices);
    router.post('/services', _createService);
    router.get('/services/<service>', _getService);
    router.patch('/services/<service>', _patchService);
    router.delete('/services/<service>', _deleteService);

    router.post('/services/<service>/types', _createType);
    router.patch('/services/<service>/types/<type>', _patchType);
    router.delete('/services/<service>/types/<type>', _deleteType);

    router.post('/services/<service>/types/<type>/properties', _createProperty);
    router.patch('/services/<service>/types/<type>/properties/<prop>',
        _patchProperty);
    router.delete('/services/<service>/types/<type>/properties/<prop>',
        _deleteProperty);

    router.post('/services/<service>/sets', _createSet);
    router.patch('/services/<service>/sets/<set>', _patchSet);
    router.delete('/services/<service>/sets/<set>', _deleteSet);

    router.get('/services/<service>/sets/<set>/rows', _listRows);
    router.post('/services/<service>/sets/<set>/rows', _createRow);
    router.put('/services/<service>/sets/<set>/rows/<id>', _putRow);
    router.patch('/services/<service>/sets/<set>/rows/<id>', _patchRow);
    router.delete('/services/<service>/sets/<set>/rows/<id>', _deleteRow);

    return router.call;
  }

  Future<Response> _reset(Request request) async {
    await store.reset();
    return _json({'ok': true});
  }

  Response _listServices(Request request) {
    return _json({
      'services':
          store.services.map((s) => _summariseService(s)).toList(),
    });
  }

  Response _getService(Request request, String service) {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    return _json(svc.toJson());
  }

  Future<Response> _createService(Request request) async {
    final body = await _readJson(request);
    final name = (body['name'] as String?)?.trim();
    if (name == null || name.isEmpty) return _err(400, 'Missing name');
    if (store.service(name) != null) {
      return _err(409, 'Service $name already exists');
    }
    final svc = Service(name: name, entityTypes: [], entitySets: []);
    store.services.add(svc);
    store.scheduleSave();
    return _json(svc.toJson(), status: 201);
  }

  Future<Response> _patchService(Request request, String service) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final body = await _readJson(request);
    final newName = (body['name'] as String?)?.trim();
    if (newName != null && newName.isNotEmpty && newName != svc.name) {
      if (store.service(newName) != null) {
        return _err(409, 'Service $newName already exists');
      }
      svc.name = newName;
    }
    store.scheduleSave();
    return _json(svc.toJson());
  }

  Response _deleteService(Request request, String service) {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    store.services.remove(svc);
    store.scheduleSave();
    return Response(204);
  }

  Future<Response> _createType(Request request, String service) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final body = await _readJson(request);
    final name = (body['name'] as String?)?.trim();
    if (name == null || name.isEmpty) return _err(400, 'Missing name');
    if (svc.entityType(name) != null) {
      return _err(409, 'Entity type $name already exists in ${svc.name}');
    }
    final props = <Property>[];
    final rawProps = body['properties'];
    if (rawProps is List) {
      for (final p in rawProps) {
        props.add(Property.fromJson(Map<String, dynamic>.from(p as Map)));
      }
    }
    final type = EntityType(name: name, properties: props);
    svc.entityTypes.add(type);
    store.scheduleSave();
    return _json(type.toJson(), status: 201);
  }

  Future<Response> _patchType(Request request, String service, String type) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final et = svc.entityType(type);
    if (et == null) return _err(404, 'Unknown entity type: $type');
    final body = await _readJson(request);
    final newName = (body['name'] as String?)?.trim();
    if (newName != null && newName.isNotEmpty && newName != et.name) {
      if (svc.entityType(newName) != null) {
        return _err(409, 'Entity type $newName already exists');
      }
      final oldName = et.name;
      et.name = newName;
      for (final set in svc.entitySets) {
        if (set.entityType == oldName) set.entityType = newName;
      }
    }
    store.scheduleSave();
    return _json(et.toJson());
  }

  Response _deleteType(Request request, String service, String type) {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final et = svc.entityType(type);
    if (et == null) return _err(404, 'Unknown entity type: $type');
    final used = svc.entitySets.where((s) => s.entityType == type).toList();
    if (used.isNotEmpty) {
      return _err(409,
          'Entity type $type is used by sets: ${used.map((s) => s.name).join(', ')}');
    }
    svc.entityTypes.remove(et);
    store.scheduleSave();
    return Response(204);
  }

  Future<Response> _createProperty(
      Request request, String service, String type) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final et = svc.entityType(type);
    if (et == null) return _err(404, 'Unknown entity type: $type');
    final body = await _readJson(request);
    final prop = Property.fromJson(body);
    if (et.property(prop.name) != null) {
      return _err(409, 'Property ${prop.name} already exists on $type');
    }
    et.properties.add(prop);
    store.scheduleSave();
    return _json(prop.toJson(), status: 201);
  }

  Future<Response> _patchProperty(
      Request request, String service, String type, String prop) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final et = svc.entityType(type);
    if (et == null) return _err(404, 'Unknown entity type: $type');
    final p = et.property(prop);
    if (p == null) return _err(404, 'Unknown property: $prop');
    final body = await _readJson(request);

    final newName = (body['name'] as String?)?.trim();
    if (newName != null && newName.isNotEmpty && newName != p.name) {
      if (et.property(newName) != null) {
        return _err(409, 'Property $newName already exists on $type');
      }
      final oldName = p.name;
      p.name = newName;
      for (final set in svc.entitySets) {
        if (set.entityType != type) continue;
        for (final row in set.rows) {
          if (row.containsKey(oldName)) {
            row[newName] = row.remove(oldName);
          }
        }
      }
    }
    if (body['type'] is String) p.type = body['type'] as String;
    if (body.containsKey('maxLength')) p.maxLength = body['maxLength'] as int?;
    if (body.containsKey('precision')) p.precision = body['precision'] as int?;
    if (body.containsKey('scale')) p.scale = body['scale'] as int?;
    if (body['nullable'] is bool) p.nullable = body['nullable'] as bool;
    if (body['key'] is bool) p.key = body['key'] as bool;
    if (body.containsKey('label')) p.label = body['label'] as String?;

    store.scheduleSave();
    return _json(p.toJson());
  }

  Response _deleteProperty(
      Request request, String service, String type, String prop) {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final et = svc.entityType(type);
    if (et == null) return _err(404, 'Unknown entity type: $type');
    final p = et.property(prop);
    if (p == null) return _err(404, 'Unknown property: $prop');
    et.properties.remove(p);
    for (final set in svc.entitySets) {
      if (set.entityType != type) continue;
      for (final row in set.rows) {
        row.remove(prop);
      }
    }
    store.scheduleSave();
    return Response(204);
  }

  Future<Response> _createSet(Request request, String service) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final body = await _readJson(request);
    final name = (body['name'] as String?)?.trim();
    final typeName = (body['entityType'] as String?)?.trim();
    if (name == null || name.isEmpty) return _err(400, 'Missing name');
    if (typeName == null || typeName.isEmpty) return _err(400, 'Missing entityType');
    if (svc.entitySet(name) != null) {
      return _err(409, 'Entity set $name already exists');
    }
    if (svc.entityType(typeName) == null) {
      return _err(400, 'Entity type $typeName not found in ${svc.name}');
    }
    final set = EntitySet(name: name, entityType: typeName, rows: []);
    svc.entitySets.add(set);
    store.scheduleSave();
    return _json(set.toJson(), status: 201);
  }

  Future<Response> _patchSet(Request request, String service, String set) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final es = svc.entitySet(set);
    if (es == null) return _err(404, 'Unknown entity set: $set');
    final body = await _readJson(request);
    final newName = (body['name'] as String?)?.trim();
    if (newName != null && newName.isNotEmpty && newName != es.name) {
      if (svc.entitySet(newName) != null) {
        return _err(409, 'Entity set $newName already exists');
      }
      es.name = newName;
    }
    final newType = (body['entityType'] as String?)?.trim();
    if (newType != null && newType.isNotEmpty && newType != es.entityType) {
      if (svc.entityType(newType) == null) {
        return _err(400, 'Entity type $newType not found in ${svc.name}');
      }
      es.entityType = newType;
    }
    store.scheduleSave();
    return _json(es.toJson());
  }

  Response _deleteSet(Request request, String service, String set) {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final es = svc.entitySet(set);
    if (es == null) return _err(404, 'Unknown entity set: $set');
    svc.entitySets.remove(es);
    store.scheduleSave();
    return Response(204);
  }

  Response _listRows(Request request, String service, String set) {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final es = svc.entitySet(set);
    if (es == null) return _err(404, 'Unknown entity set: $set');
    return _json({'data': es.rows, 'total': es.rows.length});
  }

  Future<Response> _createRow(Request request, String service, String set) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final es = svc.entitySet(set);
    if (es == null) return _err(404, 'Unknown entity set: $set');
    final et = svc.entityType(es.entityType);
    if (et == null) return _err(500, 'Entity type ${es.entityType} missing');
    final body = await _readJson(request);
    for (final k in et.keyProperties) {
      if (body[k.name] == null) {
        return _err(400, 'Missing key property ${k.name}');
      }
    }
    final id = rowKeyOf(et, body);
    if (_indexOf(et, es.rows, id) >= 0) {
      return _err(409, 'Row $id already exists');
    }
    es.rows.add(body);
    store.scheduleSave();
    return _json(body, status: 201);
  }

  Future<Response> _putRow(
      Request request, String service, String set, String id) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final es = svc.entitySet(set);
    if (es == null) return _err(404, 'Unknown entity set: $set');
    final et = svc.entityType(es.entityType);
    if (et == null) return _err(500, 'Entity type ${es.entityType} missing');
    final body = await _readJson(request);
    final idx = _indexOf(et, es.rows, id);
    if (idx < 0) return _err(404, 'Row $id not found');
    es.rows[idx] = body;
    store.scheduleSave();
    return _json(body);
  }

  Future<Response> _patchRow(
      Request request, String service, String set, String id) async {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final es = svc.entitySet(set);
    if (es == null) return _err(404, 'Unknown entity set: $set');
    final et = svc.entityType(es.entityType);
    if (et == null) return _err(500, 'Entity type ${es.entityType} missing');
    final idx = _indexOf(et, es.rows, id);
    if (idx < 0) return _err(404, 'Row $id not found');
    final body = await _readJson(request);
    final updated = Map<String, dynamic>.from(es.rows[idx])..addAll(body);
    es.rows[idx] = updated;
    store.scheduleSave();
    return _json(updated);
  }

  Response _deleteRow(
      Request request, String service, String set, String id) {
    final svc = store.service(service);
    if (svc == null) return _err(404, 'Unknown service: $service');
    final es = svc.entitySet(set);
    if (es == null) return _err(404, 'Unknown entity set: $set');
    final et = svc.entityType(es.entityType);
    if (et == null) return _err(500, 'Entity type ${es.entityType} missing');
    final idx = _indexOf(et, es.rows, id);
    if (idx < 0) return _err(404, 'Row $id not found');
    es.rows.removeAt(idx);
    store.scheduleSave();
    return Response(204);
  }

  Map<String, dynamic> _summariseService(Service s) => {
        'name': s.name,
        'entityTypes': s.entityTypes.map((t) => t.toJson()).toList(),
        'entitySets': s.entitySets
            .map((set) => {
                  'name': set.name,
                  'entityType': set.entityType,
                  'collection': collectionNameFor(set.name),
                  'rowCount': set.rows.length,
                })
            .toList(),
      };
}

int _indexOf(EntityType type, List<Map<String, dynamic>> rows, String id) {
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
