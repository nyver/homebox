import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Delivers paths dropped onto the native Windows window to the Files view.
///
/// The Windows runner owns accepting the shell drop, while this bridge keeps
/// the platform boundary small and lets the normal encrypted upload flow own
/// every file read and network request.
final class WindowsFileDrop {
  static const MethodChannel _channel = MethodChannel('homebox/windows');

  static Future<void> listen(
    Future<void> Function(List<String> paths) onFilesDropped,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'filesDropped') return;
      final paths = (call.arguments as List<Object?>? ?? const <Object?>[])
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toList(growable: false);
      if (paths.isNotEmpty) await onFilesDropped(paths);
    });
  }

  static void stopListening() => _channel.setMethodCallHandler(null);
}
