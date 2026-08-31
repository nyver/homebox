import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges the selected Windows sync folder to the native runner so both the
/// Sync page and its notification-area menu can open it in Explorer.
final class WindowsSyncFolder {
  static const MethodChannel _channel = MethodChannel('homebox/windows');

  Future<void> setSelectedFolder(String folderPath) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await _channel.invokeMethod<void>('setSyncFolder', folderPath);
    } on MissingPluginException {
      // Widgets/tests on non-Windows hosts keep working without the runner.
    }
  }

  Future<bool> open() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return false;
    try {
      return await _channel.invokeMethod<bool>('openSyncFolder') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
