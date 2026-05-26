import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gateway_api.dart';
import '../models.dart';
import '../widgets/stat_tile.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _connectionCount = 0;
  int _outboundCount = 0;
  int _outboundScheduledCount = 0;
  int _inboundCount = 0;
  bool _surrealConfigured = false;
  List<AuditEvent> _recent = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      // Four independent endpoints — fire in parallel so a slow gateway
      // doesn't multiply latency by four.
      final results = await Future.wait([
        api.listConnections(),
        api.listOutboundFlows(),
        api.listInboundFlows(),
        api.getAudit(limit: 5),
      ]);
      if (!mounted) return;
      final connections = results[0] as List<Map<String, dynamic>>;
      final outbound = results[1] as List<Map<String, dynamic>>;
      final inbound = results[2] as List<Map<String, dynamic>>;
      final events = results[3] as List<AuditEvent>;
      setState(() {
        _connectionCount = connections.length;
        _surrealConfigured = connections.any((c) => c['type'] == 'surreal');
        _outboundCount = outbound.length;
        _outboundScheduledCount = outbound
            .where((f) =>
                (f['pullIntervalSeconds'] as num?) != null &&
                (f['pullIntervalSeconds'] as num) > 0)
            .length;
        _inboundCount = inbound.length;
        _recent = events;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorBanner(message: _error!, onRetry: _reload)
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildStatStrip(context),
                      const SizedBox(height: 24),
                      const SectionHeader(
                        title: 'Data flow',
                        subtitle:
                            'Outbound moves data from a REST source into SurrealDB. Inbound moves approved records from SurrealDB into SAP via OData V2 + SSO.',
                      ),
                      const _FlowDiagram(),
                      if (_recent.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        const SectionHeader(title: 'Recent activity'),
                        _RecentActivity(events: _recent),
                      ],
                    ],
                  ),
                ),
    );
  }
}

extension on _DashboardScreenState {
  Widget _buildStatStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lastRun = _recent.isNotEmpty ? _recent.first : null;
    final manualOutbound = _outboundCount - _outboundScheduledCount;

    return StatStrip([
      StatTileData(
        icon: Icons.cable,
        label: 'Connections',
        value: '$_connectionCount',
        hint: _surrealConfigured
            ? '$_connectionCount configured'
            : 'No SurrealDB target yet',
        colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)],
      ),
      StatTileData(
        icon: Icons.call_made,
        label: 'Outbound flows',
        value: '$_outboundCount',
        hint: '$_outboundScheduledCount scheduled · $manualOutbound manual',
        colors: [scheme.secondary, scheme.secondary.withValues(alpha: 0.7)],
      ),
      StatTileData(
        icon: Icons.call_received,
        label: 'Inbound flows',
        value: '$_inboundCount',
        hint: 'OData + SSO — pending',
        colors: [scheme.tertiary, scheme.tertiary.withValues(alpha: 0.7)],
      ),
      StatTileData(
        icon: Icons.history,
        label: 'Last sync',
        value: lastRun != null ? _relative(lastRun.timestamp) : '—',
        hint: lastRun != null
            ? '${lastRun.action} · ${lastRun.collection ?? "—"}'
            : 'No runs yet',
        colors: [
          scheme.primary.withValues(alpha: 0.8),
          scheme.tertiary.withValues(alpha: 0.8),
        ],
      ),
    ]);
  }
}

