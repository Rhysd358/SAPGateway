import 'dart:async';
import 'dart:io';

import 'config.dart';
import 'handler.dart';

/// Ticks every [tickInterval] and fires any pull/push runs whose configured
/// interval has elapsed since their last run. Tracks in-flight runs so a slow
/// run isn't double-fired by the next tick. Survives restart: schedule lives
/// on each [Mapping] in `data/integration.json`.
class IntegrationScheduler {
  final IntegrationConfig config;
  final IntegrationHandler handler;
  final Duration tickInterval;

  final Map<String, DateTime> _lastRunAt = {};
  final Set<String> _inFlight = {};
  Timer? _ticker;

  IntegrationScheduler({
    required this.config,
    required this.handler,
    this.tickInterval = const Duration(seconds: 5),
  });

  void start() {
    if (_ticker != null) return;
    _ticker = Timer.periodic(tickInterval, (_) => _tick());
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _tick() async {
    final now = DateTime.now();
    for (final m in config.mappings) {
      if (m.pullScheduled) {
        _maybeFire(
          key: '${m.collection}:pull',
          intervalSeconds: m.pullIntervalSeconds!,
          now: now,
          run: () => handler.runPull(m.collection),
        );
      }
      if (m.pushScheduled) {
        _maybeFire(
          key: '${m.collection}:push',
          intervalSeconds: m.pushIntervalSeconds!,
          now: now,
          run: () => handler.runPush(m.collection),
        );
      }
    }
  }

  void _maybeFire({
    required String key,
    required int intervalSeconds,
    required DateTime now,
    required Future<void> Function() run,
  }) {
    if (_inFlight.contains(key)) return;
    final last = _lastRunAt[key];
    if (last != null && now.difference(last).inSeconds < intervalSeconds) {
      return;
    }
    _lastRunAt[key] = now;
    _inFlight.add(key);
    // Fire and forget. Errors are captured in the audit log by run* itself;
    // anything beyond that we just log to stderr.
    unawaited(run().then((_) {}, onError: (e) {
      stderr.writeln('[scheduler] $key failed: $e');
    }).whenComplete(() {
      _inFlight.remove(key);
    }));
  }

  /// Snapshot for /schedules-style introspection.
  Map<String, dynamic> describe() {
    final entries = <Map<String, dynamic>>[];
    for (final m in config.mappings) {
      if (!m.pullScheduled && !m.pushScheduled) continue;
      entries.add({
        'collection': m.collection,
        if (m.pullScheduled) 'pullIntervalSeconds': m.pullIntervalSeconds,
        if (m.pushScheduled) 'pushIntervalSeconds': m.pushIntervalSeconds,
        if (_lastRunAt['${m.collection}:pull'] != null)
          'lastPullAt':
              _lastRunAt['${m.collection}:pull']!.toUtc().toIso8601String(),
        if (_lastRunAt['${m.collection}:push'] != null)
          'lastPushAt':
              _lastRunAt['${m.collection}:push']!.toUtc().toIso8601String(),
      });
    }
    return {'schedules': entries};
  }
}
