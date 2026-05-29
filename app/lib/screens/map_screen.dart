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
            for (final srcId in orderedSources)
              _SourceGroup(
                source: _connectionById(srcId),
                sourceId: srcId,
                flows: groups[srcId]!,
                resolveTarget: _connectionById,
                lastRun: _lastRun,
                statusOf: _flowStatus,
              ),
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
// Per-source group — collapsible header + one tight row per flow.
// Designed for density: a 100-flow deployment should fit in a few
// screens of scroll, not a few dozen.
// ─────────────────────────────────────────────────────────────────────

class _SourceGroup extends StatefulWidget {
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
  State<_SourceGroup> createState() => _SourceGroupState();
}

class _SourceGroupState extends State<_SourceGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.source?.type.colorOn(scheme) ?? scheme.outline;
    final failingCount = widget.flows
        .where((f) => widget.statusOf(f) == 'failing')
        .length;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Header is the clickable strip — small footprint, all the
          // group-level signals (name / type / health / flow count) on
          // one row plus a chevron.
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.08),
                borderRadius: _expanded
                    ? const BorderRadius.vertical(top: Radius.circular(8))
                    : BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: Icon(Icons.chevron_right,
                        size: 18, color: scheme.outline),
                  ),
                  const SizedBox(width: 4),
                  Icon(widget.source?.type.icon ?? Icons.help_outline,
                      size: 16, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.source?.name ??
                                '⚠ Missing connection (${widget.sourceId})',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '· ${widget.source?.type.label ?? "unknown"}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.outline),
                        ),
                      ],
                    ),
                  ),
                  if (widget.source != null)
                    _ConnectionHealthBadge(connection: widget.source!),
                  const SizedBox(width: 8),
                  // Flow count + failing indicator. Red number shows up
                  // at a glance for unhealthy groups even when collapsed.
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${widget.flows.length}',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (failingCount > 0) ...[
                          const SizedBox(width: 4),
                          Text('· $failingCount failing',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: scheme.error,
                                    fontWeight: FontWeight.w700,
                                  )),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Column(
              children: [
                // Sub-header — column labels, dim. Gives the dense rows
                // below a frame of reference without re-stating them.
                Container(
                  padding: const EdgeInsets.fromLTRB(36, 6, 12, 4),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLowest,
                    border: Border(
                      bottom: BorderSide(
                          color: scheme.outlineVariant, width: 0.5),
                    ),
                  ),
                  child: DefaultTextStyle.merge(
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.outline,
                              letterSpacing: 0.4,
                            ) ??
                        const TextStyle(),
                    child: const Row(
                      children: [
                        Expanded(flex: 5, child: Text('DATASET')),
                        SizedBox(width: 24),
                        Expanded(flex: 5, child: Text('TARGET')),
                        SizedBox(
                            width: 90,
                            child: Text('SCANNED / FAILED',
                                textAlign: TextAlign.right)),
                        SizedBox(
                            width: 50,
                            child: Text('LAST',
                                textAlign: TextAlign.right)),
                      ],
                    ),
                  ),
                ),
                for (final f in widget.flows)
                  _FlowRow(
                    flow: f,
                    target: widget.resolveTarget(f.targetConnectionId),
                    event: widget.lastRun[f.id],
                    status: widget.statusOf(f),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// One flow row — single line, ~30 px tall. Columns are aligned so a
// long list reads like a table.
// ─────────────────────────────────────────────────────────────────────

class _FlowRow extends StatelessWidget {
  final OutboundFlow flow;
  final Connection? target;
  final AuditEvent? event;
  final String status;
  const _FlowRow({
    required this.flow,
    required this.target,
    required this.event,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = switch (status) {
      'healthy' => Colors.green.shade600,
      'failing' => scheme.error,
      _ => scheme.outline,
    };
    final scanned = event?.rowsScanned ?? 0;
    final failed = event?.rowsFailed ?? 0;
    final tooltip = _tooltipFor(flow, event, status);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        constraints: const BoxConstraints(minHeight: 30),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant, width: 0.4),
          ),
        ),
        child: Row(
          children: [
            // Status dot — full colour for healthy/failing, hollow for never-run.
            SizedBox(
              width: 18,
              child: status == 'idle'
                  ? Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: statusColor, width: 1.5),
                      ),
                    )
                  : Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
            ),
            const SizedBox(width: 6),
            // Dataset (flow name) — bold for the most important text.
            Expanded(
              flex: 5,
              child: Text(
                flow.name.isEmpty ? flow.dataset : flow.name,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            // Extract type micro-chip — F / D so DELTA flows stand out.
            Container(
              width: 16,
              height: 16,
              margin: const EdgeInsets.only(right: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: (flow.extractType == ExtractType.delta
                        ? scheme.tertiary
                        : scheme.primary)
                    .withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                flow.extractType == ExtractType.delta ? 'D' : 'F',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: flow.extractType == ExtractType.delta
                          ? scheme.tertiary
                          : scheme.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            Icon(Icons.east, size: 14, color: scheme.outline),
            const SizedBox(width: 6),
            // Target — connection · table.
            Expanded(
              flex: 5,
              child: Text(
                target == null
                    ? '⚠ missing · ${flow.targetTable.isEmpty ? "?" : flow.targetTable}'
                    : '${target!.name} · ${flow.targetTable.isEmpty ? "?" : flow.targetTable}',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: target == null ? scheme.error : scheme.outline,
                    ),
              ),
            ),
            // Scanned / failed — fixed-width, right-aligned for vertical scan.
            SizedBox(
              width: 90,
              child: Text(
                event == null
                    ? '—'
                    : (failed > 0 ? '$scanned / $failed' : '$scanned'),
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: failed > 0 ? scheme.error : scheme.outline,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ),
            // Last-run time — short form ('2h', 'never').
            SizedBox(
              width: 50,
              child: Text(
                event == null ? 'never' : _shortRelative(event!.timestamp),
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.outline,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _tooltipFor(
      OutboundFlow flow, AuditEvent? event, String status) {
    final lines = <String>[
      'Flow: ${flow.name.isEmpty ? flow.dataset : flow.name}',
      'Dataset: ${flow.dataset} (${flow.extractType.value})',
      'Target table: ${flow.targetTable.isEmpty ? "—" : flow.targetTable}',
      'Status: $status',
    ];
    if (event != null) {
      lines.add(
        'Last run: ${_relative(event.timestamp)}'
        ' · scanned ${event.rowsScanned}'
        ' · updated ${event.rowsUpdated}'
        ' · failed ${event.rowsFailed}',
      );
      if (event.error != null && event.error!.isNotEmpty) {
        lines.add('Error: ${event.error}');
      }
    } else {
      lines.add('Last run: never');
    }
    return lines.join('\n');
  }
}

/// Ultra-short relative time for the last column. Keeps the column at
/// ~40 px so 100s of rows stay aligned and scannable.
String _shortRelative(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) return '${diff.inSeconds}s';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 365) return '${diff.inDays}d';
  return '${diff.inDays ~/ 365}y';
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