String _relative(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

class _FlowDiagram extends StatelessWidget {
  const _FlowDiagram();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            _FlowLane(
              label: 'Outbound',
              labelIcon: Icons.call_made,
              accent: Theme.of(context).colorScheme.primary,
              source: const _Node(
                icon: Icons.api,
                title: 'REST API',
                subtitle: 'SAP source (Basic / OAuth2)',
              ),
              middle: const _MiddleEngine(
                label: 'Gateway',
                sublabel: 'pull · map · upsert',
              ),
              target: const _Node(
                icon: Icons.storage,
                title: 'SurrealDB',
                subtitle: 'nucleus / test',
              ),
            ),
            const SizedBox(height: 28),
            _FlowLane(
              label: 'Inbound',
              labelIcon: Icons.call_received,
              accent: Theme.of(context).colorScheme.tertiary,
              source: const _Node(
                icon: Icons.storage,
                title: 'SurrealDB',
                subtitle: 'Status = APPROVED',
              ),
              middle: const _MiddleEngine(
                label: 'Gateway',
                sublabel: 'push · OData V2',
              ),
              target: const _Node(
                icon: Icons.business_center,
                title: 'SAP ECC',
                subtitle: 'OData V2 + SSO (TBD)',
                muted: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FlowLane extends StatelessWidget {
  final String label;
  final IconData labelIcon;
  final Color accent;
  final _Node source;
  final Widget middle;
  final _Node target;
  const _FlowLane({
    required this.label,
    required this.labelIcon,
    required this.accent,
    required this.source,
    required this.middle,
    required this.target,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(labelIcon, size: 16, color: accent),
            const SizedBox(width: 6),
            Text(label.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: accent,
                      letterSpacing: 1.0,
                      fontWeight: FontWeight.w700,
                    )),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, c) {
          if (c.maxWidth < 560) {
            return Column(
              children: [
                source,
                _Arrow(vertical: true, color: accent),
                middle,
                _Arrow(vertical: true, color: accent),
                target,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: source),
              _Arrow(color: accent),
              Expanded(child: middle),
              _Arrow(color: accent),
              Expanded(child: target),
            ],
          );
        }),
      ],
    );
  }
}

class _Node extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool muted;
  const _Node({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = muted ? scheme.surfaceContainerHighest : scheme.primaryContainer;
    final fg = muted ? scheme.outline : scheme.onPrimaryContainer;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Icon(icon, size: 28, color: fg),
          const SizedBox(height: 8),
          Text(title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  )),
          const SizedBox(height: 2),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: fg.withValues(alpha: 0.85))),
        ],
      ),
    );
  }
}

class _MiddleEngine extends StatelessWidget {
  final String label;
  final String sublabel;
  const _MiddleEngine({required this.label, required this.sublabel});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scheme.secondary.withValues(alpha: 0.18),
            scheme.primary.withValues(alpha: 0.14),
          ],
        ),
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub, color: scheme.primary, size: 28),
          const SizedBox(height: 6),
          Text(label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  )),
          Text(sublabel,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.outline)),
        ],
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  final bool vertical;
  final Color color;
  const _Arrow({this.vertical = false, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: vertical
          ? const EdgeInsets.symmetric(vertical: 8)
          : const EdgeInsets.symmetric(horizontal: 12),
      child: Icon(
        vertical ? Icons.south : Icons.east,
        color: color.withValues(alpha: 0.7),
        size: 22,
      ),
    );
  }
}

class _RecentActivity extends StatelessWidget {
  final List<AuditEvent> events;
  const _RecentActivity({required this.events});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < events.length; i++) ...[
            ListTile(
              dense: true,
              leading: _statusIcon(events[i].status, scheme),
              title: Text(
                '${events[i].action}  ·  ${events[i].collection ?? "—"}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              subtitle: Text(
                _summary(events[i]),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.outline,
                    ),
              ),
              trailing: Text(_relative(events[i].timestamp),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                      )),
            ),
            if (i < events.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }

  Widget _statusIcon(String status, ColorScheme s) {
    return switch (status) {
      'success' => Icon(Icons.check_circle, color: Colors.green.shade600),
      'error' => Icon(Icons.error, color: s.error),
      _ => Icon(Icons.help_outline, color: s.outline),
    };
  }

  String _summary(AuditEvent e) {
    final parts = <String>[];
    if (e.rowsScanned > 0) parts.add('${e.rowsScanned} scanned');
    if (e.rowsUpdated > 0) parts.add('${e.rowsUpdated} updated');
    if (e.rowsCreated > 0) parts.add('${e.rowsCreated} created');
    if (e.rowsFailed > 0) parts.add('${e.rowsFailed} failed');
    if (parts.isEmpty) return '${e.durationMs}ms · ${e.dryRun ? "dry run" : "live"}';
    return '${parts.join(" · ")}  ·  ${e.durationMs}ms';
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 48, color: scheme.outline),
              const SizedBox(height: 12),
              Text('Gateway unreachable',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
