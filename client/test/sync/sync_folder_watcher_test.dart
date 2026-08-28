import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/features/syncfolder/sync_folder_watcher.dart';

void main() {
  test(
    'debounces user paths and ignores materializer temporary files',
    () async {
      final events = StreamController<String>.broadcast();
      addTearDown(events.close);
      var calls = 0;
      final watcher = SyncFolderWatcher(
        onChange: () async => calls++,
        debounce: const Duration(milliseconds: 5),
        eventStream: (_) => events.stream,
      );
      addTearDown(watcher.dispose);

      watcher.start('/sync-root');
      events
        ..add('/sync-root/photo.jpg.homebox-tmp')
        ..add('/sync-root/photo.jpg')
        ..add('/sync-root/notes.txt');

      await _waitFor(() => calls == 1);
      expect(watcher.status, SyncFolderWatcherStatus.watching);

      watcher.stop();
      events.add('/sync-root/after-stop.txt');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1);
    },
  );

  test('queues one follow-up pass while a sync pass is running', () async {
    final events = StreamController<String>.broadcast();
    addTearDown(events.close);
    final firstPass = Completer<void>();
    var calls = 0;
    final watcher = SyncFolderWatcher(
      onChange: () async {
        calls++;
        if (calls == 1) await firstPass.future;
      },
      debounce: const Duration(milliseconds: 5),
      eventStream: (_) => events.stream,
    );
    addTearDown(watcher.dispose);

    watcher.start('/sync-root');
    events.add('/sync-root/first.txt');
    await _waitFor(() => calls == 1);
    events.add('/sync-root/second.txt');
    await Future<void>.delayed(const Duration(milliseconds: 15));
    firstPass.complete();

    await _waitFor(() => calls == 2);
  });

  test('stopping while a pass runs cannot reactivate the watcher', () async {
    final events = StreamController<String>.broadcast();
    addTearDown(events.close);
    final firstPass = Completer<void>();
    var calls = 0;
    final watcher = SyncFolderWatcher(
      onChange: () async {
        calls++;
        await firstPass.future;
      },
      debounce: const Duration(milliseconds: 5),
      eventStream: (_) => events.stream,
    );
    addTearDown(watcher.dispose);

    watcher.start('/sync-root');
    events.add('/sync-root/first.txt');
    await _waitFor(() => calls == 1);
    watcher.stop();
    firstPass.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(watcher.status, SyncFolderWatcherStatus.stopped);
    expect(calls, 1);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Condition did not become true before the timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
