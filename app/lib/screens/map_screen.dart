import 'dart:math' as math;

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
                for (final f in widget.flows)
                  _FlowRow(
                    flow: f,
                    sourceAccent: accent,
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
// One flow row — single line, ~38 px tall. Each row is a visual
// "data pipe": dataset (left) → coloured gradient pipe with arrow head
// → target (right). Status tint on the row background and on the pipe
// makes a list of 100s of rows still readable at a glance.
// ─────────────────────────────────────────────────────────────────────

class _FlowRow extends StatelessWidget {
  final OutboundFlow flow;
  final Color sourceAccent; // colour of the source connection's type
  final Connection? target;
  final AuditEvent? event;
  final String status;
  const _FlowRow({
    required this.flow,
    required this.sourceAccent,
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
    // The pipe ramps from the source connection's colour, through the
    // status colour at its midpoint, to the target connection's colour.
    // For "never run" we mute the whole pipe so it reads as inert.
    final targetAccent = target?.type.colorOn(scheme) ?? scheme.outline;
    final pipeColors = status == 'idle'
        ? <Color>[
            sourceAccent.withValues(alpha: 0.25),
            scheme.outline.withValues(alpha: 0.35),
            targetAccent.withValues(alpha: 0.25),
          ]
        : <Color>[
            sourceAccent.withValues(alpha: 0.85),
            statusColor,
            targetAccent.withValues(alpha: 0.85),
          ];
    // A pale wash of the status colour — turns the whole row into a
    // visual indicator of health without overwhelming the text.
    final bgTint = switch (status) {
      'healthy' => Colors.green.withValues(alpha: 0.05),
      'failing' => scheme.error.withValues(alpha: 0.07),
      _ => null,
    };

    final scanned = event?.rowsScanned ?? 0;
    final failed = event?.rowsFailed ?? 0;

    return Tooltip(
      message: _tooltipFor(flow, event, status),
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        constraints: const BoxConstraints(minHeight: 38),
        decoration: BoxDecoration(
          color: bgTint,
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant, width: 0.4),
          ),
        ),
        child: Row(
          children: [
            _StatusDot(color: statusColor, hollow: status == 'idle'),
            const SizedBox(width: 8),
            // Dataset name — left endpoint of the pipe.
            SizedBox(
              width: 170,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      flow.name.isEmpty ? flow.dataset : flow.name,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _ExtractTypeChip(type: flow.extractType, scheme: scheme),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // ── THE PIPE ── visual centerpiece. Gradient between source
            // and target type colours, status colour at the midpoint,
            // arrow head at the right. Width flexes with the row.
            Expanded(
              child: _Pipe(colors: pipeColors, endColor: statusColor),
            ),
            const SizedBox(width: 10),
            // Target — right endpoint of the pipe.
            SizedBox(
              width: 200,
              child: Text(
                target == null
                    ? '⚠ missing · ${flow.targetTable.isEmpty ? "?" : flow.targetTable}'
                    : '${target!.name} · ${flow.targetTable.isEmpty ? "?" : flow.targetTable}',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color:
                          target == null ? scheme.error : scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ),
            const SizedBox(width: 10),
            // Visual stat bar — green for OK rows, red for failed.
            // Width signals magnitude (last run's row count); the small
            // number to the right gives the precise count.
            SizedBox(
              width: 80,
              child: _RunMagnitudeBar(
                event: event,
                scheme: scheme,
              ),
            ),
            // Numeric stat — kept for precision; tabular figures align it
            // across rows.
            SizedBox(
              width: 60,
              child: Text(
                event == null
                    ? '—'
                    : (failed > 0 ? '$scanned/$failed' : '$scanned'),
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: failed > 0 ? scheme.error : scheme.outline,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontWeight: failed > 0 ? FontWeight.w700 : FontWeight.normal,
                    ),
              ),
            ),
            const SizedBox(width: 4),
            // Short relative time, fixed width so columns align.
            SizedBox(
              width: 44,
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

/// Filled or hollow circle showing flow health. Hollow = never run.
class _StatusDot extends StatelessWidget {
  final Color color;
  final bool hollow;
  const _StatusDot({required this.color, required this.hollow});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? null : color,
        border: hollow ? Border.all(color: color, width: 1.5) : null,
        boxShadow: hollow
            ? null
            : [
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 4,
                  spreadRadius: 0.5,
                ),
              ],
      ),
    );
  }
}

/// The 1-character extract-type tag (F or D) — small but coloured by
/// type so DELTA flows stand out in a long list.
class _ExtractTypeChip extends StatelessWidget {
  final ExtractType type;
  final ColorScheme scheme;
  const _ExtractTypeChip({required this.type, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final color = type == ExtractType.delta ? scheme.tertiary : scheme.primary;
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        type == ExtractType.delta ? 'D' : 'F',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// The visual pipe: gradient rounded bar + arrow head. The gradient
/// ramps source → status → target so the data path is visible at a
/// glance; failing pipes go red, idle ones fade to grey.
class _Pipe extends StatelessWidget {
  final List<Color> colors;
  final Color endColor;
  const _Pipe({required this.colors, required this.endColor});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 12,
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: colors),
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: endColor.withValues(alpha: 0.25),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
          // Arrow head — a small triangle pointing right, sized to match
          // the pipe's thickness and coloured to its terminal end.
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: CustomPaint(
              size: const Size(10, 12),
              painter: _ArrowHeadPainter(endColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArrowHeadPainter extends CustomPainter {
  final Color color;
  _ArrowHeadPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height / 2)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowHeadPainter old) => old.color != color;
}

/// Horizontal magnitude bar that visualises last run's row count
/// without the user having to read a number. Filled portion = scanned
/// rows; red overlay = failed rows. Log-scaled so 10 vs 10,000 still
/// reads cleanly.
class _RunMagnitudeBar extends StatelessWidget {
  final AuditEvent? event;
  final ColorScheme scheme;
  const _RunMagnitudeBar({required this.event, required this.scheme});

  @override
  Widget build(BuildContext context) {
    if (event == null) {
      return Container(
        height: 6,
        decoration: BoxDecoration(
          color: scheme.outlineVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(3),
        ),
      );
    }
    final scanned = event!.rowsScanned;
    final failed = event!.rowsFailed;
    // Log-scaled fill so a 10-row flow and a 10 000-row flow both register
    // visually without the small one disappearing. Empty → empty track.
    final cleanFill = scanned == 0
        ? 0.0
        : (0.15 +
                (math.log(scanned.clamp(1, 100000).toDouble()) /
                        math.log(100000)) *
                    0.85)
            .clamp(0.0, 1.0);
    final failFraction =
        scanned == 0 ? 0.0 : (failed / scanned).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, c) {
        final fillW = (c.maxWidth * cleanFill).clamp(0.0, c.maxWidth);
        final failW = (fillW * failFraction).clamp(0.0, fillW);
        return Stack(
          alignment: Alignment.centerLeft,
          children: [
            // Track
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            // Scanned bar (green)
            Container(
              height: 6,
              width: fillW,
              decoration: BoxDecoration(
                color: Colors.green.shade500,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            // Failed overlay (red, drawn over the scanned bar so the red
            // portion replaces the green for the failed slice).
            if (failW > 0)
              Container(
                height: 6,
                width: failW,
                decoration: BoxDecoration(
                  color: scheme.error,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        );
      },
    );
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
