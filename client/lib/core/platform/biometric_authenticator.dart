import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Android is the only platform with an app-level biometric lock for now.
bool supportsBiometricAppLock(TargetPlatform platform) =>
    platform == TargetPlatform.android;

/// The platform boundary for unlocking HomeBox once, at launch. Deliberately
/// not re-checked on every background/foreground cycle: many in-app flows
/// (the system file picker, the Android "Save As" picker, camera capture)
/// briefly background the app as part of their own normal operation, and
/// re-locking on each of those would both interrupt whatever was in
/// progress and prompt for biometrics far more often than a user expects.
abstract interface class BiometricAuthenticator {
  /// Returns whether the device has an enrolled biometric method available.
  Future<bool> isAvailable();

  /// Prompts the user for an enrolled biometric and reports whether it passed.
  Future<bool> authenticate();
}

final class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication? localAuthentication})
    : _localAuthentication = localAuthentication ?? LocalAuthentication();

  final LocalAuthentication _localAuthentication;

  @override
  Future<bool> isAvailable() async =>
      await _localAuthentication.isDeviceSupported() &&
      await _localAuthentication.canCheckBiometrics;

  @override
  Future<bool> authenticate() => _localAuthentication.authenticate(
    localizedReason: 'Unlock HomeBox to access your encrypted files.',
    options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
  );
}
