import 'dart:async';
import 'dart:io';

import 'flows_store.dart';
import 'handler.dart';

/// Polls [FlowsStore.outboundFlows] every [tick] and fires
/// [IntegrationHandler.runOutboundFlowById] for any flow whose
/// `pullIntervalSeconds` has elapsed since its last run.
///
/// Replaces the legacy [IntegrationScheduler] which only knew about
/// `Mapping` records in `integration.json`. Both can coexist if needed —
/// the new scheduler only ever touches `OutboundFlow` records.
class FlowScheduler {
  final FlowsStore store;
  final IntegrationHandler handler;
  final Duration tick;

  Timer? _timer;
  // Per-flow last-run timestamps. Pruned every tick for deleted flows so it
  // can't grow unbounded.
  final Map<String, DateTime> _lastRun = {};
  // Flow IDs whose previous run is still in flight. Prevents double-firing
  // when a Python pull takes longer than [tick].
  final Set<String> _inFlight = {};

  FlowScheduler({
    required this.store,
    required this.handler,
    this.tick = const Duration(seconds: 5),
  });

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(tick, (_) => _onTick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTick() {
    final now = DateTime.now();
    final liveIds = {for (final f in store.outboundFlows) f.id};
    _lastRun.removeWhere((id, _) => !liveIds.contains(id));
    _inFlight.removeWhere((id) => !liveIds.contains(id));

    for (final flow in store.outboundFlows) {
      final secs = flow.pullIntervalSeconds;
      if (secs == null || secs <= 0) continue;
      if (_inFlight.contains(flow.id)) continue;
      final last = _lastRun[flow.id];
      if (last != null && now.difference(last).inSeconds < secs) continue;

      _lastRun[flow.id] = now;
      _inFlight.add(flow.id);
      // Don't await — fire-and-forget so a slow run doesn't block the
      // tick for other flows. Errors are already captured into the audit
      // log by runOutboundFlowById's own error-event handling.
      unawaited(handler.runOutboundFlowById(flow.id).catchError((e) {
        stderr.writeln('FlowScheduler: flow ${flow.id} failed: $e');
        return _placeholderEvent();
      }).whenComplete(() {
        _inFlight.remove(flow.id);
      }));
    }
  }

  /// Snapshot for the `/integration/schedules` endpoint.
  List<Map<String, dynamic>> describe() {
    final out = <Map<String, dynamic>>[];
    for (final flow in store.outboundFlows) {
      if (flow.pullIntervalSeconds == null || flow.pullIntervalSeconds! <= 0) {
        continue;
      }
      out.add({
        'flowId': flow.id,
        'name': flow.name,
        'pullIntervalSeconds': flow.pullIntervalSeconds,
        'lastRun': _lastRun[flow.id]?.toIso8601String(),
        'inFlight': _inFlight.contains(flow.id),
      });
    }
    return out;
  }
}

// `catchError` on a Future needs a return value of the future's type. The
// run helper returns an AuditEvent but that's not exported here — and we
// don't need the value, just the side-effect of swallowing the exception.
// `dynamic` keeps the import surface small.
dynamic _placeholderEvent() => null;
