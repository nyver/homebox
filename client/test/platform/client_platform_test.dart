import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/platform/client_platform.dart';

void main() {
  test('maps supported Flutter targets to HomeBox device platforms', () {
    expect(homeBoxDevicePlatformFor(TargetPlatform.android), 'ANDROID');
    expect(homeBoxDevicePlatformFor(TargetPlatform.windows), 'WINDOWS');
  });

  test('maps unsupported Flutter targets to OTHER', () {
    expect(homeBoxDevicePlatformFor(TargetPlatform.iOS), 'OTHER');
    expect(homeBoxDevicePlatformFor(TargetPlatform.linux), 'OTHER');
  });
}
