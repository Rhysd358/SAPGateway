import 'dart:io';

const _mime = {
  'html': 'text/html; charset=utf-8',
  'js': 'application/javascript; charset=utf-8',
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

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : '../app/build/web';
  final port = args.length > 1 ? int.parse(args[1]) : 8090;
  final rootDir = Directory(root).absolute;
  if (!await rootDir.exists()) {
    stderr.writeln('Root directory does not exist: ${rootDir.path}');
    exit(1);
  }

  final server = await HttpServer.bind('127.0.0.1', port);
  stdout.writeln('Serving ${rootDir.path} on http://localhost:$port');

  await for (final req in server) {
    try {
      var rel = req.uri.path;
      if (rel.startsWith('/')) rel = rel.substring(1);
      if (rel.isEmpty || rel.endsWith('/')) rel = '${rel}index.html';
      final file = File('${rootDir.path}${Platform.pathSeparator}'
              '${rel.replaceAll('/', Platform.pathSeparator)}');
      final ext = rel.split('.').last.toLowerCase();
      final ct = _mime[ext] ?? 'application/octet-stream';
      if (await file.exists()) {
        req.response.headers.set('Content-Type', ct);
        await file.openRead().pipe(req.response);
      } else {
        // SPA fallback
        final index = File(
            '${rootDir.path}${Platform.pathSeparator}index.html');
        if (await index.exists()) {
          req.response.headers.set('Content-Type', 'text/html; charset=utf-8');
          await index.openRead().pipe(req.response);
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      }
    } catch (e) {
      stderr.writeln('serve_app error: $e');
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }
}
