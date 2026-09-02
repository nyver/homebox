import 'dart:async';

import 'package:flutter/foundation.dart';

/// One visible confirmation that a decrypted server file reached its chosen
/// local destination.
final class DownloadCompletionNotification {
  const DownloadCompletionNotification({
    required this.id,
    required this.fileName,
    required this.location,
  });

  final int id;
  final String fileName;
  final String location;
}

/// Keeps a small, independently-dismissible stack of completed downloads.
///
/// A [SnackBar] only shows one message at a time, which makes successive
/// downloads easy to miss. This controller deliberately keeps separate cards
/// visible at once while bounding the stack so it cannot cover the Files UI.
final class DownloadNotificationController extends ChangeNotifier {
  DownloadNotificationController({
    this.visibleLimit = 3,
    this.displayDuration = const Duration(seconds: 10),
  }) : assert(visibleLimit > 0);

  final int visibleLimit;
  final Duration displayDuration;
  final List<DownloadCompletionNotification> _notifications = [];
  final Map<int, Timer> _dismissTimers = {};
  int _nextId = 0;

  List<DownloadCompletionNotification> get notifications =>
      List.unmodifiable(_notifications);

  void show({required String fileName, required String location}) {
    final notification = DownloadCompletionNotification(
      id: _nextId++,
      fileName: fileName,
      location: location,
    );
    _notifications.add(notification);
    _dismissTimers[notification.id] = Timer(displayDuration, () {
      dismiss(notification.id);
    });

    while (_notifications.length > visibleLimit) {
      _remove(_notifications.first.id);
    }
    notifyListeners();
  }

  void dismiss(int id) {
    if (!_remove(id)) return;
    notifyListeners();
  }

  bool _remove(int id) {
    final index = _notifications.indexWhere(
      (notification) => notification.id == id,
    );
    if (index == -1) return false;
    _notifications.removeAt(index);
    _dismissTimers.remove(id)?.cancel();
    return true;
  }

  @override
  void dispose() {
    for (final timer in _dismissTimers.values) {
      timer.cancel();
    }
    _dismissTimers.clear();
    super.dispose();
  }
}
