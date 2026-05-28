import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gateway_api.dart';

// Connection type — drives which fields the editor shows.
enum ConnectionType { rest, surreal, odata }

extension ConnectionTypeX on ConnectionType {
  String get label => switch (this) {
        ConnectionType.rest => 'REST',
        ConnectionType.surreal => 'SurrealDB',
        ConnectionType.odata => 'OData V2',
      };
  IconData get icon => switch (this) {
        ConnectionType.rest => Icons.api,
        ConnectionType.surreal => Icons.storage,
        ConnectionType.odata => Icons.business_center,
      };
  Color colorOn(ColorScheme s) => switch (this) {
        ConnectionType.rest => s.primary,
        ConnectionType.surreal => s.tertiary,
        ConnectionType.odata => s.secondary,
      };
}

// Auth scheme for REST/OData. SurrealDB always uses Basic.
enum AuthScheme { none, basic, bearer, oauth2ClientCredentials, ssoSamlBearer }

extension on AuthScheme {
  String get label => switch (this) {
        AuthScheme.none => 'No authentication',
        AuthScheme.basic => 'HTTP Basic',
        AuthScheme.bearer => 'Bearer token',
        AuthScheme.oauth2ClientCredentials => 'OAuth2 client credentials',
        AuthScheme.ssoSamlBearer => 'SAML bearer (SSO)',
      };
  bool get disabled =>
      this == AuthScheme.oauth2ClientCredentials ||
      this == AuthScheme.ssoSamlBearer;
}

// Status surfaces a colored dot on each card. Future: persist after Test runs.
enum HealthStatus { unknown, healthy, failing }

extension on HealthStatus {
  String get label => switch (this) {
        HealthStatus.unknown => 'Not tested',
        HealthStatus.healthy => 'Healthy',
        HealthStatus.failing => 'Failing',
      };
  Color colorOn(ColorScheme s) => switch (this) {
        HealthStatus.unknown => s.outline,
        HealthStatus.healthy => Colors.green.shade600,
        HealthStatus.failing => s.error,
      };
}

class Connection {
  final String id;
  String name;
  ConnectionType type;
  // REST/OData
  String endpoint;
  AuthScheme authScheme;
  String authUser;
  // Write-only: typed by the user in the editor; cleared once saved. Server
  // exposes only [passwordSet] / [bearerSet] back.
  String authPass;
  String bearerToken;
  bool passwordSet;
  bool bearerSet;
  // Surreal
  String namespace;
  String database;
  // Save-as-draft: the editor's "Save as draft" button persists a partial
  // connection so the user can come back to it. Drafts are excluded from
  // Outbound / Inbound target dropdowns and rendered with a muted style +
  // "DRAFT" badge in the Connections list.
  bool isDraft;
  // Persisted test result — written back by the server on every Test
  // Connection probe and survives tab navigation. Cleared by the server
  // when a material field (endpoint, auth, namespace, database) changes.
  String lastTestedStatus; // '' = untested, 'ok', 'error'
  String lastTestedError;  // optional human-readable failure message
  DateTime? lastTestedAt;
  // Runtime only — true while a Test Connection probe is in flight so the
  // card can show a spinner without losing the previous result underneath.
  bool isTesting;

  Connection({
    required this.id,
    required this.name,
    required this.type,
    this.endpoint = '',
    this.authScheme = AuthScheme.none,
    this.authUser = '',
    this.authPass = '',
    this.bearerToken = '',
    this.passwordSet = false,
    this.bearerSet = false,
    this.namespace = '',
    this.database = '',
    this.isDraft = false,
    this.lastTestedStatus = '',
    this.lastTestedError = '',
    this.lastTestedAt,
    this.isTesting = false,
  });

  /// Derived health: reflects the persisted server state so the badge
  /// survives a tab switch without a re-test.
  HealthStatus get status => switch (lastTestedStatus) {
        'ok' => HealthStatus.healthy,
        'error' => HealthStatus.failing,
        _ => HealthStatus.unknown,
      };

  /// Alias — preserved so existing card code that read `lastTested` keeps
  /// working unchanged.
  DateTime? get lastTested => lastTestedAt;

  /// True if the last test was over a day ago — UI greys the badge to nudge
  /// "you probably want to re-test before trusting this".
  bool get isStale {
    final t = lastTestedAt;
    if (t == null) return false;
    return DateTime.now().difference(t) >= const Duration(hours: 24);
  }

