import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gateway_api.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _baseUrl;
  bool _gatewayReachable = false;
  bool _probing = true;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _baseUrl = TextEditingController(text: s.baseUrl);
    WidgetsBinding.instance.addPostFrameCallback((_) => _probe());
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    setState(() => _probing = true);
    final api = context.read<AppState>().api;
    try {
      await api.getIntegrationConfig();
      if (!mounted) return;
      setState(() {
        _gatewayReachable = true;
        _probing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _gatewayReachable = false;
        _probing = false;
      });
    }
  }

  Future<void> _saveBaseUrl() async {
    await context.read<AppState>().setBaseUrl(_baseUrl.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Gateway URL saved')),
    );
    _probe();
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset to seed?'),
        content: const Text(
            'All schema changes and row edits will be discarded. The bundled HR + Expenses seed will be reloaded.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().api.resetSeed();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seed restored')),
      );
    } on GatewayException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reset failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _probing ? null : _probe,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _GatewayHero(
            url: state.baseUrl,
            reachable: _gatewayReachable,
            probing: _probing,
          ),
          const SizedBox(height: 20),
          _GatewayUrlCard(
            controller: _baseUrl,
            onSave: _saveBaseUrl,
            reachable: _gatewayReachable,
            probing: _probing,
          ),
          const SizedBox(height: 16),
          _AppearanceCard(
            mode: state.themeMode,
            onChanged: (m) => state.setThemeMode(m),
          ),
          const SizedBox(height: 16),
          _MaintenanceCard(onReset: _confirmReset),
          const SizedBox(height: 16),
          const _AboutCard(),
        ],
      ),
    );
  }
}

/// Gateway connection hero — large gradient banner showing live reachability.
/// Mirrors the dashboard's gradient stat tile aesthetic for the most
/// important Settings signal (am I connected to the gateway?).
class _GatewayHero extends StatelessWidget {
  final String url;
  final bool reachable;
  final bool probing;
  const _GatewayHero({
    required this.url,
    required this.reachable,
    required this.probing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = probing
        ? scheme.primary
        : reachable
            ? scheme.secondary
            : scheme.error;
    final headline = probing
        ? 'Checking…'
        : reachable
            ? 'Connected to gateway'
            : 'Gateway unreachable';

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent, accent.withValues(alpha: 0.7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.25),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(13),
            ),
            child: probing
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    reachable ? Icons.check_circle : Icons.cloud_off,
                    color: Colors.white,
                    size: 26,
                  ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  url,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GatewayUrlCard extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSave;
  final bool reachable;
  final bool probing;
  const _GatewayUrlCard({
    required this.controller,
    required this.onSave,
    required this.reachable,
    required this.probing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.link, color: scheme.primary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: 'Gateway URL',
                  hintText: 'http://localhost:8080',
                  suffixIcon: probing
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2)))
                      : Icon(
                          reachable ? Icons.check_circle : Icons.error,
                          color: reachable
                              ? Colors.green.shade600
                              : scheme.error,
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: onSave, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}

class _AppearanceCard extends StatelessWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;
  const _AppearanceCard({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.secondary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_iconFor(mode), color: scheme.secondary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Appearance',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                  const SizedBox(height: 2),
                  Text(
                    'Choose light, dark, or follow your system setting.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                        icon: Icon(Icons.brightness_auto, size: 18),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                        icon: Icon(Icons.light_mode, size: 18),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode, size: 18),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => onChanged(s.first),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(ThemeMode m) => switch (m) {
        ThemeMode.light => Icons.light_mode,
        ThemeMode.dark => Icons.dark_mode,
        ThemeMode.system => Icons.brightness_auto,
      };
}

class _MaintenanceCard extends StatelessWidget {
  final VoidCallback onReset;
  const _MaintenanceCard({required this.onReset});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.tertiary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.restart_alt, color: scheme.tertiary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Reset to seed data',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                  const SizedBox(height: 2),
                  Text(
                    'Drops in-memory runtime state and reloads the bundled HR + Expenses seed.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Reset'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = [
      (Icons.flutter_dash, 'Frontend', 'Flutter web (Dart + Material 3)'),
      (Icons.dns, 'Backend', 'Dart shelf · static native binary'),
      (Icons.code, 'Outbound worker', 'Python 3 (stdlib only)'),
      (Icons.shield_outlined, 'Auth', 'HTTP Basic; OAuth2 + SSO stubs in place'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              ListTile(
                dense: true,
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(items[i].$1, color: scheme.primary, size: 18),
                ),
                title: Text(items[i].$2,
                    style: Theme.of(context).textTheme.bodyMedium),
                subtitle: Text(items[i].$3,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              if (i < items.length - 1)
                Divider(height: 1, color: scheme.outlineVariant),
            ],
          ],
        ),
      ),
    );
  }
}
