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
import 'outbound_screen.dart'
    show FieldMapping, SchedulePreset, SchedulePresetX;

// ─────────────────────────────────────────────────────────────
// Inbound flow model — SurrealDB → SAP OData V2.
// Triggered when [sourceTable] has rows matching [triggerFilter];
// each row is POSTed to [targetEntity] on the target connection and the
// SAP-returned key (e.g. REINR) is written back to [writeBackField].
// ─────────────────────────────────────────────────────────────

class InboundFlow {
  String id;
  String name;
  String sourceConnectionId;
  String sourceTable;
  Map<String, String> triggerFilter;
  String targetConnectionId;
  String targetEntity;
  String writeBackField;
  SchedulePreset schedule;
  int? customSeconds;
  List<FieldMapping> mappings;

  InboundFlow({
    required this.id,
    required this.name,
    required this.sourceConnectionId,
    required this.sourceTable,
    Map<String, String>? triggerFilter,
    required this.targetConnectionId,
    this.targetEntity = '',
    this.writeBackField = '',
    this.schedule = SchedulePreset.manual,
    this.customSeconds,
    List<FieldMapping>? mappings,
  })  : triggerFilter = triggerFilter ?? {},
        mappings = mappings ?? [];

  factory InboundFlow.fromJson(Map<String, dynamic> j) => InboundFlow(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        sourceConnectionId: j['sourceConnectionId'] as String? ?? '',
        sourceTable: j['sourceTable'] as String? ?? '',
        triggerFilter: (j['triggerFilter'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            {},
        targetConnectionId: j['targetConnectionId'] as String? ?? '',
        targetEntity: j['targetEntity'] as String? ?? '',
        writeBackField: j['writeBackField'] as String? ?? '',
        schedule:
            _scheduleFromSeconds((j['pushIntervalSeconds'] as num?)?.toInt()),
        customSeconds:
            _customSecondsFor((j['pushIntervalSeconds'] as num?)?.toInt()),
        mappings: [
          for (final m in (j['mappings'] as List? ?? []))
            FieldMapping(
              source: (m as Map)['source']?.toString(),
              target: m['target']?.toString(),
            ),
        ],
      );

  Map<String, dynamic> toJsonPatch() => {
        'name': name,
        'sourceConnectionId': sourceConnectionId,
        'sourceTable': sourceTable,
        'triggerFilter': triggerFilter,
        'targetConnectionId': targetConnectionId,
        'targetEntity': targetEntity,
        'writeBackField': writeBackField,
        'pushIntervalSeconds':
            schedule == SchedulePreset.custom ? customSeconds : schedule.seconds,
        'mappings': [
          for (final m in mappings)
            if (m.source != null && m.target != null)
              {'source': m.source, 'target': m.target},
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

  String get triggerSummary {
    if (triggerFilter.isEmpty) return 'no filter';
    return triggerFilter.entries
        .map((e) => '${e.key}=${e.value}')
        .join(' · ');
  }
}

// ─────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────

class InboundScreen extends StatefulWidget {
  const InboundScreen({super.key});

  @override
  State<InboundScreen> createState() => _InboundScreenState();
}

class _InboundScreenState extends State<InboundScreen> {
  List<InboundFlow> _flows = [];
  List<Connection> _connections = [];
  // Derived from `_connections` on each reload — avoids a linear scan
  // through every card on every rebuild.
  Map<String, String> _connectionNamesById = const {};
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
        api.listInboundFlows(),
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
          for (final j in results[1]) InboundFlow.fromJson(j),
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

  Future<void> _openEditor({InboundFlow? existing}) async {
    final result = await showDialog<InboundFlow>(
      context: context,
      builder: (_) => _InboundEditorDialog(
        initial: existing,
        connections: _connections,
      ),
    );
    if (result == null || !mounted) return;
    try {
      final saved = await context
          .read<AppState>()
          .api
          .putInboundFlow(result.id, result.toJsonPatch());
      if (!mounted) return;
      final updated = InboundFlow.fromJson(saved);
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

  Future<void> _deleteFlow(InboundFlow f) async {
    try {
      await context.read<AppState>().api.deleteInboundFlow(f.id);
      if (!mounted) return;
      setState(() => _flows.remove(f));
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: ${e.message}')),
      );
    }
  }

  String _connectionName(String id) =>
      _connectionNamesById[id] ?? (id.isEmpty ? '—' : id);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inbound'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(20),
          child: Padding(
            padding: EdgeInsets.only(left: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('SurrealDB source → SAP OData V2 target'),
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
              : _flows.isEmpty
                  ? _EmptyState(scheme: scheme, onAdd: () => _openEditor())
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
}

class _EmptyState extends StatelessWidget {
  final ColorScheme scheme;
  final VoidCallback onAdd;
  const _EmptyState({required this.scheme, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.primary,
                scheme.tertiary.withValues(alpha: 0.85),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.25),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.call_received,
                    color: Colors.white, size: 28),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('No inbound flows yet',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        )),
                    const SizedBox(height: 4),
                    Text(
                      'Add a flow to push approved SurrealDB records into SAP via OData V2 with SSO. SAP returns the key (e.g. REINR), which is written back to the originating record.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add inbound flow'),
          ),
        ),
      ],
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
  final InboundFlow flow;
  final String sourceName;
  final String targetName;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onViewLogs;
  const _FlowCard({
    required this.flow,
    required this.sourceName,
    required this.targetName,
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
                        scheme.tertiary,
                        scheme.tertiary.withValues(alpha: 0.7),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.tertiary.withValues(alpha: 0.25),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.call_received,
                      color: Colors.white, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(flow.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                ),
                _SchedulePill(schedule: flow.schedule),
              ],
            ),
            const SizedBox(height: 14),
            LayoutBuilder(builder: (context, c) {
              final narrow = c.maxWidth < 520;
              final source = _EndpointBlock(
                label: 'Source',
                icon: Icons.storage,
                name: sourceName,
                detail: 'table: ${flow.sourceTable.isEmpty ? "—" : flow.sourceTable}',
                colors: [scheme.tertiary, scheme.tertiary.withValues(alpha: 0.7)],
              );
              final target = _EndpointBlock(
                label: 'Target',
                icon: Icons.business_center,
                name: targetName,
                detail: 'entity: ${flow.targetEntity.isEmpty ? "—" : flow.targetEntity}',
                colors: [scheme.primary, scheme.primary.withValues(alpha: 0.7)],
              );
              if (narrow) {
                return Column(
                  children: [
                    source,
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Icon(Icons.south, color: scheme.outline),
                    ),
                    target,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: source),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.east, color: scheme.outline),
                  ),
                  Expanded(child: target),
                ],
              );
            }),
            if (flow.triggerFilter.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Icon(Icons.filter_alt_outlined,
                        size: 14, color: scheme.outline),
                  ),
                  for (final e in flow.triggerFilter.entries)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: scheme.secondary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('${e.key} = ${e.value}',
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: scheme.secondary,
                                    fontWeight: FontWeight.w600,
                                  )),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Divider(color: scheme.outlineVariant, height: 1),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Tooltip(
                  message: 'Inbound runs are scheduler-only until the '
                      'OData/SSO target is wired.',
                  child: TextButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Run'),
                  ),
                ),
                IconButton(
                  tooltip: 'View logs',
                  icon: const Icon(Icons.history),
                  onPressed: onViewLogs,
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: onEdit,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

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
              Text(label.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  )),
            ],
          ),
          const SizedBox(height: 8),
          Text(name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis),
          Text(detail,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

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
          Text(schedule.chipLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  )),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Editor dialog
