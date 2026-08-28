// Constructor parameters keep the public callback names readable.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef SyncFolderChangeHandler = Future<void> Function();
typedef SyncFolderPathEventStream = Stream<String> Function(String rootPath);

enum SyncFolderWatcherStatus { stopped, watching, error }

/// Coalesces native filesystem notifications into safe sync-folder passes.
///
/// The owner must make [onChange] serialize pull-before-push work; the
/// desktop app uses its existing `_runSyncFolderPass` coordinator for that.
/// This class only observes paths and never reads plaintext file contents.
final class SyncFolderWatcher extends ChangeNotifier {
  SyncFolderWatcher({
    required SyncFolderChangeHandler onChange,
    Duration debounce = const Duration(milliseconds: 750),
    SyncFolderPathEventStream? eventStream,
  }) : _onChange = onChange,
       _debounce = debounce,
       _eventStream = eventStream ?? _watchDirectory;

  final SyncFolderChangeHandler _onChange;
  final Duration _debounce;
  final SyncFolderPathEventStream _eventStream;

  StreamSubscription<String>? _subscription;
  Timer? _timer;
  int _generation = 0;
  bool _runningCallback = false;
  int? _queuedCallbackGeneration;
  bool _disposed = false;
  SyncFolderWatcherStatus _status = SyncFolderWatcherStatus.stopped;
  String? _errorMessage;

  SyncFolderWatcherStatus get status => _status;
  String? get errorMessage => _errorMessage;

  /// Starts watching [rootPath], replacing any earlier watched directory.
  /// Paths ending in `.homebox-tmp` are materializer staging files and do not
  /// represent user changes.
  void start(String rootPath) {
    if (rootPath.isEmpty) {
      throw ArgumentError.value(rootPath, 'rootPath');
    }
    stop();
    final generation = ++_generation;
    _subscription = _eventStream(rootPath).listen(
      (path) => _onPathEvent(generation, path),
      onError: (Object error, StackTrace stackTrace) =>
          _onWatchError(generation, error),
    );
    _errorMessage = null;
    _setStatus(SyncFolderWatcherStatus.watching);
  }

  void stop() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _queuedCallbackGeneration = null;
    _errorMessage = null;
    _setStatus(SyncFolderWatcherStatus.stopped);
  }

  void _onPathEvent(int generation, String path) {
    if (_disposed || generation != _generation || _isTemporaryPath(path)) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      if (_disposed || generation != _generation) return;
      unawaited(_runCallback(generation));
    });
  }

  Future<void> _runCallback(int generation) async {
    if (_runningCallback) {
      _queuedCallbackGeneration = generation;
      return;
    }
    _runningCallback = true;
    try {
      do {
        _queuedCallbackGeneration = null;
        await _onChange();
      } while (_queuedCallbackGeneration == generation && !_disposed);
      if (!_disposed && generation == _generation) {
        _errorMessage = null;
        _setStatus(SyncFolderWatcherStatus.watching);
      }
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _errorMessage = '$error';
        _setStatus(SyncFolderWatcherStatus.error);
      }
    } finally {
      _runningCallback = false;
      final queuedGeneration = _queuedCallbackGeneration;
      _queuedCallbackGeneration = null;
      if (!_disposed &&
          queuedGeneration != null &&
          queuedGeneration == _generation) {
        unawaited(_runCallback(queuedGeneration));
      }
    }
  }

  void _onWatchError(int generation, Object error) {
    if (_disposed || generation != _generation) return;
    _errorMessage = '$error';
    _setStatus(SyncFolderWatcherStatus.error);
  }

  bool _isTemporaryPath(String path) => path.endsWith('.homebox-tmp');

  void _setStatus(SyncFolderWatcherStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

Stream<String> _watchDirectory(String rootPath) =>
    Directory(rootPath).watch(recursive: true).map((event) => event.path);
