import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'screens/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(prefs);
  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const SapGatewayApp(),
    ),
  );
}

class SapGatewayApp extends StatefulWidget {
  const SapGatewayApp({super.key});

  @override
  State<SapGatewayApp> createState() => _SapGatewayAppState();
}

class _SapGatewayAppState extends State<SapGatewayApp> {
  // Theme construction is non-trivial (color scheme from seed + 10+ sub-
  // themes). Build once and reuse so a tab change or other AppState notify
  // doesn't pay the cost again.
  late final ThemeData _light = _buildTheme(Brightness.light);
  late final ThemeData _dark = _buildTheme(Brightness.dark);

  @override
  Widget build(BuildContext context) {
    // `select` so MaterialApp only rebuilds when themeMode itself flips,
    // not on every AppState.notifyListeners (selectTab, auth changes, …).
    final mode =
        context.select<AppState, ThemeMode>((s) => s.themeMode);
    return MaterialApp(
      title: 'SAP Gateway Admin',
      debugShowCheckedModeBanner: false,
      theme: _light,
      darkTheme: _dark,
      themeMode: mode,
      home: const AppShell(),
    );
  }
}

/// Vivid colour scheme:
///   primary   = bright blue (Tailwind blue-600)
///   secondary = emerald  (Tailwind emerald-500)
///   tertiary  = amber    (Tailwind amber-500)
/// Generated tonal palette via [ColorScheme.fromSeed], then specific roles
/// overridden so the brand colours surface where they matter.
ThemeData _buildTheme(Brightness brightness) {
  const primary = Color(0xFF2563EB);
  const secondary = Color(0xFF10B981);
  const tertiary = Color(0xFFF59E0B);
  final dark = brightness == Brightness.dark;

  final base = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: brightness,
    primary: primary,
    secondary: secondary,
    tertiary: tertiary,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: base,
    // Explicit Roboto pins the entire text theme to the bundled font asset
    // declared in pubspec.yaml. Material 3's default already prefers Roboto,
    // but spelling it out guarantees canvaskit never asks fonts.gstatic.com
    // for it (we ship Roboto under app/fonts/Roboto/ for the offline target).
    fontFamily: 'Roboto',
    scaffoldBackgroundColor: dark ? base.surface : const Color(0xFFF7F9FC),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? base.surface : Colors.white,
      foregroundColor: base.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: base.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? base.surfaceContainerHigh : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: base.outlineVariant),
      ),
      margin: EdgeInsets.zero,
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: base.outlineVariant),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? base.surfaceContainerHighest : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: base.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: base.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: base.primary, width: 1.5),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: dark ? base.surfaceContainerLowest : Colors.white,
      indicatorColor: base.primary.withValues(alpha: 0.12),
      selectedIconTheme: IconThemeData(color: base.primary),
      unselectedIconTheme: IconThemeData(color: base.outline),
      selectedLabelTextStyle: TextStyle(
        color: base.primary,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: base.onSurface,
        fontSize: 12,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? base.surfaceContainerLowest : Colors.white,
      indicatorColor: base.primary.withValues(alpha: 0.12),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return TextStyle(color: base.primary, fontWeight: FontWeight.w600);
        }
        return TextStyle(color: base.onSurface);
      }),
    ),
    dividerTheme: DividerThemeData(
      color: base.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      elevation: 8,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