// ─────────────────────────────────────────────────────────────

class _InboundEditorDialog extends StatefulWidget {
  final InboundFlow? initial;
  final List<Connection> connections;
  const _InboundEditorDialog({this.initial, required this.connections});

  @override
  State<_InboundEditorDialog> createState() => _InboundEditorDialogState();
}

class _InboundEditorDialogState extends State<_InboundEditorDialog> {
  late GatewayApi _api;
  late String? _sourceConnId;
  late String? _targetConnId;
  late SchedulePreset _schedule;
  late final TextEditingController _name;
  late final TextEditingController _customMinutes;
  late final TextEditingController _targetEntity;
  late final TextEditingController _writeBackField;
  late final TextEditingController _filterKey;
  late final TextEditingController _filterValue;

  String? _selectedTable;
  late List<FieldMapping> _mappings;

  List<String> _tables = [];
  List<String> _sourceFields = [];
  bool _loadingTables = false;
  bool _loadingSourceFields = false;
  String? _loadError;

  // Filtered once in initState; widget.connections is final for the
  // dialog's lifetime so we don't need to re-filter on every build.
  late final List<Connection> _surrealConnections;
  late final List<Connection> _restOrOdataConnections;

  Connection? get _sourceConnection {
    if (_sourceConnId == null) return null;
    for (final c in widget.connections) {
      if (c.id == _sourceConnId) return c;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _api = context.read<AppState>().api;
    _surrealConnections = widget.connections
        .where((c) => c.type == ConnectionType.surreal)
        .toList(growable: false);
    _restOrOdataConnections = widget.connections
        .where((c) =>
            c.type == ConnectionType.rest || c.type == ConnectionType.odata)
        .toList(growable: false);
    _sourceConnId = i?.sourceConnectionId ??
        (_surrealConnections.isNotEmpty ? _surrealConnections.first.id : null);
    _targetConnId = i?.targetConnectionId ??
        (_restOrOdataConnections.isNotEmpty
            ? _restOrOdataConnections.first.id
            : null);
    _schedule = i?.schedule ?? SchedulePreset.manual;
    _name = TextEditingController(text: i?.name ?? '');
    _customMinutes = TextEditingController(
      text: i?.customSeconds != null
          ? (i!.customSeconds! ~/ 60).toString()
          : '',
    );
    _targetEntity = TextEditingController(text: i?.targetEntity ?? '');
    _writeBackField = TextEditingController(text: i?.writeBackField ?? '');
    final filter = (i?.triggerFilter.entries.isNotEmpty ?? false)
        ? i!.triggerFilter.entries.first
        : null;
    _filterKey = TextEditingController(text: filter?.key ?? 'status');
    _filterValue = TextEditingController(text: filter?.value ?? 'APPROVED');
    _selectedTable = i?.sourceTable.isEmpty == true ? null : i?.sourceTable;
    _mappings = [
      for (final m in (i?.mappings ?? const <FieldMapping>[]))
        FieldMapping(source: m.source, target: m.target),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadTables();
      if (_selectedTable != null) _loadSourceFields();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _customMinutes.dispose();
    _targetEntity.dispose();
    _writeBackField.dispose();
    _filterKey.dispose();
    _filterValue.dispose();
    super.dispose();
  }

  Future<void> _loadTables() async {
    final src = _sourceConnection;
    if (src == null) {
      setState(() {
        _tables = [];
        _loadingTables = false;
        _loadError = 'Pick a source connection to load tables';
      });
      return;
    }
    setState(() {
      _loadingTables = true;
      _loadError = null;
    });
    try {
      final list = await _api.listSurrealTables(connectionId: src.id);
      if (!mounted) return;
      setState(() {
        _tables = list;
        _loadingTables = false;
        if (_selectedTable != null && !_tables.contains(_selectedTable)) {
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
    final t = _selectedTable;
    final src = _sourceConnection;
    if (t == null || src == null) {
      setState(() => _sourceFields = []);
      return;
    }
    setState(() => _loadingSourceFields = true);
    try {
      final fields =
          await _api.listSurrealTableFields(t, connectionId: src.id);
      if (!mounted) return;
      setState(() {
        _sourceFields = fields;
        _loadingSourceFields = false;
      });
    } on GatewayException catch (_) {
      if (!mounted) return;
      setState(() {
        _sourceFields = [];
        _loadingSourceFields = false;
      });
    }
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      _selectedTable != null &&
      _targetEntity.text.trim().isNotEmpty &&
      _targetConnId != null;

  void _save() {
    if (!_canSave) return;
    final filter = <String, String>{};
    final k = _filterKey.text.trim();
    final v = _filterValue.text.trim();
    if (k.isNotEmpty && v.isNotEmpty) filter[k] = v;
    Navigator.of(context).pop(InboundFlow(
      id: widget.initial?.id ??
          'inbound-${DateTime.now().microsecondsSinceEpoch}',
      name: _name.text.trim(),
      sourceConnectionId: _sourceConnId ?? '',
      sourceTable: _selectedTable!,
      triggerFilter: filter,
      targetConnectionId: _targetConnId ?? '',
      targetEntity: _targetEntity.text.trim(),
      writeBackField: _writeBackField.text.trim(),
      schedule: _schedule,
      customSeconds: _schedule == SchedulePreset.custom
          ? (int.tryParse(_customMinutes.text.trim()) ?? 0) * 60
          : null,
      mappings: _mappings
          .where((m) => m.source != null && m.target != null)
          .map((m) => FieldMapping(source: m.source, target: m.target))
          .toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingDialog(
      maxWidth: 760,
      hero: DialogHero(
        icon: Icons.call_received,
        title: widget.initial == null ? 'New inbound flow' : 'Edit inbound flow',
        subtitle: 'SurrealDB → SAP OData V2',
        colors: [scheme.tertiary, scheme.tertiary.withValues(alpha: 0.7)],
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
                child: Row(children: [
                  Icon(Icons.warning_amber,
                      color: scheme.onErrorContainer, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_loadError!,
                        style: TextStyle(color: scheme.onErrorContainer)),
                  ),
                ]),
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
                    hintText: 'e.g. expense_approvals',
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
                          labelText: 'Inbound schedule',
                          prefixIcon: Icon(Icons.schedule),
                        ),
                        items: [
                          for (final s in SchedulePreset.values)
                            DropdownMenuItem(value: s, child: Text(s.label)),
                        ],
                        onChanged: (v) =>
                            setState(() => _schedule = v ?? _schedule),
                      ),
                    ),
                    if (_schedule == SchedulePreset.custom) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 140,
                        child: TextField(
                          controller: _customMinutes,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Minutes'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            DialogSection(
              icon: Icons.storage,
              label: 'Source · SurrealDB',
              accent: scheme.tertiary,
              children: [
                DropdownButtonFormField<String>(
                  value: _sourceConnId,
                  decoration: const InputDecoration(labelText: 'Connection'),
                  items: [
                    for (final c in _surrealConnections)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) {
                    setState(() => _sourceConnId = v ?? _sourceConnId);
                    _loadTables();
                    _loadSourceFields();
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _selectedTable,
                  decoration: InputDecoration(
                    labelText: 'Table',
                    helperText: _loadingTables
                        ? 'Loading tables…'
                        : 'Pick the source table to scan',
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
                  ],
                  onChanged: (v) {
                    setState(() => _selectedTable = v);
                    _loadSourceFields();
                  },
                ),
                const SizedBox(height: 8),
                _FieldsHint(
                  label: 'Source fields',
                  fields: _sourceFields,
                  loading: _loadingSourceFields,
                  accent: scheme.tertiary,
                  emptyHint: 'Pick a table to see its fields',
                ),
              ],
            ),
            DialogSection(
              icon: Icons.filter_alt_outlined,
              label: 'Trigger filter',
              accent: scheme.secondary,
              children: [
                Text(
                  'Only rows matching this filter will be pushed to SAP. Leave blank to push every row in the table.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                      ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _filterKey,
                        decoration: const InputDecoration(
                          labelText: 'Field',
                          hintText: 'status',
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('='),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _filterValue,
                        decoration: const InputDecoration(
                          labelText: 'Value',
                          hintText: 'APPROVED',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            DialogSection(
              icon: Icons.business_center,
              label: 'Target · SAP OData V2',
              accent: scheme.primary,
              children: [
                DropdownButtonFormField<String>(
                  value: _targetConnId,
                  decoration: const InputDecoration(labelText: 'Connection'),
                  items: [
                    for (final c in _restOrOdataConnections)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) =>
                      setState(() => _targetConnId = v ?? _targetConnId),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _targetEntity,
                  decoration: const InputDecoration(
                    labelText: 'Entity / path',
                    hintText: '/TripSet',
                    helperText:
                        'Where new records are POSTed (e.g. /TripSet for ZTRIP_SRV)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _writeBackField,
                  decoration: const InputDecoration(
                    labelText: 'Write-back field',
                    hintText: 'sap_trip_id',
                    helperText:
                        'Surreal field where the SAP-returned key (e.g. REINR) is written on success',
                  ),
                ),
              ],
            ),
            DialogSection(
              icon: Icons.swap_horiz,
              label: 'Field mapping',
              accent: scheme.secondary,
              children: [
                Text(
                  'Each row is transformed by these rules before POSTing. Surreal field → SAP field.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                      ),
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
                    child: Row(children: [
                      Icon(Icons.info_outline,
                          color: scheme.outline, size: 18),
                      const SizedBox(width: 8),
                      Text('No field mappings yet.',
                          style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                for (var i = 0; i < _mappings.length; i++) ...[
                  _MappingRow(
                    mapping: _mappings[i],
                    sourceOptions: _sourceFields,
                    targetOptions: const [],
                    sourceAccent: scheme.tertiary,
                    targetAccent: scheme.primary,
                    onChanged: () => setState(() {}),
                    onDelete: () =>
                        setState(() => _mappings.removeAt(i)),
                  ),
                  const SizedBox(height: 8),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _mappings.add(FieldMapping())),
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
  // Controllers are owned by State so they survive parent rebuilds (instead
  // of leaking + losing the cursor on every keystroke).
  late final TextEditingController _sourceFreeText;
  late final TextEditingController _targetText;

  @override
  void initState() {
    super.initState();
    _sourceFreeText =
        TextEditingController(text: widget.mapping.source ?? '');
    _targetText = TextEditingController(text: widget.mapping.target ?? '');
  }

  @override
  void dispose() {
    _sourceFreeText.dispose();
    _targetText.dispose();
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
              color: widget.sourceAccent,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: sources.isEmpty
                ? TextField(
                    controller: _sourceFreeText,
                    onChanged: (v) {
                      mapping.source = v.isEmpty ? null : v;
                      widget.onChanged();
                    },
                    decoration: const InputDecoration(
                      labelText: 'Source field',
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                    ),
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
                      mapping.source = v;
                      widget.onChanged();
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.east, color: scheme.outline, size: 18),
          ),
          Expanded(
            child: TextField(
              controller: _targetText,
              onChanged: (v) {
                mapping.target = v.isEmpty ? null : v;
                widget.onChanged();
              },
              decoration: const InputDecoration(
                labelText: 'SAP field',
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
              ),
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
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: accent)),
          const SizedBox(width: 8),
          Text('Probing $label…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                  )),
        ],
      );
    }
    if (fields.isEmpty) {
      return Text(emptyHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.outline,
                fontStyle: FontStyle.italic,
              ));
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
