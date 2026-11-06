import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/localization/app_locale_controller.dart';
import 'package:homebox_client/core/localization/user_text.dart';
import 'package:homebox_client/core/util/user_facing_error.dart';

final class _MemoryLanguageStorage implements AppLanguageStorage {
  _MemoryLanguageStorage([this.value]);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String languageCode) async {
    value = languageCode;
  }
}

void main() {
  test('restores and persists the selected application language', () async {
    final storage = _MemoryLanguageStorage('ru');
    final controller = AppLocaleController(storage);
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.language, AppLanguage.russian);

    await controller.setLanguage(AppLanguage.english);
    expect(controller.language, AppLanguage.english);
    expect(storage.value, 'en');
  });

  test('messages built outside the widget tree follow the language', () async {
    final controller = AppLocaleController(_MemoryLanguageStorage());
    addTearDown(controller.dispose);
    addTearDown(() => UserText.languageCode = 'en');

    await controller.setLanguage(AppLanguage.russian);
    expect(UserText.of(en: 'Cancel', ru: 'Отмена'), 'Отмена');
    expect(
      describeError(const SocketException('down')),
      startsWith('Нет связи с сервером HomeBox'),
    );

    await controller.setLanguage(AppLanguage.english);
    expect(UserText.of(en: 'Cancel', ru: 'Отмена'), 'Cancel');
  });
}
