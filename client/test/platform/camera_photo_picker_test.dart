import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/platform/camera_photo_picker.dart';

void main() {
  test('camera capture is exposed only on the supported Android target', () {
    expect(supportsCameraCapture(TargetPlatform.android), isTrue);
    expect(supportsCameraCapture(TargetPlatform.windows), isFalse);
    expect(supportsCameraCapture(TargetPlatform.iOS), isFalse);
  });
}
