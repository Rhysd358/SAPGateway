import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'package:sap_gateway_server/admin_handler.dart';
import 'package:sap_gateway_server/auth.dart';
import 'package:sap_gateway_server/integration/audit.dart';
import 'package:sap_gateway_server/integration/config.dart';
import 'package:sap_gateway_server/integration/flow_scheduler.dart';
import 'package:sap_gateway_server/integration/flows_store.dart';
import 'package:sap_gateway_server/integration/handler.dart';
import 'package:sap_gateway_server/integration/scheduler.dart';
import 'package:sap_gateway_server/rest_handler.dart';
import 'package:sap_gateway_server/store.dart';

Future<void> main(List<String> args) async {
  // Run the whole server inside a guarded zone. Any uncaught asynchronous
  // error — including ones that escape shelf's per-request handler chain
  // (fire-and-forget futures, native socket / TLS callbacks on Windows
  // throwing out-of-band, etc.) — is logged here instead of terminating
  // the isolate. Without this, a Test Connection against an unreachable
  // host with a weird cert state has been observed to crash the whole
  // PowerShell window on Windows Server. Setup errors still surface
  // because runZonedGuarded returns before the server starts listening.
  runZonedGuarded(() => _serve(args), (error, stack) {
    stderr.writeln('═══ UNCAUGHT ASYNC ERROR ═══');
    stderr.writeln('error: $error');
    stderr.writeln('stack:\n$stack');
    stderr.writeln('(server continuing — request that triggered this returned 500 or hung)');
  });
}

