import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Windows notification-area icon: its status tooltip, its menu labels
/// in the app's language, and system notifications shown from it.
final class WindowsTray {
  const WindowsTray();

  static const MethodChannel _channel = MethodChannel('homebox/windows');

  bool get _supported => defaultTargetPlatform == TargetPlatform.windows;

  Future<void> setStatus({
    required String tooltip,
    required String showLabel,
    required String openFolderLabel,
    required String exitLabel,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('setTrayStatus', {
        'tooltip': tooltip,
        'show': showLabel,
        'openFolder': openFolderLabel,
        'exit': exitLabel,
      });
    } on MissingPluginException {
      // Widgets/tests on non-Windows hosts keep working without the runner.
    } on PlatformException {
      // A status hint must never disturb the app.
    }
  }

  Future<void> notify({required String title, required String body}) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('showNotification', {
        'title': title,
        'body': body,
      });
    } on MissingPluginException {
      // See setStatus.
    } on PlatformException {
      // See setStatus.
    }
  }
}

/// Something that newly needs the user's attention.
enum AttentionKind { syncConflict, failedTransfer, syncError }

/// Turns the current counts into "what is new since last time", so each
/// conflict, failed transfer or sync error is announced once rather than on
/// every status change.
final class AttentionTracker {
  int _conflicts = 0;
  int _failedTransfers = 0;
  bool _syncError = false;

  Set<AttentionKind> update({
    required int openConflicts,
    required int unseenFailedTransfers,
    required bool syncError,
  }) {
    final news = <AttentionKind>{
      if (openConflicts > _conflicts) AttentionKind.syncConflict,
      if (unseenFailedTransfers > _failedTransfers)
        AttentionKind.failedTransfer,
      if (syncError && !_syncError) AttentionKind.syncError,
    };
    _conflicts = openConflicts;
    _failedTransfers = unseenFailedTransfers;
    _syncError = syncError;
    return news;
  }
}
