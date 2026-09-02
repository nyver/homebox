import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/platform/windows_sync_folder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('homebox/windows');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('opens the requested materialized file location', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    String? requestedPath;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'openFileLocation');
          requestedPath = call.arguments as String;
          return true;
        });

    final opened = await WindowsSyncFolder().openFileLocation(
      r'C:\HomeBox\Sync\report.pdf',
    );

    expect(opened, isTrue);
    expect(requestedPath, r'C:\HomeBox\Sync\report.pdf');
  });

  test('does not invoke the native runner for an empty file path', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    expect(await WindowsSyncFolder().openFileLocation(''), isFalse);
  });
}