Future<void> _serve(List<String> args) async {
  final dataDir = _arg(args, '--data') ?? Platform.environment['GATEWAY_DATA'] ?? 'data';
  final port = int.tryParse(
          _arg(args, '--port') ?? Platform.environment['GATEWAY_PORT'] ?? '') ??
      8080;
  final host = _arg(args, '--host') ?? Platform.environment['GATEWAY_HOST'] ?? '0.0.0.0';
  // When set, the gateway also serves the Flutter web build (static files +
  // SPA fallback) so a deployment is a single process — no separate static
  // server. Unset in dev, where the UI is served separately.
  final webRoot =
      _arg(args, '--web-root') ?? Platform.environment['GATEWAY_WEB_ROOT'];
  final authConfig = AuthConfig.from(
    env: Platform.environment,
    cliUser: _arg(args, '--auth-user'),
    cliPass: _arg(args, '--auth-pass'),
  );

  final store = await GatewayStore.load('$dataDir/runtime.json');
  final config = await IntegrationConfig.load('$dataDir/integration.json');
  final flowsStore = await FlowsStore.load('$dataDir/flows.json');
  final audit = await AuditLog.load('$dataDir/audit.json');

  final rest = RestHandler(store);
  final admin = AdminHandler(store);
  final loopbackHost = (host == '0.0.0.0' || host.isEmpty) ? 'localhost' : host;
  final integration = IntegrationHandler(
    store: store,
    config: config,
    flowsStore: flowsStore,
    audit: audit,
    gatewayUrl: 'http://$loopbackHost:$port',
    authConfig: authConfig,
  );
  // Legacy scheduler — still instantiated so the `/schedules` endpoint
  // can describe it, but no longer started. The new FlowScheduler below
  // owns auto-fired runs against the OutboundFlow model.
  final scheduler = IntegrationScheduler(config: config, handler: integration);
  final flowScheduler =
      FlowScheduler(store: flowsStore, handler: integration);

  final root = Router();
  root.get('/healthz', (Request request) =>
      Response.ok('{"ok":true}', headers: {'content-type': 'application/json'}));
  root.get('/api/v1/integration/schedules', (Request request) {
    return Response.ok(
      _encodeJson({
        'legacy': scheduler.describe(),
        'flows': flowScheduler.describe(),
      }),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  root.mount('/api/v1/integration/', integration.handler);
  root.mount('/api/v1/', rest.handler);
  root.mount('/admin/', admin.handler);
  if (webRoot != null && webRoot.isNotEmpty) {
    // Registered last so the API mounts above take precedence; everything
    // else (/, /dashboard, assets) is served from the Flutter build.
    root.mount('/', _staticHandler(webRoot));
  } else {
    root.get('/', (Request request) {
      return Response.ok(
        '{"ok":true,"message":"SAP Gateway — see /api/v1/ for REST, /admin/ for schema CRUD, /api/v1/integration/ for SurrealDB sync","auth":"${authConfig.mode}"}',
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
  }

  final pipeline = const Pipeline()
      .addMiddleware(_logging())
      .addMiddleware(_cors())
      .addMiddleware(authMiddleware(config: authConfig))
      .addHandler(root.call);

  final server = await shelf_io.serve(pipeline, host, port);
  server.autoCompress = true;
  stdout.writeln(
      'SAP Gateway mock listening on http://${server.address.host}:${server.port}');
  stdout.writeln('  REST:        http://localhost:$port/api/v1/');
  stdout.writeln('  Admin:       http://localhost:$port/admin/');
  stdout.writeln('  Integration: http://localhost:$port/api/v1/integration/');
  if (webRoot != null && webRoot.isNotEmpty) {
    stdout.writeln('  Admin UI:    http://localhost:$port/  (web root: $webRoot)');
  }
  stdout.writeln('  Data dir:    $dataDir');
  stdout.writeln('  Auth:        ${authConfig.mode}'
      '${authConfig.enabled ? ' (user=${authConfig.username})' : ''}');
  final scheduledFlows = flowsStore.outboundFlows
      .where((f) => f.pullIntervalSeconds != null && f.pullIntervalSeconds! > 0)
      .length;
  stdout.writeln(
      '  Scheduler:   tick=5s · $scheduledFlows outbound flow(s) on a schedule');
  // Legacy scheduler is NOT started — its mappings (in integration.json)
  // would otherwise fire continuously. Run flows from the Outbound tab
  // or set pullIntervalSeconds on an OutboundFlow to schedule it.
  flowScheduler.start();

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('Shutting down…');
    flowScheduler.stop();
    scheduler.stop();
    await store.flush();
    await server.close(force: true);
    exit(0);
  });
}

String _encodeJson(Object o) => const JsonEncoder().convert(o);

const _mimeTypes = {
  'html': 'text/html; charset=utf-8',
  'js': 'application/javascript; charset=utf-8',
  'mjs': 'application/javascript; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'json': 'application/json; charset=utf-8',
  'wasm': 'application/wasm',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'svg': 'image/svg+xml',
  'ico': 'image/x-icon',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
};

/// Serves the Flutter web build from [root] with SPA fallback: a request for
/// a real file returns that file; anything else returns index.html so the
/// client-side router can take over. Mounted at '/' after the API routes,
/// so it only sees paths the API didn't claim.
Handler _staticHandler(String root) {
  final rootDir = Directory(root).absolute;
  return (Request request) async {
    var rel = request.url.path; // already prefix-stripped by the mount
    if (rel.isEmpty || rel.endsWith('/')) rel = '${rel}index.html';
    final file = File(
        '${rootDir.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}');
    final ext = rel.split('.').last.toLowerCase();
    final ct = _mimeTypes[ext] ?? 'application/octet-stream';
    if (await file.exists()) {
      return Response.ok(file.openRead(), headers: {'content-type': ct});
    }
    final index = File('${rootDir.path}${Platform.pathSeparator}index.html');
    if (await index.exists()) {
      return Response.ok(index.openRead(),
          headers: {'content-type': 'text/html; charset=utf-8'});
    }
    return Response.notFound('Not found');
  };
}

String? _arg(List<String> args, String flag) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == flag && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$flag=')) return args[i].substring(flag.length + 1);
  }
  return null;
}

Middleware _logging() {
  return (Handler inner) {
    return (Request request) async {
      final start = DateTime.now();
      try {
        final resp = await inner(request);
        final ms = DateTime.now().difference(start).inMilliseconds;
        stdout.writeln(
            '${start.toIso8601String()} ${request.method.padRight(6)} ${request.requestedUri.path} ${resp.statusCode} ${ms}ms');
        return resp;
      } catch (e, st) {
        final ms = DateTime.now().difference(start).inMilliseconds;
        stderr.writeln(
            '${start.toIso8601String()} ${request.method.padRight(6)} ${request.requestedUri.path} ERROR ${ms}ms — $e');
        stderr.writeln(st);
        rethrow;
      }
    };
  };
}

Middleware _cors() {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers':
        'Origin, Content-Type, Accept, Authorization',
    'Access-Control-Max-Age': '86400',
  };
  return (Handler inner) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }
      final resp = await inner(request);
      return resp.change(headers: {...resp.headers, ...headers});
    };
  };
}
