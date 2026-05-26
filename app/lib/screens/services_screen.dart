import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gateway_api.dart';
import '../models.dart';

class ServicesScreen extends StatefulWidget {
  const ServicesScreen({super.key});

  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen> {
  List<ServiceSummary> _services = [];
  bool _loading = true;
  String? _error;
  String? _selectedService;
  String? _selectedSet;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload({bool keepSelection = true}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await context.read<AppState>().api.listServices();
      if (!mounted) return;
      setState(() {
        _services = list;
        _loading = false;
        if (!keepSelection ||
            !list.any((s) => s.name == _selectedService)) {
          _selectedService = null;
          _selectedSet = null;
        } else if (_selectedSet != null) {
          final svc = list.firstWhere((s) => s.name == _selectedService);
          if (!svc.entitySets.any((es) => es.name == _selectedSet)) {
            _selectedSet = null;
          }
        }
      });
    } on GatewayException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  ServiceSummary? get _currentService {
    if (_selectedService == null) return null;
    for (final s in _services) {
      if (s.name == _selectedService) return s;
    }
    return null;
  }

  EntitySetSummary? get _currentSet {
    final svc = _currentService;
    if (svc == null || _selectedSet == null) return null;
    for (final es in svc.entitySets) {
      if (es.name == _selectedSet) return es;
    }
    return null;
  }

  EntityType? get _currentType {
    final svc = _currentService;
    final set = _currentSet;
    if (svc == null || set == null) return null;
    for (final t in svc.entityTypes) {
      if (t.name == set.entityType) return t;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Services'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _reload(),
          ),
          IconButton(
            tooltip: 'New service',
            icon: const Icon(Icons.add),
            onPressed: _loading ? null : _createService,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorBanner(message: _error!, onRetry: _reload)
              : LayoutBuilder(
                  builder: (context, c) {
                    final wide = c.maxWidth >= 880;
                    if (wide) {
                      return Row(
                        children: [
                          SizedBox(
                            width: 340,
                            child: _ServicesList(
                              services: _services,
                              selectedSet: _selectedSet,
                              onSelectSet: _onSelectSet,
                              onServiceAction: _handleServiceAction,
                              onTypeAction: _handleTypeAction,
                              onSetAction: _handleSetAction,
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: _detailPane()),
                        ],
                      );
                    }
                    return _selectedSet == null
                        ? _ServicesList(
                            services: _services,
                            selectedSet: _selectedSet,
                            onSelectSet: _onSelectSet,
                            onServiceAction: _handleServiceAction,
                            onTypeAction: _handleTypeAction,
                            onSetAction: _handleSetAction,
                          )
                        : _detailPane(showBack: true);
                  },
                ),
    );
  }

  Widget _detailPane({bool showBack = false}) {
    if (_currentSet == null || _currentType == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Select an entity set on the left to view its rows.'),
        ),
      );
    }
    return _RowBrowser(
      service: _currentService!.name,
      set: _currentSet!,
      type: _currentType!,
      onBack: showBack ? () => setState(() => _selectedSet = null) : null,
      onChanged: _reload,
    );
  }

  void _onSelectSet(String service, String set) {
    setState(() {
      _selectedService = service;
      _selectedSet = set;
    });
  }

