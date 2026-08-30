import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AppLanguage {
  english('en'),
  russian('ru');

  const AppLanguage(this.languageCode);

  final String languageCode;
}

abstract interface class AppLanguageStorage {
  Future<String?> read();

  Future<void> write(String languageCode);
}

final class PlatformAppLanguageStorage implements AppLanguageStorage {
  const PlatformAppLanguageStorage([
    this._storage = const FlutterSecureStorage(),
  ]);

  static const _key = 'homebox.app_language.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String languageCode) =>
      _storage.write(key: _key, value: languageCode);
}

/// Holds the user's UI-language choice independently from server settings.
final class AppLocaleController extends ChangeNotifier {
  AppLocaleController([AppLanguageStorage? storage])
    : _storage = storage ?? const PlatformAppLanguageStorage();

  final AppLanguageStorage _storage;
  AppLanguage _language = AppLanguage.english;

  AppLanguage get language => _language;

  Future<void> initialize() async {
    String? stored;
    try {
      stored = await _storage.read();
    } catch (_) {
      return; // A language preference must never prevent app startup.
    }
    final language = AppLanguage.values
        .where((candidate) => candidate.languageCode == stored)
        .firstOrNull;
    if (language == null || language == _language) return;
    _language = language;
    notifyListeners();
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (language == _language) return;
    _language = language;
    notifyListeners();
    try {
      await _storage.write(language.languageCode);
    } catch (_) {
      // The selected language remains active for this app session.
    }
  }
}
