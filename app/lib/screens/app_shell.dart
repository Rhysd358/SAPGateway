import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'connections_screen.dart';
import 'dashboard_screen.dart';
import 'inbound_screen.dart';
import 'logs_screen.dart';
import 'map_screen.dart';
import 'outbound_screen.dart';
import 'settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  @override
  void initState() {
    super.initState();
    // Honour ?tab=N on first load — dev convenience for screenshots.
    final t = Uri.base.queryParameters['tab'];
    if (t == null) return;
    final n = int.tryParse(t);
    if (n == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().selectTab(n.clamp(0, _pages.length - 1));
    });
  }

  static const _pages = <Widget>[
    DashboardScreen(),
    ConnectionsScreen(),
    OutboundScreen(),
    MapScreen(),
    InboundScreen(),
    LogsScreen(),
    SettingsScreen(),
  ];

  static const _railDestinations = <NavigationRailDestination>[
    NavigationRailDestination(
      icon: Icon(Icons.dashboard_outlined),
      selectedIcon: Icon(Icons.dashboard),
      label: Text('Dashboard'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.cable_outlined),
      selectedIcon: Icon(Icons.cable),
      label: Text('Connections'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.call_made_outlined),
      selectedIcon: Icon(Icons.call_made),
      label: Text('Outbound'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.account_tree_outlined),
      selectedIcon: Icon(Icons.account_tree),
      label: Text('Map'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.call_received_outlined),
      selectedIcon: Icon(Icons.call_received),
      label: Text('Inbound'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.history_outlined),
      selectedIcon: Icon(Icons.history),
      label: Text('Logs'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: Text('Settings'),
    ),
  ];

  static const _barDestinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.dashboard_outlined),
      selectedIcon: Icon(Icons.dashboard),
      label: 'Dashboard',
    ),
    NavigationDestination(
      icon: Icon(Icons.cable_outlined),
      selectedIcon: Icon(Icons.cable),
      label: 'Connections',
    ),
    NavigationDestination(
      icon: Icon(Icons.call_made_outlined),
      selectedIcon: Icon(Icons.call_made),
      label: 'Outbound',
    ),
    NavigationDestination(
      icon: Icon(Icons.account_tree_outlined),
      selectedIcon: Icon(Icons.account_tree),
      label: 'Map',
    ),
    NavigationDestination(
      icon: Icon(Icons.call_received_outlined),
      selectedIcon: Icon(Icons.call_received),
      label: 'Inbound',
    ),
    NavigationDestination(
      icon: Icon(Icons.history_outlined),
      selectedIcon: Icon(Icons.history),
      label: 'Logs',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final index = context.watch<AppState>().selectedTab.clamp(0, _pages.length - 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        if (wide) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) =>
                      context.read<AppState>().selectTab(i),
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Icon(Icons.hub, size: 28),
                  ),
                  destinations: _railDestinations,
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _pages[index]),
              ],
            ),
          );
        }
        return Scaffold(
          body: _pages[index],
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) =>
                context.read<AppState>().selectTab(i),
            destinations: _barDestinations,
          ),
        );
      },
    );
  }
}
