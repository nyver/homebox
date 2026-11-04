import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/transport/homebox_api_client.dart';
import 'package:homebox_client/core/transport/pinned_http_client.dart';
import 'package:homebox_client/core/util/user_facing_error.dart';

void main() {
  test('API errors become plain sentences instead of exception dumps', () {
    const conflict = HomeBoxApiException(
      statusCode: 409,
      code: 'REVISION_CONFLICT',
      message: 'node revision conflict',
      requestId: 'r-1',
    );
    expect(describeError(conflict), contains('changed on another device'));
    expect(describeError(conflict), isNot(contains('HomeBoxApiException')));

    const internal = HomeBoxApiException(
      statusCode: 500,
      code: 'INTERNAL_ERROR',
      message: 'an internal error occurred',
      requestId: 'req-42',
    );
    expect(describeError(internal), contains('req-42'));
  });

  test('connectivity failures read as offline, a pin mismatch never does', () {
    for (final error in <Object>[
      const SocketException('refused'),
      TimeoutException('stalled'),
      const HttpException('Connection closed'),
    ]) {
      expect(describeError(error), contains('Cannot reach the HomeBox server'));
    }
    final mismatch = describeError(const ServerIdentityMismatchException('ab'));
    expect(mismatch, contains('different identity'));
    expect(mismatch, isNot(contains('Cannot reach')));
  });

  test('local and validation failures keep their own message', () {
    expect(describeError(const FormatException('Too large.')), 'Too large.');
    expect(describeError(StateError('No content yet.')), 'No content yet.');
    expect(
      describeError(const FileSystemException('Access denied', r'C:\a.txt')),
      contains(r'C:\a.txt'),
    );
  });
}