  factory Connection.fromJson(Map<String, dynamic> j) => Connection(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        type: _parseType(j['type'] as String?),
        endpoint: j['endpoint'] as String? ?? '',
        authScheme: _parseAuth(j['authScheme'] as String?),
        authUser: j['authUser'] as String? ?? '',
        passwordSet: j['passwordSet'] as bool? ?? false,
        bearerSet: j['bearerSet'] as bool? ?? false,
        namespace: j['namespace'] as String? ?? '',
        database: j['database'] as String? ?? '',
        isDraft: j['isDraft'] as bool? ?? false,
        lastTestedStatus: j['lastTestedStatus'] as String? ?? '',
        lastTestedError: j['lastTestedError'] as String? ?? '',
        lastTestedAt: j['lastTestedAt'] is String
            ? DateTime.tryParse(j['lastTestedAt'] as String)
            : null,
      );

  /// PUT body. Password/bearer are sent only when the user typed something
  /// new — the server keeps the previous value otherwise.
  Map<String, dynamic> toJsonPatch() => {
        'name': name,
        'type': switch (type) {
          ConnectionType.rest => 'rest',
          ConnectionType.surreal => 'surreal',
          ConnectionType.odata => 'odata',
        },
        'endpoint': endpoint,
        'authScheme': switch (authScheme) {
          AuthScheme.none => 'none',
          AuthScheme.basic => 'basic',
          AuthScheme.bearer => 'bearer',
          AuthScheme.oauth2ClientCredentials => 'oauth2-client-credentials',
          AuthScheme.ssoSamlBearer => 'sso-saml-bearer',
        },
        'authUser': authUser,
        if (authPass.isNotEmpty) 'authPass': authPass,
        if (bearerToken.isNotEmpty) 'bearerToken': bearerToken,
        'namespace': namespace,
        'database': database,
        'isDraft': isDraft,
      };

  static ConnectionType _parseType(String? s) => switch (s) {
        'surreal' => ConnectionType.surreal,
        'odata' => ConnectionType.odata,
        _ => ConnectionType.rest,
      };

  static AuthScheme _parseAuth(String? s) => switch (s) {
        'basic' => AuthScheme.basic,
        'bearer' => AuthScheme.bearer,
        'oauth2-client-credentials' => AuthScheme.oauth2ClientCredentials,
        'sso-saml-bearer' => AuthScheme.ssoSamlBearer,
        _ => AuthScheme.none,
      };

  String get authLabel {
    if (type == ConnectionType.surreal) {
      return 'Basic · $authUser';
    }
    return switch (authScheme) {
      AuthScheme.none => 'No auth',
      AuthScheme.basic => 'HTTP Basic · $authUser',
      AuthScheme.bearer => 'Bearer token',
      AuthScheme.oauth2ClientCredentials => 'OAuth2 client credentials',
      AuthScheme.ssoSamlBearer => 'SAML bearer (SSO)',
    };
  }

  String get endpointDisplay {
    if (type == ConnectionType.surreal) {
      return '$endpoint  ·  ns=$namespace  db=$database';
    }
    return endpoint;
  }
}

