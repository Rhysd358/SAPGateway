import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gateway_api.dart';
import '../models.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<AuditEvent> _events = [];
  // Job names sourced from the flows store (outbound + inbound) so the
  // filter dropdown lists known jobs even before any events exist.
  List<String> _knownJobs = const [];
  bool _loading = true;
  String? _error;

  // Filters
  String _actionFilter = 'all';
  String _statusFilter = 'all';
  String _jobFilter = 'all';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Honour a pending filter set by another screen's "View logs" button.
    final pending = context.read<AppState>().consumePendingJobFilter();
    if (pending != null) _jobFilter = pending;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      // Fetch events + flow names in parallel so the job filter dropdown
      // includes flows that have never run yet.
      final results = await Future.wait([
        api.getAudit(limit: 500),
        api.listOutboundFlows(),
        api.listInboundFlows(),
      ]);
      if (!mounted) return;
      final events = results[0] as List<AuditEvent>;
      final outbound = results[1] as List<Map<String, dynamic>>;
      final inbound = results[2] as List<Map<String, dynamic>>;
      final names = <String>{
        for (final f in outbound)
          if ((f['name'] as String?)?.isNotEmpty == true) f['name'] as String,
        for (final f in inbound)
          if ((f['name'] as String?)?.isNotEmpty == true) f['name'] as String,
        for (final e in events)
          if (e.collection != null && e.collection!.isNotEmpty) e.collection!,
      };
      setState(() {
        _events = events;
        _knownJobs = names.toList()..sort();
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

  Future<void> _clearLogs() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear audit log?'),
        content: const Text(
            'This permanently removes every event from data/audit.json. Connections and flows are not affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().api.clearAudit();
      if (!mounted) return;
      setState(() => _events = []);
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Clear failed: ${e.message}')),
      );
    }
  }

  List<AuditEvent> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _events.where((e) {
      if (_actionFilter != 'all' && e.action != _actionFilter) return false;
      if (_statusFilter != 'all' && e.status != _statusFilter) return false;
      if (_jobFilter != 'all') {
        final eventCollection = e.collection ?? '';
        final eventFlowId = e.details?['flowId']?.toString() ?? '';
        if (eventCollection != _jobFilter && eventFlowId != _jobFilter) {
          return false;
        }
      }
      if (q.isNotEmpty) {
        final hay = '${e.action} ${e.collection ?? ""} ${e.error ?? ""}'
            .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(20),
          child: Padding(
            padding: EdgeInsets.only(left: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Gateway audit log — every run, config change, and connection test'),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _loading || _events.isEmpty ? null : _clearLogs,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _ErrorBanner(message: _error!, onRetry: _reload);
    // Materialize once per build — the getter walked up to 500 events with
    // regex matching, and was called three times before this refactor.
    final filtered = _filtered;
    return Column(
      children: [
        _FilterBar(
          action: _actionFilter,
          status: _statusFilter,
          job: _jobFilter,
          jobOptions: _knownJobs,
          searchCtrl: _searchCtrl,
          total: _events.length,
          filtered: filtered.length,
          onAction: (v) => setState(() => _actionFilter = v ?? 'all'),
          onStatus: (v) => setState(() => _statusFilter = v ?? 'all'),
          onJob: (v) => setState(() => _jobFilter = v ?? 'all'),
          onSearchChanged: () => setState(() {}),
        ),
        Expanded(
          child: filtered.isEmpty
              ? _EmptyState(hasFilter: _events.isNotEmpty)
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _EventCard(event: filtered[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  final String action;
  final String status;
  final String job;
  final List<String> jobOptions;
  final TextEditingController searchCtrl;
  final int total;
  final int filtered;
  final ValueChanged<String?> onAction;
  final ValueChanged<String?> onStatus;
  final ValueChanged<String?> onJob;
  final VoidCallback onSearchChanged;
  const _FilterBar({
    required this.action,
    required this.status,
    required this.job,
    required this.jobOptions,
    required this.searchCtrl,
    required this.total,
    required this.filtered,
    required this.onAction,
    required this.onStatus,
    required this.onJob,
    required this.onSearchChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<String>(
              value: action,
              isDense: true,
              decoration: const InputDecoration(
                labelText: 'Action',
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All actions')),
                DropdownMenuItem(value: 'pull', child: Text('Pull (outbound)')),
                DropdownMenuItem(value: 'push', child: Text('Push (inbound)')),
                DropdownMenuItem(
                    value: 'test-connection', child: Text('Test connection')),
                DropdownMenuItem(
                    value: 'config-update', child: Text('Config update')),
              ],
              onChanged: onAction,
            ),
          ),
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<String>(
              value: status,
              isDense: true,
              decoration: const InputDecoration(
                labelText: 'Status',
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All')),
                DropdownMenuItem(value: 'success', child: Text('Success')),
                DropdownMenuItem(value: 'error', child: Text('Error')),
              ],
              onChanged: onStatus,
            ),
          ),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String>(
              value: jobOptions.contains(job) || job == 'all' ? job : 'all',
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Job',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('All jobs')),
                for (final j in jobOptions)
                  DropdownMenuItem(value: j, child: Text(j)),
              ],
              onChanged: onJob,
            ),
          ),
          SizedBox(
            width: 260,
            child: TextField(
              controller: searchCtrl,
              decoration: const InputDecoration(
                labelText: 'Search',
                hintText: 'collection, error text…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
              onChanged: (_) => onSearchChanged(),
            ),
          ),
          Text(
            filtered == total
                ? '$total event${total == 1 ? "" : "s"}'
                : '$filtered of $total',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
          ),
        ],
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  final AuditEvent event;
  const _EventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _accentFor(event, scheme);
    final hasError = event.status == 'error' && event.error != null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(_iconFor(event), color: accent, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    event.action,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  if (event.collection != null) ...[
                                    const SizedBox(width: 8),
                                    Text('· ${event.collection}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: scheme.outline,
                                            )),
                                  ],
                                  if (event.dryRun) ...[
                                    const SizedBox(width: 8),
                                    _Pill(
                                        label: 'dry run',
                                        color: scheme.outline),
                                  ],
                                ],
                              ),
                              if (_rowSummary(event) != null) ...[
                                const SizedBox(height: 2),
                                Text(_rowSummary(event)!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: scheme.outline)),
                              ],
                            ],
                          ),
                        ),
                        _Pill(
                          label: event.status,
                          color: accent,
                          filled: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.schedule,
                            size: 12, color: scheme.outline),
                        const SizedBox(width: 4),
                        Text(_format(event.timestamp),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.outline)),
                        const SizedBox(width: 12),
                        Icon(Icons.timer_outlined,
                            size: 12, color: scheme.outline),
                        const SizedBox(width: 4),
                        Text('${event.durationMs} ms',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: scheme.outline,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                )),
                      ],
                    ),
                    if (hasError) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.error_outline,
                                size: 16, color: scheme.onErrorContainer),
                            const SizedBox(width: 6),
                            Expanded(
                              child: SelectableText(
                                event.error!,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: scheme.onErrorContainer,
                                      fontFamily: 'monospace',
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(AuditEvent e) {
    return switch (e.action) {
      'pull' => Icons.call_made,
      'push' => Icons.call_received,
      'test-connection' => Icons.wifi_tethering,
      'config-update' => Icons.settings,
      _ => Icons.event_note,
    };
  }

  Color _accentFor(AuditEvent e, ColorScheme s) {
    if (e.status == 'error') return s.error;
    return switch (e.action) {
      'pull' => s.primary,
      'push' => s.tertiary,
      'test-connection' => s.secondary,
      'config-update' => s.outline,
      _ => s.outline,
    };
  }

  String? _rowSummary(AuditEvent e) {
    final parts = <String>[];
    if (e.rowsScanned > 0) parts.add('${e.rowsScanned} scanned');
    if (e.rowsCreated > 0) parts.add('${e.rowsCreated} created');
    if (e.rowsUpdated > 0) parts.add('${e.rowsUpdated} updated');
    if (e.rowsSkipped > 0) parts.add('${e.rowsSkipped} skipped');
    if (e.rowsFailed > 0) parts.add('${e.rowsFailed} failed');
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  String _format(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final bool filled;
  const _Pill({required this.label, required this.color, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled
            ? color.withValues(alpha: 0.14)
            : Colors.transparent,
        border: filled ? null : Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasFilter;
  const _EmptyState({required this.hasFilter});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasFilter ? Icons.search_off : Icons.history,
              size: 48,
              color: scheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              hasFilter ? 'No events match the current filters' : 'No events yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              hasFilter
                  ? 'Adjust the filters above to see more.'
                  : 'Run an outbound flow or test a connection to see entries here.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
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
            Text('Couldn\'t load logs',
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
