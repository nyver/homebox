import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/util/local_path.dart';

void main() {
  test('isTransientSyncFileName flags staging and lock files only', () {
    expect(isTransientSyncFileName('photo.jpg.homebox-tmp'), isTrue);
    expect(isTransientSyncFileName('passwords.kdbx.lock'), isTrue);
    expect(isTransientSyncFileName('Passwords.KDBX.LOCK'), isTrue);
    expect(isTransientSyncFileName(r'~$report.docx'), isTrue);

    expect(isTransientSyncFileName('passwords.kdbx'), isFalse);
    expect(isTransientSyncFileName('yarn.lock'), isFalse);
    expect(isTransientSyncFileName(r'a~$b.txt'), isFalse);
  });
}