class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  List<Connection> _connections = [];
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
      final list = await context.read<AppState>().api.listConnections();
      if (!mounted) return;
      setState(() {
        _connections = [
          for (final j in list) Connection.fromJson(j),
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

  Future<void> _openEditor({Connection? existing}) async {
    final result = await showDialog<Connection>(
      context: context,
      builder: (_) => _ConnectionEditorDialog(initial: existing),
    );
    if (result == null || !mounted) return;
    try {
      final saved = await context
          .read<AppState>()
          .api
          .putConnection(result.id, result.toJsonPatch());
      if (!mounted) return;
      final updated = Connection.fromJson(saved);
      setState(() {
        final i = _connections.indexWhere((c) => c.id == updated.id);
        if (i >= 0) {
          _connections[i] = updated;
        } else {
          _connections.add(updated);
        }
      });
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: ${e.message}')),
      );
    }
  }

  Future<void> _deleteConnection(Connection c) async {
    final api = context.read<AppState>().api;
    try {
      await api.deleteConnection(c.id);
      if (!mounted) return;
      setState(() => _connections.remove(c));
    } on ConnectionInUseException catch (e) {
      // The connection has dependent flows. Offer cascade.
      if (!mounted) return;
      final cascade = await _confirmCascadeDelete(e);
      if (cascade != true || !mounted) return;
      try {
        await api.deleteConnection(c.id, cascade: true);
        if (!mounted) return;
        setState(() => _connections.remove(c));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(
              'Deleted "${c.name}" + ${e.totalReferences} dependent flow(s)')),
        );
      } on GatewayException catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cascade delete failed: ${e.message}')),
        );
      }
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: ${e.message}')),
      );
    }
  }

  /// Confirmation dialog that lists the flows referencing the connection
  /// and offers Cancel vs "Delete connection + N flows".
  Future<bool?> _confirmCascadeDelete(ConnectionInUseException e) {
    return showDialog<bool>(
      context: context,
      builder: (_) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: scheme.error, size: 36),
          title: Text('Delete "${e.connectionName}"?'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This connection is used by ${e.totalReferences} flow'
                  '${e.totalReferences == 1 ? "" : "s"}. Deleting the '
                  'connection removes them too:',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                if (e.outboundFlows.isNotEmpty) ...[
                  Text('Outbound:',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.outline,
                          )),
                  const SizedBox(height: 4),
                  for (final f in e.outboundFlows)
                    Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 2),
                      child: Row(children: [
                        Icon(Icons.call_made,
                            size: 14, color: scheme.primary),
                        const SizedBox(width: 6),
                        Text(f['name']?.toString() ?? f['id']?.toString() ?? ''),
                      ]),
                    ),
                  const SizedBox(height: 8),
                ],
                if (e.inboundFlows.isNotEmpty) ...[
                  Text('Inbound:',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.outline,
                          )),
                  const SizedBox(height: 4),
                  for (final f in e.inboundFlows)
                    Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 2),
                      child: Row(children: [
                        Icon(Icons.call_received,
                            size: 14, color: scheme.tertiary),
                        const SizedBox(width: 6),
                        Text(f['name']?.toString() ?? f['id']?.toString() ?? ''),
                      ]),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.delete_forever, size: 18),
              style: FilledButton.styleFrom(backgroundColor: scheme.error),
              onPressed: () => Navigator.of(context).pop(true),
              label: Text(
                  'Delete connection + ${e.totalReferences} flow${e.totalReferences == 1 ? "" : "s"}'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _testConnection(Connection c) async {
    setState(() => c.isTesting = true);
    String? error;
    String? detail;
    DateTime? testedAt;
    try {
      // Probed server-side by id so the gateway uses the stored credentials
      // (the UI only holds them write-only) and there's no browser CORS.
      // The server also writes the result back onto the Connection record
      // so the badge survives a tab switch — we reflect the same change
      // locally to avoid a round-trip.
      final r = await context.read<AppState>().api.testConnectionById(c.id);
      if (r['ok'] == true) {
        detail = r['detail']?.toString();
      } else {
        error = r['error']?.toString() ?? 'unknown error';
      }
      final t = r['testedAt'];
      if (t is String) testedAt = DateTime.tryParse(t);
    } on GatewayException catch (e) {
      error = e.message;
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() {
      c.isTesting = false;
      c.lastTestedStatus = error == null ? 'ok' : 'error';
      c.lastTestedError = error ?? '';
      c.lastTestedAt = testedAt ?? DateTime.now().toUtc();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error != null
            ? 'Test failed (${c.name}): $error'
            : '${c.name} is reachable${detail != null ? " · $detail" : ""}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// "Test all" button — fires Test Connection for every non-draft
  /// connection in parallel. Each probe writes its result back to the
  /// connection record server-side, so all the badges settle simultaneously
  /// once Future.wait completes.
  Future<void> _testAllConnections() async {
    final targets =
        _connections.where((c) => !c.isDraft && !c.isTesting).toList();
    if (targets.isEmpty) return;
    // Optimistic: show every targeted card as "in flight" up front so the
    // user gets immediate feedback even if some probes are slow.
    setState(() {
      for (final c in targets) c.isTesting = true;
    });
    await Future.wait([for (final c in targets) _testConnectionSilent(c)]);
    if (!mounted) return;
    final failed = targets.where((c) => c.status == HealthStatus.failing).length;
    final passed = targets.length - failed;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Tested ${targets.length} connection${targets.length == 1 ? "" : "s"} · '
            '$passed healthy · $failed failing'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Same probe as [_testConnection] but without the per-connection
  /// SnackBar — used by [_testAllConnections] which emits one summary
  /// SnackBar at the end instead of N noisy ones.
  Future<void> _testConnectionSilent(Connection c) async {
    String? error;
    DateTime? testedAt;
    try {
      final r = await context.read<AppState>().api.testConnectionById(c.id);
      if (r['ok'] != true) {
        error = r['error']?.toString() ?? 'unknown error';
      }
      final t = r['testedAt'];
      if (t is String) testedAt = DateTime.tryParse(t);
    } on GatewayException catch (e) {
      error = e.message;
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() {
      c.isTesting = false;
      c.lastTestedStatus = error == null ? 'ok' : 'error';
      c.lastTestedError = error ?? '';
      c.lastTestedAt = testedAt ?? DateTime.now().toUtc();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
          // Test all: probes every non-draft connection in parallel and
          // settles every badge at once. Disabled while still loading or
          // mid-probe to avoid stacking up overlapping rounds.
          TextButton.icon(
            onPressed: _loading ||
                    _connections.where((c) => !c.isDraft).isEmpty ||
                    _connections.any((c) => c.isTesting)
                ? null
                : _testAllConnections,
            icon: const Icon(Icons.wifi_tethering, size: 18),
            label: const Text('Test all'),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add connection'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_off,
                            size: 48,
                            color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        Text(
                          'Couldn\'t load connections',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(_error!,
                            style: Theme.of(context).textTheme.bodySmall,
                            textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : _connections.isEmpty
                  ? _EmptyState(onAdd: () => _openEditor())
                  : RefreshIndicator(
                      onRefresh: _reload,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          for (final c in _connections)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _ConnectionCard(
                                connection: c,
                                onEdit: () => _openEditor(existing: c),
                                onDelete: () => _deleteConnection(c),
                                onTest: () => _testConnection(c),
                              ),
                            ),
                        ],
                      ),
                    ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cable_outlined, size: 64, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No connections yet',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Add a REST source, a SurrealDB target, or an OData V2 endpoint to '
              'start building flows.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add connection'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  final Connection connection;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTest;
  const _ConnectionCard({
    required this.connection,
    required this.onEdit,
    required this.onDelete,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typeColor = connection.type.colorOn(scheme);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Coloured left rail keyed to connection type — instant visual ID.
          Container(width: 5, color: typeColor),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Gradient icon tile, same vocabulary as the dashboard.
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              typeColor,
                              typeColor.withValues(alpha: 0.7),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: typeColor.withValues(alpha: 0.25),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child:
                            Icon(connection.type.icon, color: Colors.white),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    connection.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                                _TypeChip(
                                    label: connection.type.label,
                                    color: typeColor),
                                if (connection.isDraft) ...[
                                  const SizedBox(width: 6),
                                  _TypeChip(
                                      label: 'DRAFT', color: scheme.outline),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              connection.endpointDisplay,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: scheme.outline,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(color: scheme.outlineVariant, height: 1),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      // Status pill reflects the SERVER-PERSISTED test result,
                      // so it survives tab navigation. While a test is in
                      // flight we overlay a 12px spinner on top of the pill
                      // instead of clearing it — keeps the previous state
                      // visible underneath so the card doesn't flicker.
                      _StatusPill(
                        status: connection.status,
                        stale: connection.isStale,
                        loading: connection.isTesting,
                      ),
                      if (connection.lastTested != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          connection.isStale
                              ? 'tested ${_relativeTime(connection.lastTested!)} (stale)'
                              : 'tested ${_relativeTime(connection.lastTested!)}',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.outline,
                                    fontStyle: connection.isStale
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                  ),
                        ),
                      ],
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          connection.authLabel,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.outline,
                                  ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // Drafts skip the Test button — there's nothing
                      // complete to probe yet. Same for any test in flight.
                      if (!connection.isDraft)
                        TextButton.icon(
                          onPressed: connection.isTesting ? null : onTest,
                          icon: connection.isTesting
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.wifi_tethering, size: 18),
                          label: Text(
                              connection.isTesting ? 'Testing…' : 'Test'),
                        ),
                      IconButton(
                        tooltip: connection.isDraft
                            ? 'Continue editing draft'
                            : 'Edit',
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
          ),
        ],
      ),
      ),
    );
  }
}

/// Capsule-shaped pill showing the current health status with a tinted
/// background — matches the dashboard's punchy stat aesthetic. When
/// [stale] is true the colour is dialed back to neutral grey to nudge "you
/// probably want to re-test before trusting this". When [loading] is true
/// the leading dot becomes a spinner so the previous result stays visible
/// underneath instead of the pill flickering through "Not tested".
class _StatusPill extends StatelessWidget {
  final HealthStatus status;
  final bool stale;
  final bool loading;
  const _StatusPill({
    required this.status,
    this.stale = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final liveColor = status.colorOn(scheme);
    // Stale = same data, faded to outline grey so it doesn't read as "all
    // good" when it might be hours/days out of date.
    final color = stale && status == HealthStatus.healthy
        ? scheme.outline
        : liveColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            )
          else
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Text(
            status.label,
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

class _TypeChip extends StatelessWidget {
  final String label;
  final Color color;
  const _TypeChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
      ),
    );
  }
}

String _relativeTime(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

// ─────────────────────────────────────────────────────────────
// Editor dialog
// ─────────────────────────────────────────────────────────────

class _ConnectionEditorDialog extends StatefulWidget {
  final Connection? initial;
  const _ConnectionEditorDialog({this.initial});

  @override
  State<_ConnectionEditorDialog> createState() =>
      _ConnectionEditorDialogState();
}

class _ConnectionEditorDialogState extends State<_ConnectionEditorDialog> {
  late ConnectionType _type;
  late AuthScheme _authScheme;
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  late final TextEditingController _bearer;
  late final TextEditingController _namespace;
  late final TextEditingController _database;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _type = i?.type ?? ConnectionType.rest;
    _authScheme = i?.authScheme ?? AuthScheme.basic;
    _name = TextEditingController(text: i?.name ?? '');
    _endpoint = TextEditingController(text: i?.endpoint ?? '');
    _user = TextEditingController(text: i?.authUser ?? '');
    _pass = TextEditingController(text: i?.authPass ?? '');
    _bearer = TextEditingController(text: i?.bearerToken ?? '');
    _namespace = TextEditingController(text: i?.namespace ?? '');
    _database = TextEditingController(text: i?.database ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _user.dispose();
    _pass.dispose();
    _bearer.dispose();
    _namespace.dispose();
    _database.dispose();
    super.dispose();
  }

  /// Full save: requires name + endpoint at minimum so the connection is
  /// usable by flows / Test Connection.
  bool get _canSave =>
      _name.text.trim().isNotEmpty && _endpoint.text.trim().isNotEmpty;

  /// Draft save: only the name is required (so the entry has a label in the
  /// Connections list). Everything else can be empty — the user is
  /// explicitly parking incomplete work to come back to.
  bool get _canSaveAsDraft => _name.text.trim().isNotEmpty;

  void _save({required bool asDraft}) {
    if (asDraft ? !_canSaveAsDraft : !_canSave) return;
    final c = widget.initial ??
        Connection(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: '',
          type: _type,
        );
    c.name = _name.text.trim();
    c.type = _type;
    c.endpoint = _endpoint.text.trim();
    c.authScheme =
        _type == ConnectionType.surreal ? AuthScheme.basic : _authScheme;
    c.authUser = _user.text.trim();
    c.authPass = _pass.text;
    c.bearerToken = _bearer.text;
    c.namespace = _namespace.text.trim();
    c.database = _database.text.trim();
    c.isDraft = asDraft;
    Navigator.of(context).pop(c);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typeColor = _type.colorOn(scheme);
    return FloatingDialog(
      maxWidth: 580,
      hero: DialogHero(
        icon: _type.icon,
        title: widget.initial == null ? 'New connection' : 'Edit connection',
        subtitle:
            '${_type.label} · ${widget.initial?.name ?? "Configure source or target"}',
        colors: [typeColor, typeColor.withValues(alpha: 0.7)],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
                    DialogSection(
                      icon: Icons.badge_outlined,
                      label: 'Identity',
                      accent: scheme.primary,
                      children: [
                        TextField(
                          controller: _name,
                          decoration: const InputDecoration(
                            labelText: 'Name',
                            hintText: 'e.g. SAP HR Production',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<ConnectionType>(
                          value: _type,
                          decoration: const InputDecoration(
                            labelText: 'Type',
                          ),
                          items: [
                            for (final t in ConnectionType.values)
                              DropdownMenuItem(
                                value: t,
                                child: Row(
                                  children: [
                                    Icon(t.icon,
                                        size: 18,
                                        color: t.colorOn(scheme)),
                                    const SizedBox(width: 8),
                                    Text(t.label),
                                  ],
                                ),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _type = v ?? _type),
                        ),
                      ],
                    ),
                    DialogSection(
                      icon: Icons.link,
                      label: 'Endpoint',
                      accent: typeColor,
                      children: [
                        TextField(
                          controller: _endpoint,
                          decoration: InputDecoration(
                            labelText: switch (_type) {
                              ConnectionType.rest => 'Base URL',
                              ConnectionType.surreal => 'Endpoint',
                              ConnectionType.odata => 'Service root',
                            },
                            hintText: switch (_type) {
                              ConnectionType.rest => 'http://host/api/v1',
                              ConnectionType.surreal =>
                                'http://localhost:8000',
                              ConnectionType.odata =>
                                'https://sap/sap/opu/odata/sap/ZTRIP_SRV',
                            },
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        if (_type == ConnectionType.surreal) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _namespace,
                                  decoration: const InputDecoration(
                                    labelText: 'Namespace',
                                    hintText: 'nucleus',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  controller: _database,
                                  decoration: const InputDecoration(
                                    labelText: 'Database',
                                    hintText: 'test',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
            DialogSection(
              icon: Icons.lock_outline,
              label: 'Authentication',
              accent: scheme.secondary,
              children: _type == ConnectionType.surreal
                  ? _surrealAuthInputs()
                  : _restAuthInputs(),
            ),
          ],
        ),
      ),
      footer: DialogFooter(
        // Test-from-editor isn't wired yet — the per-row Test on the
        // Connections list already works. Hidden until we have a probe
        // path that doesn't require persisting first.
        leading: const SizedBox.shrink(),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          // Save as draft: relaxed validation (name only). Lets the user
          // park half-finished work without committing to a complete
          // connection. The list shows it with a "DRAFT" badge.
          OutlinedButton.icon(
            onPressed:
                _canSaveAsDraft ? () => _save(asDraft: true) : null,
            icon: const Icon(Icons.drafts_outlined, size: 18),
            label: Text(widget.initial?.isDraft == true
                ? 'Keep as draft'
                : 'Save as draft'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _canSave ? () => _save(asDraft: false) : null,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  List<Widget> _surrealAuthInputs() => [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _user,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
            ),
          ],
        ),
      ];

  List<Widget> _restAuthInputs() {
    return [
      DropdownButtonFormField<AuthScheme>(
        value: _authScheme,
        decoration: const InputDecoration(labelText: 'Scheme'),
        items: [
          for (final s in AuthScheme.values)
            DropdownMenuItem(
              value: s,
              enabled: !s.disabled,
              child: Row(
                children: [
                  Text(s.label),
                  if (s.disabled) ...[
                    const SizedBox(width: 6),
                    const Text('(TBD)',
                        style: TextStyle(fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
        ],
        onChanged: (v) {
          if (v == null || v.disabled) return;
          setState(() => _authScheme = v);
        },
      ),
      if (_authScheme == AuthScheme.basic) ...[
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _user,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
            ),
          ],
        ),
      ] else if (_authScheme == AuthScheme.bearer) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _bearer,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Token'),
        ),
      ],
    ];
  }
}

// ─────────────────────────────────────────────────────────────
// Shared dialog parts — gradient hero, sectioned body, footer.
// Used by both the Connection editor and the Outbound Flow editor.
// ─────────────────────────────────────────────────────────────

class DialogHero extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Color> colors;
  const DialogHero({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.30),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(24, 18, 16, 18),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// A two-card dialog scaffold: the [DialogHero] floats above as its own
/// rounded card, then a gap, then the body card holding the scrollable
/// content and sticky footer. Replaces the standard [Dialog] when you want
/// the hero detached from the body.
class FloatingDialog extends StatelessWidget {
  final DialogHero hero;
  final Widget body;
  final Widget? footer;
  final double maxWidth;
  const FloatingDialog({
    super.key,
    required this.hero,
    required this.body,
    this.footer,
    this.maxWidth = 580,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            hero,
            const SizedBox(height: 12),
            Flexible(
              child: Material(
                color: Theme.of(context).brightness == Brightness.dark
                    ? scheme.surfaceContainerHigh
                    : Colors.white,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(16),
                elevation: 0,
                shadowColor: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: body),
                      if (footer != null) footer!,
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DialogSection extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final List<Widget> children;
  const DialogSection({
    super.key,
    required this.icon,
    required this.label,
    required this.accent,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(icon, color: accent, size: 14),
                ),
                const SizedBox(width: 8),
                Text(
                  label.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class DialogFooter extends StatelessWidget {
  final Widget? leading;
  final List<Widget> actions;
  const DialogFooter({super.key, this.leading, required this.actions});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          if (leading != null) leading!,
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}
