import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/platform/android_file_sharer.dart';
import 'package:homebox_client/core/platform/camera_photo_picker.dart';

void main() {
  test('camera capture is exposed only on the supported Android target', () {
    expect(supportsCameraCapture(TargetPlatform.android), isTrue);
    expect(supportsCameraCapture(TargetPlatform.windows), isFalse);
    expect(supportsCameraCapture(TargetPlatform.iOS), isFalse);
  });

  test('file sharing is exposed only on the supported Android target', () {
    expect(supportsAndroidFileSharing(TargetPlatform.android), isTrue);
    expect(supportsAndroidFileSharing(TargetPlatform.windows), isFalse);
    expect(supportsAndroidFileSharing(TargetPlatform.iOS), isFalse);
  });
}
