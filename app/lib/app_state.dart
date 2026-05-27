import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import 'gateway_api.dart';

class AppState extends ChangeNotifier {
  static const _baseUrlKey = 'baseUrl';
  static const _authModeKey = 'authMode';
  static const _authUserKey = 'authUser';
  static const _authPassKey = 'authPass';
  static const _themeModeKey = 'themeMode';

  /// Default gateway URL when nothing is saved: the same origin the app was
  /// served from. For a single-origin deployment (the gateway serves both
  /// the UI and the API on one port) this "just works" with zero config. In
  /// dev the UI is served separately (port 8090), so a saved value from
  /// Settings overrides this — and existing profiles already have one.
  static String get _defaultBaseUrl {
    final origin = Uri.base.origin;
    return origin.isEmpty ? 'http://localhost:8080' : origin;
  }

  // Dev defaults so a fresh browser profile (e.g. Edge with empty
  // localStorage) can talk to the local gateway without a setup step.
  // The gateway's actual creds come from --auth-user/--auth-pass when it
  // starts; these defaults assume the local-dev conventions in
  // CONNECTIONS.md. Override per-environment by setting these values via
  // the AppState API at startup or via SharedPreferences.
  static const _defaultAuthMode = 'basic';
  static const _defaultAuthUser = 'admin';
  static const _defaultAuthPass = 's3cret';

  final SharedPreferences _prefs;
  String _baseUrl;
  String _authMode;
  String _authUser;
  String _authPass;
  ThemeMode _themeMode;
  GatewayApi _api;

  // Navigation — lifted out of AppShell so other screens can deep-link
  // (e.g. an Outbound card's "View logs" button jumps to the Logs tab
  // with a job pre-filtered).
  int _selectedTab = 0;
  String? _pendingJobFilter;

  AppState(this._prefs)
      : _baseUrl = _prefs.getString(_baseUrlKey) ?? _defaultBaseUrl,
        _authMode = _prefs.getString(_authModeKey) ?? _defaultAuthMode,
        _authUser = _prefs.getString(_authUserKey) ?? _defaultAuthUser,
        _authPass = _prefs.getString(_authPassKey) ?? _defaultAuthPass,
        _themeMode = _parseThemeMode(_prefs.getString(_themeModeKey)),
        _api = GatewayApi(
          _prefs.getString(_baseUrlKey) ?? _defaultBaseUrl,
          authMode: _prefs.getString(_authModeKey) ?? _defaultAuthMode,
          authUser: _prefs.getString(_authUserKey) ?? _defaultAuthUser,
          authPass: _prefs.getString(_authPassKey) ?? _defaultAuthPass,
        );

  String get baseUrl => _baseUrl;
  String get authMode => _authMode;
  String get authUser => _authUser;
  bool get hasAuthPass => _authPass.isNotEmpty;
  ThemeMode get themeMode => _themeMode;
  GatewayApi get api => _api;

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    await _prefs.setString(_themeModeKey, _themeModeToString(mode));
    notifyListeners();
  }

  int get selectedTab => _selectedTab;
  String? get pendingJobFilter => _pendingJobFilter;

  /// Set the active tab. Pass [jobFilter] when navigating to Logs and you
  /// want a specific job preselected — the Logs screen consumes it via
  /// [consumePendingJobFilter] on init.
  void selectTab(int index, {String? jobFilter}) {
    if (index == _selectedTab && jobFilter == null) return;
    _selectedTab = index;
    if (jobFilter != null) _pendingJobFilter = jobFilter;
    notifyListeners();
  }

  /// Read the pending filter (if any) and clear it. Logs screen calls this
  /// in initState so the filter only fires once per navigation.
  String? consumePendingJobFilter() {
    final f = _pendingJobFilter;
    _pendingJobFilter = null;
    return f;
  }

  static ThemeMode _parseThemeMode(String? s) => switch (s) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String _themeModeToString(ThemeMode m) => switch (m) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  Future<void> setBaseUrl(String value) async {
    final cleaned = value.trim();
    if (cleaned.isEmpty || cleaned == _baseUrl) return;
    _baseUrl = cleaned;
    await _prefs.setString(_baseUrlKey, cleaned);
    _rebuildApi();
  }

  Future<void> setAuth({
    required String mode,
    String? username,
    String? password,
  }) async {
    final prevMode = _authMode;
    final prevUser = _authUser;
    final prevPass = _authPass;
    _authMode = mode;
    if (username != null) _authUser = username;
    if (password != null && password.isNotEmpty) _authPass = password;
    if (mode == 'none') {
      _authUser = '';
      _authPass = '';
    }
    final changed = prevMode != _authMode ||
        prevUser != _authUser ||
        prevPass != _authPass;
    if (!changed) return;
    await _prefs.setString(_authModeKey, _authMode);
    await _prefs.setString(_authUserKey, _authUser);
    await _prefs.setString(_authPassKey, _authPass);
    _rebuildApi();
  }

  void _rebuildApi() {
    _api = GatewayApi(
      _baseUrl,
      authMode: _authMode,
      authUser: _authUser,
      authPass: _authPass,
    );
    notifyListeners();
  }
}
