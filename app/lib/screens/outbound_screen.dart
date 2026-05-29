import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gateway_api.dart';
import 'connections_screen.dart'
    show
        Connection,
        ConnectionType,
        DialogFooter,
        DialogHero,
        DialogSection,
        FloatingDialog;

// ─────────────────────────────────────────────────────────────
// Schedule frequency — the Outbound editor's dropdown.
// ─────────────────────────────────────────────────────────────
enum SchedulePreset {
  manual,
  every1m,
  every5m,
  every15m,
  every30m,
  every1h,
  custom,
}

extension SchedulePresetX on SchedulePreset {
  String get label => switch (this) {
        SchedulePreset.manual => 'Manual',
        SchedulePreset.every1m => 'Every 1 minute',
        SchedulePreset.every5m => 'Every 5 minutes',
        SchedulePreset.every15m => 'Every 15 minutes',
        SchedulePreset.every30m => 'Every 30 minutes',
        SchedulePreset.every1h => 'Every 1 hour',
        SchedulePreset.custom => 'Custom…',
      };

  int? get seconds => switch (this) {
        SchedulePreset.manual => null,
        SchedulePreset.every1m => 60,
        SchedulePreset.every5m => 300,
        SchedulePreset.every15m => 900,
        SchedulePreset.every30m => 1800,
        SchedulePreset.every1h => 3600,
        SchedulePreset.custom => null,
      };

  String get chipLabel => switch (this) {
        SchedulePreset.manual => 'manual',
        SchedulePreset.every1m => 'every 1m',
        SchedulePreset.every5m => 'every 5m',
        SchedulePreset.every15m => 'every 15m',
        SchedulePreset.every30m => 'every 30m',
        SchedulePreset.every1h => 'every 1h',
        SchedulePreset.custom => 'custom',
      };
}

// ─────────────────────────────────────────────────────────────
// Outbound flow model + screen state
// ─────────────────────────────────────────────────────────────

/// Source REST API extract mode. The real API takes `type=full|delta`.
enum ExtractType { full, delta }

extension ExtractTypeX on ExtractType {
  String get label => switch (this) {
        ExtractType.full => 'Full',
        ExtractType.delta => 'Delta',
      };
  String get value => switch (this) {
        ExtractType.full => 'full',
        ExtractType.delta => 'delta',
      };
}

/// When type=delta the API needs ONE of these as the cutoff parameter.
/// Stored on the flow so the scheduler knows which key to pass on each run.
enum DeltaBasis { changeDate, keyDate }

extension DeltaBasisX on DeltaBasis {
  String get label => switch (this) {
        DeltaBasis.changeDate => 'change_date',
        DeltaBasis.keyDate => 'key_date',
      };
  String get prettyLabel => switch (this) {
        DeltaBasis.changeDate => 'Change date',
        DeltaBasis.keyDate => 'Key date',
      };
}

/// Known dataset names from the SAP extract API. The editor surfaces these
/// in the dropdown plus a "Custom…" option for anything new.
const knownDatasets = <String>[
  'employees',
  'line_managers',
  'user_data',
  'expense_priv',
];

/// One row of the Outbound flow's field-mapping table.
///
/// A mapping is either:
///   - **source-driven** — `isConstant=false`, pull a value from
///     [source] on each row.
///   - **constant** — `isConstant=true`, write the literal text in
///     [constantValue] into [target] for every row. Useful when the
///     target table requires a SCHEMAFULL field that the source doesn't
///     supply (the case that motivated this — `cost_centre` on `person`).
class FieldMapping {
  String? source;
  String? target;
  bool isConstant;
  String constantValue;
  FieldMapping({
    this.source,
    this.target,
    this.isConstant = false,
    this.constantValue = '',
  });

  Map<String, dynamic> toJson() => {
        if (source != null) 'source': source,
        if (target != null) 'target': target,
        if (isConstant) 'isConstant': true,
        if (isConstant && constantValue.isNotEmpty)
          'constantValue': constantValue,
      };

  factory FieldMapping.fromJson(Map<String, dynamic> j) => FieldMapping(
        source: j['source'] as String?,
        target: j['target'] as String?,
        isConstant: j['isConstant'] as bool? ?? false,
        constantValue: j['constantValue'] as String? ?? '',
      );
}

class OutboundFlow {
  String id;
  String name;
  String sourceConnectionId;
  // Source REST shape — matches `/ai/extract?type=…&dataset=…&change_date=…`.
  ExtractType extractType;
  String dataset;
  DeltaBasis deltaBasis;
  // SAP-style YYYYMMDDhhmmss (14 digits). On scheduled delta runs this is
  // updated to the previous run's timestamp; the editor exposes it as the
  // "since" starting point.
  String deltaSince;
  String targetConnectionId;
  String targetTable;
  SchedulePreset schedule;
  int? customSeconds;
  List<FieldMapping> mappings;

  OutboundFlow({
    required this.id,
    required this.name,
    required this.sourceConnectionId,
    this.extractType = ExtractType.full,
    required this.dataset,
    this.deltaBasis = DeltaBasis.changeDate,
    this.deltaSince = '',
    required this.targetConnectionId,
    required this.targetTable,
    this.schedule = SchedulePreset.manual,
    this.customSeconds,
    List<FieldMapping>? mappings,
  }) : mappings = mappings ?? [];

