import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gateway_api.dart';
import '../models.dart';
import 'connections_screen.dart';
import 'outbound_screen.dart';

/// "Map" tab — a visual overview of every outbound flow, grouped by source
/// connection, with each flow rendered as a source → dataset → target
/// lane plus a status pill driven by the most recent audit event. Gives
/// the user a holistic sense of "what data is moving where" without
/// digging into the Outbound editor for each flow.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  List<Connection> _connections = const [];
  List<OutboundFlow> _flows = const [];
  // {flowId: latest audit event for that flow}, populated from the recent
  // audit-event list at load time.
  Map<String, AuditEvent> _lastRun = const {};
  bool _loading = true;
  String? _error;

  // Filters
  String _statusFilter = 'all'; // all | healthy | failing | idle
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      // Pull connections + flows + recent audit in parallel so the page
      // settles in a single re-render and the lanes have all the data
      // they need (connection health + last-run status) at first paint.
      final results = await Future.wait([
        api.listConnections(),
        api.listOutboundFlows(),
        api.getAudit(limit: 500),
      ]);
      if (!mounted) return;
      final conns = [
        for (final c in results[0] as List<Map<String, dynamic>>)
          Connection.fromJson(c),
      ];
      final flows = [
        for (final f in results[1] as List<Map<String, dynamic>>)
          OutboundFlow.fromJson(f),
      ];
      final events = results[2] as List<AuditEvent>;

      // Build a map of {flowId: most recent audit event}. Walking the
      // list once and keeping the first hit per flow id works because the
      // audit endpoint returns newest-first.
      final lastRun = <String, AuditEvent>{};
      for (final e in events) {
        final flowId = e.details?['flowId']?.toString();
        if (flowId == null || flowId.isEmpty) continue;
        lastRun.putIfAbsent(flowId, () => e);
      }

      setState(() {
        _connections = conns;
        _flows = flows;
        _lastRun = lastRun;
        _loading = false;
      });
    } on GatewayException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Connection? _connectionById(String id) {
    for (final c in _connections) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Health derived from the most recent run: 'healthy' if last run
  /// succeeded with no failed rows, 'failing' if it errored or had
  /// failed rows, 'idle' if there's no run on record yet.
  String _flowStatus(OutboundFlow f) {
    final ev = _lastRun[f.id];
    if (ev == null) return 'idle';
    if (ev.status == 'error' || ev.rowsFailed > 0) return 'failing';
    return 'healthy';
  }

  /// Whether a flow passes the current filter + search query.
  bool _matches(OutboundFlow f) {
    if (_statusFilter != 'all' && _flowStatus(f) != _statusFilter) {
      return false;
    }
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    final src = _connectionById(f.sourceConnectionId);
    final tgt = _connectionById(f.targetConnectionId);
    final hay = [
      f.name,
      f.dataset,
      f.targetTable,
      src?.name ?? '',
      tgt?.name ?? '',
    ].join(' ').toLowerCase();
    return hay.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(20),
          child: Padding(
            padding: EdgeInsets.only(left: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  'Visual map of every outbound flow — source, dataset, target'),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorBanner(message: _error!, onRetry: _reload)
              : _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_flows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_tree_outlined, size: 64, color: scheme.outline),
              const SizedBox(height: 16),
              Text('No outbound flows yet',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Create an outbound flow in the Outbound tab to see it here.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // Visible flows after filters, grouped by source connection id so each
    // source becomes its own section. Sources are sorted by name for stable
    // rendering.
    final visible = _flows.where(_matches).toList();
    final groups = <String, List<OutboundFlow>>{};
    for (final f in visible) {
      groups.putIfAbsent(f.sourceConnectionId, () => []).add(f);
    }
    final orderedSources = groups.keys.toList()
      ..sort((a, b) => (_connectionById(a)?.name ?? a)
          .toLowerCase()
          .compareTo((_connectionById(b)?.name ?? b).toLowerCase()));

    // Top-level totals for the stat strip — computed from the whole set
    // (not the filter) so the user can see what's been hidden.
    final total = _flows.length;
    final healthy = _flows.where((f) => _flowStatus(f) == 'healthy').length;
    final failing = _flows.where((f) => _flowStatus(f) == 'failing').length;
    final idle = _flows.where((f) => _flowStatus(f) == 'idle').length;

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatStrip(
            total: total,
            healthy: healthy,
            failing: failing,
            idle: idle,
          ),
          const SizedBox(height: 16),
          _FilterBar(
            status: _statusFilter,
            search: _search,
            onStatus: (v) => setState(() => _statusFilter = v ?? 'all'),
            onSearchChanged: () => setState(() {}),
            shownCount: visible.length,
            totalCount: total,
          ),
          const SizedBox(height: 16),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No flows match the current filters.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.outline),
                ),
              ),
            )
          else
            for (final srcId in orderedSources) ...[
              _SourceGroup(
                source: _connectionById(srcId),
                sourceId: srcId,
                flows: groups[srcId]!,
                resolveTarget: _connectionById,
                lastRun: _lastRun,
                statusOf: _flowStatus,
              ),
              const SizedBox(height: 18),
            ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Stat strip — coloured tiles up top showing the totals at a glance.
// ─────────────────────────────────────────────────────────────────────

class _StatStrip extends StatelessWidget {
  final int total;
  final int healthy;
  final int failing;
  final int idle;
  const _StatStrip({
    required this.total,
    required this.healthy,
    required this.failing,
    required this.idle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        children: [
          Expanded(
            child: _StatTile(
              label: 'Total flows',
              value: '$total',
              icon: Icons.account_tree,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatTile(
              label: 'Healthy',
              value: '$healthy',
              icon: Icons.check_circle_outline,
              color: Colors.green.shade600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatTile(
              label: 'Failing',
              value: '$failing',
              icon: Icons.error_outline,
              color: scheme.error,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatTile(
              label: 'Never run',
              value: '$idle',
              icon: Icons.hourglass_empty,
              color: scheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.06)],
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        )),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Filter bar — status dropdown + search.
// ─────────────────────────────────────────────────────────────────────

class _FilterBar extends StatelessWidget {
  final String status;
  final TextEditingController search;
  final ValueChanged<String?> onStatus;
  final VoidCallback onSearchChanged;
  final int shownCount;
  final int totalCount;
  const _FilterBar({
    required this.status,
    required this.search,
    required this.onStatus,
    required this.onSearchChanged,
    required this.shownCount,
    required this.totalCount,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<String>(
              value: status,
              isDense: true,
              decoration:
                  const InputDecoration(labelText: 'Status', isDense: true),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All')),
                DropdownMenuItem(value: 'healthy', child: Text('Healthy')),
                DropdownMenuItem(value: 'failing', child: Text('Failing')),
                DropdownMenuItem(value: 'idle', child: Text('Never run')),
              ],
              onChanged: onStatus,
            ),
          ),
          SizedBox(
            width: 280,
            child: TextField(
              controller: search,
              decoration: const InputDecoration(
                labelText: 'Search',
                hintText: 'name, dataset, table, connection…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
              onChanged: (_) => onSearchChanged(),
            ),
          ),
          Text(
            shownCount == totalCount
                ? '$totalCount flow${totalCount == 1 ? "" : "s"}'
                : '$shownCount of $totalCount',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Per-source group — header card + lane card per flow underneath.
// ─────────────────────────────────────────────────────────────────────

class _SourceGroup extends StatelessWidget {
  final Connection? source;
  final String sourceId;
  final List<OutboundFlow> flows;
  final Connection? Function(String id) resolveTarget;
  final Map<String, AuditEvent> lastRun;
  final String Function(OutboundFlow f) statusOf;
  const _SourceGroup({
    required this.source,
    required this.sourceId,
    required this.flows,
    required this.resolveTarget,
    required this.lastRun,
    required this.statusOf,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Source colour keys the whole group — chosen by connection type if we
    // have the connection, otherwise grey (orphaned reference after the
    // 0.2.1 "Delete only" path).
    final accent = source?.type.colorOn(scheme) ?? scheme.outline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _GroupHeader(connection: source, sourceId: sourceId, accent: accent),
        const SizedBox(height: 10),
        for (final f in flows) ...[
          _FlowLane(
            flow: f,
            sourceAccent: accent,
            source: source,
            target: resolveTarget(f.targetConnectionId),
            event: lastRun[f.id],
            status: statusOf(f),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final Connection? connection;
  final String sourceId;
  final Color accent;
  const _GroupHeader({
    required this.connection,
    required this.sourceId,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = connection?.name ?? '⚠ Missing connection ($sourceId)';
    final typeLabel = connection?.type.label ?? 'unknown';
    final isMissing = connection == null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent.withValues(alpha: 0.18), accent.withValues(alpha: 0.06)],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              connection?.type.icon ?? Icons.help_outline,
              color: accent,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(isMissing ? 'orphaned source' : '$typeLabel · source',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                          letterSpacing: 0.3,
                        )),
              ],
            ),
          ),
          if (connection != null) _ConnectionHealthBadge(connection: connection!),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// One flow lane — source chip → dataset/arrow → target chip + status row.
// ─────────────────────────────────────────────────────────────────────

class _FlowLane extends StatelessWidget {
  final OutboundFlow flow;
  final Color sourceAccent;
  final Connection? source;
  final Connection? target;
  final AuditEvent? event;
  final String status;
  const _FlowLane({
    required this.flow,
    required this.sourceAccent,
    required this.source,
    required this.target,
    required this.event,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tgtAccent = target?.type.colorOn(scheme) ?? scheme.outline;
    final statusColor = switch (status) {
      'healthy' => Colors.green.shade600,
      'failing' => scheme.error,
      _ => scheme.outline,
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Top: source label + arrow + target label, all on one line so
          // the eye can trace the data path in one sweep.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: LayoutBuilder(
              builder: (context, c) {
                final narrow = c.maxWidth < 560;
                final children = <Widget>[
                  _LaneEndpoint(
                    title: flow.name.isEmpty ? flow.dataset : flow.name,
                    subtitle: 'dataset ${flow.dataset}',
                    accent: sourceAccent,
                    icon: Icons.api,
                  ),
                  const SizedBox(width: 8),
                  _ArrowSegment(
                    label: flow.extractType.value.toUpperCase(),
                    accent: statusColor,
                  ),
                  const SizedBox(width: 8),
                  _LaneEndpoint(
                    title: target?.name ?? '⚠ missing target',
                    subtitle: flow.targetTable.isEmpty
                        ? 'no table picked'
                        : 'table ${flow.targetTable}',
                    accent: tgtAccent,
                    icon: target?.type.icon ?? Icons.help_outline,
                    alignEnd: true,
                  ),
                ];
                if (narrow) {
                  // On narrow widths fall back to a vertical stack so
                  // neither endpoint gets squished into ellipsis.
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      children[0],
                      const SizedBox(height: 8),
                      Center(child: children[2]),
                      const SizedBox(height: 8),
                      children[4],
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: children[0]),
                    children[2],
                    Expanded(child: children[4]),
                  ],
                );
              },
            ),
          ),
          // Footer row: status pill + last-run summary, the operational
          // signal you'd otherwise hunt for in the Logs tab.
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              border: Border(
                top: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                      color: statusColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  switch (status) {
                    'healthy' => 'Healthy',
                    'failing' => 'Failing',
                    _ => 'Never run',
                  },
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _runSummary(event),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                  ),
                ),
                if (_intervalSeconds(flow) > 0) ...[
                  Icon(Icons.schedule, size: 14, color: scheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    _scheduleLabel(_intervalSeconds(flow)),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Human-readable summary of the last audit event for this flow.
  String _runSummary(AuditEvent? e) {
    if (e == null) return 'no runs on record · trigger from the Outbound tab';
    final parts = <String>[];
    if (e.rowsScanned > 0) parts.add('${e.rowsScanned} scanned');
    if (e.rowsUpdated > 0) parts.add('${e.rowsUpdated} updated');
    if (e.rowsFailed > 0) parts.add('${e.rowsFailed} failed');
    final stats = parts.isEmpty ? '' : ' · ${parts.join(" · ")}';
    return 'last run ${_relative(e.timestamp)}$stats';
  }

  /// Effective interval in seconds for [flow], taking either the preset's
  /// canonical value or the custom override. Manual / unscheduled = 0.
  int _intervalSeconds(OutboundFlow flow) {
    if (flow.schedule == SchedulePreset.custom) return flow.customSeconds ?? 0;
    return flow.schedule.seconds ?? 0;
  }

  String _scheduleLabel(int seconds) {
    if (seconds < 60) return 'every ${seconds}s';
    if (seconds < 3600) return 'every ${seconds ~/ 60}m';
    if (seconds < 86400) return 'every ${seconds ~/ 3600}h';
    return 'every ${seconds ~/ 86400}d';
  }
}

class _LaneEndpoint extends StatelessWidget {
  final String title;
  final String subtitle;
  final Color accent;
  final IconData icon;
  final bool alignEnd;
  const _LaneEndpoint({
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.icon,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment:
          alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!alignEnd) ...[
          _EndpointIcon(accent: accent, icon: icon),
          const SizedBox(width: 10),
        ],
        Flexible(
          child: Column(
            crossAxisAlignment:
                alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                subtitle,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.outline,
                    ),
              ),
            ],
          ),
        ),
        if (alignEnd) ...[
          const SizedBox(width: 10),
          _EndpointIcon(accent: accent, icon: icon),
        ],
      ],
    );
  }
}

class _EndpointIcon extends StatelessWidget {
  final Color accent;
  final IconData icon;
  const _EndpointIcon({required this.accent, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent, accent.withValues(alpha: 0.65)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 19),
    );
  }
}

class _ArrowSegment extends StatelessWidget {
  final String label;
  final Color accent;
  const _ArrowSegment({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: accent.withValues(alpha: 0.4)),
          ),
          child: Text(label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  )),
        ),
        const SizedBox(height: 2),
        Icon(Icons.east, color: accent, size: 18),
      ],
    );
  }
}

class _ConnectionHealthBadge extends StatelessWidget {
  final Connection connection;
  const _ConnectionHealthBadge({required this.connection});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = connection.status.colorOn(scheme);
    final label = switch (connection.status) {
      HealthStatus.healthy => 'Healthy',
      HealthStatus.failing => 'Failing',
      HealthStatus.unknown => 'Untested',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  )),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text("Couldn't load the map",
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

String _relative(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
