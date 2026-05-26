import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gateway_api.dart';
import '../models.dart';

class IntegrationScreen extends StatefulWidget {
  const IntegrationScreen({super.key});
  @override
  State<IntegrationScreen> createState() => _IntegrationScreenState();
}

class _IntegrationScreenState extends State<IntegrationScreen> {
  IntegrationConfigView? _config;
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
      final cfg = await context.read<AppState>().api.getIntegrationConfig();
      if (!mounted) return;
      setState(() {
        _config = cfg;
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
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Integration'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.cable), text: 'Connection'),
            Tab(icon: Icon(Icons.compare_arrows), text: 'Mappings'),
            Tab(icon: Icon(Icons.history), text: 'Audit'),
          ]),
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
                ? Center(child: Text('Failed to load: $_error'))
                : TabBarView(
                    children: [
                      _ConnectionTab(
                          config: _config!, onChanged: _reload),
                      _MappingsTab(
                          config: _config!, onChanged: _reload),
                      const _AuditTab(),
                    ],
                  ),
      ),
    );
  }
}

class _ConnectionTab extends StatefulWidget {
  final IntegrationConfigView config;
  final Future<void> Function() onChanged;
  const _ConnectionTab({required this.config, required this.onChanged});

  @override
  State<_ConnectionTab> createState() => _ConnectionTabState();
}

class _ConnectionTabState extends State<_ConnectionTab> {
  late final TextEditingController _endpoint;
  late final TextEditingController _namespace;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;

  bool _saving = false;
  bool _testing = false;
  _Banner? _banner;

