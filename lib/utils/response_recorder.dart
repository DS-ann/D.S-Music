import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'debug_logger.dart';

/// Records raw HTTP request/response pairs to disk so the captured payload
/// can be inspected offline (Postman, VSCode, diff between calls, etc.).
///
/// Disabled by default. Enable with [ResponseRecorder.enabled] = true at app
/// startup, or via the `--dart-define=RECORD_API=true` build flag.
///
/// Output layout under `<app docs>/api_recordings/<session>/`:
/// ```
/// 2026-06-23T18-42-12.345Z__search__unfiltered__req.txt     ← headers + body
/// 2026-06-23T18-42-12.345Z__search__unfiltered__res.txt     ← status + headers + body
/// 2026-06-23T18-42-12.345Z__search__unfiltered__summary.json ← metadata
/// ```
///
/// Each file is plain text. Bodies are pretty-printed JSON when possible
/// (2-space indent, exactly what you would want to read). The session folder
/// makes it easy to delete a whole batch at once.
class ResponseRecorder {
  ResponseRecorder._();

  /// Master switch. Set to true at app start to begin recording.
  /// Can also be flipped at runtime via the settings screen.
  static bool enabled = const bool.fromEnvironment('RECORD_API', defaultValue: false);

  /// Cap on the number of response bodies retained on disk per session to
  /// avoid filling up the device. When exceeded, oldest files are removed.
  static int maxFilesPerSession = 200;

  static String? _baseDir;
  static String? _sessionDir;
  static DateTime? _sessionStart;

  /// Initialize the recorder. Idempotent.
  ///
  /// On Android the recordings are written to the app's *external* files
  /// directory (`/sdcard/Android/data/<package>/files/api_recordings/`).
  /// This path is:
  ///   - accessible via `adb pull` WITHOUT `run-as`
  ///   - accessible WITHOUT stopping the app
  ///   - wiped automatically by Android when the user uninstalls the app
  ///   - does not require runtime permissions (scoped storage)
  ///
  /// On other platforms we fall back to the regular documents directory.
  static Future<void> init() async {
    if (!enabled) return;
    if (_baseDir != null) return;
    try {
      final base = await _pickBaseDirectory();
      _baseDir = '$base/api_recordings';
      _sessionStart = DateTime.now().toUtc();
      _sessionDir =
          '$_baseDir/${_sessionStart!.toIso8601String().replaceAll(':', '-')}';
      await Directory(_sessionDir!).create(recursive: true);
      DebugLogger.info(
        'Recorder',
        'enabled. Writing captures to: $_sessionDir',
      );
      DebugLogger.info(
        'Recorder',
        'extract with: adb pull ${_sessionDir!.replaceAll('\\', '/')} ./recordings',
      );
    } catch (e, st) {
      DebugLogger.error('Recorder', 'init failed; recording disabled', e, st);
      enabled = false;
    }
  }

