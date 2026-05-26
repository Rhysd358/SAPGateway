import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'schema.dart';
import 'seed.dart';

class CollectionRef {
  final Service service;
  final EntitySet entitySet;
  final EntityType entityType;
  CollectionRef(this.service, this.entitySet, this.entityType);
}

class GatewayStore {
  GatewayState _state;
  final File _file;
  Timer? _saveDebounce;

  GatewayStore._(this._state, this._file);

  static Future<GatewayStore> load(String path) async {
    final file = File(path);
    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        final state = GatewayState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        return GatewayStore._(state, file);
      } catch (e) {
        stderr.writeln('Failed to load runtime state from $path: $e — using seed');
      }
    }
    final store = GatewayStore._(buildSeed(), file);
    await store._writeNow();
    return store;
  }

  GatewayState get state => _state;
  List<Service> get services => _state.services;

  Service? service(String name) {
    for (final s in _state.services) {
      if (s.name == name) return s;
    }
    return null;
  }

  CollectionRef? collection(String collectionName) {
    final target = collectionName.toLowerCase();
    for (final s in _state.services) {
      for (final set in s.entitySets) {
        if (collectionNameFor(set.name) == target) {
          final type = s.entityType(set.entityType);
          if (type == null) continue;
          return CollectionRef(s, set, type);
        }
      }
    }
    return null;
  }

  Map<String, CollectionRef> get allCollections {
    final out = <String, CollectionRef>{};
    for (final s in _state.services) {
      for (final set in s.entitySets) {
        final type = s.entityType(set.entityType);
        if (type == null) continue;
        out[collectionNameFor(set.name)] = CollectionRef(s, set, type);
      }
    }
    return out;
  }

  Future<void> reset() async {
    _state = buildSeed();
    await _writeNow();
  }

  Future<void> replace(GatewayState state) async {
    _state = state;
    await _writeNow();
  }

  void scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 250), _writeNow);
  }

  Future<void> _writeNow() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(_state.toJson()));
    await tmp.rename(_file.path);
  }

  Future<void> flush() async {
    _saveDebounce?.cancel();
    await _writeNow();
  }
}
