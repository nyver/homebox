import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Delivers files dragged from Explorer onto the native Windows window to
/// the Files view: the drag hovering (to highlight the target), leaving,
/// and the final drop.
///
/// The Windows runner owns the OLE drop target, while this bridge keeps the
/// platform boundary small and lets the normal encrypted upload flow own
/// every file read and network request. Positions are in physical pixels of
/// the Flutter view; divide by the device pixel ratio for logical pixels.
/// A null position means the runner could not tell (older drop path).
final class WindowsFileDrop {
  static const MethodChannel _channel = MethodChannel('homebox/windows');

  static Future<void> listen({
    required Future<void> Function(List<String> paths, Offset? position)
    onFilesDropped,
    void Function(Offset position)? onHover,
    VoidCallback? onExit,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'fileDragHover':
          final position = _position(call.arguments);
          if (position != null) onHover?.call(position);
        case 'fileDragExit':
          onExit?.call();
        case 'filesDropped':
          final arguments = call.arguments;
          // A bare list is the older payload without a position.
          final rawPaths = arguments is Map ? arguments['paths'] : arguments;
          final paths = (rawPaths as List<Object?>? ?? const <Object?>[])
              .whereType<String>()
              .where((path) => path.isNotEmpty)
              .toList(growable: false);
          onExit?.call();
          if (paths.isNotEmpty) {
            await onFilesDropped(paths, _position(arguments));
          }
      }
    });
  }

  static Offset? _position(Object? arguments) {
    if (arguments is! Map) return null;
    final x = arguments['x'];
    final y = arguments['y'];
    if (x is! int || y is! int || x < 0 || y < 0) return null;
    return Offset(x.toDouble(), y.toDouble());
  }

  static void stopListening() => _channel.setMethodCallHandler(null);
}
