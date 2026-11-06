import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/platform/windows_file_drop.dart';

Future<void> _send(String method, [Object? arguments]) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'homebox/windows',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hover, leave and drop messages reach the Files callbacks', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() {
      WindowsFileDrop.stopListening();
      debugDefaultTargetPlatformOverride = null;
    });
    final hovers = <Offset>[];
    var exits = 0;
    final drops = <(List<String>, Offset?)>[];
    await WindowsFileDrop.listen(
      onFilesDropped: (paths, position) async => drops.add((paths, position)),
      onHover: hovers.add,
      onExit: () => exits++,
    );

    await _send('fileDragHover', {'x': 120, 'y': 40});
    await _send('fileDragExit');
    await _send('filesDropped', {
      'paths': ['C:\\a.txt', '', 'C:\\b.txt'],
      'x': 10,
      'y': 20,
    });
    // The older payload: a bare list and no position.
    await _send('filesDropped', ['C:\\c.txt']);
    // The runner's "unknown position" marker.
    await _send('filesDropped', {
      'paths': ['C:\\d.txt'],
      'x': -1,
      'y': -1,
    });

    expect(hovers, [const Offset(120, 40)]);
    // Each drop also ends the drag highlight.
    expect(exits, 4);
    expect(drops.map((drop) => drop.$1), [
      ['C:\\a.txt', 'C:\\b.txt'],
      ['C:\\c.txt'],
      ['C:\\d.txt'],
    ]);
    expect(drops.map((drop) => drop.$2), [const Offset(10, 20), null, null]);
    debugDefaultTargetPlatformOverride = null;
  });
}
