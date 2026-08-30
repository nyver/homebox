import 'package:flutter/foundation.dart';

/// Returns the protocol platform value accepted by HomeBox device registration.
///
/// Keep this mapping separate from presentation strings: it is sent to the
/// server and is part of the authenticated device record.
String homeBoxDevicePlatformFor(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => 'ANDROID',
  TargetPlatform.windows => 'WINDOWS',
  _ => 'OTHER',
};

/// The protocol platform for the running HomeBox client.
String get homeBoxDevicePlatform => homeBoxDevicePlatformFor(defaultTargetPlatform);
