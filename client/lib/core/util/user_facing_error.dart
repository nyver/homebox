import 'dart:io';

import '../transport/homebox_api_client.dart';
import '../transport/network_errors.dart';
import '../transport/pinned_http_client.dart';
import '../localization/user_text.dart';

/// Turns an exception raised by a HomeBox operation into a sentence that can
/// be shown to the user. Raw `toString()` output such as
/// `HomeBoxApiException(409 REVISION_CONFLICT): …` or a `SocketException`
/// dump explains nothing to a non-developer, so known failure kinds get a
/// plain description and a hint about what to do next.
String describeError(Object error) {
  if (error is ServerIdentityMismatchException) {
    return UserText.of(
      en:
          'The server presented a different identity than the one you '
          'verified, so HomeBox refused to connect. Confirm the server '
          'fingerprint with its administrator before reconnecting.',
      ru:
          'Сервер предъявил не тот ключ, который вы проверяли, поэтому HomeBox '
          'отказался подключаться. Сверьте отпечаток сервера с администратором.',
    );
  }
  if (isTransientNetworkError(error)) {
    return UserText.of(
      en: 'Cannot reach the HomeBox server. Check the network and try again.',
      ru: 'Нет связи с сервером HomeBox. Проверьте сеть и повторите попытку.',
    );
  }
  if (error is HomeBoxApiException) return _describeApiError(error);
  if (error is FileSystemException) {
    final reason = error.osError?.message.trim();
    final path = error.path;
    final subject = path == null || path.isEmpty
        ? UserText.of(en: 'a local file', ru: 'локальному файлу')
        : '"$path"';
    return reason == null || reason.isEmpty
        ? UserText.of(
            en: 'Could not access $subject.',
            ru: 'Нет доступа к $subject.',
          )
        : UserText.of(
            en: 'Could not access $subject: $reason',
            ru: 'Нет доступа к $subject: $reason',
          );
  }
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message;
  if (error is ArgumentError) {
    return '${error.message ?? UserText.of(en: 'Invalid input.', ru: 'Некорректные данные.')}';
  }
  final text = '$error';
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}

String _describeApiError(HomeBoxApiException error) {
  final reference = error.requestId.isEmpty
      ? ''
      : UserText.of(
          en: ' (reference ${error.requestId})',
          ru: ' (код ${error.requestId})',
        );
  return switch (error.code) {
    'AUTH_INVALID_CREDENTIALS' => UserText.of(
      en: 'Incorrect username or password.',
      ru: 'Неверное имя пользователя или пароль.',
    ),
    'AUTH_RATE_LIMITED' => UserText.of(
      en: 'Too many failed sign-in attempts. Wait a minute and try again.',
      ru: 'Слишком много неудачных попыток входа. Подождите минуту и повторите.',
    ),
    'AUTH_TOKEN_EXPIRED' => UserText.of(
      en: 'Your session has expired. Sign in again.',
      ru: 'Сеанс истёк. Войдите снова.',
    ),
    'AUTH_DEVICE_REVOKED' => UserText.of(
      en: 'This device was removed from your account. Sign in again to register it.',
      ru: 'Это устройство удалено из аккаунта. Войдите снова, чтобы зарегистрировать его.',
    ),
    'REVISION_CONFLICT' => UserText.of(
      en: 'This item was changed on another device. Refresh and try again.',
      ru: 'Элемент изменили на другом устройстве. Обновите и повторите.',
    ),
    'NOT_FOUND' || 'UPLOAD_NOT_FOUND' => UserText.of(
      en: 'This item no longer exists on the server. Refresh to update the list.',
      ru: 'Элемента больше нет на сервере. Обновите список.',
    ),
    'FORBIDDEN' => UserText.of(
      en: 'You do not have access to this item.',
      ru: 'У вас нет доступа к этому элементу.',
    ),
    'UPLOAD_EXPIRED' ||
    'UPLOAD_CHUNK_INVALID' ||
    'UPLOAD_ID_CONFLICT' => UserText.of(
      en: 'The upload could not be completed. Try again.',
      ru: 'Не удалось завершить загрузку. Повторите попытку.',
    ),
    'UPLOAD_LIMIT_REACHED' => UserText.of(
      en: 'Too many unfinished uploads from this device. Wait for them to finish and try again.',
      ru: 'Слишком много незавершённых загрузок с этого устройства. Дождитесь их окончания и повторите.',
    ),
    'SYNC_CURSOR_INVALID' => UserText.of(
      en: 'Sync state is out of date. HomeBox will resynchronize.',
      ru: 'Состояние синхронизации устарело. HomeBox синхронизируется заново.',
    ),
    // Validation messages are written by the server for display.
    'VALIDATION_ERROR' => error.message,
    'INTERNAL_ERROR' => UserText.of(
      en: 'The server could not complete the request$reference.',
      ru: 'Сервер не смог выполнить запрос$reference.',
    ),
    _ => '${error.message}$reference',
  };
}