  @override
  void initState() {
    super.initState();
    final c = widget.config.surreal;
    _endpoint = TextEditingController(text: c.endpoint);
    _namespace = TextEditingController(text: c.namespace);
    _database = TextEditingController(text: c.database);
    _username = TextEditingController(text: c.username);
    _password = TextEditingController();
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _namespace.dispose();
    _database.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.putSurreal(
            endpoint: _endpoint.text.trim(),
            namespace: _namespace.text.trim(),
            database: _database.text.trim(),
            username: _username.text.trim(),
            password: _password.text.isEmpty ? null : _password.text,
          );
      _password.clear();
      await widget.onChanged();
      if (!mounted) return;
      setState(() => _banner = _Banner.success('Saved'));
    } on GatewayException catch (e) {
      if (!mounted) return;
      setState(() => _banner = _Banner.error(e.message));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      final result = await context.read<AppState>().api.testConnection();
      if (!mounted) return;
      setState(() => _banner = _Banner.success(
          'Connected · SurrealDB ${result['version'] ?? ''}'));
    } on GatewayException catch (e) {
      if (!mounted) return;
      setState(() => _banner = _Banner.error('Connection failed: ${e.message}'));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final passwordSet = widget.config.surreal.passwordSet;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('SurrealDB connection',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'External Surreal instance the integration layer mirrors data into. '
          'Uses Basic auth + NS/DB headers.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (_banner != null) ...[
          _banner!.build(context),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _endpoint,
          decoration: const InputDecoration(
            labelText: 'Endpoint',
            hintText: 'http://localhost:8000',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _namespace,
                decoration: const InputDecoration(
                  labelText: 'Namespace',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _database,
                decoration: const InputDecoration(
                  labelText: 'Database',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _username,
          decoration: const InputDecoration(
            labelText: 'Username',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: passwordSet
                ? 'A password is already stored. Leave blank to keep it; type a new one to replace.'
                : 'Not set.',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              label: const Text('Save'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_find),
              label: const Text('Test connection'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Banner {
  final String message;
  final bool error;
  _Banner._(this.message, this.error);
  factory _Banner.success(String m) => _Banner._(m, false);
  factory _Banner.error(String m) => _Banner._(m, true);

  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = error ? scheme.errorContainer : scheme.tertiaryContainer;
    final fg = error ? scheme.onErrorContainer : scheme.onTertiaryContainer;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(error ? Icons.error_outline : Icons.check_circle_outline,
              color: fg),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: TextStyle(color: fg))),
        ],
      ),
    );
  }
}

class _MappingsTab extends StatefulWidget {
  final IntegrationConfigView config;
  final Future<void> Function() onChanged;
  const _MappingsTab({required this.config, required this.onChanged});

  @override
  State<_MappingsTab> createState() => _MappingsTabState();
}

class _MappingsTabState extends State<_MappingsTab> {
  final Map<String, AuditEvent> _lastRun = {};
  final Map<String, bool> _running = {};

  Future<void> _run(Mapping m, {required bool push, required bool dryRun}) async {
    final key = m.collection;
    setState(() => _running[key] = true);
    try {
      final event = push
          ? await context.read<AppState>().api.push(m.collection, dryRun: dryRun)
          : await context.read<AppState>().api.pull(m.collection, dryRun: dryRun);
      if (!mounted) return;
      setState(() => _lastRun[key] = event);
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _running[key] = false);
    }
  }

  Future<void> _addMapping() async {
    final m = await showDialog<Mapping>(
      context: context,
      builder: (_) => const _MappingDialog(initial: null),
    );
    if (m == null) return;
    try {
      await context.read<AppState>().api.putMapping(m);
      await widget.onChanged();
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _edit(Mapping m) async {
    final updated = await showDialog<Mapping>(
      context: context,
      builder: (_) => _MappingDialog(initial: m),
    );
    if (updated == null) return;
    try {
      await context.read<AppState>().api.putMapping(updated);
      await widget.onChanged();
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(Mapping m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete mapping for ${m.collection}?'),
        content: const Text(
            'Pull and push for this collection will be disabled.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await context.read<AppState>().api.deleteMapping(m.collection);
      await widget.onChanged();
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mappings = widget.config.mappings;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            if (mappings.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No mappings yet — tap + to add one.')),
              )
            else
              for (final m in mappings)
                _MappingCard(
                  mapping: m,
                  running: _running[m.collection] == true,
                  lastRun: _lastRun[m.collection],
                  onPull: () => _run(m, push: false, dryRun: false),
                  onPullDry: () => _run(m, push: false, dryRun: true),
                  onPush: () => _run(m, push: true, dryRun: false),
                  onPushDry: () => _run(m, push: true, dryRun: true),
                  onEdit: () => _edit(m),
                  onDelete: () => _delete(m),
                ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            onPressed: _addMapping,
            icon: const Icon(Icons.add),
            label: const Text('Mapping'),
          ),
        ),
      ],
    );
  }
}

class _MappingCard extends StatelessWidget {
  final Mapping mapping;
  final bool running;
  final AuditEvent? lastRun;
  final VoidCallback onPull;
  final VoidCallback onPullDry;
  final VoidCallback onPush;
  final VoidCallback onPushDry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MappingCard({
    required this.mapping,
    required this.running,
    required this.lastRun,
    required this.onPull,
    required this.onPullDry,
    required this.onPush,
    required this.onPushDry,
    required this.onEdit,
    required this.onDelete,
  });

  Color _chipColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (mapping.direction) {
      case 'outbound':
        return scheme.primaryContainer;
      case 'inbound':
        return scheme.secondaryContainer;
      default:
        return scheme.tertiaryContainer;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(mapping.collection,
                              style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_right_alt, size: 18),
                          const SizedBox(width: 8),
                          Text(mapping.table,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 14)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Chip(
                            label: Text(mapping.directionLabel),
                            backgroundColor: _chipColor(context),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                          if (mapping.pushFilter.isNotEmpty)
                            Chip(
                              avatar: const Icon(Icons.filter_alt, size: 14),
                              label: Text(
                                mapping.pushFilter.entries
                                    .map((e) => '${e.key}=${e.value}')
                                    .join(', '),
                                style: const TextStyle(fontSize: 11),
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          if (mapping.rename.isNotEmpty)
                            Chip(
                              avatar: const Icon(Icons.swap_horiz, size: 14),
                              label: Text(
                                'rename ${mapping.rename.length} fields',
                                style: const TextStyle(fontSize: 11),
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          if (mapping.pullScheduled)
                            Chip(
                              avatar: const Icon(Icons.schedule, size: 14),
                              label: Text(
                                'auto-pull ${formatIntervalLabel(mapping.pullIntervalSeconds!)}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          if (mapping.pushScheduled)
                            Chip(
                              avatar: const Icon(Icons.schedule, size: 14),
                              label: Text(
                                'auto-push ${formatIntervalLabel(mapping.pushIntervalSeconds!)}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(onPressed: onEdit, icon: const Icon(Icons.edit)),
                IconButton(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline)),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _runButton('Pull', Icons.download, mapping.canPull && !running, onPull),
                _runButton('Dry-run pull', Icons.fact_check,
                    mapping.canPull && !running, onPullDry, outlined: true),
                _runButton('Push', Icons.upload, mapping.canPush && !running, onPush),
                _runButton('Dry-run push', Icons.fact_check,
                    mapping.canPush && !running, onPushDry, outlined: true),
              ],
            ),
            if (running) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (lastRun != null) ...[
              const SizedBox(height: 12),
              _RunResult(event: lastRun!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _runButton(String label, IconData icon, bool enabled,
      VoidCallback onPressed, {bool outlined = false}) {
    if (outlined) {
      return OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
    }
    return FilledButton.tonalIcon(
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

class _RunResult extends StatelessWidget {
  final AuditEvent event;
  const _RunResult({required this.event});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color bg;
    switch (event.status) {
      case 'error':
        bg = scheme.errorContainer;
        break;
      case 'dry-run':
        bg = scheme.surfaceContainerHighest;
        break;
      default:
        bg = scheme.tertiaryContainer;
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${event.action.toUpperCase()} · ${event.status}'
                '${event.dryRun ? ' · dry-run' : ''} · ${event.durationMs}ms',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            children: [
              _stat('scanned', event.rowsScanned),
              _stat('created', event.rowsCreated),
              _stat('updated', event.rowsUpdated),
              _stat('skipped', event.rowsSkipped),
              _stat('failed', event.rowsFailed),
            ],
          ),
          if (event.error != null) ...[
            const SizedBox(height: 8),
            Text(event.error!,
                style: const TextStyle(
                    fontSize: 11, fontFamily: 'monospace')),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, int n) =>
      Text('$label $n', style: const TextStyle(fontSize: 12));
}

class _MappingDialog extends StatefulWidget {
  final Mapping? initial;
  const _MappingDialog({required this.initial});

  @override
  State<_MappingDialog> createState() => _MappingDialogState();
}

class _MappingDialogState extends State<_MappingDialog> {
  late final TextEditingController _collection;
  late final TextEditingController _table;
  String _direction = 'both';
  late final List<_KV> _rename;
  late final List<_KV> _filter;
  int? _pullInterval;
  int? _pushInterval;

  @override
  void initState() {
    super.initState();
    final m = widget.initial;
    _collection = TextEditingController(text: m?.collection ?? '');
    _table = TextEditingController(text: m?.table ?? '');
    _direction = m?.direction ?? 'both';
    _pullInterval = m?.pullIntervalSeconds;
    _pushInterval = m?.pushIntervalSeconds;
    _rename = [
      if (m != null)
        for (final e in m.rename.entries)
          _KV(TextEditingController(text: e.key),
              TextEditingController(text: e.value)),
    ];
    _filter = [
      if (m != null)
        for (final e in m.pushFilter.entries)
          _KV(TextEditingController(text: e.key),
              TextEditingController(text: e.value)),
    ];
  }

  @override
  void dispose() {
    _collection.dispose();
    _table.dispose();
    for (final kv in [..._rename, ..._filter]) {
      kv.key.dispose();
      kv.value.dispose();
    }
    super.dispose();
  }

  bool get _canPull => _direction == 'outbound' || _direction == 'both';
  bool get _canPush => _direction == 'inbound' || _direction == 'both';

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initial != null;
    return AlertDialog(
      title: Text(isEdit ? 'Edit mapping' : 'New mapping'),
      content: SizedBox(
        width: 520,
        height: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _collection,
                enabled: !isEdit,
                decoration: const InputDecoration(
                  labelText: 'REST collection (e.g. expenses)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _table,
                decoration: const InputDecoration(
                  labelText: 'SurrealDB table',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _direction,
                decoration: const InputDecoration(
                  labelText: 'Direction',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                      value: 'outbound',
                      child: Text('Outbound (SAP → Surreal)')),
                  DropdownMenuItem(
                      value: 'inbound',
                      child: Text('Inbound (Surreal → SAP)')),
                  DropdownMenuItem(value: 'both', child: Text('Bidirectional')),
                ],
                onChanged: (v) => setState(() {
                  _direction = v!;
                  if (!_canPull) _pullInterval = null;
                  if (!_canPush) _pushInterval = null;
                }),
              ),
              const SizedBox(height: 16),
              Text('Schedule',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Server fires runs automatically at the chosen frequency. '
                'Tick precision is 5 seconds.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (_canPull)
                _FrequencyPicker(
                  label: 'Pull frequency',
                  value: _pullInterval,
                  onChanged: (v) => setState(() => _pullInterval = v),
                ),
              if (_canPull && _canPush) const SizedBox(height: 8),
              if (_canPush)
                _FrequencyPicker(
                  label: 'Push frequency',
                  value: _pushInterval,
                  onChanged: (v) => setState(() => _pushInterval = v),
                ),
              const SizedBox(height: 16),
              _kvSection(
                'Field renames (SAP → Surreal)',
                _rename,
                'SAP field (e.g. PERNR)',
                'Surreal field',
              ),
              const SizedBox(height: 16),
              _kvSection(
                'Push filter (equality)',
                _filter,
                'Field (e.g. Status)',
                'Value (e.g. SUBMITTED)',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _submit,
            child: Text(isEdit ? 'Save' : 'Create')),
      ],
    );
  }

  Widget _kvSection(
      String label, List<_KV> list, String keyHint, String valueHint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => setState(() => list.add(
                  _KV(TextEditingController(), TextEditingController()))),
            ),
          ],
        ),
        for (var i = 0; i < list.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: list[i].key,
                    decoration: InputDecoration(
                      labelText: keyHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: list[i].value,
                    decoration: InputDecoration(
                      labelText: valueHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => list.removeAt(i)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _submit() {
    final collection = _collection.text.trim();
    final table = _table.text.trim();
    if (collection.isEmpty || table.isEmpty) return;
    final rename = <String, String>{};
    for (final kv in _rename) {
      final k = kv.key.text.trim();
      final v = kv.value.text.trim();
      if (k.isNotEmpty && v.isNotEmpty) rename[k] = v;
    }
    final filter = <String, String>{};
    for (final kv in _filter) {
      final k = kv.key.text.trim();
      final v = kv.value.text.trim();
      if (k.isNotEmpty && v.isNotEmpty) filter[k] = v;
    }
    Navigator.pop(
      context,
      Mapping(
        collection: collection,
        table: table,
        direction: _direction,
        rename: rename,
        pushFilter: filter,
        pullIntervalSeconds: _canPull ? _pullInterval : null,
        pushIntervalSeconds: _canPush ? _pushInterval : null,
      ),
    );
  }
}

class _FrequencyPicker extends StatefulWidget {
  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;
  const _FrequencyPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_FrequencyPicker> createState() => _FrequencyPickerState();
}

class _FrequencyPickerState extends State<_FrequencyPicker> {
  // -1 = manual, -2 = custom (show minutes input), else seconds
  static const _presets = <_Preset>[
    _Preset(label: 'Manual only', seconds: -1),
    _Preset(label: 'Every 1 minute', seconds: 60),
    _Preset(label: 'Every 5 minutes', seconds: 300),
    _Preset(label: 'Every 15 minutes', seconds: 900),
    _Preset(label: 'Every 1 hour', seconds: 3600),
    _Preset(label: 'Custom…', seconds: -2),
  ];

  late int _selected; // sentinel from above
  late final TextEditingController _custom;

  @override
  void initState() {
    super.initState();
    final v = widget.value;
    if (v == null) {
      _selected = -1;
    } else if (_presets.any((p) => p.seconds == v)) {
      _selected = v;
    } else {
      _selected = -2;
    }
    _custom = TextEditingController(
      text: v != null && _selected == -2 ? (v ~/ 60).toString() : '',
    );
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _emit() {
    if (_selected == -1) {
      widget.onChanged(null);
    } else if (_selected == -2) {
      final mins = int.tryParse(_custom.text.trim());
      widget.onChanged(mins != null && mins > 0 ? mins * 60 : null);
    } else {
      widget.onChanged(_selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<int>(
          initialValue: _selected,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final p in _presets)
              DropdownMenuItem(value: p.seconds, child: Text(p.label)),
          ],
          onChanged: (v) {
            setState(() => _selected = v!);
            _emit();
          },
        ),
        if (_selected == -2) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _custom,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Every N minutes',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => _emit(),
          ),
        ],
      ],
    );
  }
}

class _Preset {
  final String label;
  final int seconds;
  const _Preset({required this.label, required this.seconds});
}

class _KV {
  final TextEditingController key;
  final TextEditingController value;
  _KV(this.key, this.value);
}

class _AuditTab extends StatefulWidget {
  const _AuditTab();
  @override
  State<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<_AuditTab> {
  List<AuditEvent> _events = [];
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
      final list =
          await context.read<AppState>().api.getAudit(limit: 200);
      if (!mounted) return;
      setState(() {
        _events = list;
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

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear audit log?'),
        content: const Text('All events will be permanently removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await context.read<AppState>().api.clearAudit();
      await _reload();
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('Failed to load: $_error'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text('${_events.length} events',
                  style: Theme.of(context).textTheme.bodyMedium),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: _reload,
              ),
              OutlinedButton.icon(
                onPressed: _events.isEmpty ? null : _clear,
                icon: const Icon(Icons.delete_sweep),
                label: const Text('Clear'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _events.isEmpty
              ? const Center(child: Text('No audit events yet.'))
              : ListView.separated(
                  itemCount: _events.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _AuditTile(event: _events[i]),
                ),
        ),
      ],
    );
  }
}

class _AuditTile extends StatelessWidget {
  final AuditEvent event;
  const _AuditTile({required this.event});

  IconData get _icon {
    switch (event.action) {
      case 'pull':
        return Icons.download;
      case 'push':
        return Icons.upload;
      case 'test-connection':
        return Icons.wifi_find;
      case 'config-update':
        return Icons.settings;
      case 'mapping-upsert':
        return Icons.add_link;
      case 'mapping-delete':
        return Icons.link_off;
      default:
        return Icons.bolt;
    }
  }

  Color _statusColour(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (event.status) {
      case 'error':
        return scheme.error;
      case 'dry-run':
        return scheme.tertiary;
      default:
        return scheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final col = _statusColour(context);
    return ExpansionTile(
      leading: CircleAvatar(
        backgroundColor: col.withValues(alpha: 0.15),
        foregroundColor: col,
        child: Icon(_icon, size: 18),
      ),
      title: Row(
        children: [
          Text(event.action,
              style: const TextStyle(
                  fontFamily: 'monospace', fontWeight: FontWeight.bold)),
          if (event.collection != null) ...[
            const SizedBox(width: 8),
            Text('· ${event.collection}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
          if (event.dryRun) ...[
            const SizedBox(width: 8),
            const Chip(
              label: Text('dry-run', style: TextStyle(fontSize: 10)),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
      subtitle: Text(
        '${event.timestamp.toLocal().toIso8601String()} · ${event.status} · ${event.durationMs}ms',
        style: const TextStyle(fontSize: 11),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(72, 0, 16, 16),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              Text('scanned ${event.rowsScanned}'),
              Text('created ${event.rowsCreated}'),
              Text('updated ${event.rowsUpdated}'),
              Text('skipped ${event.rowsSkipped}'),
              Text('failed ${event.rowsFailed}'),
            ],
          ),
        ),
        if (event.error != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              event.error!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ],
        if (event.details != null && event.details!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(event.details!.toString(),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        ],
      ],
    );
  }
}
