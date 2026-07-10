import 'dart:convert';

import 'package:dio/dio.dart';

import '../utils/debug_logger.dart';
import '../utils/response_recorder.dart';

/// Dio interceptor that emits **concise, scannable** logs for every request
/// and response. Disabled in release mode.
///
/// **Important design rule:** the full request/response bodies are NEVER
/// dumped to the console. Response bodies for the YouTube Music internal
/// API are routinely 100-300 KB of JSON, which immediately overflows the
/// logcat/console buffer and makes the app unusable. The full bodies are
/// saved to disk by [ResponseRecorder] (when enabled) so they can be
/// inspected offline in a text editor.
///
/// Log shape:
/// ```
/// [INFO ] [HTTP] ──> POST  https://music.youtube.com/youtubei/v1/search?...
/// [INFO ] [HTTP]     body: 0.4 KB
/// [INFO ] [HTTP] <── 200 POST  (1047ms, 211.3 KB, top-keys=[responseContext, contents])
/// ```
///
/// If [ResponseRecorder.enabled] is true, the same call also writes
/// `<app docs>/api_recordings/<session>/<ts>-<endpoint>-<variant>-res.txt`
/// with the full body pretty-printed (2-space indent).
class HttpLoggingInterceptor extends Interceptor {
  HttpLoggingInterceptor({this.tag = 'HTTP'});

  final String tag;
  static const _stopwatchKey = '__debug_logger_started_at';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_stopwatchKey] = DateTime.now();
    final uri = _uriString(options);
    final sizeKb = _approxKb(options.data);
    DebugLogger.info(tag,
        '──> ${options.method.padRight(5)} $uri  body=${sizeKb}KB');
    _fireAndForget(
      ResponseRecorder.recordRequest(
        endpoint: _endpointLabel(options),
        variant: _variantLabel(options),
        method: options.method,
        url: uri,
        headers: options.headers,
        body: _normalizeForLog(options.data),
      ),
    );
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final elapsed = _elapsedMs(response.requestOptions);
    final sizeKb = _approxKb(response.data);
    final topKeys = _topLevelKeys(response.data);
    DebugLogger.info(
      tag,
      '<── ${response.statusCode} '
      '${response.requestOptions.method.padRight(5)} '
      '(${elapsed}ms, $sizeKb KB, top-keys=$topKeys)',
    );
    _fireAndForget(
      ResponseRecorder.recordResponse(
        endpoint: _endpointLabel(response.requestOptions),
        variant: _variantLabel(response.requestOptions),
        statusCode: response.statusCode ?? 0,
        elapsedMs: elapsed,
        method: response.requestOptions.method,
        url: _uriString(response.requestOptions),
        responseHeaders: response.headers.map,
        body: _normalizeForLog(response.data),
      ),
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final elapsed = _elapsedMs(err.requestOptions);
    DebugLogger.error(
      tag,
      'xx ${err.requestOptions.method.padRight(5)} '
      '${err.response?.statusCode ?? "no-status"} '
      '(${elapsed}ms) ${_uriString(err.requestOptions)}',
      err,
      err.stackTrace,
    );
    _fireAndForget(
      ResponseRecorder.recordError(
        endpoint: _endpointLabel(err.requestOptions),
        variant: _variantLabel(err.requestOptions),
        error: err,
        stackTrace: err.stackTrace,
        method: err.requestOptions.method,
        url: _uriString(err.requestOptions),
      ),
    );
    handler.next(err);
  }

  // --- helpers --------------------------------------------------------------

  String _uriString(RequestOptions o) {
    final base = o.baseUrl;
    final path = o.path;
    final full = base.isEmpty ? path : '$base$path';
    if (o.queryParameters.isEmpty) return full;
    final query = o.queryParameters.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value.toString())}')
        .join('&');
    return '$full?$query';
  }

  int _elapsedMs(RequestOptions o) {
    final start = o.extra[_stopwatchKey];
    if (start is DateTime) {
      return DateTime.now().difference(start).inMilliseconds;
    }
    return -1;
  }

  String _approxKb(Object? data) {
    try {
      final s = data is String ? data : json.encode(data);
      return (s.length / 1024).toStringAsFixed(1);
    } catch (_) {
      return '?';
    }
  }

  /// Shape data for the recorder file. We pass JSON-serializable objects
  /// through unchanged and replace non-serializable things (bytes, FormData)
  /// with placeholders so the recorder can pretty-print without crashing.
  Object? _normalizeForLog(Object? data) {
    if (data is List<int>) {
      return '<binary ${data.length} bytes>';
    }
    if (data is FormData) {
      return '<form data fields=${data.fields.length} files=${data.files.length}>';
    }
    return data;
  }

  /// Return the top-level keys of a Map response, or `[]` for other shapes.
  /// Used for a one-line summary in the log so you can see at a glance
  /// what the response contains without dumping the full body.
  List<String> _topLevelKeys(Object? data) {
    if (data is Map) {
      return data.keys.take(6).map((e) => e.toString()).toList();
    }
    if (data is List) {
      return ['<list len=${data.length}>'];
    }
    return const [];
  }

  /// Derive a short, stable endpoint label from the path so the recorder
  /// files are easy to group. Returns just the last segment of the path
  /// (e.g. `search`, `browse`, `next`, `player`) with any query string
  /// stripped. Strips the `youtubei/v1/` prefix so the label is portable
  /// to other base URLs.
  String _endpointLabel(RequestOptions o) {
    final raw = o.path;
    // Strip leading slash.
    var p = raw.startsWith('/') ? raw.substring(1) : raw;
    // Drop query string if present.
    final q = p.indexOf('?');
    if (q >= 0) p = p.substring(0, q);
    // Drop `youtubei/v1/` prefix.
    if (p.startsWith('youtubei/v1/')) p = p.substring('youtubei/v1/'.length);
    // If the path is multi-segment, keep the first one (e.g. `music/get_search_suggestions`).
    final slash = p.indexOf('/');
    if (slash > 0) p = p.substring(0, slash);
    return p.isEmpty ? 'unknown' : p;
  }

  /// Best-effort variant label: for search requests, look at the body to
  /// detect unfiltered vs filtered. For browse, use the browseId. Falls
  /// back to a stable hash of the URL.
  String _variantLabel(RequestOptions o) {
    final path = o.path;
    if (path.contains('search') || path == 'search') {
      final data = o.data;
      if (data is Map) {
        if (!data.containsKey('params') || data['params'] == null) {
          return 'unfiltered';
        }
        final params = data['params'].toString();
        if (params.contains('playlists')) return 'playlists';
        if (params.contains('songs')) return 'songs';
        if (params.contains('videos')) return 'videos';
        if (params.contains('albums')) return 'albums';
        if (params.contains('artists')) return 'artists';
        return 'filtered';
      }
      return 'unfiltered';
    }
    if (path.contains('browse')) {
      final data = o.data;
      if (data is Map && data['browseId'] != null) {
        return data['browseId'].toString();
      }
    }
    return 'default';
  }

  /// Fire-and-forget so recorder I/O never blocks or breaks the request
  /// pipeline. Errors are already logged inside the recorder itself.
  void _fireAndForget(Future<void> future) {
    future.catchError((Object e, StackTrace st) {
      DebugLogger.error('Recorder', 'unhandled error', e, st);
    });
  }
}