  factory OutboundFlow.fromJson(Map<String, dynamic> j) => OutboundFlow(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        sourceConnectionId: j['sourceConnectionId'] as String? ?? '',
        extractType: (j['extractType'] as String?) == 'delta'
            ? ExtractType.delta
            : ExtractType.full,
        dataset: j['dataset'] as String? ?? '',
        deltaBasis: (j['deltaBasis'] as String?) == 'key_date'
            ? DeltaBasis.keyDate
            : DeltaBasis.changeDate,
        deltaSince: j['deltaSince'] as String? ?? '',
        targetConnectionId: j['targetConnectionId'] as String? ?? '',
        targetTable: j['targetTable'] as String? ?? '',
        schedule: _scheduleFromSeconds(
            (j['pullIntervalSeconds'] as num?)?.toInt()),
        customSeconds: _customSecondsFor(
            (j['pullIntervalSeconds'] as num?)?.toInt()),
        mappings: [
          for (final m in (j['mappings'] as List? ?? []))
            FieldMapping.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
      );

  Map<String, dynamic> toJsonPatch() => {
        'name': name,
        'sourceConnectionId': sourceConnectionId,
        'extractType': extractType.value,
        'dataset': dataset,
        'deltaBasis': deltaBasis.label,
        'deltaSince': deltaSince,
        'targetConnectionId': targetConnectionId,
        'targetTable': targetTable,
        'pullIntervalSeconds':
            schedule == SchedulePreset.custom ? customSeconds : schedule.seconds,
        'mappings': [
          for (final m in mappings)
            if (m.target != null &&
                (m.isConstant || m.source != null))
              m.toJson(),
        ],
      };

  static SchedulePreset _scheduleFromSeconds(int? s) => switch (s) {
        null => SchedulePreset.manual,
        60 => SchedulePreset.every1m,
        300 => SchedulePreset.every5m,
        900 => SchedulePreset.every15m,
        1800 => SchedulePreset.every30m,
        3600 => SchedulePreset.every1h,
        _ => SchedulePreset.custom,
      };

  static int? _customSecondsFor(int? s) {
    if (s == null) return null;
    if (const [60, 300, 900, 1800, 3600].contains(s)) return null;
    return s;
  }

  /// Reconstructs the API path the puller will hit at runtime.
  /// Example: `/ai/extract?type=delta&dataset=employees&change_date=20260101000000`
  String get sourcePath {
    final params = <String>[
      'type=${extractType.value}',
      'dataset=$dataset',
    ];
    if (extractType == ExtractType.delta && deltaSince.isNotEmpty) {
      params.add('${deltaBasis.label}=$deltaSince');
    }
    return '/ai/extract?${params.join('&')}';
  }

  /// Short tag for the flow card chips, e.g. "Delta · change_date".
  String get extractTag {
    if (extractType == ExtractType.full) return 'Full';
    return 'Delta · ${deltaBasis.label}';
  }
}

class OutboundScreen extends StatefulWidget {
  const OutboundScreen({super.key});

  @override
  State<OutboundScreen> createState() => _OutboundScreenState();
}

class _OutboundScreenState extends State<OutboundScreen> {
  List<OutboundFlow> _flows = [];
  List<Connection> _connections = [];
  // Derived from `_connections` on each reload — avoids a linear scan
  // through every card on every rebuild.
  Map<String, String> _connectionNamesById = const {};
  // Tracks which flows are currently running so the card can show a
  // spinner instead of the Run button.
  final Set<String> _running = {};
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
      final results = await Future.wait([
        api.listConnections(),
        api.listOutboundFlows(),
      ]);
      if (!mounted) return;
      setState(() {
        _connections = [
          for (final j in results[0]) Connection.fromJson(j),
        ];
        _connectionNamesById = {
          for (final c in _connections) c.id: c.name,
        };
        _flows = [
          for (final j in results[1]) OutboundFlow.fromJson(j),
        ];
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

  Future<void> _openEditor({OutboundFlow? existing}) async {
    final result = await showDialog<OutboundFlow>(
      context: context,
      builder: (_) => _FlowEditorDialog(
        initial: existing,
        connections: _connections,
      ),
    );
    if (result == null || !mounted) return;
    try {
      final saved = await context
          .read<AppState>()
          .api
          .putOutboundFlow(result.id, result.toJsonPatch());
      if (!mounted) return;
      final updated = OutboundFlow.fromJson(saved);
      setState(() {
        final i = _flows.indexWhere((f) => f.id == updated.id);
        if (i >= 0) {
          _flows[i] = updated;
        } else {
          _flows.add(updated);
        }
      });
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: ${e.message}')),
      );
    }
  }

  Future<void> _deleteFlow(OutboundFlow f) async {
    try {
      await context.read<AppState>().api.deleteOutboundFlow(f.id);
      if (!mounted) return;
      setState(() => _flows.remove(f));
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: ${e.message}')),
      );
    }
  }