  static Future<String> _pickBaseDirectory() async {
    try {
      // `getExternalStorageDirectories` returns a list (one entry per
      // storage volume). On Android the first entry is the app's own
      // external dir at `/sdcard/Android/data/<package>/files/`, which is
      // accessible via `adb pull` without `run-as` and without stopping
      // the app. On non-Android platforms this returns null.
      final ext = await getExternalStorageDirectories();
      if (ext != null && ext.isNotEmpty) {
        return ext.first.path;
      }
    } catch (_) {
      // fall through to the internal dir
    }
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  /// Records a request. [endpoint] is a short label like `search` or
  /// `browse-home`. [variant] is a free-form sub-label like `unfiltered` or
  /// `songs`. Headers/body are passed as Dart objects and will be pretty-
  /// printed if possible.
  static Future<void> recordRequest({
    required String endpoint,
    required String variant,
    required String method,
    required String url,
    required Map<String, dynamic> headers,
    required Object? body,
  }) async {
    await _write(
      endpoint: endpoint,
      variant: variant,
      kind: 'req',
      method: method,
      url: url,
      headers: headers,
      body: body,
    );
  }

  /// Records a response. Same parameters as [recordRequest] plus [statusCode]
  /// and [elapsedMs].
  static Future<void> recordResponse({
    required String endpoint,
    required String variant,
    required int statusCode,
    required int elapsedMs,
    required String method,
    required String url,
    required Map<String, dynamic> responseHeaders,
    required Object? body,
  }) async {
    await _write(
      endpoint: endpoint,
      variant: variant,
      kind: 'res',
      method: method,
      url: url,
      statusCode: statusCode,
      elapsedMs: elapsedMs,
      headers: responseHeaders,
      body: body,
    );
  }

  /// Records an error response (no body, or network failure).
  static Future<void> recordError({
    required String endpoint,
    required String variant,
    required Object error,
    StackTrace? stackTrace,
    String? method,
    String? url,
  }) async {
    await _write(
      endpoint: endpoint,
      variant: variant,
      kind: 'err',
      method: method,
      url: url,
      body: '$error\n\n$stackTrace',
    );
  }

  /// Returns the current session directory, or null if not enabled.
  static String? get currentSessionDir => _sessionDir;

  /// Force-flush by writing the session manifest. Useful right before app
  /// shutdown to make the directory self-describing.
  static Future<void> writeManifest({
    required String appVersion,
    required String platform,
  }) async {
    if (!enabled || _sessionDir == null) return;
    final manifest = {
      'startedAt': _sessionStart?.toIso8601String(),
      'appVersion': appVersion,
      'platform': platform,
      'baseUrl': '$_sessionDir',
      'tip': 'Each .txt file is headers + body. .json files are metadata.',
    };
    final f = File('$_sessionDir/_manifest.json');
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  // --- internals ------------------------------------------------------------

  static Future<void> _write({
    required String endpoint,
    required String variant,
    required String kind,
    String? method,
    String? url,
    int? statusCode,
    int? elapsedMs,
    Map<String, dynamic>? headers,
    Object? body,
  }) async {
    if (!enabled || _sessionDir == null) return;
    try {
      final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
      final safeVariant = variant.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final safeEndpoint = endpoint.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      // Use single underscore + dash as separators to avoid Dart treating
      // `__` as a single identifier boundary in the interpolation.
      final base = '$ts-$safeEndpoint-$safeVariant';
      final bodyText = _renderBody(body);
      final headerText = _renderHeaders(headers);
      final meta = <String, dynamic>{
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'endpoint': endpoint,
        'variant': variant,
        'kind': kind,
        if (method != null) 'method': method,
        if (url != null) 'url': url,
        if (statusCode != null) 'statusCode': statusCode,
        if (elapsedMs != null) 'elapsedMs': elapsedMs,
        'bodySizeChars': bodyText.length,
        'bodyPreview': bodyText.length > 200
            ? '${bodyText.substring(0, 200)}...'
            : bodyText,
      };

      final txt = StringBuffer();
      if (method != null && url != null) {
        txt.writeln('$method $url');
      }
      if (statusCode != null) {
        txt.writeln('Status: $statusCode');
      }
      if (elapsedMs != null) {
        txt.writeln('Elapsed: ${elapsedMs}ms');
      }
      if (headers != null && headers.isNotEmpty) {
        txt.writeln();
        txt.writeln('--- HEADERS ---');
        txt.writeln(headerText);
      }
      if (body != null) {
        txt.writeln();
        txt.writeln('--- BODY ---');
        txt.writeln(bodyText);
      }

      final txtFile = File('$_sessionDir/${base}__$kind.txt');
      final metaFile = File('$_sessionDir/${base}__$kind.json');
      await txtFile.writeAsString(txt.toString());
      await metaFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(meta),
      );

      await _enforceRetention();
    } catch (e, st) {
      DebugLogger.error('Recorder', 'failed to write capture', e, st);
    }
  }

  static String _renderBody(Object? body) {
    if (body == null) return '(empty)';
    try {
      return const JsonEncoder.withIndent('  ').convert(body);
    } catch (_) {
      return body.toString();
    }
  }

  static String _renderHeaders(Map<String, dynamic>? headers) {
    if (headers == null || headers.isEmpty) return '(none)';
    try {
      return const JsonEncoder.withIndent('  ').convert(headers);
    } catch (_) {
      return headers.toString();
    }
  }

  static Future<void> _enforceRetention() async {
    if (_sessionDir == null) return;
    try {
      final dir = Directory(_sessionDir!);
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.txt'))
          .toList();
      if (files.length <= maxFilesPerSession) return;
      files.sort(
        (a, b) => a.path.compareTo(b.path),
      ); // oldest first (ISO timestamps sort lex)
      final toRemove = files.length - maxFilesPerSession;
      for (var i = 0; i < toRemove; i++) {
        final txt = files[i] as File;
        final base = txt.path.replaceAll(RegExp(r'__req\.txt$|__res\.txt$|__err\.txt$'), '');
        await txt.delete();
        final meta = File('${base}__req.json');
        if (await meta.exists()) await meta.delete();
        final meta2 = File('${base}__res.json');
        if (await meta2.exists()) await meta2.delete();
        final meta3 = File('${base}__err.json');
        if (await meta3.exists()) await meta3.delete();
      }
    } catch (_) {
      // Retention is best-effort; never crash the app over it.
    }
  }
}