  Future<void> _createService() async {
    final name = await _renameDialog(context,
        title: 'New service', initial: 'Z_NEW_SRV');
    if (name == null) return;
    try {
      await context.read<AppState>().api.createService(name);
      await _reload();
    } on GatewayException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _handleServiceAction(
      ServiceSummary service, _ServiceAction action) async {
    switch (action) {
      case _ServiceAction.rename:
        final newName = await _renameDialog(context,
            title: 'Rename service', initial: service.name);
        if (newName == null || newName == service.name) return;
        try {
          await context.read<AppState>().api.renameService(service.name, newName);
          if (_selectedService == service.name) _selectedService = newName;
          await _reload();
        } on GatewayException catch (e) {
          _snack(e.message);
        }
        break;
      case _ServiceAction.delete:
        final ok = await _confirm(context, 'Delete ${service.name}?',
            'All entity types, sets and rows in this service will be deleted.');
        if (!ok) return;
        try {
          await context.read<AppState>().api.deleteService(service.name);
          if (_selectedService == service.name) {
            _selectedService = null;
            _selectedSet = null;
          }
          await _reload();
        } on GatewayException catch (e) {
          _snack(e.message);
        }
        break;
      case _ServiceAction.addType:
        final name = await _renameDialog(context,
            title: 'New entity type', initial: 'NewType');
        if (name == null) return;
        try {
          await context
              .read<AppState>()
              .api
              .createType(service.name, EntityType(name: name, properties: []));
          await _reload();
        } on GatewayException catch (e) {
          _snack(e.message);
        }
        break;
      case _ServiceAction.addSet:
        if (service.entityTypes.isEmpty) {
          _snack('Add an entity type first');
          return;
        }
        final result = await showDialog<_NewSet>(
          context: context,
          builder: (_) => _NewSetDialog(types: service.entityTypes),
        );
        if (result == null) return;
        try {
          await context
              .read<AppState>()
              .api
              .createSet(service.name, result.name, result.entityType);
          await _reload();
        } on GatewayException catch (e) {
          _snack(e.message);
        }
        break;
    }
  }

  Future<void> _handleTypeAction(
      ServiceSummary service, EntityType type, _TypeAction action) async {
    switch (action) {
      case _TypeAction.rename:
        final newName = await _renameDialog(context,
            title: 'Rename entity type', initial: type.name);
        if (newName == null || newName == type.name) return;
        try {
          await context
              .read<AppState>()
              .api
              .renameType(service.name, type.name, newName);
          await _reload();
        } on GatewayException catch (e) {
          _snack(e.message);
        }
        break;
      case _TypeAction.delete:
        final ok = await _confirm(context, 'Delete ${type.name}?',
            'You cannot delete a type used by an entity set.');
        if (!ok) return;
        try {
          await context.read<AppState>().api.deleteType(service.name, type.name);
          await _reload();
        } on GatewayException catch (e) {
          _snack(e.message);
        }
        break;
      case _TypeAction.editProperties:
        await showDialog(
          context: context,
          builder: (_) => _PropertiesDialog(
            service: service.name,
            type: type,
          ),
        );
        await _reload();
        break;
    }
  }

  Future<void> _handleSetAction(ServiceSummary service,
      EntitySetSummary set, _SetAction action) async {
    switch (action) {
      case _SetAction.rename:
        final newName = await _renameDialog(context,
            title: 'Rename entity set', initial: set.name);
        if (newName == null || newName == set.name) return;
        try {
          await context.read<AppState>().api.renameSet(service.name, set.name, newName);
          if (_selectedSet == set.name) _selectedSet = newName;
          await _reload();
        } on GatewayException catch (e) {
          _snack(e.message);
        }
        break;
      case _SetAction.delete:
        final ok = await _confirm(context, 'Delete ${set.name}?',
            'All rows in this set will be lost.');
        if (!ok) return;
        try {
          await context.read<AppState>().api.deleteSet(service.name, set.name);
          if (_selectedSet == set.name) _selectedSet = null;
          await _reload();
        } on GatewayException catch (e) {
          _snack(e.message);
        }
        break;
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _ServiceAction { rename, delete, addType, addSet }

enum _TypeAction { rename, delete, editProperties }

enum _SetAction { rename, delete }

class _ServicesList extends StatelessWidget {
  final List<ServiceSummary> services;
  final String? selectedSet;
  final void Function(String service, String set) onSelectSet;
  final Future<void> Function(ServiceSummary, _ServiceAction) onServiceAction;
  final Future<void> Function(ServiceSummary, EntityType, _TypeAction) onTypeAction;
  final Future<void> Function(ServiceSummary, EntitySetSummary, _SetAction)
      onSetAction;

  const _ServicesList({
    required this.services,
    required this.selectedSet,
    required this.onSelectSet,
    required this.onServiceAction,
    required this.onTypeAction,
    required this.onSetAction,
  });

  @override
  Widget build(BuildContext context) {
    if (services.isEmpty) {
      return const Center(child: Text('No services yet — use + to create one.'));
    }
    return ListView(
      children: [
        for (final svc in services)
          _ServiceTile(
            service: svc,
            selectedSet: selectedSet,
            onSelectSet: onSelectSet,
            onServiceAction: onServiceAction,
            onTypeAction: onTypeAction,
            onSetAction: onSetAction,
          ),
      ],
    );
  }
}

class _ServiceTile extends StatelessWidget {
  final ServiceSummary service;
  final String? selectedSet;
  final void Function(String, String) onSelectSet;
  final Future<void> Function(ServiceSummary, _ServiceAction) onServiceAction;
  final Future<void> Function(ServiceSummary, EntityType, _TypeAction) onTypeAction;
  final Future<void> Function(ServiceSummary, EntitySetSummary, _SetAction)
      onSetAction;

  const _ServiceTile({
    required this.service,
    required this.selectedSet,
    required this.onSelectSet,
    required this.onServiceAction,
    required this.onTypeAction,
    required this.onSetAction,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: ExpansionTile(
        initiallyExpanded:
            service.entitySets.any((es) => es.name == selectedSet),
        leading: const Icon(Icons.folder_special_outlined),
        title: Text(service.name,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
        subtitle: Text(
            '${service.entityTypes.length} types · ${service.entitySets.length} sets'),
        trailing: PopupMenuButton<_ServiceAction>(
          onSelected: (a) => onServiceAction(service, a),
          itemBuilder: (_) => const [
            PopupMenuItem(value: _ServiceAction.addType, child: Text('Add entity type')),
            PopupMenuItem(value: _ServiceAction.addSet, child: Text('Add entity set')),
            PopupMenuItem(value: _ServiceAction.rename, child: Text('Rename service')),
            PopupMenuItem(value: _ServiceAction.delete, child: Text('Delete service')),
          ],
        ),
        children: [
          if (service.entityTypes.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Entity types',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ),
            for (final t in service.entityTypes)
              ListTile(
                dense: true,
                leading: const Icon(Icons.account_tree_outlined, size: 20),
                title: Text(t.name,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                subtitle: Text(
                  '${t.properties.length} properties · key: ${t.keyProperties.map((p) => p.name).join(', ')}',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: PopupMenuButton<_TypeAction>(
                  onSelected: (a) => onTypeAction(service, t, a),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: _TypeAction.editProperties, child: Text('Edit properties…')),
                    PopupMenuItem(value: _TypeAction.rename, child: Text('Rename')),
                    PopupMenuItem(value: _TypeAction.delete, child: Text('Delete')),
                  ],
                ),
              ),
          ],
          if (service.entitySets.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Entity sets',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ),
            for (final es in service.entitySets)
              ListTile(
                dense: true,
                leading: const Icon(Icons.table_rows_outlined, size: 20),
                selected: es.name == selectedSet,
                title: Text(es.name,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                subtitle: Text(
                    '${es.entityType} · ${es.rowCount} rows · /${es.collection}',
                    style: const TextStyle(fontSize: 11)),
                onTap: () => onSelectSet(service.name, es.name),
                trailing: PopupMenuButton<_SetAction>(
                  onSelected: (a) => onSetAction(service, es, a),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: _SetAction.rename, child: Text('Rename')),
                    PopupMenuItem(value: _SetAction.delete, child: Text('Delete')),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _RowBrowser extends StatefulWidget {
  final String service;
  final EntitySetSummary set;
  final EntityType type;
  final VoidCallback? onBack;
  final Future<void> Function() onChanged;

  const _RowBrowser({
    required this.service,
    required this.set,
    required this.type,
    required this.onBack,
    required this.onChanged,
  });

  @override
  State<_RowBrowser> createState() => _RowBrowserState();
}

class _RowBrowserState extends State<_RowBrowser> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_RowBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.set.name != widget.set.name ||
        oldWidget.service != widget.service) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await context
          .read<AppState>()
          .api
          .listSetRows(widget.service, widget.set.name);
      if (!mounted) return;
      setState(() {
        _rows = rows;
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

  String _idOf(Map<String, dynamic> row) {
    return widget.type.keyProperties
        .map((p) => row[p.name]?.toString() ?? '')
        .join(',');
  }

  Future<void> _addRow() async {
    final row = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _RowDialog(type: widget.type, initial: null),
    );
    if (row == null) return;
    try {
      await context
          .read<AppState>()
          .api
          .createSetRow(widget.service, widget.set.name, row);
      await _load();
      await widget.onChanged();
    } on GatewayException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _editRow(Map<String, dynamic> row) async {
    final id = _idOf(row);
    final updated = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _RowDialog(type: widget.type, initial: row),
    );
    if (updated == null) return;
    try {
      await context
          .read<AppState>()
          .api
          .patchSetRow(widget.service, widget.set.name, id, updated);
      await _load();
      await widget.onChanged();
    } on GatewayException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _deleteRow(Map<String, dynamic> row) async {
    final id = _idOf(row);
    final ok = await _confirm(context, 'Delete row $id?',
        'This will permanently remove the row.');
    if (!ok) return;
    try {
      await context
          .read<AppState>()
          .api
          .deleteSetRow(widget.service, widget.set.name, id);
      await _load();
      await widget.onChanged();
    } on GatewayException catch (e) {
      _snack(e.message);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          elevation: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                if (widget.onBack != null)
                  IconButton(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back',
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.set.name,
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      Text(
                        '${widget.type.name} · /api/v1/${widget.set.collection} · ${_rows.length} rows',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                ),
                FilledButton.icon(
                  onPressed: _loading ? null : _addRow,
                  icon: const Icon(Icons.add),
                  label: const Text('Add row'),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _ErrorBanner(message: _error!, onRetry: _load)
                  : _rows.isEmpty
                      ? const Center(child: Text('No rows yet.'))
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints:
                                const BoxConstraints(minWidth: 600),
                            child: SingleChildScrollView(
                              child: DataTable(
                                columns: [
                                  for (final p in widget.type.properties)
                                    DataColumn(
                                      label: Text(
                                        p.name +
                                            (p.key ? ' 🔑' : ''),
                                        style: const TextStyle(
                                            fontFamily: 'monospace'),
                                      ),
                                    ),
                                  const DataColumn(label: Text('')),
                                ],
                                rows: [
                                  for (final row in _rows)
                                    DataRow(cells: [
                                      for (final p in widget.type.properties)
                                        DataCell(
                                          Text(
                                            row[p.name]?.toString() ?? '',
                                            style: const TextStyle(
                                                fontFamily: 'monospace'),
                                          ),
                                          onTap: () => _editRow(row),
                                        ),
                                      DataCell(Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            tooltip: 'Edit',
                                            icon: const Icon(Icons.edit,
                                                size: 18),
                                            onPressed: () => _editRow(row),
                                          ),
                                          IconButton(
                                            tooltip: 'Delete',
                                            icon: const Icon(
                                                Icons.delete_outline,
                                                size: 18),
                                            onPressed: () => _deleteRow(row),
                                          ),
                                        ],
                                      )),
                                    ]),
                                ],
                              ),
                            ),
                          ),
                        ),
        ),
      ],
    );
  }
}

class _RowDialog extends StatefulWidget {
  final EntityType type;
  final Map<String, dynamic>? initial;
  const _RowDialog({required this.type, required this.initial});

  @override
  State<_RowDialog> createState() => _RowDialogState();
}

class _RowDialogState extends State<_RowDialog> {
  late final Map<String, TextEditingController> _controllers;
  late final Map<String, bool> _booleans;

  @override
  void initState() {
    super.initState();
    _controllers = {};
    _booleans = {};
    for (final p in widget.type.properties) {
      final raw = widget.initial?[p.name];
      if (p.type == 'boolean') {
        _booleans[p.name] = raw == true;
      } else {
        _controllers[p.name] = TextEditingController(text: raw?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initial != null;
    return AlertDialog(
      title: Text(isEdit ? 'Edit row' : 'New ${widget.type.name}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in widget.type.properties)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: p.type == 'boolean'
                      ? SwitchListTile(
                          title: Text(p.name +
                              (p.key ? '  🔑' : '') +
                              (p.label != null ? '  · ${p.label}' : '')),
                          value: _booleans[p.name] ?? false,
                          onChanged: (v) =>
                              setState(() => _booleans[p.name] = v),
                          contentPadding: EdgeInsets.zero,
                        )
                      : TextField(
                          controller: _controllers[p.name],
                          enabled: !(isEdit && p.key),
                          decoration: InputDecoration(
                            labelText:
                                p.name + (p.key ? ' 🔑' : '') + ' · ${p.type}',
                            helperText: p.label,
                            border: const OutlineInputBorder(),
                          ),
                        ),
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
          child: Text(isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }

  void _submit() {
    final out = <String, dynamic>{};
    for (final p in widget.type.properties) {
      if (p.type == 'boolean') {
        out[p.name] = _booleans[p.name] ?? false;
        continue;
      }
      final raw = _controllers[p.name]!.text;
      if (raw.isEmpty) continue;
      if (p.type == 'int') {
        final n = int.tryParse(raw);
        out[p.name] = n ?? raw;
      } else {
        out[p.name] = raw;
      }
    }
    Navigator.pop(context, out);
  }
}

class _NewSet {
  final String name;
  final String entityType;
  _NewSet(this.name, this.entityType);
}

class _NewSetDialog extends StatefulWidget {
  final List<EntityType> types;
  const _NewSetDialog({required this.types});

  @override
  State<_NewSetDialog> createState() => _NewSetDialogState();
}

class _NewSetDialogState extends State<_NewSetDialog> {
  final _nameController = TextEditingController();
  String? _typeName;

  @override
  void initState() {
    super.initState();
    _typeName = widget.types.first.name;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New entity set'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Set name (e.g. CustomerSet)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _typeName,
              decoration: const InputDecoration(
                labelText: 'Entity type',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final t in widget.types)
                  DropdownMenuItem(value: t.name, child: Text(t.name)),
              ],
              onChanged: (v) => setState(() => _typeName = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isEmpty || _typeName == null) return;
            Navigator.pop(context, _NewSet(name, _typeName!));
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _PropertiesDialog extends StatefulWidget {
  final String service;
  final EntityType type;
  const _PropertiesDialog({required this.service, required this.type});

  @override
  State<_PropertiesDialog> createState() => _PropertiesDialogState();
}

class _PropertiesDialogState extends State<_PropertiesDialog> {
  late List<Property> _properties;

  @override
  void initState() {
    super.initState();
    _properties = List.of(widget.type.properties);
  }

  Future<void> _add() async {
    final p = await showDialog<Property>(
      context: context,
      builder: (_) => const _PropertyEditDialog(initial: null),
    );
    if (p == null) return;
    try {
      await context
          .read<AppState>()
          .api
          .createProperty(widget.service, widget.type.name, p);
      setState(() => _properties.add(p));
    } on GatewayException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _edit(Property p) async {
    final updated = await showDialog<Property>(
      context: context,
      builder: (_) => _PropertyEditDialog(initial: p),
    );
    if (updated == null) return;
    try {
      await context.read<AppState>().api.updateProperty(
          widget.service, widget.type.name, p.name, updated.toJson());
      setState(() {
        final idx = _properties.indexWhere((x) => x.name == p.name);
        if (idx >= 0) _properties[idx] = updated;
      });
    } on GatewayException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _remove(Property p) async {
    final ok = await _confirm(context, 'Delete ${p.name}?',
        'The property and its values across all rows will be removed.');
    if (!ok) return;
    try {
      await context
          .read<AppState>()
          .api
          .deleteProperty(widget.service, widget.type.name, p.name);
      setState(() => _properties.removeWhere((x) => x.name == p.name));
    } on GatewayException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.type.name} — properties'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: Column(
          children: [
            Row(
              children: [
                const Text('Renames cascade through existing rows.'),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: _properties.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = _properties[i];
                  return ListTile(
                    dense: true,
                    leading: Icon(p.key ? Icons.vpn_key : Icons.label_outline,
                        size: 18),
                    title: Text(p.name,
                        style: const TextStyle(fontFamily: 'monospace')),
                    subtitle: Text(
                      [
                        p.type,
                        if (p.maxLength != null) 'maxLength ${p.maxLength}',
                        if (p.precision != null)
                          'precision ${p.precision}.${p.scale ?? 0}',
                        if (!p.nullable) 'not null',
                        if (p.label != null) p.label!,
                      ].join(' · '),
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 18),
                          onPressed: () => _edit(p),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => _remove(p),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}

class _PropertyEditDialog extends StatefulWidget {
  final Property? initial;
  const _PropertyEditDialog({required this.initial});

  @override
  State<_PropertyEditDialog> createState() => _PropertyEditDialogState();
}

class _PropertyEditDialogState extends State<_PropertyEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _maxLength;
  late final TextEditingController _precision;
  late final TextEditingController _scale;
  late final TextEditingController _label;
  String _type = 'string';
  bool _nullable = true;
  bool _key = false;

  static const _types = ['string', 'int', 'decimal', 'datetime', 'boolean'];

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    _name = TextEditingController(text: p?.name ?? '');
    _maxLength = TextEditingController(text: p?.maxLength?.toString() ?? '');
    _precision = TextEditingController(text: p?.precision?.toString() ?? '');
    _scale = TextEditingController(text: p?.scale?.toString() ?? '');
    _label = TextEditingController(text: p?.label ?? '');
    _type = p?.type ?? 'string';
    _nullable = p?.nullable ?? true;
    _key = p?.key ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _maxLength.dispose();
    _precision.dispose();
    _scale.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'New property' : 'Edit property'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name (DDIC field code, e.g. PERNR)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(
                  labelText: 'Type',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final t in _types)
                    DropdownMenuItem(value: t, child: Text(t)),
                ],
                onChanged: (v) => setState(() => _type = v!),
              ),
              const SizedBox(height: 12),
              if (_type == 'string')
                TextField(
                  controller: _maxLength,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'maxLength',
                    border: OutlineInputBorder(),
                  ),
                ),
              if (_type == 'decimal')
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _precision,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'precision',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _scale,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'scale',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Key'),
                value: _key,
                onChanged: (v) => setState(() => _key = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Nullable'),
                value: _nullable,
                onChanged: (v) => setState(() => _nullable = v),
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
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final p = Property(
      name: name,
      type: _type,
      maxLength: int.tryParse(_maxLength.text),
      precision: int.tryParse(_precision.text),
      scale: int.tryParse(_scale.text),
      nullable: _nullable,
      key: _key,
      label: _label.text.trim().isEmpty ? null : _label.text.trim(),
    );
    Navigator.pop(context, p);
  }
}

Future<String?> _renameDialog(BuildContext context,
    {required String title, required String initial}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  controller.dispose();
  return (result != null && result.isNotEmpty) ? result : null;
}

Future<bool> _confirm(BuildContext context, String title, String message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return ok == true;
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                color: Theme.of(context).colorScheme.error, size: 32),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