  Future<void> _runFlow(OutboundFlow f) async {
    if (_running.contains(f.id)) return;
    setState(() => _running.add(f.id));
    try {
      final event =
          await context.read<AppState>().api.runOutboundFlow(f.id);
      if (!mounted) return;
      final summary = event.status == 'error'
          ? 'Run failed${event.error != null ? ": ${event.error}" : ""}'
          : event.dryRun
              ? 'Dry-run: ${event.rowsScanned} scanned'
              : 'Ran in ${event.durationMs}ms — ${event.rowsScanned} scanned · ${event.rowsUpdated} updated · ${event.rowsFailed} failed';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(summary)),
      );
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Run failed: ${e.message}')),
      );
    } finally {
      if (mounted) setState(() => _running.remove(f.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Outbound'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(20),
          child: Padding(
            padding: EdgeInsets.only(left: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('REST source → SurrealDB target'),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
          FilledButton.icon(
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add flow'),
          ),
          const SizedBox(width: 12),
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
                      for (final f in _flows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _FlowCard(
                            flow: f,
                            sourceName: _connectionName(f.sourceConnectionId),
                            targetName: _connectionName(f.targetConnectionId),
                            running: _running.contains(f.id),
                            onRun: () => _runFlow(f),
                            onEdit: () => _openEditor(existing: f),
                            onDelete: () => _deleteFlow(f),
                            onViewLogs: () => context
                                .read<AppState>()
                                .selectTab(4, jobFilter: f.name),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }

  String _connectionName(String id) =>
      _connectionNamesById[id] ?? (id.isEmpty ? '—' : id);
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
            Text('Couldn\'t load flows',
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

class _FlowCard extends StatelessWidget {
  final OutboundFlow flow;
  final String sourceName;
  final String targetName;
  final bool running;
  final VoidCallback onRun;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onViewLogs;
  const _FlowCard({
    required this.flow,
    required this.sourceName,
    required this.targetName,
    required this.running,
    required this.onRun,
    required this.onEdit,
    required this.onDelete,
    required this.onViewLogs,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        scheme.primary,
                        scheme.primary.withValues(alpha: 0.7),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.25),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.call_made,
                      color: Colors.white, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    flow.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                _ExtractPill(flow: flow),
                const SizedBox(width: 6),
                _SchedulePill(schedule: flow.schedule),
              ],
            ),
            const SizedBox(height: 14),
            LayoutBuilder(builder: (context, c) {
              final narrow = c.maxWidth < 520;
              if (narrow) {
                return Column(
                  children: [
                    _EndpointBlock(
                      label: 'Source',
                      icon: Icons.api,
                      name: sourceName,
                      detail: flow.sourcePath,
                      colors: [
                        scheme.primary,
                        scheme.primary.withValues(alpha: 0.7),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Icon(Icons.south, color: scheme.outline),
                    ),
                    _EndpointBlock(
                      label: 'Target',
                      icon: Icons.storage,
                      name: targetName,
                      detail: 'table: ${flow.targetTable}',
                      colors: [
                        scheme.tertiary,
                        scheme.tertiary.withValues(alpha: 0.7),
                      ],
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(
                    child: _EndpointBlock(
                      label: 'Source',
                      icon: Icons.api,
                      name: sourceName,
                      detail: flow.sourcePath,
                      colors: [
                        scheme.primary,
                        scheme.primary.withValues(alpha: 0.7),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.east, color: scheme.outline),
                  ),
                  Expanded(
                    child: _EndpointBlock(
                      label: 'Target',
                      icon: Icons.storage,
                      name: targetName,
                      detail: 'table: ${flow.targetTable}',
                      colors: [
                        scheme.tertiary,
                        scheme.tertiary.withValues(alpha: 0.7),
                      ],
                    ),
                  ),
                ],
              );
            }),
            if (flow.mappings.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in flow.mappings)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: scheme.secondary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${m.source ?? '?'} → ${m.target ?? '?'}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.secondary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Divider(color: scheme.outlineVariant, height: 1),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: running ? null : onRun,
                  icon: running
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow, size: 18),
                  label: Text(running ? 'Running…' : 'Run'),
                ),
                IconButton(
                  tooltip: 'View logs',
                  icon: const Icon(Icons.history),
                  onPressed: onViewLogs,
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: running ? null : onEdit,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: running ? null : onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Gradient-backed endpoint block — source uses primary blue, target uses
/// tertiary amber. White text on top of the gradient for high-contrast read.
class _EndpointBlock extends StatelessWidget {
  final String label;
  final IconData icon;
  final String name;
  final String detail;
  final List<Color> colors;
  const _EndpointBlock({
    required this.label,
    required this.icon,
    required this.name,
    required this.detail,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.20),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            detail,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Tag showing Full vs Delta and (for delta) which basis column. Full is
/// muted; delta uses the tertiary amber so it stands out as the more
/// dynamic mode.
class _ExtractPill extends StatelessWidget {
  final OutboundFlow flow;
  const _ExtractPill({required this.flow});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isFull = flow.extractType == ExtractType.full;
    final color = isFull ? scheme.outline : scheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isFull ? Icons.download_for_offline : Icons.compare_arrows,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            flow.extractTag,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

/// Schedule chip with a soft tint — manual is muted, scheduled is emerald.
class _SchedulePill extends StatelessWidget {
  final SchedulePreset schedule;
  const _SchedulePill({required this.schedule});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isManual = schedule == SchedulePreset.manual;
    final color = isManual ? scheme.outline : scheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isManual ? Icons.pan_tool_alt : Icons.schedule,
              size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            schedule.chipLabel,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Editor dialog — now backed by live gateway probes
// ─────────────────────────────────────────────────────────────

class _FlowEditorDialog extends StatefulWidget {
  final OutboundFlow? initial;
  final List<Connection> connections;
  const _FlowEditorDialog({this.initial, required this.connections});

  @override
  State<_FlowEditorDialog> createState() => _FlowEditorDialogState();
}

class _FlowEditorDialogState extends State<_FlowEditorDialog> {
  static const _kNewTableSentinel = '__new__';

  late GatewayApi _api;
  late String? _sourceConnId;
  late String? _targetConnId;
  late SchedulePreset _schedule;
  late final TextEditingController _name;
  late final TextEditingController _customMinutes;

  // Source-side extract config — see [OutboundFlow] for the model.
  late ExtractType _extractType;
  // `_dataset` is the dropdown selection; `_kCustomDataset` means "custom
  // name supplied via [_customDataset]".
  static const _kCustomDataset = '__custom__';
  late String? _dataset;
  late final TextEditingController _customDataset;
  late DeltaBasis _deltaBasis;
  late final TextEditingController _deltaSince;

  String? _selectedTable;
  final TextEditingController _newTable = TextEditingController();
  late List<FieldMapping> _mappings;

  // Live data — populated by gateway probes.
  List<String> _tables = [];
  List<String> _sourceFields = [];
  List<String> _targetFields = [];
  // Subset of [_targetFields] that the target schema marks as required
  // (non-`option<…>`, no DEFAULT). Empty for SCHEMALESS tables.
  List<String> _requiredTargetFields = const [];
  // Datasets discovered by probing the source REST API (envelope keys).
  // Null until the first probe has either succeeded or failed; falls back
  // to [knownDatasets] in the dropdown until then.
  List<String>? _datasets;
  bool _loadingDatasets = false;
  // Tells the UI whether the dataset dropdown is showing the live list
  // (true) or the baked-in defaults (false, because the probe failed or
  // hasn't run yet).
  bool _datasetsAreLive = false;
  bool _loadingTables = false;
  bool _loadingSourceFields = false;
  bool _loadingTargetFields = false;
  String? _loadError;

  // Filtered once in initState; widget.connections is final for the
  // dialog's lifetime so we don't need to re-filter on every build.
  late final List<Connection> _restConnections;
  late final List<Connection> _surrealConnections;

  Connection? get _targetConnection {
    if (_targetConnId == null) return null;
    for (final c in widget.connections) {
      if (c.id == _targetConnId) return c;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _api = context.read<AppState>().api;
    _restConnections = widget.connections
        .where((c) =>
            c.type == ConnectionType.rest || c.type == ConnectionType.odata)
        .toList(growable: false);
    _surrealConnections = widget.connections
        .where((c) => c.type == ConnectionType.surreal)
        .toList(growable: false);
    _sourceConnId = i?.sourceConnectionId ??
        (_restConnections.isNotEmpty ? _restConnections.first.id : null);
    _targetConnId = i?.targetConnectionId ??
        (_surrealConnections.isNotEmpty ? _surrealConnections.first.id : null);
    _schedule = i?.schedule ?? SchedulePreset.manual;
    _name = TextEditingController(text: i?.name ?? '');
    _extractType = i?.extractType ?? ExtractType.full;
    _deltaBasis = i?.deltaBasis ?? DeltaBasis.changeDate;
    _deltaSince = TextEditingController(text: i?.deltaSince ?? '');
    final initialDataset = i?.dataset ?? '';
    if (initialDataset.isEmpty) {
      _dataset = null;
      _customDataset = TextEditingController();
    } else if (knownDatasets.contains(initialDataset)) {
      _dataset = initialDataset;
      _customDataset = TextEditingController();
    } else {
      _dataset = _kCustomDataset;
      _customDataset = TextEditingController(text: initialDataset);
    }
    _selectedTable = i?.targetTable;
    _mappings = [
      for (final m in (i?.mappings ?? const <FieldMapping>[]))
        FieldMapping(
          source: m.source,
          target: m.target,
          isConstant: m.isConstant,
          constantValue: m.constantValue,
        ),
    ];
    _customMinutes = TextEditingController(
      text: i?.customSeconds != null
          ? (i!.customSeconds! ~/ 60).toString()
          : '',
    );

    // Kick off the table + dataset probes immediately so the dropdowns are
    // populated by the time the user starts interacting with them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTables();
      _loadDatasets();
      if (_effectiveDataset.isNotEmpty) _loadSourceFields();
      if (_selectedTable != null &&
          _selectedTable != _kNewTableSentinel) {
        _loadTargetFields();
      }
    });
  }

  /// Discover the source API's datasets and use them in the dropdown
  /// instead of the hardcoded fallback list. Re-fires whenever the source
  /// connection changes. Failure is silent — we just keep the
  /// [knownDatasets] fallback so the editor is never blocked.
  Future<void> _loadDatasets() async {
    final connId = _sourceConnId;
    if (connId == null) {
      setState(() {
        _datasets = null;
        _datasetsAreLive = false;
        _loadingDatasets = false;
      });
      return;
    }
    setState(() => _loadingDatasets = true);
    try {
      final list = await _api.listConnectionDatasets(connId);
      if (!mounted) return;
      // Build a deduplicated, sorted URL-param list. If the probe
      // returned nothing we drop back to [knownDatasets] so the dropdown
      // still has something useful.
      final names = <String>{
        for (final d in list)
          if ((d['urlParam'] ?? '').isNotEmpty) d['urlParam']!,
      }.toList()
        ..sort();
      setState(() {
        _datasets = names.isEmpty ? null : names;
        _datasetsAreLive = names.isNotEmpty;
        _loadingDatasets = false;
      });
    } on GatewayException {
      // Couldn't reach the gateway / source — keep showing the defaults.
      if (!mounted) return;
      setState(() {
        _datasets = null;
        _datasetsAreLive = false;
        _loadingDatasets = false;
      });
    }
  }

  /// The list the dataset dropdown should actually offer right now: live
  /// names if we have them, baked-in defaults otherwise. Always includes
  /// the existing selection if it isn't in the list, so editing an old
  /// flow with a non-standard dataset name doesn't lose the value.
  List<String> get _effectiveDatasetOptions {
    final base = _datasets ?? knownDatasets;
    final picked = _dataset;
    if (picked != null &&
        picked != _kCustomDataset &&
        !base.contains(picked)) {
      return [...base, picked]..sort();
    }
    return base;
  }

  @override
  void dispose() {
    _name.dispose();
    _customDataset.dispose();
    _deltaSince.dispose();
    _newTable.dispose();
    _customMinutes.dispose();
    super.dispose();
  }

  /// Resolves the dataset name from the dropdown + custom field combo.
  String get _effectiveDataset {
    if (_dataset == _kCustomDataset) return _customDataset.text.trim();
    return _dataset ?? '';
  }

  Future<void> _loadTables() async {
    final target = _targetConnection;
    if (target == null) {
      setState(() {
        _tables = [];
        _loadingTables = false;
        _loadError = 'Pick a target connection to load tables';
      });
      return;
    }
    setState(() {
      _loadingTables = true;
      _loadError = null;
    });
    try {
      final list = await _api.listSurrealTables(connectionId: target.id);
      if (!mounted) return;
      setState(() {
        _tables = list;
        _loadingTables = false;
        // Surface an existing-selection that the live list doesn't include.
        if (_selectedTable != null &&
            _selectedTable != _kNewTableSentinel &&
            !_tables.contains(_selectedTable)) {
          _tables = [..._tables, _selectedTable!];
        }
      });
    } on GatewayException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Tables: ${e.message}';
        _loadingTables = false;
      });
    }
  }

  Future<void> _loadSourceFields() async {
    final dataset = _effectiveDataset;
    final connId = _sourceConnId;
    if (dataset.isEmpty || connId == null) {
      setState(() => _sourceFields = []);
      return;
    }
    setState(() {
      _loadingSourceFields = true;
      _loadError = null;
    });
    try {
      final fields = await _api.probeSourceFields(
        connId,
        dataset,
        type: _extractType.value,
        deltaBasis: _deltaBasis.label,
        deltaSince: _deltaSince.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _sourceFields = fields;
        _loadingSourceFields = false;
      });
    } on GatewayException catch (e) {
      if (!mounted) return;
      setState(() {
        _sourceFields = [];
        _loadingSourceFields = false;
        _loadError = 'Source: ${e.message}';
      });
    }
  }

  Future<void> _loadTargetFields() async {
    final t = _selectedTable;
    if (t == null || t == _kNewTableSentinel) {
      setState(() {
        _targetFields = [];
        _requiredTargetFields = const [];
      });
      return;
    }
    setState(() => _loadingTargetFields = true);
    final target = _targetConnection;
    if (target == null) {
      setState(() {
        _targetFields = [];
        _requiredTargetFields = const [];
        _loadingTargetFields = false;
      });
      return;
    }
    setState(() => _loadError = null);
    try {
      final info =
          await _api.getSurrealTableInfo(t, connectionId: target.id);
      if (!mounted) return;
      setState(() {
        _targetFields = info.fields;
        // Required fields are only meaningful when the field list came
        // from DEFINE FIELD statements — sampled SCHEMALESS tables have
        // no formal required-ness to enforce.
        _requiredTargetFields =
            info.fieldSource == 'schema' ? info.requiredFields : const [];
        _loadingTargetFields = false;
      });
    } on GatewayException catch (e) {
      if (!mounted) return;
      setState(() {
        _targetFields = [];
        _requiredTargetFields = const [];
        _loadingTargetFields = false;
        _loadError = 'Target: ${e.message}';
      });
    }
  }

  /// Required target fields that aren't on the left side of any mapping —
  /// these are the ones Surreal will reject as NONE if the user runs the
  /// flow as-is. Shown as a red warning row in the mappings section.
  List<String> get _unmappedRequiredFields {
    if (_requiredTargetFields.isEmpty) return const [];
    final mapped = <String>{
      for (final m in _mappings)
        if (m.target != null) m.target!,
    };
    return [
      for (final r in _requiredTargetFields)
        if (!mapped.contains(r)) r,
    ];
  }

  String? get _effectiveTable {
    if (_selectedTable == _kNewTableSentinel) {
      final t = _newTable.text.trim();
      return t.isEmpty ? null : t;
    }
    return _selectedTable;
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      _effectiveDataset.isNotEmpty &&
      (_effectiveTable?.isNotEmpty ?? false) &&
      (_extractType == ExtractType.full || _deltaSince.text.trim().isNotEmpty);

  /// URL that the runtime will hit (preview only).
  String get _previewPath {
    final ds = _effectiveDataset;
    if (ds.isEmpty) return '/ai/extract?type=${_extractType.value}';
    final params = ['type=${_extractType.value}', 'dataset=$ds'];
    if (_extractType == ExtractType.delta) {
      final since = _deltaSince.text.trim();
      if (since.isNotEmpty) params.add('${_deltaBasis.label}=$since');
    }
    return '/ai/extract?${params.join('&')}';
  }

  Future<void> _save() async {
    if (!_canSave) return;
    // If the user picked "Create new table…", DEFINE it before closing.
    if (_selectedTable == _kNewTableSentinel) {
      final target = _targetConnection;
      if (target == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Pick a target connection before creating')),
        );
        return;
      }
      try {
        await _api.defineSurrealTable(
          _newTable.text.trim(),
          connectionId: target.id,
        );
      } on GatewayException catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Create table failed: ${e.message}')),
        );
        return;
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(OutboundFlow(
      id: widget.initial?.id ??
          'flow-${DateTime.now().microsecondsSinceEpoch}',
      name: _name.text.trim(),
      sourceConnectionId: _sourceConnId ?? '',
      extractType: _extractType,
      dataset: _effectiveDataset,
      deltaBasis: _deltaBasis,
      deltaSince: _extractType == ExtractType.delta
          ? _deltaSince.text.trim()
          : '',
      targetConnectionId: _targetConnId ?? '',
      targetTable: _effectiveTable!,
      schedule: _schedule,
      customSeconds: _schedule == SchedulePreset.custom
          ? (int.tryParse(_customMinutes.text.trim()) ?? 0) * 60
          : null,
      mappings: _mappings
          // Keep both source-driven and constant mappings — drop only the
          // half-finished rows (no target picked, or source-driven with
          // no source field).
          .where((m) =>
              m.target != null &&
              (m.isConstant || m.source != null))
          .map((m) => FieldMapping(
                source: m.source,
                target: m.target,
                isConstant: m.isConstant,
                constantValue: m.constantValue,
              ))
          .toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingDialog(
      maxWidth: 760,
      hero: DialogHero(
        icon: Icons.call_made,
        title: widget.initial == null
            ? 'New outbound flow'
            : 'Edit outbound flow',
        subtitle: 'REST → SurrealDB',
        colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
                    if (_loadError != null) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber,
                                color: scheme.onErrorContainer, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _loadError!,
                                style: TextStyle(
                                    color: scheme.onErrorContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    DialogSection(
                      icon: Icons.label_outline,
                      label: 'Flow basics',
                      accent: scheme.primary,
                      children: [
                        TextField(
                          controller: _name,
                          decoration: const InputDecoration(
                            labelText: 'Flow name',
                            hintText: 'e.g. employees',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<SchedulePreset>(
                                value: _schedule,
                                decoration: const InputDecoration(
                                  labelText: 'Outbound schedule',
                                  prefixIcon: Icon(Icons.schedule),
                                ),
                                items: [
                                  for (final s in SchedulePreset.values)
                                    DropdownMenuItem(
                                        value: s, child: Text(s.label)),
                                ],
                                onChanged: (v) => setState(
                                    () => _schedule = v ?? _schedule),
                              ),
                            ),
                            if (_schedule == SchedulePreset.custom) ...[
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 140,
                                child: TextField(
                                  controller: _customMinutes,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Minutes',
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                    DialogSection(
                      icon: Icons.api,
                      label: 'Source · REST',
                      accent: scheme.primary,
                      children: [
                        DropdownButtonFormField<String>(
                          value: _sourceConnId,
                          decoration:
                              const InputDecoration(labelText: 'Connection'),
                          items: [
                            for (final c in _restConnections)
                              DropdownMenuItem(
                                  value: c.id, child: Text(c.name)),
                          ],
                          onChanged: (v) {
                            setState(() => _sourceConnId = v ?? _sourceConnId);
                            // Re-probe — the new connection may expose a
                            // different set of datasets (or be unreachable).
                            _loadDatasets();
                            if (_effectiveDataset.isNotEmpty) {
                              _loadSourceFields();
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        // Extract type — Full / Delta segmented buttons.
                        SegmentedButton<ExtractType>(
                          segments: [
                            for (final t in ExtractType.values)
                              ButtonSegment(
                                value: t,
                                label: Text(t.label),
                                icon: Icon(t == ExtractType.full
                                    ? Icons.download_for_offline
                                    : Icons.compare_arrows),
                              ),
                          ],
                          selected: {_extractType},
                          onSelectionChanged: (s) =>
                              setState(() => _extractType = s.first),
                        ),
                        const SizedBox(height: 12),
                        // Dataset dropdown. Options come from the live API
                        // probe (preferred) and fall back to the baked-in
                        // [knownDatasets] list. Existing flow values that
                        // aren't in either list still appear (via
                        // [_effectiveDatasetOptions]) so editing an old
                        // record doesn't silently drop the selection.
                        DropdownButtonFormField<String>(
                          value: _dataset,
                          decoration: InputDecoration(
                            labelText: 'Dataset',
                            helperText: _loadingDatasets
                                ? 'Loading datasets from source…'
                                : (_datasetsAreLive
                                    ? '${_effectiveDatasetOptions.length} dataset(s) from source API'
                                    : 'Defaults shown — couldn\'t reach source'),
                          ),
                          items: [
                            for (final d in _effectiveDatasetOptions)
                              DropdownMenuItem(value: d, child: Text(d)),
                            const DropdownMenuItem(
                              value: _kCustomDataset,
                              child: Row(
                                children: [
                                  Icon(Icons.add, size: 18),
                                  SizedBox(width: 8),
                                  Text('Custom…'),
                                ],
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => _dataset = v);
                            _loadSourceFields();
                          },
                        ),
                        if (_dataset == _kCustomDataset) ...[
                          const SizedBox(height: 8),
                          TextField(
                            controller: _customDataset,
                            decoration: const InputDecoration(
                              labelText: 'Custom dataset',
                              prefixIcon: Icon(Icons.add_box_outlined),
                            ),
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) => _loadSourceFields(),
                          ),
                        ],
                        if (_extractType == ExtractType.delta) ...[
                          const SizedBox(height: 12),
                          SegmentedButton<DeltaBasis>(
                            segments: [
                              for (final b in DeltaBasis.values)
                                ButtonSegment(
                                  value: b,
                                  label: Text(b.prettyLabel),
                                ),
                            ],
                            selected: {_deltaBasis},
                            onSelectionChanged: (s) =>
                                setState(() => _deltaBasis = s.first),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _deltaSince,
                            decoration: InputDecoration(
                              labelText: 'Since (${_deltaBasis.label})',
                              hintText: 'YYYYMMDDhhmmss',
                              helperText:
                                  'SAP date format. Scheduled runs auto-advance this to the previous run\'s timestamp.',
                              prefixIcon: const Icon(Icons.event),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                        const SizedBox(height: 12),
                        // URL preview chip — shows the runtime request shape.
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: scheme.primary
                                    .withValues(alpha: 0.20)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.link,
                                  size: 16, color: scheme.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SelectableText(
                                  _previewPath,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: scheme.primary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Probe source for fields',
                                icon: _loadingSourceFields
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.refresh, size: 18),
                                onPressed: _loadingSourceFields
                                    ? null
                                    : _loadSourceFields,
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        _FieldsHint(
                          label: 'Source fields',
                          fields: _sourceFields,
                          loading: _loadingSourceFields,
                          accent: scheme.primary,
                          emptyHint:
                              'Pick a dataset and tap refresh to detect available fields',
                        ),
                      ],
                    ),
                    DialogSection(
                      icon: Icons.storage,
                      label: 'Target · SurrealDB',
                      accent: scheme.tertiary,
                      children: [
                        DropdownButtonFormField<String>(
                          value: _targetConnId,
                          decoration:
                              const InputDecoration(labelText: 'Connection'),
                          items: [
                            for (final c in _surrealConnections)
                              DropdownMenuItem(
                                  value: c.id, child: Text(c.name)),
                          ],
                          onChanged: (v) {
                            setState(() => _targetConnId = v ?? _targetConnId);
                            // Different connection means a different
                            // (namespace, database) — re-probe.
                            _loadTables();
                            _loadTargetFields();
                          },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          value: _selectedTable,
                          decoration: InputDecoration(
                            labelText: 'Table',
                            helperText: _loadingTables
                                ? (_targetConnection != null
                                    ? 'Loading tables from ${_targetConnection!.namespace}/${_targetConnection!.database}…'
                                    : 'Loading tables…')
                                : 'Pick an existing Surreal table or create a new one',
                            suffixIcon: _loadingTables
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2)),
                                  )
                                : IconButton(
                                    icon: const Icon(Icons.refresh, size: 18),
                                    onPressed: _loadTables,
                                  ),
                          ),
                          items: [
                            for (final t in _tables)
                              DropdownMenuItem(value: t, child: Text(t)),
                            const DropdownMenuItem(
                              value: _kNewTableSentinel,
                              child: Row(
                                children: [
                                  Icon(Icons.add, size: 18),
                                  SizedBox(width: 8),
                                  Text('Create new table…'),
                                ],
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => _selectedTable = v);
                            _loadTargetFields();
                          },
                        ),
                        if (_selectedTable == _kNewTableSentinel) ...[
                          const SizedBox(height: 8),
                          TextField(
                            controller: _newTable,
                            autofocus: true,
                            decoration: const InputDecoration(
                              labelText: 'New table name',
                              hintText: 'e.g. employee_archive',
                              prefixIcon: Icon(Icons.add_box_outlined),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                        const SizedBox(height: 8),
                        _FieldsHint(
                          label: 'Target fields',
                          fields: _targetFields,
                          loading: _loadingTargetFields,
                          accent: scheme.tertiary,
                          emptyHint:
                              'Pick an existing table to see its fields',
                        ),
                      ],
                    ),
                    DialogSection(
                      icon: Icons.swap_horiz,
                      label: 'Field mapping',
                      accent: scheme.secondary,
                      children: [
                        Text(
                          'Map each source field to a target field. Unmapped source fields are written through unchanged; unmapped target fields stay null.',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.outline),
                        ),
                        const SizedBox(height: 12),
                        if (_mappings.isEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.info_outline,
                                    color: scheme.outline, size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  'No field mappings yet.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: scheme.outline),
                                ),
                              ],
                            ),
                          ),
                        for (var i = 0; i < _mappings.length; i++) ...[
                          _MappingRow(
                            mapping: _mappings[i],
                            sourceOptions: _sourceFields,
                            targetOptions: _targetFields,
                            sourceAccent: scheme.primary,
                            targetAccent: scheme.tertiary,
                            onChanged: () => setState(() {}),
                            onDelete: () =>
                                setState(() => _mappings.removeAt(i)),
                          ),
                          const SizedBox(height: 8),
                        ],
                        // Schema pre-flight: if the target table has
                        // SCHEMAFULL required fields (no `option<…>`, no
                        // DEFAULT) that nothing's mapped to, Surreal will
                        // reject every row with a coercion error mid-run.
                        // Flag it now so the user can either add a mapping
                        // or a constant default before clicking Run.
                        if (_unmappedRequiredFields.isNotEmpty) ...[
                          _RequiredFieldsWarning(
                            fields: _unmappedRequiredFields,
                            onAddConstant: (field) => setState(() {
                              _mappings.add(FieldMapping(
                                target: field,
                                isConstant: true,
                              ));
                            }),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => setState(
                                () => _mappings.add(FieldMapping())),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Add mapping'),
                          ),
                        ),
                      ],
                    ),
          ],
        ),
      ),
      footer: DialogFooter(
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _canSave ? _save : null,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _MappingRow extends StatefulWidget {
  final FieldMapping mapping;
  final List<String> sourceOptions;
  final List<String> targetOptions;
  final Color sourceAccent;
  final Color targetAccent;
  final VoidCallback onChanged;
  final VoidCallback onDelete;
  const _MappingRow({
    required this.mapping,
    required this.sourceOptions,
    required this.targetOptions,
    required this.sourceAccent,
    required this.targetAccent,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  State<_MappingRow> createState() => _MappingRowState();
}

class _MappingRowState extends State<_MappingRow> {
  late final TextEditingController _constantCtrl;

  @override
  void initState() {
    super.initState();
    _constantCtrl =
        TextEditingController(text: widget.mapping.constantValue);
  }

  @override
  void dispose() {
    _constantCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mapping = widget.mapping;
    final sources = {
      ...widget.sourceOptions,
      if (mapping.source != null) mapping.source!,
    }.toList();
    final targets = {
      ...widget.targetOptions,
      if (mapping.target != null) mapping.target!,
    }.toList();
    // Constant-mode rail uses the tertiary accent to read as "a different
    // kind of input" without colliding with the source/target hue.
    final leftAccent =
        mapping.isConstant ? scheme.tertiary : widget.sourceAccent;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 36,
            decoration: BoxDecoration(
              color: leftAccent,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 4),
          // Mode toggle — flip between "pull from source field" and
          // "write a literal value".
          PopupMenuButton<bool>(
            tooltip: mapping.isConstant
                ? 'Constant value · click to switch'
                : 'Source field · click to switch',
            icon: Icon(
              mapping.isConstant ? Icons.label_outline : Icons.input,
              size: 20,
              color: leftAccent,
            ),
            onSelected: (asConstant) {
              setState(() {
                mapping.isConstant = asConstant;
                if (asConstant) {
                  mapping.source = null;
                } else {
                  mapping.constantValue = '';
                  _constantCtrl.text = '';
                }
              });
              widget.onChanged();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: false,
                child: ListTile(
                  leading: Icon(Icons.input),
                  title: Text('Source field'),
                  subtitle: Text('Pull value from each row'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: true,
                child: ListTile(
                  leading: Icon(Icons.label_outline),
                  title: Text('Constant value'),
                  subtitle: Text('Same literal text every row'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
          Expanded(
            child: mapping.isConstant
                ? TextField(
                    controller: _constantCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Constant value',
                      hintText: 'literal text written to every row',
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                    ),
                    onChanged: (v) {
                      mapping.constantValue = v;
                      widget.onChanged();
                    },
                  )
                : DropdownButtonFormField<String>(
                    value: mapping.source,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Source field',
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                    ),
                    items: [
                      for (final s in sources)
                        DropdownMenuItem(value: s, child: Text(s)),
                    ],
                    onChanged: (v) {
                      setState(() => mapping.source = v);
                      widget.onChanged();
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.east,
                color: scheme.outline, size: 18),
          ),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: mapping.target,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Target field',
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
              ),
              items: [
                for (final t in targets)
                  DropdownMenuItem(value: t, child: Text(t)),
              ],
              onChanged: (v) {
                setState(() => mapping.target = v);
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 5,
            height: 36,
            decoration: BoxDecoration(
              color: widget.targetAccent,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          IconButton(
            tooltip: 'Remove mapping',
            icon: const Icon(Icons.close, size: 18),
            onPressed: widget.onDelete,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _FieldsHint extends StatelessWidget {
  final String label;
  final List<String> fields;
  final bool loading;
  final Color accent;
  final String emptyHint;
  const _FieldsHint({
    required this.label,
    required this.fields,
    required this.accent,
    required this.emptyHint,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (loading) {
      return Row(
        children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent)),
          const SizedBox(width: 8),
          Text('Probing $label…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                  )),
        ],
      );
    }
    if (fields.isEmpty) {
      return Text(
        emptyHint,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.outline,
              fontStyle: FontStyle.italic,
            ),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('$label:',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                )),
        for (final f in fields)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(f,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    )),
          ),
      ],
    );
  }
}

/// Banner shown above "Add mapping" when the target table has SCHEMAFULL
/// required fields that nothing's mapped to yet. Lets the user either map
/// a source field (via the regular Add mapping flow) or jump straight to
/// adding a constant-value mapping for that specific field.
class _RequiredFieldsWarning extends StatelessWidget {
  final List<String> fields;
  final void Function(String field) onAddConstant;
  const _RequiredFieldsWarning({
    required this.fields,
    required this.onAddConstant,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = fields.length == 1 ? '' : 's';
    final is_ = fields.length == 1 ? 'is' : 'are';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: scheme.error, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${fields.length} required target field$s $is_ not mapped',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Text(
              'The target table\'s schema marks these as required (no '
              'option<…>, no DEFAULT). Without a mapping or constant '
              'value Surreal will reject every row with a NONE coercion '
              'error.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer.withValues(alpha: 0.85),
                  ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in fields)
                  ActionChip(
                    avatar: const Icon(Icons.label_outline, size: 14),
                    label: Text(f),
                    tooltip: 'Add a constant-value mapping for "$f"',
                    onPressed: () => onAddConstant(f),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
