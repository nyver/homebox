/// Picks the user's language for text produced outside the widget tree, such
/// as a controller's error message, which has no [BuildContext] to read the
/// locale from. [AppLocaleController] keeps [languageCode] in step with the
/// language chosen in Settings; a message keeps the language it was created
/// in.
abstract final class UserText {
  /// The active UI language code (`en` or `ru`).
  static String languageCode = 'en';

  static String of({required String en, required String ru}) =>
      languageCode == 'ru' ? ru : en;
}
