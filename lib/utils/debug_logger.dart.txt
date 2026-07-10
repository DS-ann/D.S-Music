import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Log severity levels, ordered from least to most severe.
enum LogLevel { trace, debug, info, warn, error }

/// A lightweight, color-aware, structured logger for debug builds.
///
/// - No-ops in release mode unless [forceEnabled] is true (useful for unit
///   tests or local debugging of release builds).
/// - Output goes through [debugPrint] so it appears in `flutter logs` and
///   `adb logcat` (Android) or the Xcode console (iOS).
/// - Each line is prefixed with `[timestamp] [LEVEL] [TAG]`.
/// - Long values are truncated to [maxObjectChars] for readability; pass
///   [fullDump] to log the full JSON.
///
/// Example:
/// ```dart
/// DebugLogger.info('HTTP', 'GET /search?q=bruno');
/// DebugLogger.dump('search', resultContent);
/// ```
class DebugLogger {
  DebugLogger._();

  /// Master switch. Defaults to `kDebugMode`. Tests can flip this on to assert
  /// log output without going through `debugPrint`.
  static bool forceEnabled = false;

  /// Maximum number of characters to print for a single object before
  /// truncating with an ellipsis. Set to `0` to disable truncation.
  static int maxObjectChars = 800;

  // --- Public API -----------------------------------------------------------

  static void trace(String tag, String message) =>
      _log(LogLevel.trace, tag, message);

  static void debug(String tag, String message) =>
      _log(LogLevel.debug, tag, message);

  static void info(String tag, String message) =>
      _log(LogLevel.info, tag, message);

  static void warn(String tag, String message) =>
      _log(LogLevel.warn, tag, message);

  static void error(String tag, String message, [Object? err, StackTrace? st]) {
    _log(LogLevel.error, tag, message);
    if (err != null) _log(LogLevel.error, tag, '  cause: $err');
    if (st != null) _log(LogLevel.error, tag, '  stack:\n$st');
  }

  /// Pretty-prints a Dart object as JSON where possible, otherwise as `toString()`.
  /// Useful for dumping the full `resultContent` map to the console.
  static void dump(
    String tag,
    Object? value, {
    String label = '',
    bool fullDump = false,
  }) {
    final rendered = _render(value, fullDump: fullDump);
    final prefix = label.isEmpty ? '' : '$label = ';
    _log(LogLevel.debug, tag, '$prefix$rendered');
  }

  // --- Internals ------------------------------------------------------------

  static void _log(LogLevel level, String tag, String message) {
    if (kReleaseMode && !forceEnabled) return;

    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final colored = _colorize(level, '[$ts] [${_label(level)}] [$tag] $message');
    debugPrint(colored);
  }

  static String _label(LogLevel level) {
    switch (level) {
      case LogLevel.trace:
        return 'TRACE';
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO ';
      case LogLevel.warn:
        return 'WARN ';
      case LogLevel.error:
        return 'ERROR';
    }
  }

  static String _colorize(LogLevel level, String text) {
    // ANSI: 90=gray, 36=cyan, 32=green, 33=yellow, 31=red
    const codes = {
      LogLevel.trace: 90,
      LogLevel.debug: 36,
      LogLevel.info: 32,
      LogLevel.warn: 33,
      LogLevel.error: 31,
    };
    final code = codes[level]!;
    return '\x1B[${code}m$text\x1B[0m';
  }

  static String _render(Object? value, {required bool fullDump}) {
    if (value == null) return 'null';
    try {
      // Encodable (Map, List, primitives) -> pretty JSON
      final encoded = const JsonEncoder.withIndent('  ').convert(value);
      if (fullDump || maxObjectChars == 0 || encoded.length <= maxObjectChars) {
        return encoded;
      }
      return '${encoded.substring(0, maxObjectChars)}... '
          '[truncated, total=${encoded.length} chars]';
    } catch (_) {
      // Fall back to toString()
      final s = value.toString();
      if (fullDump || maxObjectChars == 0 || s.length <= maxObjectChars) {
        return s;
      }
      return '${s.substring(0, maxObjectChars)}... '
          '[truncated, total=${s.length} chars]';
    }
  }
}